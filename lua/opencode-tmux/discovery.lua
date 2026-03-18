local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local tmux = require("opencode-tmux.tmux")

local M = {}
local sibling_panes_by_tty

---@param name string
---@param args table|nil
local function debug_call(name, args)
	system.debug("call discovery." .. name .. " args=" .. vim.inspect(args or {}))
end

---@param args string
---@return string|nil
local function parse_dir_from_args(args)
	debug_call("parse_dir_from_args", { args = args })
	return args:match("%-%-dir=([^%s]+)") or args:match("%-%-dir%s+([^%s]+)")
end

---Parse the opencode session title from a tmux pane title.
---The opencode TUI sets the pane title to "OC | <session title>".
---@param pane_title string|nil
---@return string|nil
local function parse_session_title_from_pane(pane_title)
	if not pane_title or pane_title == "" then
		return nil
	end
	local title = pane_title:match("^OC | (.+)$")
	if title and title ~= "" then
		return title
	end
	return nil
end

---Find the best matching session from a list, preferring a title hint match.
---Falls back to the first session (most recently updated) if no title match.
---@param sessions table[]
---@param title_hint string|nil
---@return table|nil
local function best_session_by_title(sessions, title_hint)
	if not sessions or #sessions == 0 then
		return nil
	end
	if title_hint then
		for _, session in ipairs(sessions) do
			if session.title == title_hint then
				return session
			end
		end
	end
	-- Fallback: most recently updated (first in the list)
	return sessions[1]
end

