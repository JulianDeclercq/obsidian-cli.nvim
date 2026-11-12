-- Vault-wide note cache shared by completion and search.
-- nil = not yet built; {} = built but empty
local _cache = nil

-- Background scan state: _scanning = a worker-thread scan is in flight;
-- _stale = the cache was touched while it ran, so its result must be dropped.
local _scanning = false
local _stale = false

-- Parse the frontmatter block out of a note's text (stops at closing --- or line 50)
local function parse_content(content)
  local result = { id = nil, aliases = {} }
  local lines = {}
  for ln in (content .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  local in_fm, in_aliases = false, false
  for n, line in ipairs(lines) do
    if n == 1 then
      if line:match('^%-%-%-') then in_fm = true else break end
    elseif in_fm then
      if line:match('^%-%-%-') then break end
      local id = line:match('^id:%s*(.+)')
      if id then result.id = id:match('^%s*(.-)%s*$') end
      if line:match('^aliases:') then
        in_aliases = true
        -- Inline list syntax: aliases: [foo, bar]
        local bracket = line:match('^aliases:%s*%[(.-)%]')
        if bracket then
          in_aliases = false
          for item in bracket:gmatch('[^,]+') do
            local trimmed = item:match('^%s*(.-)%s*$')
            if trimmed ~= '' then
              table.insert(result.aliases, trimmed)
            end
          end
        end
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
  return result
end

-- Parse only the frontmatter block of a file
local function parse_frontmatter(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return parse_content(content)
end

-- Scan every .md file in vault_path and populate the cache (blocks the UI)
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
      path    = p,
    }
  end
  _cache = notes
  if _scanning then _stale = true end
end

-- Runs on a libuv worker thread (own Lua state: no upvalues, no vim.fn).
-- Walks the vault like globpath('**/*.md') does (dot-entries skipped) and
-- returns an mpack list of { path, frontmatter_text } pairs.
local function scan_worker(root, sep)
  local uv = vim.uv
  local out = {}
  local function head(path)
    local fd = uv.fs_open(path, 'r', 292)
    if not fd then return '' end
    local data = uv.fs_read(fd, 16384, 0) or ''
    uv.fs_close(fd)
    if data:sub(1, 3) ~= '---' then return '' end
    local _, e = data:find('\n%-%-%-', 4)
    return (e and data:sub(1, e) or data)
  end
  local function walk(dir, depth)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    local files, dirs = {}, {}
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= '.' then
        local full = dir .. sep .. name
        if typ == 'link' or not typ then
          local st = uv.fs_stat(full)
          typ = st and st.type or typ
        end
        if typ == 'directory' then
          dirs[#dirs + 1] = full
        elseif typ == 'file' and name:lower():sub(-3) == '.md' then
          files[#files + 1] = full
        end
      end
    end
    for _, f in ipairs(files) do out[#out + 1] = { f, head(f) } end
    if depth < 100 then
      for _, d in ipairs(dirs) do walk(d, depth + 1) end
    end
  end
  walk(root, 0)
  return vim.mpack.encode(out)
end

local Cache = {}

-- Return the cache, building it lazily from vault_path if not yet populated
function Cache.get(vault_path)
  if _cache == nil and vault_path and vault_path ~= '' then
    build_cache(vault_path)
  end
  return _cache or {}
end

-- Append a single newly-created note without rescanning the vault
function Cache.add(id, title, path)
  if _scanning then _stale = true end
  if _cache then
    local stem = path and vim.fn.fnamemodify(path, ':t:r') or title
    _cache[#_cache + 1] = { id = id, aliases = { title }, stem = stem, path = path }
  end
  -- If cache isn't built yet the lazy build on next access will pick it up anyway
end

-- Remove a note by path (called on :DeleteFile)
function Cache.remove(path)
  if _scanning then _stale = true end
  if not _cache then return end
  for i, note in ipairs(_cache) do
    if note.path == path then
      table.remove(_cache, i)
      return
    end
  end
end

-- Re-parse frontmatter for a saved file and update the entry if aliases/id changed.
-- Also handles notes created outside nvim (entry not yet in cache).
function Cache.update_from_file(path)
  if _scanning then _stale = true end
  if not _cache then return end
  local stem      = vim.fn.fnamemodify(path, ':t:r')
  local info      = parse_frontmatter(path)
  if not info then return end
  local new_id      = info.id or stem
  local new_aliases = info.aliases or {}
  for _, note in ipairs(_cache) do
    if note.path == path then
      if note.id ~= new_id or not vim.deep_equal(note.aliases, new_aliases) then
        note.id      = new_id
        note.aliases = new_aliases
      end
      return
    end
  end
  -- Entry not found — note created outside nvim; add it now
  _cache[#_cache + 1] = { id = new_id, aliases = new_aliases, stem = stem, path = path }
end

-- Force a full vault rescan (manual escape hatch for external edits)
function Cache.refresh(vault_path)
  build_cache(vault_path)
end

-- Build the cache on a worker thread so startup never blocks on the vault.
-- If the cache is needed (or edited) before the scan lands, the normal
-- synchronous build takes over and the scan result is discarded.
function Cache.refresh_async(vault_path)
  if _scanning or not vault_path or vault_path == '' then return end
  local sep = vim.fn.has('win32') == 1 and '\\' or '/'
  local ok, work = pcall(vim.uv.new_work, scan_worker, function(packed)
    vim.schedule(function()
      _scanning = false
      if _stale or type(packed) ~= 'string' then
        _stale = false
        return
      end
      local notes = {}
      for _, entry in ipairs(vim.mpack.decode(packed)) do
        local p = entry[1]
        local info = parse_content((entry[2]:gsub('\r\n', '\n')))
        local stem = vim.fn.fnamemodify(p, ':t:r')
        notes[#notes + 1] = { id = info.id or stem, aliases = info.aliases, stem = stem, path = p }
      end
      _cache = notes
    end)
  end)
  if not ok then return end
  _scanning, _stale = true, false
  -- globpath returns native separators; emit the same paths it would
  local root = sep == '\\' and vault_path:gsub('/', '\\') or vault_path
  if not work:queue(root, sep) then _scanning = false end
end

return Cache
