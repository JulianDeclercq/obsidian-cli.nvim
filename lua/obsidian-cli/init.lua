local M = {}

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

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  -- Inject vault path into the completion module so it knows where to scan
  local vault = norm_vault()
  if vault ~= '' then
    local ok, comp = pcall(require, 'obsidian-cli.completion')
    if ok then comp._vault = vault end
  end
end

local function generate_id()
  local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local suffix = ''
  for _ = 1, 4 do
    local i = math.random(1, #chars)
    suffix = suffix .. chars:sub(i, i)
  end
  return tostring(os.time()) .. '-' .. suffix
end

-- Returns the id that was written (or already present), nil on failure.
local function write_frontmatter(path, title)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()

  if content:match('^%-%-%-') then
    -- Already has frontmatter — extract existing id and leave file untouched
    return content:match('\nid:%s*(.-)%s*\n')
  end

  local id = generate_id()
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
  if not out then return id end
  out:write(fm .. content)
  out:close()
  return id
end

-- Run a CLI command synchronously. args is a list of extra arguments.
-- vault=<name> is appended automatically if configured.
local function run(args)
  local argv = { config.bin }
  for _, a in ipairs(args) do table.insert(argv, a) end
  if config.vault then table.insert(argv, 'vault=' .. config.vault) end
  local output = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    vim.notify('obsidian-cli: command failed: ' .. table.concat(argv, ' '), vim.log.levels.ERROR)
    return {}
  end
  local lines = {}
  for line in output:gmatch('[^\r\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' then table.insert(lines, trimmed) end
  end
  return lines
end

-- Run a CLI command asynchronously. args is a list of extra arguments.
-- vault=<name> is appended automatically if configured.
-- Calls cb(lines) on success, cb(nil) on error.
local function run_async(args, cb)
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
-- Falls back to vault_path/name.md if not found.
local function resolve_note_path(name)
  local vault = norm_vault()
  local filename = (name:match('[^/\\]+$') or name):gsub('%.md$', '') .. '.md'
  if vault ~= '' then
    local escaped = filename:gsub('([%[%]{}*?])', '\\%1')
    local matches = vim.fn.globpath(vault, '**/' .. escaped, false, true)
    if matches and #matches > 0 then
      return matches[1]
    end
    return vault .. '/' .. filename
  end
  return filename
end

local function open_in_nvim(name)
  local path = resolve_note_path(name)
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
  local path = resolve_note_path(raw)
  return {
    value = raw,
    display = raw,
    ordinal = raw,
    filename = path,
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
      local id = write_frontmatter(path, title)
      -- Append to completion cache so [[ shows it immediately
      local ok, comp = pcall(require, 'obsidian-cli.completion')
      if ok and id then comp.add_to_cache(id, title) end
      open_in_nvim(title)
    end)
  end)
end

-- Follow [[wikilink]] under cursor, open in nvim
function M.follow_link()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local name = nil
  for s, content, e in line:gmatch('()%[%[([^%]]+)%]%]()') do
    if col >= s and col <= e then
      name = content:match('^([^|#]+)')
      break
    end
  end
  if not name or name == '' then
    vim.notify('obsidian-cli: no wikilink found under cursor', vim.log.levels.WARN)
    return
  end
  name = name:match('^%s*(.-)%s*$')
  open_in_nvim(name)
end

-- Pick from all vault notes with Telescope, open selected in nvim
function M.quick_switch()
  run_async({ 'files' }, function(lines)
    if not lines or #lines == 0 then
      vim.notify('obsidian-cli: no files found', vim.log.levels.WARN)
      return
    end
    telescope_pick(lines, 'Obsidian: Quick Switch', function(name)
      open_in_nvim(name)
    end)
  end)
end

-- Search notes by filename with a live Telescope finder
function M.find_notes()
  local vault = norm_vault()
  if vault == '' then
    vim.notify('obsidian-cli: vault_path not configured', vim.log.levels.WARN)
    return
  end
  require('telescope.builtin').find_files {
    cwd = vault,
    prompt_title = 'Obsidian: Find Notes',
    follow = true,
  }
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

-- Internals re-exported for completion.lua (avoids circular dependency issues)
M._run_async        = run_async
M._resolve_note_path = resolve_note_path
M._write_frontmatter = write_frontmatter

-- Force a full completion cache rebuild (useful if notes were edited outside nvim)
function M.refresh_cache()
  local ok, comp = pcall(require, 'obsidian-cli.completion')
  if ok then comp.refresh(norm_vault()) end
end

return M
