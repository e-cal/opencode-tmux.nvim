local state = require("opencode-tmux.state")
local tmux = require("opencode-tmux.tmux")
local patch = require("opencode-tmux.patch")
local config = require("opencode-tmux.config")
local system = require("opencode-tmux.system")
local discovery = require("opencode-tmux.discovery")

local M = {}

---@param name string
---@param args table|nil
local function debug_call(name, args)
	system.debug("call " .. name .. " args=" .. vim.inspect(args or {}))
end

---@param server_item opencode.cli.server.Server
local function notify_connected(server_item)
	local port = server_item and server_item.port or "?"
	local pane = state.sse_target_pane_by_port[port]
	local pane_label = nil
	if pane and pane.pane_id then
		local pane_spec = system.run({
			"tmux",
			"display-message",
			"-p",
			"-t",
			pane.pane_id,
			"[#{pane_index}]",
		})
		pane_label = pane_spec ~= "" and pane_spec or pane.pane_id
	end
	if not pane_label or pane_label == "" then
		pane_label = "<unknown pane>"
	end
	vim.notify("Connected to: " .. tostring(pane_label) .. " (port " .. tostring(port) .. ")")
end

---@param value any
---@return string|nil
local function find_path_like_value(value)
	if type(value) == "string" and value ~= "" then
		if value:find("/", 1, true) or value:find("\\", 1, true) then
			return value
		end
	end
	if type(value) ~= "table" then
		return nil
	end

	local keys = {
		"filepath",
		"filePath",
		"path",
		"filename",
		"fileName",
	}
	for _, key in ipairs(keys) do
		local candidate = value[key]
		if type(candidate) == "string" and candidate ~= "" then
			return candidate
		end
	end

	for _, key in ipairs({ "file", "target", "diff", "properties" }) do
		local nested = value[key]
		local found = find_path_like_value(nested)
		if found then
			return found
		end
	end

	for _, nested in pairs(value) do
		local found = find_path_like_value(nested)
		if found then
			return found
		end
	end

	return nil
end

---@class opencode_tmux.Opts
---@field enabled? boolean
---@field cmd? string
---@field options? string
---@field focus? boolean
---@field allow_passthrough? boolean
---@field auto_close? boolean
---@field find_sibling? boolean
---@field debug? boolean
---@field connect_keymap? string|false
---@field connect_launch? boolean

---@param opts? { launch?: boolean, notify_failure?: boolean }
---@return Promise|nil
function M.connect(opts)
	debug_call("connect", opts)
	local ok, _ = pcall(require, "opencode.promise")
	if not ok then
		system.notify("opencode.nvim is required", vim.log.levels.ERROR)
		return nil
	end
	local server = require("opencode.cli.server")

	opts = opts or {}
	local launch = opts.launch
	local notify_failure = opts.notify_failure
	if launch == nil then
		launch = state.opts.connect_launch == true
	end
	if notify_failure == nil then
		notify_failure = true
	end

	local promise = server.get(launch):next(function(server_item)
		notify_connected(server_item)
		return server_item
	end)

	promise = promise:catch(function(err)
		if notify_failure then
			system.notify(tostring(err), vim.log.levels.ERROR)
		else
			system.debug("connect failed: " .. tostring(err))
		end
		return nil
	end)

	return promise
end

---@param prompt_text string
---@param opts? { clear?: boolean, submit?: boolean, new?: boolean, context?: opencode.Context }
---@return Promise|nil
function M.prompt(prompt_text, opts)
	debug_call("prompt", {
		prompt_text = prompt_text,
		clear = opts and opts.clear or false,
		submit = opts and opts.submit or false,
		new = opts and opts.new or false,
		has_context = opts and opts.context ~= nil or false,
	})
	local ok, _ = pcall(require, "opencode.promise")
	if not ok then
		system.notify("opencode.nvim is required", vim.log.levels.ERROR)
		return nil
	end
	return require("opencode.api.prompt").prompt(prompt_text, opts)
end

---@return Promise|nil
function M.servers()
	debug_call("servers", nil)
	local ok, _ = pcall(require, "opencode.promise")
	if not ok then
		system.notify("opencode.nvim is required", vim.log.levels.ERROR)
		return nil
	end
	return discovery.sibling_servers():next(discovery.unique_by_port)
end

---@param opts? opencode_tmux.Opts
function M.setup(opts)
	debug_call("setup", opts)
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

	if type(state.opts.connect_keymap) == "string" and state.opts.connect_keymap ~= "" then
		vim.keymap.set("n", state.opts.connect_keymap, function()
			M.connect({ launch = state.opts.connect_launch })
		end, {
			desc = "opencode-tmux: connect",
			silent = true,
		})
	end

	vim.api.nvim_create_autocmd("User", {
		group = vim.api.nvim_create_augroup("OpencodeTmuxEventDebug", { clear = true }),
		pattern = "OpencodeEvent:*",
		callback = function(args)
			local event = args and args.data and args.data.event or nil
			local event_type = event and event.type or "<unknown>"
			state.last_event_ms = vim.uv.now()
			state.last_event_type = event_type
			if event_type == "server.heartbeat" then
				return
			end
			system.debug("event " .. tostring(event_type))
			if event_type == "file.edited" then
				local filepath = find_path_like_value(event and event.properties)
					or find_path_like_value(event)
					or "<unknown>"
				local port = args and args.data and args.data.port or nil
				local base_dir = port and state.sse_target_directory_by_port[port] or nil
				if type(base_dir) == "string" and base_dir ~= "" then
					local prefix = base_dir:gsub("/$", "") .. "/"
					if type(filepath) == "string" and filepath:sub(1, #prefix) == prefix then
						filepath = filepath:sub(#prefix + 1)
					elseif filepath == base_dir then
						filepath = "."
					end
				end
				vim.notify("Opencode edited " .. tostring(filepath), vim.log.levels.INFO, {
					title = "opencode",
				})
			end
		end,
		desc = "Log opencode events (except heartbeat)",
	})

	-- Kill stash session when nvim exits
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if not state.opts.auto_close and state.hidden_pane_spec and system.in_tmux() then
				vim.system({ "tmux", "kill-pane", "-t", state.hidden_pane_spec }):wait(1000)
				tmux.clean_up_stash_session()
			end
		end,
	})
end

return M
