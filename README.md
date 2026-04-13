# opencode-tmux.nvim

Tmux extension for [`opencode.nvim`](https://github.com/NickvanDyke/opencode.nvim).

`opencode.nvim` is required. This plugin does not work standalone. When not running inside tmux, it silently no-ops.

It provides tmux-backed server management with sibling-aware patching and helper APIs:

- **tmux-backed `server.start/stop/toggle`** — opens opencode in a tmux split pane
- **toggle with persist** — when `auto_close = false` (default), toggling hides/restores the pane instead of killing it, preserving your opencode session
- **sibling-pane discovery** — finds opencode servers running in other panes of the same tmux window
- **server/prompt patching** — patches `opencode.cli.server` and prompt routing so connect stays sibling-first while prompt send opens a sibling-pane picker
- **session-scoped isolation** — subscribes via `/global/event` and filters by directory + session ID; sends prompts directly via `/session/:id/message` to target the exact attached session
- **wrapper APIs** — explicit `connect()`, `prompt()`, and `servers()` helpers for direct usage

## Setup

Use `lazy.nvim` and load this plugin as a dependency of `opencode.nvim`.

If you use `connect_keymap`, set `lazy = false` so the mapping is registered at startup:

```lua
{
  "nickvandyke/opencode.nvim",
  dependencies = {
    {
      "e-cal/opencode-tmux.nvim",
      lazy = false,
      opts = {
        options = "-h",
        focus = false,
        auto_close = false,
        allow_passthrough = false,
        find_sibling = true,
        connect_keymap = "<leader>O",
        connect_launch = false,
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
| `debug` | `boolean` | `false` | Enable debug logging to `/tmp/opencode-tmux-debug.log` (heartbeats ignored). |
| `connect_keymap` | `string \| false` | `false` | Optional normal-mode keymap for `require("opencode-tmux").connect()`. Example: `"<leader>O"`. |
| `connect_launch` | `boolean` | `false` | Whether `connect()` should start a new tmux-managed server when no sibling is found. |

## Wrapper APIs

These helpers are exported in addition to the patched default behavior:

```lua
require("opencode-tmux").connect()
require("opencode-tmux").prompt("Fix failing tests", { new = true, submit = true })
require("opencode-tmux").servers()
```

- `connect()` uses `connect_launch` by default.
- `connect({ launch = true })` overrides the default and allows launching a new tmux-managed server.
- `prompt()` renders context, asks which sibling opencode pane to target, then sends there via tmux.
- `prompt(..., { new = true })` sends `Ctrl+x` then `n` before any other prompt keys/text.
- `servers()` returns discovered sibling servers (unique by port).


## Sibling discovery

When `find_sibling = true`, the plugin scans all panes in the current tmux window for running opencode processes and resolves their listening ports. This means:

- Built-in `opencode.nvim` flows use sibling-first behavior through patched server discovery/routing.
- `connect()` and `prompt()` can also be called directly for explicit control.
- `connect()` still auto-targets the inferred sibling pane/session, while prompt sending asks you to choose from sibling opencode panes shown as `[pane_index] Title`.
- If no sibling server is found and launching is enabled, connect starts a tmux-managed split and retries discovery.

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
