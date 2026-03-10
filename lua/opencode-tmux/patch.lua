local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local discovery = require("opencode-tmux.discovery")

local M = {}

local function send_message_and_ignore_timeout(port, session_id, text)
	local Promise = require("opencode.promise")

	return Promise.new(function(resolve, reject)
		local stderr_lines = {}
		local body = vim.fn.json_encode({
			sessionID = session_id,
			parts = {
				{
					type = "text",
					text = text,
				},
			},
		})

		local command = {
			"curl",
			"-s",
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-H",
			"Accept: application/json",
			"--max-time",
			"2",
			"-d",
			body,
			"http://localhost:" .. port .. "/session/" .. session_id .. "/message",
		}

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
				if code == 0 or code == 28 then
					resolve(true)
					return
				end
				local stderr_message = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or "<none>"
				reject("Failed to send session message (" .. tostring(code) .. "): " .. stderr_message)
			end,
		})
	end)
end

local function get_target_session(port)
	local Promise = require("opencode.promise")
	local client = require("opencode.cli.client")

	return Promise.new(function(resolve, reject)
		client.get_sessions(port, function(sessions)
			if not sessions or #sessions == 0 then
				reject("No opencode sessions found on selected server")
				return
			end

			local hinted_session_id = discovery.session_id_for_port(port, sessions)
			if hinted_session_id then
				for _, session in ipairs(sessions) do
					if session.id == hinted_session_id then
						resolve(session)
						return
					end
				end
			end

			table.sort(sessions, function(a, b)
				return a.time.updated > b.time.updated
			end)

			resolve(sessions[1])
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
		local Promise = require("opencode.promise")
		local events = require("opencode.events")
		local select_server = require("opencode.ui.select_server").select_server

		local function connect(server_item)
			events.connect(server_item)
			return server_item
		end

		return discovery
			.sibling_servers()
			:next(function(siblings)
				local candidates = discovery.unique_by_port(siblings)
				if #candidates == 1 then
					return connect(candidates[1])
				end

				if #candidates > 1 then
					return select_server(candidates):next(connect)
				end

				return state.original_get(launch)
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

		if opts.submit ~= true then
			return state.original_prompt(prompt_text, opts)
		end

		local Promise = require("opencode.promise")
		return require("opencode.cli.server")
			.get()
			:next(function(server_item)
				local rendered = opts.context:render(prompt_text, server_item.subagents)
				local plaintext = opts.context.plaintext(rendered.output)

				return get_target_session(server_item.port):next(function(session)
					return send_message_and_ignore_timeout(server_item.port, session.id, plaintext):next(function()
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
