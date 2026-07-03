-- Native [[ wikilink completion for markdown files (Neovim 0.12+)
local M = {}

local generate_id = require('obsidian-cli.util').generate_id

-- Memoize the "New note" ID so rapid keystrokes don't burn a new one each time
local last_create_search = nil
local last_create_id = nil

function M.setup(vault_path)
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = vim.api.nvim_create_augroup('obsidian-wikilink-complete', { clear = true }),
    pattern = '*.md',
    callback = function()
      local line = vim.api.nvim_get_current_line()
      local col = vim.fn.col '.'
      local before = line:sub(1, col - 1)
      local search = before:match '%[%[([^%]]*)$'
      if not search then return end
      local after = line:sub(col)
      local suffix = after:match '^%]%]' and '' or ']]'

      local Cache = require 'obsidian-cli.cache'
      local notes = Cache.get(vault_path)
      local q = search:lower()
      local items = {}

      for _, note in ipairs(notes) do
        local seen = {}
        local candidates = { note.id, note.stem }
        for _, a in ipairs(note.aliases) do candidates[#candidates + 1] = a end
        for _, label in ipairs(candidates) do
          if label and label ~= '' and not seen[label] and label:lower():find(q, 1, true) then
            seen[label] = true
            local target = note.id or note.stem
            local text = target .. ((label ~= target) and ('|' .. label) or '') .. suffix
            items[#items + 1] = { word = text, abbr = label, menu = '[Obsidian]' }
          end
        end
      end

      -- "New note: <search>" as the last item
      if search ~= '' then
        if last_create_search ~= search then
          last_create_search = search
          last_create_id = generate_id()
        end
        local text = last_create_id .. '|' .. search .. suffix
        items[#items + 1] = { word = text, abbr = 'New note: ' .. search, menu = '[Create]', user_data = { create_title = search, create_id = last_create_id } }
      end

      if #items > 0 then
        local saved = vim.o.completeopt
        vim.o.completeopt = 'menuone,noinsert,noselect'
        local start_col = col - #search
        vim.fn.complete(start_col, items)
        vim.o.completeopt = saved
      end
    end,
  })

  -- Handle note creation when the "New note" item is accepted
  vim.api.nvim_create_autocmd('CompleteDone', {
    group = vim.api.nvim_create_augroup('obsidian-wikilink-create', { clear = true }),
    pattern = '*.md',
    callback = function()
      local completed = vim.v.completed_item
      if not completed or not completed.user_data then return end

      local data = completed.user_data
      -- user_data arrives as a JSON string from vim.fn.complete; decode it
      if type(data) == 'string' then
        local ok, parsed = pcall(vim.json.decode, data)
        if not ok then return end
        data = parsed
      end

      if not data.create_title then return end

      local title = data.create_title
      local path, id = require('obsidian-cli.util').create_note_file(vault_path, title, data.create_id)
      if not path then
        vim.notify('[obsidian] ' .. id, vim.log.levels.ERROR)
        return
      end

      require('obsidian-cli.cache').add(id, title, path)
      vim.notify('[obsidian] created: ' .. title .. '  [' .. id .. ']', vim.log.levels.INFO)
    end,
  })

  -- Map <CR> to accept completion (like blink's preset='enter') in markdown buffers.
  -- When the completion popup is visible, <CR> confirms the selection without inserting a newline.
  -- When no popup is visible, <CR> behaves normally.
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('obsidian-complete-cr', { clear = true }),
    pattern = 'markdown',
    callback = function(ev)
      vim.keymap.set('i', '<CR>', function()
        return vim.fn.pumvisible() == 1 and '<C-y>' or '<CR>'
      end, { buffer = ev.buf, expr = true })
    end,
  })
end

return M
