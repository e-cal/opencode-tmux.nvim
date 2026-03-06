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

---@return string[]
local function get_user_options_args()
	local args = {}

	if not state.opts.focus then
		table.insert(args, "-d")
	end
	if state.opts.options and state.opts.options ~= "" then
		for _, token in ipairs(vim.split(state.opts.options, "%s+", { trimempty = true })) do
			table.insert(args, token)
		end
	end
	return args
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
	vim.list_extend(args, get_user_options_args())

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

function M.clean_up_stash_session()
	if state.hidden_pane_spec then
		state.hidden_pane_spec = nil
		local remaining = vim.system({ "tmux", "list-panes", "-t", "__opencode_stash" }):wait(1000)
		if remaining.code ~= 0 then
			vim.system({ "tmux", "kill-session", "-t", "__opencode_stash" }):wait(1000)
		end
	end
end

---@param pane_id string
function M.auto_toggle(pane_id)
	if not state.hidden_pane_spec then -- Hide pane
		-- Check if stash session exists
		local session_exists = vim.system({ "tmux", "has-session", "-t", "__opencode_stash" }):wait().code == 0
		-- Create stash session if it doesn't exist
		if not session_exists then
			vim.system({ "tmux", "new-session", "-d", "-s", "__opencode_stash" }):wait()
		end

		-- Run tmux break-pane to move pane to the stash session
		local hidden_pane = system.run({ "tmux", "break-pane", "-d", "-P", "-s", pane_id, "-t", "__opencode_stash" })
		if hidden_pane ~= "" then
			state.hidden_pane_spec = hidden_pane
		else
			system.notify("failed to break tmux pane", vim.log.levels.ERROR)
		end
	else -- Show pane
		local args = { "tmux", "join-pane" }
		vim.list_extend(args, get_user_options_args())

		table.insert(args, "-s")
		table.insert(args, state.hidden_pane_spec)

		-- Run tmux join-pane to restore the pane
		local joined = vim.system(args, { text = true }):wait()

		if joined.code == 0 then
			M.clean_up_stash_session()
		else
			system.notify("failed to restore tmux pane", vim.log.levels.ERROR)
			return
		end
	end
end

function M.toggle()
	local pane_id = M.get_managed_pane_id()

	if pane_id then
		if state.opts.auto_close ~= false then
			M.stop()
		else
			M.auto_toggle(pane_id)
		end
	else
		-- Clear hidden_pane_spec if the pane no longer exists
		M.clean_up_stash_session()
		M.start()
	end
end

---@return string|nil
function M.current_pane_id()
	return get_current_pane_id()
end

return M
