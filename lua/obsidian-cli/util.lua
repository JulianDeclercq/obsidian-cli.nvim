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

-- Create a new note file named <id>.md at the vault root with standard
-- frontmatter. Single source of truth for both create_note and the wikilink
-- completion "New note" flow, so the two can't drift. Returns path, id on
-- success or nil, err on failure.
function M.create_note_file(vault_path, title, id)
  id = id or M.generate_id()
  local root = vault_path:gsub('\\', '/'):gsub('/+$', '')
  local path = root .. '/' .. id .. '.md'
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
