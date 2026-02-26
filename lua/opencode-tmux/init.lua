local state = require("opencode-tmux.state")
local tmux = require("opencode-tmux.tmux")
local patch = require("opencode-tmux.patch")
local config = require("opencode-tmux.config")

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
	state.opts = config.setup(opts)
	if state.opts.enabled == false then
		return
	end

	local ok, opencode_config = pcall(require, "opencode.config")
	if not ok then
		return
	end

	opencode_config.opts.server = opencode_config.opts.server or {}
	opencode_config.opts.server.start = tmux.start
	opencode_config.opts.server.stop = tmux.stop
	opencode_config.opts.server.toggle = tmux.toggle

	patch.apply()
end

return M
