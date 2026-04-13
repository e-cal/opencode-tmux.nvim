local M = {}
local config = require("opencode-tmux.config")

M.opts = vim.deepcopy(config.defaults)

M.pane_id = nil
M.patched = false
M.original_get_all = nil
M.original_get = nil
M.original_prompt = nil
M.original_sse_subscribe = nil
M.hidden_pane_spec = nil
M.last_event_ms = nil
M.last_event_type = nil
M.sse_target_directory_by_port = {}
M.sse_target_session_id_by_port = {}
M.sse_target_pane_by_port = {}

return M
