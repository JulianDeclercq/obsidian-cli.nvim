-- blink.cmp source for [[wikilink]] completion
-- Register in your blink config:
--   sources = {
--     default = { 'lsp', 'path', 'snippets', 'buffer', 'obsidian_cli' },
--     providers = {
--       obsidian_cli = { name = 'ObsidianCLI', module = 'obsidian-cli.completion' },
--     },
--   }

local Source = {}
Source.__index = Source


-- Vault-wide cache: built lazily on first [[ trigger, appended on create_note()
-- nil = not yet built; {} = built but empty
local cache = nil

-- Parse only the frontmatter block of a file (stops at closing --- or line 50)
local function parse_frontmatter(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local result = { id = nil, aliases = {} }
  local in_fm, in_aliases, n = false, false, 0
  for line in f:lines() do
    n = n + 1
    if n == 1 then
      if line:match('^%-%-%-') then in_fm = true else break end
    elseif in_fm then
      if line:match('^%-%-%-') then break end
      local id = line:match('^id:%s*(.+)')
      if id then result.id = id:match('^%s*(.-)%s*$') end
      if line:match('^aliases:') then
        in_aliases = true
      elseif in_aliases then
        local a = line:match('^%s*-%s+(.+)')
        if a then
          table.insert(result.aliases, a:match('^%s*(.-)%s*$'))
        elseif not line:match('^%s') then
          in_aliases = false
        end
      end
    end
    if n > 50 then break end
  end
  f:close()
  return result
end

-- Scan every .md file in vault_path and populate the cache
local function build_cache(vault_path)
  local paths = vim.fn.globpath(vault_path, '**/*.md', false, true)
  local notes = {}
  for _, p in ipairs(paths) do
    local info = parse_frontmatter(p)
    local stem = vim.fn.fnamemodify(p, ':t:r')
    notes[#notes + 1] = {
      id      = (info and info.id) or stem,
      aliases = (info and info.aliases) or {},
      stem    = stem,
    }
  end
  cache = notes
end

-- Append a single newly-created note without rescanning the vault
function Source.add_to_cache(id, title)
  if cache then
    cache[#cache + 1] = { id = id, aliases = { title }, stem = title }
  end
  -- If cache isn't built yet the lazy build on next [[ will pick it up anyway
end

-- Force a full vault rescan (manual escape hatch for external edits)
function Source.refresh(vault_path)
  build_cache(vault_path)
end

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

  -- Lazy cache build on first request
  if cache == nil then
    if not Source._vault or Source._vault == '' then
      resolve({ is_incomplete_forward = true, is_incomplete_backward = true, items = {} })
      return
    end
    build_cache(Source._vault)
  end

  -- Column positions for the textEdit range (0-indexed).
  -- We replace the search text AND any ]] already in the buffer (e.g. from autopairs).
  local col        = ctx.cursor[2]
  local start_char = col - #search
  local row_0      = ctx.cursor[1] - 1
  local after      = ctx.line and ctx.line:sub(col + 1) or ''  -- text after cursor
  local end_col    = col + (after:match('^%]%]') and 2 or 0)  -- consume ]] if present

  local items = {}
  local q = search:lower()

  for _, note in ipairs(cache) do
    local seen = {}
    local candidates = { note.id, note.stem }
    for _, a in ipairs(note.aliases) do candidates[#candidates + 1] = a end
    for _, label in ipairs(candidates) do
      if label and label ~= '' and not seen[label] and label:lower():find(q, 1, true) then
        seen[label] = true
        items[#items + 1] = {
          label    = label,
          kind     = 12, -- Value
          textEdit = {
            newText = note.stem .. ((label ~= note.stem) and ('|' .. label) or '') .. ']]',
            range   = {
              start   = { line = row_0, character = start_char },
              ['end'] = { line = row_0, character = end_col },
            },
          },
        }
      end
    end
  end

  -- "Create: <search>" item
  if search ~= '' then
    items[#items + 1] = {
      label         = 'Create: ' .. search,
      kind          = 12,
      _create_title = search,
      textEdit      = {
        newText = search .. ']]',
        range   = {
          start   = { line = row_0, character = start_char },
          ['end'] = { line = row_0, character = col },
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
  local cli = require('obsidian-cli')
  cli._run_async({ 'create', 'name=' .. title }, function(lines)
    if not lines then return end
    local path = cli._resolve_note_path(title)
    local id = cli._write_frontmatter(path, title)
    if id then Source.add_to_cache(id, title) end
  end)
end

return Source
