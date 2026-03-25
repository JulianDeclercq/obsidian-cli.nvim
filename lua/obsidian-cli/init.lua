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

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
end

local function run(cmd)
  local vault_flag = config.vault and ('--vault ' .. config.vault .. ' ') or ''
  local full_cmd = config.bin .. ' ' .. vault_flag .. cmd
  local output = vim.fn.system(full_cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify('obsidian-cli: command failed: ' .. full_cmd, vim.log.levels.ERROR)
    return {}
  end
  local lines = {}
  for line in output:gmatch('[^\r\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      table.insert(lines, trimmed)
    end
  end
  return lines
end

-- Run cmd asynchronously, call cb(lines) on success or cb(nil) on error.
local function run_async(cmd, cb)
  local vault_flag = config.vault and ('--vault ' .. config.vault .. ' ') or ''
  local full_cmd = config.bin .. ' ' .. vault_flag .. cmd
  vim.system(vim.split(full_cmd, '%s+'), { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        vim.notify('obsidian-cli: command failed: ' .. full_cmd, vim.log.levels.ERROR)
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
  local vault = (config.vault_path or ''):gsub('\\', '/'):gsub('/+$', '')
  local filename = (name:match('[^/\\]+$') or name):gsub('%.md$', '') .. '.md'
  if vault ~= '' then
    local matches = vim.fn.globpath(vault, '**/' .. filename, false, true)
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

local function current_note_name()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' then return nil end
  path = path:gsub('\\', '/')
  if config.vault_path then
    local vp = config.vault_path:gsub('\\', '/'):gsub('/+$', '')
    local rel = path:match('^' .. vim.pesc(vp) .. '/(.+)$')
    if rel then path = rel end
  end
  path = path:gsub('%.md$', '')
  return path
end

local function quote(val)
  -- Escape internal double-quotes then wrap in double-quotes if value has spaces.
  local escaped = val:gsub('"', '\\"')
  if escaped:find('%s') then
    return '"' .. escaped .. '"'
  end
  return escaped
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
    run('create name=' .. quote(title))
    open_in_nvim(title)
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
  run_async('files', function(lines)
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
  local vault = (config.vault_path or ''):gsub('\\', '/')
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
  local vault = (config.vault_path or ''):gsub('\\', '/')
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
  run('open file=' .. quote(name))
end

-- Show backlinks to current note in Telescope, open selected in nvim
function M.backlinks()
  local name = current_note_name()
  if not name then
    vim.notify('obsidian-cli: no active note', vim.log.levels.WARN)
    return
  end
  run_async('backlinks file=' .. quote(name), function(lines)
    if not lines or #lines == 0 then
      vim.notify('obsidian-cli: no backlinks for "' .. name .. '"', vim.log.levels.INFO)
      return
    end
    telescope_pick(lines, 'Obsidian: Backlinks – ' .. name, function(link)
      open_in_nvim(link)
    end)
  end)
end

-- Open today's daily note in nvim.
-- Computes path locally from config.daily_notes settings; falls back to CLI.
function M.today()
  local dn = config.daily_notes
  if dn and dn.date_format then
    local vault = (config.vault_path or ''):gsub('\\', '/'):gsub('/+$', '')
    local date_str = os.date(dn.date_format)
    local folder = dn.folder and (vault .. '/' .. dn.folder) or vault
    local path = folder .. '/' .. date_str .. '.md'
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  else
    local lines = run('daily:path')
    if #lines == 0 then
      vim.notify("obsidian-cli: could not get today's note path", vim.log.levels.ERROR)
      return
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(lines[1]:gsub('\\', '/')))
  end
end

-- Browse and edit Obsidian CSS snippets in nvim via Telescope
function M.snippets()
  local vault = (config.vault_path or ''):gsub('\\', '/')
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

return M
