-- blink.cmp source for [[wikilink]] completion
-- Register in your blink config:
--   sources = {
--     default = { 'lsp', 'path', 'snippets', 'buffer', 'obsidian_cli' },
--     providers = {
--       obsidian_cli = { name = 'ObsidianCLI', module = 'obsidian-cli.completion' },
--     },
--   }

local Cache       = require('obsidian-cli.cache')
local generate_id = require('obsidian-cli.util').generate_id

local Source = {}
Source.__index = Source

-- Return the search string typed after [[ (nil if cursor isn't inside [[)
local function extract_search(ctx)
  local before = ctx.cursor_before_line
    or (ctx.line and ctx.line:sub(1, ctx.cursor[2]))
    or ''
  return before:match('%[%[([^%]]*)$')
end

-- blink.cmp calls new() to instantiate the source
function Source.new()
  return setmetatable({}, Source)
end

function Source:get_trigger_characters()
  return { '[' }
end

function Source:get_completions(ctx, resolve)
  local search = extract_search(ctx)
  if search == nil then
    resolve({ is_incomplete_forward = true, is_incomplete_backward = true, items = {} })
    return
  end

  if not Source._vault or Source._vault == '' then
    resolve({ is_incomplete_forward = true, is_incomplete_backward = true, items = {} })
    return
  end

  local notes = Cache.get(Source._vault)

  -- Column positions for the textEdit range (0-indexed).
  -- We replace the search text AND any ]] already in the buffer (e.g. from autopairs).
  local col        = ctx.cursor[2]
  local start_char = col - #search
  local row_0      = ctx.cursor[1] - 1
  local after      = ctx.line and ctx.line:sub(col + 1) or ''  -- text after cursor
  local end_col    = col + (after:match('^%]%]') and 2 or 0)  -- consume ]] if present

  local items = {}
  local q = search:lower()

  for _, note in ipairs(notes) do
    local seen = {}
    local candidates = { note.id, note.stem }
    for _, a in ipairs(note.aliases) do candidates[#candidates + 1] = a end
    for _, label in ipairs(candidates) do
      if label and label ~= '' and not seen[label] and label:lower():find(q, 1, true) then
        seen[label] = true
        local target = note.id or note.stem
        items[#items + 1] = {
          label    = label,
          kind     = 12, -- Value
          textEdit = {
            newText = target .. ((label ~= target) and ('|' .. label) or '') .. ']]',
            range   = {
              start   = { line = row_0, character = start_char },
              ['end'] = { line = row_0, character = end_col },
            },
          },
        }
      end
    end
  end

  -- "Create: <search>" item — ID generated now so textEdit already has final form.
  -- Memoize per search string so rapid keystrokes don't burn a new ID each time.
  if search ~= '' then
    if self._last_create_search ~= search then
      self._last_create_search = search
      self._last_create_id     = generate_id()
    end
    local new_id = self._last_create_id
    items[#items + 1] = {
      label         = 'Create: ' .. search,
      kind          = 12,
      _create_title = search,
      _create_id    = new_id,
      textEdit      = {
        newText = new_id .. '|' .. search .. ']]',
        range   = {
          start   = { line = row_0, character = start_char },
          ['end'] = { line = row_0, character = end_col },
        },
      },
    }
  end

  resolve({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
end

-- Called by blink when the user confirms a completion item
function Source:execute(ctx, item)
  if not item._create_title then return end
  local title = item._create_title
  local id    = item._create_id
  local buf   = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1] - 1  -- capture now, before async
  local ns    = vim.api.nvim_create_namespace('obsidian_cli_completion')
  local mark  = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {})
  local cli   = require('obsidian-cli')
  cli._run_async({ 'create', 'name=' .. title }, function(lines)
    if not lines then return end
    local path      = cli._resolve_note_path(title)
    local actual_id = cli._write_frontmatter(path, title, id)
    if not actual_id then return end
    if actual_id ~= id then
      vim.schedule(function()
        local pos         = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
        local current_row = pos[1]
        vim.api.nvim_buf_del_extmark(buf, ns, mark)
        local line     = vim.api.nvim_buf_get_lines(buf, current_row, current_row + 1, false)[1]
        local old_link = '[[' .. id .. '|' .. title .. ']]'
        local new_link = '[[' .. actual_id .. '|' .. title .. ']]'
        local patched  = line:gsub(vim.pesc(old_link), function() return new_link end, 1)
        if patched ~= line then
          vim.api.nvim_buf_set_lines(buf, current_row, current_row + 1, false, { patched })
        end
      end)
    end
    Cache.add(actual_id, title, path)
    vim.schedule(function()
      vim.notify('[obsidian] created: ' .. title .. '  [' .. actual_id .. ']', vim.log.levels.DEBUG)
    end)
  end)
end

return Source
