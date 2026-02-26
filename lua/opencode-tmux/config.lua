local M = {}

---@class opencode_tmux.Opts
---@field enabled? boolean
---@field cmd? string
---@field options? string
---@field focus? boolean
---@field allow_passthrough? boolean
---@field auto_close? boolean
---@field find_sibling? boolean

---@type opencode_tmux.Opts
M.defaults = {
	enabled = true,
	cmd = "opencode --port",
	options = "-h",
	focus = false,
	allow_passthrough = false,
	auto_close = false,
	find_sibling = true,
}

---@type opencode_tmux.Opts
M.options = vim.deepcopy(M.defaults)

---@param opts? opencode_tmux.Opts
---@return opencode_tmux.Opts
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

return M
