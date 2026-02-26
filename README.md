# opencode-tmux.nvim

Tmux extension for [`opencode.nvim`](https://github.com/NickvanDyke/opencode.nvim).

`opencode.nvim` is required. This plugin does not work standalone.

It adds tmux-oriented server behavior:

- tmux-backed `server.start/stop/toggle`
- optional sibling-pane server discovery
- sibling-aware `server.get_all` (prefers base discovery and fills in missing sibling ports)
- connection order: sibling pane first, then default `opencode.nvim` server selection/launch flow

## Setup

```lua
require("opencode-tmux").setup({
  options = "-h",
  focus = false,
  auto_close = false,
  allow_passthrough = false,
  find_sibling = true,
})
```

## Options

- `enabled` (boolean, default `true`)
- `cmd` (string, default `"opencode --port"`)
- `options` (string, default `"-h"`)
- `focus` (boolean, default `false`)
- `allow_passthrough` (boolean, default `false`)
- `auto_close` (boolean, default `false`)
- `find_sibling` (boolean, default `true`)
