local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")

local M = {}

---@return string|nil
local function get_current_pane_id()
	if not system.in_tmux() then
		return nil
	end
	local pane_id = system.run({ "tmux", "display-message", "-p", "#{pane_id}" })
	if pane_id == "" then
		return nil
	end
	return pane_id
end

---@param pane_id string
---@return boolean
local function pane_exists(pane_id)
	local result = vim.system({ "tmux", "list-panes", "-t", pane_id }, { text = true }):wait()
	return result.code == 0
end

---@return string|nil
function M.get_managed_pane_id()
	local pane_id = state.pane_id
	if not pane_id then
		return nil
	end
	if pane_exists(pane_id) then
		return pane_id
	end
	state.pane_id = nil
	return nil
end

---@return string
local function build_cmd()
	local configured = require("opencode.config").opts.server or {}
	local cmd = state.opts.cmd or "opencode --port"
	if configured.port and not cmd:match("%-%-port") then
		cmd = cmd .. " --port " .. tostring(configured.port)
	end
	return cmd
end

function M.start()
	if not system.in_tmux() then
		system.notify("tmux not available", vim.log.levels.WARN)
		return
	end

	if M.get_managed_pane_id() then
		return
	end

	local args = { "tmux", "split-window" }
	if not state.opts.focus then
		table.insert(args, "-d")
	end
	if state.opts.options and state.opts.options ~= "" then
		for _, token in ipairs(vim.split(state.opts.options, "%s+", { trimempty = true })) do
			table.insert(args, token)
		end
	end
	table.insert(args, "-P")
	table.insert(args, "-F")
	table.insert(args, "#{pane_id}")
	table.insert(args, build_cmd())

	local created = system.run(args)
	if created == "" then
		system.notify("failed to create tmux pane", vim.log.levels.ERROR)
		return
	end

	state.pane_id = created
	if state.opts.allow_passthrough ~= true then
		vim.system({ "tmux", "set-option", "-t", created, "-p", "allow-passthrough", "off" }, { text = true }):wait()
	end
end

function M.stop()
	local pane_id = M.get_managed_pane_id()
	if pane_id and state.opts.auto_close ~= false then
		vim.system({ "tmux", "kill-pane", "-t", pane_id }, { text = true }):wait()
		state.pane_id = nil
	end
end

function M.toggle()
	if M.get_managed_pane_id() then
		M.stop()
	else
		M.start()
	end
end

---@return string|nil
function M.current_pane_id()
	return get_current_pane_id()
end

return M
