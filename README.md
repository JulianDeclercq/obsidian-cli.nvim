# obsidian-cli.nvim

Neovim plugin for managing an [Obsidian](https://obsidian.md) vault. Provides note creation, search, wikilink navigation, and native `[[` completion.

Requires **Neovim 0.12+** and the [obsidian CLI](https://obsidian.md/help/cli) binary.

## Setup

### With native `vim.pack` (Neovim 0.12+)

Add the plugin to your `vim.pack.add` call:

```lua
vim.pack.add {
  'https://github.com/JulianDeclercq/obsidian-cli.nvim',
  -- ... your other plugins
}
```

Then call setup:

```lua
require('obsidian-cli').setup {
  vault = 'My Vault',                    -- vault name passed to obsidian CLI
  vault_path = '/path/to/your/vault',    -- absolute path to the vault directory
  open_strategy = 'current',             -- 'current' | 'vsplit' | 'hsplit'
  daily_notes = {
    folder = nil,                        -- subdirectory within vault, e.g. 'Daily'
    date_format = '%Y-%m-%d',
  },
}
```

### With [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'JulianDeclercq/obsidian-cli.nvim',
  lazy = false,
  opts = {
    vault = 'My Vault',                    -- vault name passed to obsidian CLI
    vault_path = '/path/to/your/vault',    -- absolute path to the vault directory
    open_strategy = 'current',             -- 'current' | 'vsplit' | 'hsplit'
    daily_notes = {
      folder = nil,                        -- subdirectory within vault, e.g. 'Daily'
      date_format = '%Y-%m-%d',
    },
  },
}
```

## Features

### Wikilink completion

Typing `[[` in any markdown file triggers a completion popup with matching notes from your vault (by ID, filename, and aliases). A "New note" option at the bottom creates a new note with generated ID and frontmatter.

- `Enter` or `<C-y>` to accept
- `<C-n>` / `<C-p>` to navigate
- Autopairs-aware (no duplicate `]]`)

### Follow link

`follow_link()` handles multiple link types:

| Syntax | Action |
|--------|--------|
| `[[note]]` | Open note in Neovim |
| `[[note\|alias]]` | Open note in Neovim |
| `[text](path)` | Open note in Neovim |
| `[text](https://url)` | Open in browser |

### Other functions

| Function | Description |
|----------|-------------|
| `create_note()` | Prompt for title, create note with frontmatter |
| `search_notes()` | Telescope picker searching by title and aliases |
| `grep_notes()` | Telescope live grep across the vault |
| `open_note()` | Open current note in the Obsidian app |
| `backlinks()` | Telescope picker showing notes that link to the current note |
| `today()` | Open or create today's daily note |
| `snippets()` | Browse Obsidian CSS snippets |
| `refresh_cache()` | Force a full vault cache rebuild |

## Vault path

The `vault_path` option must be an absolute path to your vault directory. For cross-platform configs you can resolve it dynamically:

```lua
-- lua/config/paths.lua
local M = {}
if vim.fn.has('macunix') == 1 then
  M.obsidian = vim.fn.expand('~/Documents/Obsidian/My Vault')
elseif vim.fn.has('win32') == 1 then
  M.obsidian = 'C:/Users/You/Documents/Obsidian/My Vault'
else
  M.obsidian = vim.fn.expand('~/obsidian/My Vault')
end
return M
```

Then in your plugin spec: `vault_path = require('config.paths').obsidian`
