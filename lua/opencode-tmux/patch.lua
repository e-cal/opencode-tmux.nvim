local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local discovery = require("opencode-tmux.discovery")

local M = {}

---@param port number
---@param endpoint string
---@param directory string
---@param body table|nil
---@return Promise
local function tui_post(port, endpoint, directory, body)
	local Promise = require("opencode.promise")

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

---@param port number
---@param fallback_directory string
---@return Promise
local function get_target_directory(port, fallback_directory)
	local Promise = require("opencode.promise")

	return Promise.new(function(resolve)
		discovery.target_directory_for_port_async(port, fallback_directory, function(directory)
			resolve(directory)
		end)
	end)
end

---@param port number
---@param target_directory string|nil
---@param target_session_id string|nil
---@param on_success? fun(response: table)
---@param on_error? fun(code: number, msg: string?)
---@return number
local function sse_subscribe_global(port, target_directory, target_session_id, on_success, on_error)
	local command = {
		"curl",
		"-s",
		"-X",
		"GET",
		"-H",
		"Accept: application/json",
		"-H",
		"Accept: text/event-stream",
		"-N",
		"--max-time",
		"0",
		"http://localhost:" .. tostring(port) .. "/global/event",
	}

	local response_buffer = {}
	local stderr_lines = {}

	local function process_response_buffer()
		if #response_buffer == 0 then
			return
		end

		local full_event = table.concat(response_buffer)
		response_buffer = {}

		vim.schedule(function()
			local ok, response = pcall(vim.fn.json_decode, full_event)
			if not ok or type(response) ~= "table" then
				system.debug("Skipping undecodable global SSE event")
				return
			end

			local payload = response.payload
			if type(payload) ~= "table" then
				payload = response
			end
			if type(payload) ~= "table" or type(payload.type) ~= "string" then
				return
			end

			local event_directory = response.directory
			if target_directory and target_directory ~= "" and event_directory and event_directory ~= target_directory then
				return
			end

			-- Filter by session ID when available
			if target_session_id then
				local props = payload.properties or {}
				local event_session_id = props.sessionID
					or (props.info and props.info.sessionID)
					or (props.part and props.part.sessionID)
				-- If the event carries a session ID and it doesn't match, drop it
				if event_session_id and event_session_id ~= "" and event_session_id ~= target_session_id then
					return
				end
			end

			if on_success then
				on_success(payload)
			end
		end)
	end

	return vim.fn.jobstart(command, {
		on_stdout = function(_, data)
			if not data then
				return
			end
			for _, line in ipairs(data) do
				if line == "" then
					process_response_buffer()
				else
					local clean_line = line:gsub("^data: ?", "")
					table.insert(response_buffer, clean_line)
				end
			end
		end,
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
				process_response_buffer()
				return
			end

			local stderr_message = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or nil
			if on_error then
				on_error(code, stderr_message)
			end
		end,
	})
end

