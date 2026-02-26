local state = require("opencode-tmux.state")
local tmux = require("opencode-tmux.tmux")
local patch = require("opencode-tmux.patch")

local M = {}

---@class opencode_tmux.Opts
---@field enabled? boolean
---@field cmd? string
---@field options? string
---@field focus? boolean
---@field allow_passthrough? boolean
---@field auto_close? boolean
---@field find_sibling? boolean

---@param opts? opencode_tmux.Opts
function M.setup(opts)
	state.opts = vim.tbl_deep_extend("force", state.opts, opts or {})
	if state.opts.enabled == false then
		return
	end

	local ok, config = pcall(require, "opencode.config")
	if not ok then
		return
	end

	config.opts.server = config.opts.server or {}
	config.opts.server.start = tmux.start
	config.opts.server.stop = tmux.stop
	config.opts.server.toggle = tmux.toggle

	patch.apply()
end

return M
