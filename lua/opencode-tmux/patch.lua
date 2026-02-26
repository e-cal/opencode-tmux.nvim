local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local discovery = require("opencode-tmux.discovery")

local M = {}

function M.apply()
	if state.patched or not system.in_tmux() then
		return
	end

	local server = require("opencode.cli.server")
	state.original_get_all = server.get_all
	state.original_get = server.get

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

	state.patched = true
end

return M
