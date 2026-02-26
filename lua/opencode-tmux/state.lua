local M = {}
local config = require("opencode-tmux.config")

M.opts = vim.deepcopy(config.defaults)

M.pane_id = nil
M.patched = false
M.original_get_all = nil
M.original_get = nil

return M
