# opencode-tmux.nvim

Tmux extension for [`opencode.nvim`](https://github.com/NickvanDyke/opencode.nvim).

`opencode.nvim` is required. This plugin does not work standalone. When not running inside tmux, it silently no-ops.

It overrides `opencode.nvim`'s server management with tmux-backed implementations:

- **tmux-backed `server.start/stop/toggle`** — opens opencode in a tmux split pane
- **toggle with persist** — when `auto_close = false` (default), toggling hides/restores the pane instead of killing it, preserving your opencode session
- **sibling-pane discovery** — finds opencode servers running in other panes of the same tmux window
- **connection priority** — connects to sibling panes first, falls back to default `opencode.nvim` server selection

## Setup

Use `lazy.nvim` and load this plugin as a dependency of `opencode.nvim`:

```lua
{
  "nickvandyke/opencode.nvim",
  dependencies = {
    {
      "e-cal/opencode-tmux.nvim",
      opts = {
        options = "-h",
        focus = false,
        auto_close = false,
        allow_passthrough = false,
        find_sibling = true,
      },
    },
  },
}
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | `boolean` | `true` | Enable extension. |
| `cmd` | `string` | `"opencode --port"` | Command to run in the tmux split to launch opencode. If `opencode.nvim` has a `server.port` configured and the cmd doesn't already include `--port`, the port flag is appended automatically. |
| `options` | `string` | `"-h"` | Arguments passed to `tmux split-window`. For example, `"-h"` creates a horizontal (side-by-side) split, `"-h -l 30%"` makes it 30% wide. |
| `focus` | `boolean` | `false` | Focus the opencode pane after opening. |
| `allow_passthrough` | `boolean` | `false` | When `false`, explicitly sets `allow-passthrough off` on the pane, fixing some escape sequence leak issues (see [here](https://github.com/nickjvandyke/opencode.nvim/pull/144) for more details). When `true`, inherits the tmux default. |
| `find_sibling` | `boolean` | `true` | Discover opencode servers in sibling tmux panes (same window). Enables the sibling-first connection priority. |
| `auto_close` | `boolean` | `false` | Controls toggle/stop behavior. See [Toggle behavior](#toggle-behavior). |


## Sibling discovery

When `find_sibling = true`, the plugin scans all panes in the current tmux window for running opencode processes and resolves their listening ports. This means:

- If you already have opencode running in another pane, `opencode.nvim` will connect to it automatically instead of spawning a new one.
- `server.get_all` merges both the standard server list and any discovered siblings.
- `server.get` tries siblings first. If there's exactly one, it connects directly. If there are multiple, it shows a selection UI.

## Toggle behavior

The `toggle` function (called by `opencode.toggle()`) behaves differently based on `auto_close`:

### `auto_close = false` (default)

Toggling **hides** the pane instead of killing it. The opencode process stays alive, and toggling again **restores** it in the same state.

Under the hood, this uses `tmux break-pane` to move the pane to a hidden session (`__opencode_stash`) and `tmux join-pane` to bring it back. The stash session is automatically cleaned up when the pane is restored or when neovim exits.

| Action | Result |
|--------|--------|
| Toggle (pane visible) | Pane is hidden, process stays alive |
| Toggle (pane hidden) | Pane is restored to original position |
| Toggle (no pane) | New pane is created via `start` |
| `stop` | No-op (pane is preserved) |
| Exit neovim | Hidden pane is killed, stash session cleaned up |

### `auto_close = true`

Toggling **kills** the pane and the opencode process. Each toggle on creates a fresh session.

| Action | Result |
|--------|--------|
| Toggle (pane visible) | Pane is killed |
| Toggle (no pane) | New pane is created via `start` |
| `stop` | Pane is killed |

