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
	local title = server_item and server_item.title or nil
	if not title or title == "" or title == "<No sessions>" then
		title = state.sse_target_session_id_by_port[port]
	end
	if not title or title == "" then
		title = server_item and server_item.cwd or "<unknown>"
	end
	vim.notify("Connected to session: " .. tostring(title) .. " (port " .. tostring(port) .. ")")
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

---@param opts? { launch?: boolean }
---@return Promise|nil
function M.connect(opts)
	debug_call("connect", opts)
	local ok, Promise = pcall(require, "opencode.promise")
	if not ok then
		system.notify("opencode.nvim is required", vim.log.levels.ERROR)
		return nil
	end
	local server = require("opencode.cli.server")

	opts = opts or {}
	local launch = opts.launch
	if launch == nil then
		launch = state.opts.connect_launch == true
	end

	local promise = server.get(launch):next(function(server_item)
		notify_connected(server_item)
		return server_item
	end)

	promise = promise:catch(function(err)
		system.notify(tostring(err), vim.log.levels.ERROR)
		return nil
	end)

	return promise
end

---@param prompt_text string
---@param opts? { clear?: boolean, submit?: boolean, context?: opencode.Context }
---@return Promise|nil
function M.prompt(prompt_text, opts)
	debug_call("prompt", {
		prompt_text = prompt_text,
		clear = opts and opts.clear or false,
		submit = opts and opts.submit or false,
		has_context = opts and opts.context ~= nil or false,
	})
	local ok, Promise = pcall(require, "opencode.promise")
	if not ok then
		system.notify("opencode.nvim is required", vim.log.levels.ERROR)
		return nil
	end

	opts = {
		clear = opts and opts.clear or false,
		submit = opts and opts.submit or false,
		context = opts and opts.context or require("opencode.context").new(),
	}

	local function tui_post(port, endpoint, directory, body)
		debug_call("tui_post", {
			port = port,
			endpoint = endpoint,
			directory = directory,
			body = body,
		})
		return Promise.new(function(resolve, reject)
			local stderr_lines = {}
			local command = {
				"curl",
				"-s",
				"-X",
				"POST",
				"-H",
				"Content-Type: application/json",
				"-H",
				"Accept: application/json",
				"-H",
				"x-opencode-directory: " .. directory,
				"--max-time",
				"2",
			}

			if body then
				table.insert(command, "-d")
				table.insert(command, vim.fn.json_encode(body))
			end

			table.insert(command, "http://localhost:" .. tostring(port) .. endpoint)

			vim.fn.jobstart(command, {
				on_stderr = function(_, data)
					if not data then
						return
					end
					for _, line in ipairs(data) do
						if line ~= "" then
							table.insert(stderr_lines, line)
						end
					end
				end,
				on_exit = function(_, code)
					if code == 0 then
						resolve(true)
						return
					end
					local stderr_message = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or "<none>"
					reject("Failed POST " .. endpoint .. " (" .. tostring(code) .. "): " .. stderr_message)
				end,
			})
		end)
	end

	return M.connect({ launch = state.opts.connect_launch })
		:next(function(server_item)
			if not server_item then
				return nil
			end

			local rendered = opts.context:render(prompt_text, server_item.subagents)
			local plaintext = opts.context.plaintext(rendered.output)

			return Promise.new(function(resolve)
				discovery.target_directory_for_port_async(server_item.port, server_item.cwd, resolve)
			end):next(function(directory)
				if not directory or directory == "" then
					error("No target directory resolved for sibling server", 0)
				end

				local chain = Promise.resolve(true)
				if opts.clear then
					chain = chain:next(function()
						return tui_post(server_item.port, "/tui/clear-prompt", directory, nil)
					end)
				end
				if plaintext ~= "" then
					chain = chain:next(function()
						return tui_post(server_item.port, "/tui/append-prompt", directory, { text = plaintext })
					end)
				end
				if opts.submit then
					chain = chain:next(function()
						return tui_post(server_item.port, "/tui/submit-prompt", directory, nil)
					end)
				end
				return chain
			end)
		end)
		:next(function(result)
			opts.context:clear()
			return result
		end)
		:catch(function(err)
			opts.context:resume()
			return Promise.reject(err)
		end)
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
				vim.notify("opencode-tmux: file.edited: " .. tostring(filepath), vim.log.levels.INFO, {
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
