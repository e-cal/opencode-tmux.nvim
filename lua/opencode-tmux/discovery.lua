local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local tmux = require("opencode-tmux.tmux")

local M = {}

---@param args string
---@return string|nil
local function parse_dir_from_args(args)
	return args:match("%-%-dir=([^%s]+)") or args:match("%-%-dir%s+([^%s]+)")
end

---Query the server for the most recently updated session in the given directory.
---Calls callback with the session table, or nil if none found.
---@param port number
---@param directory string
---@param callback fun(session: opencode.cli.client.Session|nil)
local function get_session_for_dir(port, directory, callback)
	local encoded = directory:gsub("([^%w%-_%.~/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local path = "/session?directory=" .. encoded .. "&limit=1"
	local command = {
		"curl", "-s", "-X", "GET",
		"-H", "Accept: application/json",
		"--max-time", "2",
		"http://localhost:" .. tostring(port) .. path,
	}
	local stdout_buf = {}
	local done = false
	vim.fn.jobstart(command, {
		on_stdout = function(_, data)
			if not data then return end
			for _, line in ipairs(data) do
				if line ~= "" then table.insert(stdout_buf, line) end
			end
		end,
		on_exit = function(_, code)
			if done then return end
			done = true
			if code ~= 0 then
				vim.schedule(function() callback(nil) end)
				return
			end
			local raw = table.concat(stdout_buf, "")
			local ok, sessions = pcall(vim.fn.json_decode, raw)
			if ok and type(sessions) == "table" and #sessions > 0 then
				vim.schedule(function() callback(sessions[1]) end)
			else
				vim.schedule(function() callback(nil) end)
			end
		end,
	})
end

---Find the --dir used by the attach process for a given port by scanning ps output.
---Falls back to server_cwd if not found.
---@param port number
---@param server_cwd string
---@return string
local function get_client_dir_for_port(port, server_cwd)
	local process_lines = system.run_lines({ "ps", "-eo", "pid=,args=" })
	for _, process in ipairs(process_lines) do
		local _, args = process:match("^%s*(%d+)%s+(.+)$")
		if args and args:find("opencode", 1, true) then
			local attach_port = args:match("%-%-attach=.-:(%d+)") or args:match("attach%s+.-:(%d+)")
			if tonumber(attach_port) == port then
				local dir = parse_dir_from_args(args)
				if dir then
					return dir
				end
			end
		end
	end
	return server_cwd
end

---@param args string
---@return number|nil
local function parse_target_port_from_args(args)
	local attach_port = args:match("%-%-attach=.-:(%d+)")
		or args:match("%-%-attach%s+.-:(%d+)")
		or args:match("attach%s+.-:(%d+)")
	if attach_port then
		return tonumber(attach_port)
	end

	local cli_port = args:match("%-%-port=(%d+)") or args:match("%-%-port%s+(%d+)")
	if cli_port then
		return tonumber(cli_port)
	end

	return nil
end

---@param pid string
---@param args string
---@param port number
---@return boolean
local function process_matches_port(pid, args, port)
	local parsed_port = parse_target_port_from_args(args)
	if parsed_port then
		return parsed_port == port
	end

	local lsof_lines = system.run_lines({ "lsof", "-w", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-a", "-p", pid })
	for _, lsof_line in ipairs(lsof_lines) do
		local process_port = tonumber(lsof_line:match(":(%d+)%s*%(LISTEN%)"))
		if process_port == port then
			return true
		end
	end

	return false
end

---@return number[]
function M.sibling_ports()
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return {}
	end

	local current_pane = tmux.current_pane_id()
	if not current_pane then
		return {}
	end

	local current_loc = system.run({ "tmux", "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}" })
	if current_loc == "" then
		return {}
	end
	local current_window = current_loc:match("^([^%.]+)")
	if not current_window then
		return {}
	end

	local tty_to_tmux = {}
	local pane_to_tmux = {}
	local pane_lines = system.run_lines({
		"tmux",
		"list-panes",
		"-a",
		"-F",
		"#{pane_id} #{pane_tty} #{session_name}:#{window_index}.#{pane_index}",
	})
	for _, line in ipairs(pane_lines) do
		local pane_id, pane_tty, pane_loc = line:match("^(%%%d+)%s+([^%s]+)%s+([^%s]+)$")
		if pane_id and pane_tty and pane_loc then
			tty_to_tmux[pane_tty:gsub("^/dev/", "")] = pane_loc
			pane_to_tmux[pane_id] = pane_loc
		end
	end

	local seen = {}
	local ports = {}

	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and args and args:find("opencode", 1, true) and tty ~= "??" then
			local pane_loc = tty_to_tmux[tty]
			if
				pane_loc
				and pane_loc:find(current_window .. ".", 1, true) == 1
				and pane_to_tmux[current_pane] ~= pane_loc
			then
				local parsed_port = parse_target_port_from_args(args)
				if parsed_port and not seen[parsed_port] then
					seen[parsed_port] = true
					table.insert(ports, parsed_port)
				end

				local lsof_lines =
					system.run_lines({ "lsof", "-w", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-a", "-p", pid })
				for _, lsof_line in ipairs(lsof_lines) do
					local port = tonumber(lsof_line:match(":(%d+)%s*%(LISTEN%)"))
					if port and not seen[port] then
						seen[port] = true
						table.insert(ports, port)
					end
				end
			end
		end
	end

	return ports
end

---Find candidates for a sibling opencode process on the given port within the current tmux window.
---Returns a list sorted by pane proximity, each with pid/tty/args/pane_index.
---@param port number
---@return table[]
local function sibling_candidates_for_port(port)
	local current_pane = tmux.current_pane_id()
	if not current_pane then return {} end

	local current_loc = system.run({ "tmux", "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}" })
	if current_loc == "" then return {} end
	local current_window = current_loc:match("^([^%.]+)")
	if not current_window then return {} end

	local tty_to_tmux = {}
	local pane_to_tmux = {}
	local pane_lines = system.run_lines({
		"tmux", "list-panes", "-a", "-F",
		"#{pane_id}\t#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}",
	})
	for _, line in ipairs(pane_lines) do
		local pane_id, pane_tty, pane_loc = line:match("^(%%%d+)\t([^\t]+)\t([^\t]+)$")
		if pane_id and pane_tty and pane_loc then
			local tty = pane_tty:gsub("^/dev/", "")
			tty_to_tmux[tty] = pane_loc
			pane_to_tmux[pane_id] = pane_loc
		end
	end

	local current_pane_index = tonumber(current_loc:match("%.(%d+)$") or "") or 0
	local tty_to_pane_index = {}
	for _, line in ipairs(pane_lines) do
		local _, pane_tty, pane_loc = line:match("^(%%%d+)\t([^\t]+)\t([^\t]+)$")
		if pane_tty and pane_loc then
			local tty = pane_tty:gsub("^/dev/", "")
			tty_to_pane_index[tty] = tonumber(pane_loc:match("%.(%d+)$") or "")
		end
	end

	local candidates = {}
	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and args and args:find("opencode", 1, true) and tty ~= "??" then
			local pane_loc = tty_to_tmux[tty]
			if pane_loc
				and pane_loc:find(current_window .. ".", 1, true) == 1
				and pane_to_tmux[current_pane] ~= pane_loc
			then
				if process_matches_port(pid, args, port) then
					table.insert(candidates, {
						pid = pid,
						tty = tty,
						args = args,
						pane_index = tty_to_pane_index[tty] or 0,
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		local a_dist = math.abs((a.pane_index or 0) - current_pane_index)
		local b_dist = math.abs((b.pane_index or 0) - current_pane_index)
		if a_dist ~= b_dist then return a_dist < b_dist end
		return (a.pane_index or 0) < (b.pane_index or 0)
	end)

	return candidates
end

---@param pid string
---@return string|nil
local function get_process_cwd(pid)
	local lines = system.run_lines({ "lsof", "-a", "-p", pid, "-d", "cwd", "-Fn" })
	for _, line in ipairs(lines) do
		if line:sub(1, 1) == "n" then
			local cwd = line:sub(2)
			if cwd ~= "" then
				return cwd
			end
		end
	end
	return nil
end

---Resolve the target directory for a sibling opencode client on the given port.
---Prefers --dir from process args, then process cwd, then fallback_directory.
---@param port number
---@param fallback_directory string
---@param callback fun(directory: string)
function M.target_directory_for_port_async(port, fallback_directory, callback)
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		callback(fallback_directory)
		return
	end

	local candidates = sibling_candidates_for_port(port)
	for _, candidate in ipairs(candidates) do
		local dir = parse_dir_from_args(candidate.args) or get_process_cwd(candidate.pid)
		if dir and dir ~= "" then
			callback(dir)
			return
		end
	end
	callback(fallback_directory)
end

---@param servers opencode.cli.server.Server[]
---@return opencode.cli.server.Server[]
function M.unique_by_port(servers)
	local unique = {}
	local seen = {}
	for _, server_item in ipairs(servers) do
		if not seen[server_item.port] then
			seen[server_item.port] = true
			table.insert(unique, server_item)
		end
	end
	return unique
end

---@param port number
---@return Promise<opencode.cli.server.Server>
function M.get_server(port)
	local Promise = require("opencode.promise")
	local client = require("opencode.cli.client")

	return Promise.new(function(resolve, reject)
		client.get_path(port, function(path)
			local cwd = path.directory or path.worktree
			if cwd then
				resolve(cwd)
			else
				reject("No opencode server responding on port " .. tostring(port))
			end
		end, function()
			reject("No opencode server responding on port " .. tostring(port))
		end)
	end)
		:next(function(cwd)
			local client_dir = get_client_dir_for_port(port, cwd)
			return Promise.all({
				cwd,
				Promise.new(function(resolve)
					get_session_for_dir(port, client_dir, function(session)
						local title = session and session.title or "<No sessions>"
						resolve(title)
					end)
				end),
				Promise.new(function(resolve)
					client.get_agents(port, function(agents)
						local subagents = vim.tbl_filter(function(agent)
							return agent.mode == "subagent"
						end, agents)
						resolve(subagents)
					end)
				end),
			})
		end)
		:next(function(results)
			return {
				port = port,
				cwd = results[1],
				title = results[2],
				subagents = results[3],
			}
		end)
end

---@param ports number[]
---@return Promise<opencode.cli.server.Server[]>
function M.servers_from_ports(ports)
	local Promise = require("opencode.promise")

	if #ports == 0 then
		return Promise.resolve({})
	end

	-- Always use our own get_server which queries /session?directory=<client_dir>
	-- to get the correct title for each sibling port.
	local lookups = {}
	for _, port in ipairs(ports) do
		table.insert(lookups, M.get_server(port))
	end

	return Promise.all_settled(lookups):next(function(results)
		local discovered = {}
		for _, result in ipairs(results) do
			if result.status == "fulfilled" then
				table.insert(discovered, result.value)
			end
		end
		return discovered
	end)
end

---@return Promise<opencode.cli.server.Server[]>
function M.sibling_servers()
	return M.servers_from_ports(M.sibling_ports())
end

return M
