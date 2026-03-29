local M = {}

math.randomseed(vim.loop.hrtime())

function M.generate_id()
  local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local suffix = ''
  for _ = 1, 4 do
    local i = math.random(1, #chars)
    suffix = suffix .. chars:sub(i, i)
  end
  return tostring(os.time()) .. '-' .. suffix
end

return M
