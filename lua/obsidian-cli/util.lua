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

return M
