-- Vault-wide note cache shared by completion and search.
-- nil = not yet built; {} = built but empty
local _cache = nil

-- Parse only the frontmatter block of a file (stops at closing --- or line 50)
local function parse_frontmatter(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
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
      path    = p,
    }
  end
  _cache = notes
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
  if _cache then
    local stem = path and vim.fn.fnamemodify(path, ':t:r') or title
    _cache[#_cache + 1] = { id = id, aliases = { title }, stem = stem, path = path }
  end
  -- If cache isn't built yet the lazy build on next access will pick it up anyway
end

-- Remove a note by path (called on :DeleteFile)
function Cache.remove(path)
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

return Cache
