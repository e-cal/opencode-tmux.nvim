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

function M.apply()
	if state.patched or not system.in_tmux() then
		return
	end

	local server = require("opencode.cli.server")
	local prompt = require("opencode.api.prompt")
	state.original_get_all = server.get_all
	state.original_get = server.get
	state.original_prompt = prompt.prompt

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
		local events = require("opencode.events")
		local select_server = require("opencode.ui.select_server").select_server
		local server_opts = require("opencode.config").opts.server or {}

		local function connect(server_item)
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
			return state.original_get(launch)
		end

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
