local M = {}

local _seeded = false

function M.generate_id()
  if not _seeded then
    math.randomseed(vim.uv.hrtime())
    _seeded = true
  end
  local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local suffix = ''
  for _ = 1, 4 do
    local i = math.random(1, #chars)
    suffix = suffix .. chars:sub(i, i)
  end
  return tostring(os.time()) .. '-' .. suffix
end

-- Folder for new notes, taken from the vault's own Obsidian setting
-- (.obsidian/app.json: newFileLocation + newFileFolderPath). Returns '' for
-- the vault root when the setting is absent or set to anything but 'folder'.
local function notes_folder(root)
  local f = io.open(root .. '/.obsidian/app.json', 'r')
  if not f then return '' end
  local raw = f:read('*a')
  f:close()
  local ok, cfg = pcall(vim.json.decode, raw)
  if not ok or type(cfg) ~= 'table' then return '' end
  if cfg.newFileLocation == 'folder' and type(cfg.newFileFolderPath) == 'string' and cfg.newFileFolderPath ~= '' then
    return cfg.newFileFolderPath:gsub('\\', '/'):gsub('/+$', '')
  end
  return ''
end

-- Create a new note file named <id>.md with standard frontmatter, in the
-- vault's configured new-note folder (Obsidian's app.json setting).
-- Single source of truth for both create_note and the wikilink
-- completion "New note" flow, so the two can't drift. Returns path, id on
-- success or nil, err on failure.
function M.create_note_file(vault_path, title, id)
  id = id or M.generate_id()
  local root = vault_path:gsub('\\', '/'):gsub('/+$', '')
  local folder = notes_folder(root)
  local dir = folder ~= '' and (root .. '/' .. folder) or root
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  local path = dir .. '/' .. id .. '.md'
  local content = table.concat({
    '---',
    'id: ' .. id,
    'aliases:',
    '  - ' .. title,
    'tags: []',
    '---',
    '',
  }, '\n')
  local f = io.open(path, 'w')
  if not f then return nil, 'failed to create: ' .. path end
  f:write(content)
  f:close()
  return path, id
end

return M
