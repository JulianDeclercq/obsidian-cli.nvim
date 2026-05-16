local M = {}
local util = require('obsidian-cli.util')

local config = {
  bin = 'obsidian',
  vault = nil,
  vault_path = nil,
  open_strategy = 'current', -- 'current' | 'vsplit' | 'hsplit'
  daily_notes = {
    folder = nil,        -- subdirectory within vault, e.g. 'Daily'
    date_format = '%Y-%m-%d',
  },
}

-- Normalize vault_path to a forward-slash, no-trailing-slash string.
local function norm_vault()
  return (config.vault_path or ''):gsub('\\', '/'):gsub('/+$', '')
end

local function cli_available()
  return vim.fn.executable(config.bin) == 1
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  if not cli_available() then
    vim.notify(
      "obsidian-cli: '" .. config.bin .. "' not found on PATH — create_note/open_note/backlinks will be unavailable. "
        .. 'Install it from https://obsidian.md/help/cli or set `bin` in setup().',
      vim.log.levels.WARN
    )
  end
  local vault = norm_vault()
  if vault ~= '' then
    -- Set up native [[ wikilink completion for markdown files
    require('obsidian-cli.completion').setup(vault)
    -- Pre-warm the cache at startup so search_notes() and [[ are instant
    vim.schedule(function()
      require('obsidian-cli.cache').refresh(vault)
    end)
    -- Keep aliases in sync: re-parse frontmatter whenever a vault .md is saved
    local grp = vim.api.nvim_create_augroup('obsidian-cli', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', {
      group    = grp,
      pattern  = '*.md',
      callback = function(ev)
        local path = ev.match:gsub('\\', '/')
        local path_lower  = path:lower()
        local vault_lower = vault:lower()
        if path_lower:sub(1, #vault_lower) == vault_lower then
          require('obsidian-cli.cache').update_from_file(path)
        end
      end,
    })
  end
end

local generate_id = util.generate_id

-- Returns the id that was written (or already present), nil on failure.
local function write_frontmatter(path, title, id)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()

  if content:match('^%-%-%-') then
    -- Already has frontmatter — extract existing id if present.
    local existing = content:match('\nid:%s*(.-)%s*\n')
    if existing and existing ~= '' then return existing end
    -- No id field — inject one just before the closing ---
    local new_id = id or generate_id()
    local eol    = content:find('\r\n') and '\r\n' or '\n'
    local lines  = {}
    for ln in (content .. '\n'):gmatch('([^\r\n]*)\r?\n') do
      lines[#lines + 1] = ln
    end
    local close_idx = nil
    for i = 2, #lines do
      if lines[i]:match('^%-%-%-%s*$') then
        close_idx = i
        break
      end
    end
    if close_idx then
      table.insert(lines, close_idx, 'id: ' .. new_id)
      local patched = table.concat(lines, eol)
      local out = io.open(path, 'w')
      if not out then return nil end
      out:write(patched); out:close()
    end
    return new_id
  end

  id = id or generate_id()
  local fm = table.concat({
    '---',
    'id: ' .. id,
    'aliases:',
    '  - ' .. title,
    'tags: []',
    '---',
    '',
  }, '\n')

  local out = io.open(path, 'w')
  if not out then return nil end
  out:write(fm .. content)
  out:close()
  return id
end

-- Run a CLI command synchronously. args is a list of extra arguments.
-- vault=<name> is appended automatically if configured.
local function run(args)
  if not cli_available() then
    vim.notify("obsidian-cli: '" .. config.bin .. "' not found on PATH", vim.log.levels.ERROR)
    return {}
  end
  local argv = { config.bin }
  for _, a in ipairs(args) do table.insert(argv, a) end
  if config.vault then table.insert(argv, 'vault=' .. config.vault) end
  local obj = vim.system(argv, { text = true }):wait()
  if obj.code ~= 0 then
    vim.notify('obsidian-cli: command failed: ' .. table.concat(argv, ' '), vim.log.levels.ERROR)
    return {}
  end
  local lines = {}
  for line in (obj.stdout or ''):gmatch('[^\r\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' then table.insert(lines, trimmed) end
  end
  return lines
end

-- Run a CLI command asynchronously. args is a list of extra arguments.
-- vault=<name> is appended automatically if configured.
-- Calls cb(lines) on success, cb(nil) on error.
local function run_async(args, cb)
  if not cli_available() then
    vim.notify("obsidian-cli: '" .. config.bin .. "' not found on PATH", vim.log.levels.ERROR)
    cb(nil)
    return
  end
  local argv = { config.bin }
  for _, a in ipairs(args) do table.insert(argv, a) end
  if config.vault then table.insert(argv, 'vault=' .. config.vault) end
  vim.system(argv, { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        vim.notify('obsidian-cli: command failed: ' .. table.concat(argv, ' '), vim.log.levels.ERROR)
        cb(nil)
      end)
      return
    end
    local lines = {}
    for line in (obj.stdout or ''):gmatch('[^\r\n]+') do
      local trimmed = line:match('^%s*(.-)%s*$')
      if trimmed ~= '' then table.insert(lines, trimmed) end
    end
    vim.schedule(function() cb(lines) end)
  end)
end

-- Resolve a note name to an absolute path by searching recursively in the vault.
-- Returns nil if not found.
local function resolve_note_path(name)
  local vault = norm_vault()
  local filename = (name:match('[^/\\]+$') or name):gsub('%.md$', '') .. '.md'
  if vault ~= '' then
    local escaped = filename:gsub('([%[%]{}*?])', '\\%1')
    local matches = vim.fn.globpath(vault, '**/' .. escaped, false, true)
    if matches and #matches > 0 then
      return matches[1]
    end
  end
  return nil
end

local function open_in_nvim(name)
  local path = resolve_note_path(name)
  if not path then
    vim.notify('obsidian-cli: note not found: ' .. name, vim.log.levels.WARN)
    return
  end
  local escaped = vim.fn.fnameescape(path)
  if config.open_strategy == 'vsplit' then
    vim.cmd('vsplit ' .. escaped)
  elseif config.open_strategy == 'hsplit' then
    vim.cmd('split ' .. escaped)
  else
    vim.cmd('edit ' .. escaped)
  end
end

-- Returns the note stem (filename without extension) for use as a file= CLI arg.
local function current_note_name()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' then return nil end
  return vim.fn.fnamemodify(path, ':t:r')
end

-- Build a Telescope entry table from a raw filename/path string.
-- Adds a `filename` field so native Telescope mappings (<C-t>, <C-v>, etc.) work.
local function make_entry(raw)
  return {
    value = raw,
    display = raw,
    ordinal = raw,
    filename = resolve_note_path(raw),
  }
end

local function telescope_pick(results, prompt_title, on_select)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  local entries = vim.tbl_map(make_entry, results)

  pickers.new({}, {
    prompt_title = prompt_title,
    finder = finders.new_table {
      results = entries,
      entry_maker = function(e) return e end,
    },
    sorter = conf.generic_sorter({}),
    previewer = conf.file_previewer({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          on_select(selection.value)
        end
      end)
      return true
    end,
  }):find()
end

-- Create a new note and open it in nvim
function M.create_note()
  vim.ui.input({ prompt = 'Note title: ' }, function(title)
    if not title or title == '' then return end
    run_async({ 'create', 'name=' .. title }, function(lines)
      if not lines then return end
      local path = resolve_note_path(title)
      if not path then
        vim.notify('obsidian-cli: created note but could not find file for: ' .. title, vim.log.levels.WARN)
        return
      end
      local id = write_frontmatter(path, title)
      if id then require('obsidian-cli.cache').add(id, title, path) end
      open_in_nvim(title)
    end)
  end)
end

-- Follow link under cursor: [[wikilink]], [text](path), or [text](https://url)
function M.follow_link()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Try wikilink with alias: [[target|label]]
  for s, content, e in line:gmatch('()%[%[([^][|]+|[^%]]+)%]%]()') do
    if col >= s and col <= e then
      local target = content:match('^([^|#]+)')
      if target and target ~= '' then
        open_in_nvim(target:match('^%s*(.-)%s*$'))
        return
      end
    end
  end

  -- Try plain wikilink: [[target]]
  for s, content, e in line:gmatch('()%[%[([^][|]+)%]%]()') do
    if col >= s and col <= e then
      local target = content:match('^([^#]+)')
      if target and target ~= '' then
        open_in_nvim(target:match('^%s*(.-)%s*$'))
        return
      end
    end
  end

  -- Try markdown link: [text](target)
  for s, _, target, e in line:gmatch('()%[([^][]+)%]%(([^%)]+)%)()') do
    if col >= s and col <= e then
      target = target:match('^%s*(.-)%s*$')
      if target:match('^https?://') or target:match('^mailto:') or target:match('^file:') then
        -- vim.ui.open on Windows uses cmd.exe which eats '&' in URLs.
        -- Use rundll32 with explicit quoting to preserve query params.
        if vim.fn.has('win32') == 1 then
          vim.fn.jobstart('rundll32 url.dll,FileProtocolHandler "' .. target .. '"')
        else
          vim.ui.open(target)
        end
      else
        open_in_nvim(target)
      end
      return
    end
  end

  vim.notify('obsidian-cli: no link found under cursor', vim.log.levels.WARN)
end

-- Search notes by title and aliases using the vault cache
function M.search_notes()
  local vault = norm_vault()
  if vault == '' then
    vim.notify('obsidian-cli: vault_path not configured', vim.log.levels.WARN)
    return
  end
  local notes = require('obsidian-cli.cache').get(vault)

  local pickers      = require('telescope.pickers')
  local finders      = require('telescope.finders')
  local conf         = require('telescope.config').values
  local actions      = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  local entries = {}
  for _, note in ipairs(notes) do
    local parts = { note.stem }
    for _, a in ipairs(note.aliases) do
      if a ~= note.stem then parts[#parts + 1] = a end
    end
    local display = note.aliases[1]
                    and (note.aliases[1] .. ' [' .. note.stem .. ']')
                    or note.stem
    entries[#entries + 1] = {
      value    = note.stem,
      display  = display,
      ordinal  = table.concat(parts, ' '),
      filename = note.path or resolve_note_path(note.stem),
    }
  end

  pickers.new({}, {
    prompt_title = 'Obsidian: Search Notes',
    finder = finders.new_table { results = entries, entry_maker = function(e) return e end },
    sorter    = conf.generic_sorter({}),
    previewer = conf.file_previewer({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local sel = action_state.get_selected_entry()
        if sel then open_in_nvim(sel.value) end
      end)
      return true
    end,
  }):find()
end

-- Full-text grep across notes with a live Telescope grep window
function M.grep_notes()
  local vault = norm_vault()
  if vault == '' then
    vim.notify('obsidian-cli: vault_path not configured', vim.log.levels.WARN)
    return
  end
  require('telescope.builtin').live_grep {
    cwd = vault,
    prompt_title = 'Obsidian: Grep Notes',
  }
end

-- Open current note in the Obsidian app
function M.open_note()
  local name = current_note_name()
  if not name then
    vim.notify('obsidian-cli: no active note', vim.log.levels.WARN)
    return
  end
  run({ 'open', 'file=' .. name })
end

-- Show backlinks to current note in Telescope, open selected in nvim
function M.backlinks()
  local name = current_note_name()
  if not name then
    vim.notify('obsidian-cli: no active note', vim.log.levels.WARN)
    return
  end
  run_async({ 'backlinks', 'file=' .. name }, function(lines)
    if not lines or #lines == 0 then
      vim.notify('obsidian-cli: no backlinks for "' .. name .. '"', vim.log.levels.INFO)
      return
    end
    telescope_pick(lines, 'Obsidian: Backlinks – ' .. name, function(link)
      open_in_nvim(link)
    end)
  end)
end

-- Open today's daily note in nvim
function M.today()
  local vault = norm_vault()
  local dn = config.daily_notes
  local folder = dn.folder and (vault .. '/' .. dn.folder) or vault
  local path = folder .. '/' .. os.date(dn.date_format) .. '.md'
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

-- Browse and edit Obsidian CSS snippets in nvim via Telescope
function M.snippets()
  local vault = norm_vault()
  if vault == '' then
    vim.notify('obsidian-cli: vault_path not configured', vim.log.levels.WARN)
    return
  end
  require('telescope.builtin').find_files {
    cwd = vault .. '/.obsidian/snippets',
    hidden = true,
    prompt_title = 'Obsidian Snippets',
  }
end

-- Force a full cache rebuild (useful if notes were edited outside nvim)
function M.refresh_cache()
  require('obsidian-cli.cache').refresh(norm_vault())
end

return M
