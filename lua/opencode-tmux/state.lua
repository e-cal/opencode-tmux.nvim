local M = {}

M.opts = {
	enabled = true,
	cmd = "opencode --port",
	options = "-h",
	focus = false,
	allow_passthrough = false,
	auto_close = false,
	find_sibling = true,
}

M.pane_id = nil
M.patched = false
M.original_get_all = nil
M.original_get = nil

return M