---Query the server for the most recently updated session in the given directory (synchronous).
---When title_hint is provided, fetches multiple sessions and prefers a title match.
---@param port number
---@param directory string
---@param title_hint string|nil
---@return opencode.cli.client.Session|nil
local function get_session_for_dir_sync(port, directory, title_hint)
	debug_call("get_session_for_dir_sync", { port = port, directory = directory, title_hint = title_hint })
	local encoded = directory:gsub("([^%w%-_%.~/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local limit = title_hint and 20 or 1
	local path = "/session?directory=" .. encoded .. "&limit=" .. tostring(limit)
	local result = vim.system({
		"curl", "-s", "-X", "GET",
		"-H", "Accept: application/json",
		"--max-time", "2",
		"http://localhost:" .. tostring(port) .. path,
	}, { text = true }):wait()
	if result.code ~= 0 or not result.stdout or result.stdout == "" then
		return nil
	end
	local ok, sessions = pcall(vim.fn.json_decode, result.stdout)
	if ok and type(sessions) == "table" and #sessions > 0 then
		return best_session_by_title(sessions, title_hint)
	end
	return nil
end

---Query the server for the most recently updated session in the given directory.
---When title_hint is provided, fetches multiple sessions and prefers a title match.
---Calls callback with the session table, or nil if none found.
---@param port number
---@param directory string
---@param callback fun(session: opencode.cli.client.Session|nil)
---@param title_hint string|nil
local function get_session_for_dir(port, directory, callback, title_hint)
	debug_call("get_session_for_dir", { port = port, directory = directory, title_hint = title_hint })
	local encoded = directory:gsub("([^%w%-_%.~/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local limit = title_hint and 20 or 1
	local path = "/session?directory=" .. encoded .. "&limit=" .. tostring(limit)
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
				vim.schedule(function() callback(best_session_by_title(sessions, title_hint)) end)
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
	debug_call("get_client_dir_for_port", { port = port, server_cwd = server_cwd })
	local pane_ctx = nil
	if system.in_tmux() and state.opts.find_sibling == true and sibling_panes_by_tty then
		pane_ctx = sibling_panes_by_tty()
	end
	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if args and args:find("opencode", 1, true) then
			local attach_port = args:match("%-%-attach=.-:(%d+)") or args:match("attach%s+.-:(%d+)")
			local attach_port_num = tonumber(attach_port)
			local is_sibling_tty = pane_ctx == nil or (tty and tty ~= "??" and pane_ctx.siblings_by_tty[tty] ~= nil)
			local pane_meta = pane_ctx and tty and pane_ctx.siblings_by_tty[tty] or nil
			-- P({
			-- 	fn = "get_client_dir_for_port:opencode_process",
			-- 	pid = pid,
			-- 	tty = tty,
			-- 	args = args,
			-- 	attach_port_raw = attach_port,
			-- 	attach_port_num = attach_port_num,
			-- 	target_port = port,
			-- 	attach_matches_target = attach_port_num == port,
			-- 	is_sibling_tty = is_sibling_tty,
			-- 	pane_meta = pane_meta,
			-- })
			if attach_port_num == port and is_sibling_tty then
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
	debug_call("parse_target_port_from_args", { args = args })
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
	debug_call("process_matches_port", { pid = pid, args = args, port = port })
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

---Resolve sibling pane metadata for the current tmux window.
---Returns nil when tmux context cannot be resolved.
---@return { current_pane_index: number, siblings_by_tty: table<string, { pane_index: number, pane_title: string }> }|nil
sibling_panes_by_tty = function()
	local current_pane = tmux.current_pane_id()
	if not current_pane then
		return nil
	end

	local current_loc = system.run({ "tmux", "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}" })
	if current_loc == "" then
		return nil
	end

	local current_window = current_loc:match("^([^%.]+)")
	if not current_window then
		return nil
	end

	local siblings_by_tty = {}
	local pane_lines = system.run_lines({
		"tmux",
		"list-panes",
		"-t",
		current_window,
		"-F",
		"#{pane_id}\t#{pane_tty}\t#{pane_index}\t#{pane_title}",
	})

	for _, line in ipairs(pane_lines) do
		local pane_id, pane_tty, pane_index, pane_title = line:match("^(%%%d+)\t([^\t]+)\t([^\t]+)\t(.*)$")
		if pane_id and pane_tty and pane_index and pane_id ~= current_pane then
			local tty = pane_tty:gsub("^/dev/", "")
			siblings_by_tty[tty] = {
				pane_index = tonumber(pane_index) or 0,
				pane_title = pane_title or "",
			}
		end
	end

	return {
		current_pane_index = tonumber(current_loc:match("%.(%d+)$") or "") or 0,
		siblings_by_tty = siblings_by_tty,
	}
end

---@return number[]
function M.sibling_ports()
	debug_call("sibling_ports", nil)
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return {}
	end

	local pane_ctx = sibling_panes_by_tty()
	if not pane_ctx then
		return {}
	end

	local seen = {}
	local ports = {}

	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and args and tty ~= "??" and args:find("opencode", 1, true) and pane_ctx.siblings_by_tty[tty] then
			local parsed_port = parse_target_port_from_args(args)
			if parsed_port and not seen[parsed_port] then
				seen[parsed_port] = true
				table.insert(ports, parsed_port)
			end

			local lsof_lines = system.run_lines({ "lsof", "-w", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-a", "-p", pid })
			for _, lsof_line in ipairs(lsof_lines) do
				local port = tonumber(lsof_line:match(":(%d+)%s*%(LISTEN%)"))
				if port and not seen[port] then
					seen[port] = true
					table.insert(ports, port)
				end
			end
		end
	end

    system.debug("found ports: " .. table.concat(ports, ", "))
	return ports
end

---Find candidates for a sibling opencode process on the given port within the current tmux window.
---Returns a list sorted by pane proximity, each with pid/tty/args/pane_index/pane_title.
---@param port number
---@return table[]
local function sibling_candidates_for_port(port)
	debug_call("sibling_candidates_for_port", { port = port })
	local pane_ctx = sibling_panes_by_tty()
	if not pane_ctx then
		return {}
	end

	local candidates = {}
	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and args and args:find("opencode", 1, true) and tty ~= "??" then
			local pane_meta = pane_ctx.siblings_by_tty[tty]
			if pane_meta then
				if process_matches_port(pid, args, port) then
					table.insert(candidates, {
						pid = pid,
						tty = tty,
						args = args,
						pane_index = pane_meta.pane_index,
						pane_title = pane_meta.pane_title,
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		local a_dist = math.abs((a.pane_index or 0) - pane_ctx.current_pane_index)
		local b_dist = math.abs((b.pane_index or 0) - pane_ctx.current_pane_index)
		if a_dist ~= b_dist then return a_dist < b_dist end
		return (a.pane_index or 0) < (b.pane_index or 0)
	end)
	return candidates
end

---@param pid string
---@return string|nil
local get_process_cwd

---@param candidates table[]
---@return string|nil
local function sibling_pane_session_title_from_candidates(candidates)
	for _, candidate in ipairs(candidates) do
		local title = parse_session_title_from_pane(candidate.pane_title)
		if title then
			return title
		end
	end
	return nil
end

---@param candidates table[]
---@param fallback_directory string
---@return string
local function target_directory_from_candidates(candidates, fallback_directory)
	for _, candidate in ipairs(candidates) do
		local dir = parse_dir_from_args(candidate.args) or get_process_cwd(candidate.pid)
		if dir and dir ~= "" then
			return dir
		end
	end

	return fallback_directory
end

---Get the opencode session title from the closest sibling pane running opencode on this port.
---Parses the tmux pane title (format "OC | <session title>") of the first candidate.
---@param port number
---@return string|nil
local function sibling_pane_session_title(port)
	debug_call("sibling_pane_session_title", { port = port })
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return nil
	end
	local candidates = sibling_candidates_for_port(port)
	local title = sibling_pane_session_title_from_candidates(candidates)
	if title then
		system.debug("Found sibling pane session title=" .. title)
		return title
	end
	return nil
end

get_process_cwd = function(pid)
	debug_call("get_process_cwd", { pid = pid })
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
---@return string
function M.target_directory_for_port(port, fallback_directory)
	debug_call("target_directory_for_port", { port = port, fallback_directory = fallback_directory })
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return fallback_directory
	end

	local candidates = sibling_candidates_for_port(port)
	return target_directory_from_candidates(candidates, fallback_directory)
end

---Resolve the target directory for a sibling opencode client on the given port.
---Prefers --dir from process args, then process cwd, then fallback_directory.
---@param port number
---@param fallback_directory string
---@param callback fun(directory: string)
function M.target_directory_for_port_async(port, fallback_directory, callback)
	debug_call("target_directory_for_port_async", { port = port, fallback_directory = fallback_directory })
	callback(M.target_directory_for_port(port, fallback_directory))
end

---Select the most relevant session for a sibling opencode client on this port.
---Uses the sibling client's directory and pane title to find a matching session and selects it in the server.
---@param port number
---@param fallback_directory string
function M.select_session_for_port_async(port, fallback_directory)
	debug_call("select_session_for_port_async", { port = port, fallback_directory = fallback_directory })
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return
	end

	local title_hint = sibling_pane_session_title(port)

	M.target_directory_for_port_async(port, fallback_directory, function(directory)
		if not directory or directory == "" then
			system.debug("No sibling directory resolved for session selection on port " .. tostring(port))
			return
		end

		get_session_for_dir(port, directory, function(session)
			if not session or not session.id then
				system.debug(
					"No matching sibling session found for port "
						.. tostring(port)
						.. " directory="
						.. tostring(directory)
						.. " title_hint="
						.. tostring(title_hint)
				)
				return
			end

			require("opencode.cli.client").select_session(port, session.id)
			system.debug(
				"Selected sibling session"
					.. " port="
					.. tostring(port)
					.. " session="
					.. tostring(session.id)
					.. " title="
					.. tostring(session.title)
					.. " directory="
					.. tostring(directory)
			)
		end, title_hint)
	end)
end

---Resolve the session ID for the sibling target directory on this port.
---Uses the sibling pane title to prefer the session the TUI is actually viewing.
---@param port number
---@param fallback_directory string
---@return string|nil session_id
---@return string|nil directory
function M.resolve_target_session(port, fallback_directory)
	debug_call("resolve_target_session", { port = port, fallback_directory = fallback_directory })
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return nil, fallback_directory
	end

	local candidates = sibling_candidates_for_port(port)
	local directory = target_directory_from_candidates(candidates, fallback_directory)
	if not directory or directory == "" then
		return nil, nil
	end
	local title_hint = sibling_pane_session_title_from_candidates(candidates)
	local session = get_session_for_dir_sync(port, directory, title_hint)
	if session and session.id then
		system.debug(
			"Resolved target session"
				.. " port=" .. tostring(port)
				.. " session=" .. tostring(session.id)
				.. " title=" .. tostring(session.title)
				.. " directory=" .. tostring(directory)
				.. " title_hint=" .. tostring(title_hint)
		)
		return session.id, directory
	end
	return nil, directory
end

---@param servers opencode.cli.server.Server[]
---@return opencode.cli.server.Server[]
function M.unique_by_port(servers)
	debug_call("unique_by_port", { server_count = #servers })
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
	debug_call("get_server", { port = port })
	local Promise = require("opencode.promise")
	local client = require("opencode.cli.client")

	local title_hint = sibling_pane_session_title(port)

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
					end, title_hint)
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
	debug_call("servers_from_ports", { ports = ports })
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
	debug_call("sibling_servers", nil)
	local ports = M.sibling_ports()
	return M.servers_from_ports(ports)
end

return M