function M.apply()
	if state.patched or not system.in_tmux() then
		return
	end

	local server = require("opencode.cli.server")
	local client = require("opencode.cli.client")
	local prompt = require("opencode.api.prompt")
	local events = require("opencode.events")
	state.original_get_all = server.get_all
	state.original_get = server.get
	state.original_prompt = prompt.prompt
	state.original_sse_subscribe = client.sse_subscribe

	client.sse_subscribe = function(port, on_success, on_error)
		if state.opts.find_sibling ~= true then
			return state.original_sse_subscribe(port, on_success, on_error)
		end

		local target_directory = state.sse_target_directory_by_port[port]
			or discovery.target_directory_for_port(port, nil)
		local target_session_id = state.sse_target_session_id_by_port[port]
		system.debug(
			"Subscribing to global event stream"
				.. " port="
				.. tostring(port)
				.. " directory="
				.. tostring(target_directory)
				.. " session_id="
				.. tostring(target_session_id)
		)
		return sse_subscribe_global(port, target_directory, target_session_id, on_success, on_error)
	end

	server.get_all = function(...)
		local Promise = require("opencode.promise")
		local original = state.original_get_all(...)

		return original
			:next(function(servers)
				local sibling_ports = discovery.sibling_ports()
				if #sibling_ports == 0 then
					return servers
				end

				local existing = {}
				for _, item in ipairs(servers) do
					existing[item.port] = true
				end

				local missing_ports = {}
				for _, port in ipairs(sibling_ports) do
					if not existing[port] then
						table.insert(missing_ports, port)
					end
				end

				if #missing_ports == 0 then
					return servers
				end

				return discovery.servers_from_ports(missing_ports):next(function(discovered)
					for _, server_item in ipairs(discovered) do
						table.insert(servers, server_item)
					end
					return servers
				end)
			end)
			:catch(function(err)
				local sibling_ports = discovery.sibling_ports()
				if #sibling_ports == 0 then
					return Promise.reject(err)
				end

				return discovery.servers_from_ports(sibling_ports):next(function(discovered)
					if #discovered > 0 then
						return discovered
					end
					return Promise.reject(err)
				end)
			end)
	end

	server.get = function(launch)
		launch = launch ~= false
		local Promise = require("opencode.promise")
		local select_server = require("opencode.ui.select_server").select_server
		local server_opts = require("opencode.config").opts.server or {}

		local function connect(server_item)
			local connected_server = events.connected_server
			local session_id, target_dir = discovery.resolve_target_session(server_item.port, server_item.cwd)
			if not target_dir or target_dir == "" then
				target_dir = server_item.cwd
			end
			state.sse_target_directory_by_port[server_item.port] = target_dir
			state.sse_target_session_id_by_port[server_item.port] = session_id
			system.debug(
				"Resolved target"
					.. " port=" .. tostring(server_item.port)
					.. " directory=" .. tostring(target_dir)
					.. " session_id=" .. tostring(session_id)
			)
			local now = vim.uv.now()
			local last_event_age_ms = state.last_event_ms and (now - state.last_event_ms) or nil
			local has_recent_events = last_event_age_ms ~= nil and last_event_age_ms <= 35000
			if connected_server and connected_server.port == server_item.port then
				if has_recent_events then
					system.debug(
						"Reusing existing SSE connection on port "
							.. tostring(server_item.port)
							.. " last_event="
							.. tostring(state.last_event_type)
							.. " age_ms="
							.. tostring(last_event_age_ms)
					)
					return server_item
				end

				system.debug(
					"SSE health unknown/stale for current port; reconnecting"
						.. " port="
						.. tostring(server_item.port)
						.. " age_ms="
						.. tostring(last_event_age_ms)
				)
			end

			system.debug(
				"Connecting SSE stream"
					.. " old="
					.. tostring(connected_server and connected_server.port or "nil")
					.. " new="
					.. tostring(server_item.port)
			)
			events.connect(server_item)
			return server_item
		end

		local function pick_sibling_candidate()
			return discovery.sibling_servers():next(function(siblings)
				local candidates = discovery.unique_by_port(siblings)
				system.debug("Sibling server candidates: " .. tostring(#candidates))
				if #candidates == 1 then
					system.debug("Connecting directly to sibling server port " .. tostring(candidates[1].port))
					return connect(candidates[1])
				end

				if #candidates > 1 then
					system.debug("Opening server selector for sibling candidates")
					return select_server(candidates):next(connect)
				end

				return nil
			end)
		end

		if state.opts.find_sibling ~= true then
			system.debug("Sibling discovery disabled; delegating to original server.get")
			return state.original_get(launch)
		end

		system.debug("Resolving server via sibling-aware flow launch=" .. tostring(launch))

		return pick_sibling_candidate()
			:next(function(server_item)
				if server_item then
					return server_item
				end

				if not launch or not server_opts.start then
					error("No sibling opencode server found in this tmux window", 0)
				end

				system.debug("No sibling candidates found; starting tmux-managed opencode server")
				local start_ok, start_result = pcall(server_opts.start)
				if not start_ok then
					error("Error starting `opencode`: " .. tostring(start_result), 0)
				end

				return Promise.new(function(resolve)
					vim.defer_fn(function()
						resolve(true)
					end, 2000)
				end):next(function()
					return pick_sibling_candidate():next(function(started_server)
						if started_server then
							return started_server
						end
						error("Started opencode but no sibling pane server was discoverable", 0)
					end)
				end)
			end)
			:catch(function(err)
				if not err then
					return Promise.reject()
				end
				return Promise.reject(err)
			end)
	end

	prompt.prompt = function(prompt_text, opts)
		opts = {
			clear = opts and opts.clear or false,
			submit = opts and opts.submit or false,
			context = opts and opts.context or require("opencode.context").new(),
		}

		if state.opts.find_sibling ~= true then
			system.debug("Sibling routing disabled; using original prompt behavior")
			return state.original_prompt(prompt_text, opts)
		end

		local Promise = require("opencode.promise")
		return require("opencode.cli.server")
			.get()
			:catch(function()
				system.debug("Failed to resolve server via sibling-aware flow; using original prompt")
				return nil
			end)
			:next(function(server_item)
				if not server_item then
					system.debug("No server resolved; falling back to original prompt")
					return state.original_prompt(prompt_text, opts)
				end

				local target_session_id = state.sse_target_session_id_by_port[server_item.port]
				local target_directory = state.sse_target_directory_by_port[server_item.port]
					or discovery.target_directory_for_port(server_item.port, server_item.cwd)

				-- If we have a session ID, send directly via the session message API
				if target_session_id and opts.submit then
					local rendered = opts.context:render(prompt_text, server_item.subagents)
					local plaintext = opts.context.plaintext(rendered.output)

					if plaintext == "" then
						system.debug("Empty prompt text; skipping direct message send")
						opts.context:clear()
						return server_item
					end

					system.debug(
						"Sending message directly to session"
							.. " port=" .. tostring(server_item.port)
							.. " session=" .. tostring(target_session_id)
							.. " directory=" .. tostring(target_directory)
					)

					return Promise.new(function(resolve, reject)
						local body = vim.fn.json_encode({
							parts = {
								{
									type = "text",
									text = plaintext,
								},
							},
						})

						local stderr_lines = {}
						local command = {
							"curl", "-s", "-X", "POST",
							"-H", "Content-Type: application/json",
							"-H", "Accept: application/json",
							"-H", "x-opencode-directory: " .. (target_directory or server_item.cwd),
							"--max-time", "120",
							"-d", body,
							"http://localhost:" .. tostring(server_item.port)
								.. "/session/" .. target_session_id .. "/message",
						}

						vim.fn.jobstart(command, {
							on_stderr = function(_, data)
								if not data then return end
								for _, line in ipairs(data) do
									if line ~= "" then table.insert(stderr_lines, line) end
								end
							end,
							on_exit = function(_, code)
								if code == 0 then
									resolve(server_item)
								else
									local msg = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or "<none>"
									reject("Direct message failed (" .. tostring(code) .. "): " .. msg)
								end
							end,
						})
					end)
				end

				-- Fallback: route through TUI endpoints (no session ID or no submit)
				local rendered = opts.context:render(prompt_text, server_item.subagents)
				local plaintext = opts.context.plaintext(rendered.output)

				return get_target_directory(server_item.port, server_item.cwd):next(function(directory)
					if not directory or directory == "" then
						system.debug("No target directory resolved; falling back to original prompt")
						return state.original_prompt(prompt_text, opts)
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

					return chain:next(function()
						system.debug(
							"Routed prompt via TUI endpoints on port "
								.. tostring(server_item.port)
								.. " directory="
								.. directory
								.. " submit="
								.. tostring(opts.submit)
						)
						return server_item
					end)
				end)
			end)
			:next(function()
				opts.context:clear()
			end)
			:catch(function(err)
				opts.context:resume()
				return Promise.reject(err)
			end)
	end

	state.patched = true
end

return M
