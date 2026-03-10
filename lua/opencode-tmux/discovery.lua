local state = require("opencode-tmux.state")
local system = require("opencode-tmux.system")
local tmux = require("opencode-tmux.tmux")

local M = {}

---@param s string
---@return string
local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param args string
---@return string|nil
local function parse_session_id_from_args(args)
	local session_id = args:match("%-%-session=([%w%-%_]+)")
		or args:match("%-%-session%s+([%w%-%_]+)")
		or args:match("%-s=([%w%-%_]+)")
		or args:match("%-s%s+([%w%-%_]+)")

	if session_id and session_id:match("^ses") then
		return session_id
	end

	return nil
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

---@param pane_title string
---@return string|nil
local function parse_session_hint_from_pane_title(pane_title)
	pane_title = trim(pane_title)
	if pane_title == "" or pane_title == "OpenCode" then
		return nil
	end

	local hint = pane_title:match("^OC%s*|%s*(.+)$") or pane_title
	hint = trim(hint)
	if hint == "" or hint == "OpenCode" then
		return nil
	end

	return hint
end

---@param hint string
---@param sessions opencode.cli.client.Session[]
---@return string|nil
local function match_session_id_by_title_hint(hint, sessions)
	if hint == "" then
		return nil
	end

	local matches = {}
	if hint:sub(-3) == "..." then
		local prefix = hint:sub(1, -4)
		for _, session in ipairs(sessions) do
			if session.title and session.title:find(prefix, 1, true) == 1 then
				table.insert(matches, session)
			end
		end
	else
		for _, session in ipairs(sessions) do
			if session.title == hint then
				table.insert(matches, session)
			end
		end
	end

	if #matches == 1 then
		return matches[1].id
	end

	return nil
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

	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,comm=" })
	for _, process in ipairs(process_lines) do
		local pid, tty, comm = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and comm and comm:find("opencode", 1, true) and tty ~= "??" then
			local pane_loc = tty_to_tmux[tty]
			if
				pane_loc
				and pane_loc:find(current_window .. ".", 1, true) == 1
				and pane_to_tmux[current_pane] ~= pane_loc
			then
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

---@param port number
---@param sessions opencode.cli.client.Session[]
---@return string|nil
function M.session_id_for_port(port, sessions)
	if not system.in_tmux() or state.opts.find_sibling ~= true then
		return nil
	end
	if not sessions or #sessions == 0 then
		return nil
	end

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

	local tty_to_tmux = {}
	local pane_to_tmux = {}
	local tty_to_title = {}
	local pane_lines = system.run_lines({
		"tmux",
		"list-panes",
		"-a",
		"-F",
		"#{pane_id}\t#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_title}",
	})
	for _, line in ipairs(pane_lines) do
		local pane_id, pane_tty, pane_loc, pane_title = line:match("^(%%%d+)\t([^\t]+)\t([^\t]+)\t(.*)$")
		if pane_id and pane_tty and pane_loc then
			local tty = pane_tty:gsub("^/dev/", "")
			tty_to_tmux[tty] = pane_loc
			pane_to_tmux[pane_id] = pane_loc
			tty_to_title[tty] = pane_title or ""
		end
	end

	local current_pane_index = tonumber(current_loc:match("%.(%d+)$") or "") or 0
	local tty_to_pane_index = {}
	for _, line in ipairs(pane_lines) do
		local pane_id, pane_tty, pane_loc = line:match("^(%%%d+)\t([^\t]+)\t([^\t]+)\t.*$")
		if pane_id and pane_tty and pane_loc then
			local tty = pane_tty:gsub("^/dev/", "")
			tty_to_pane_index[tty] = tonumber(pane_loc:match("%.(%d+)$") or "")
		end
	end

	local process_lines = system.run_lines({ "ps", "-eo", "pid=,tty=,args=" })
	local candidates = {}
	for _, process in ipairs(process_lines) do
		local pid, tty, args = process:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
		if pid and tty and args and args:find("opencode", 1, true) and tty ~= "??" then
			local pane_loc = tty_to_tmux[tty]
			if
				pane_loc
				and pane_loc:find(current_window .. ".", 1, true) == 1
				and pane_to_tmux[current_pane] ~= pane_loc
			then
				if process_matches_port(pid, args, port) then
					table.insert(candidates, {
						pid = pid,
						tty = tty,
						args = args,
						pane_title = tty_to_title[tty] or "",
						pane_index = tty_to_pane_index[tty] or 0,
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		local a_distance = math.abs((a.pane_index or 0) - current_pane_index)
		local b_distance = math.abs((b.pane_index or 0) - current_pane_index)
		if a_distance ~= b_distance then
			return a_distance < b_distance
		end
		return (a.pane_index or 0) < (b.pane_index or 0)
	end)

	for _, candidate in ipairs(candidates) do
		local session_id = parse_session_id_from_args(candidate.args)
		if session_id then
			return session_id
		end

		local pane_hint = parse_session_hint_from_pane_title(candidate.pane_title)
		if pane_hint then
			local matched_session_id = match_session_id_by_title_hint(pane_hint, sessions)
			if matched_session_id then
				return matched_session_id
			end
		end
	end

	return nil
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
			return Promise.all({
				cwd,
				Promise.new(function(resolve)
					client.get_sessions(port, function(session)
						local title = session[1] and session[1].title or "<No sessions>"
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
	local server = require("opencode.cli.server")

	if #ports == 0 then
		return Promise.resolve({})
	end

	local get_all = state.original_get_all or server.get_all
	return get_all()
		:catch(function()
			return {}
		end)
		:next(function(existing_servers)
			local discovered = {}
			local existing_by_port = {}

			for _, server_item in ipairs(existing_servers) do
				existing_by_port[server_item.port] = server_item
			end

			local missing_ports = {}
			for _, port in ipairs(ports) do
				local existing = existing_by_port[port]
				if existing then
					table.insert(discovered, existing)
				else
					table.insert(missing_ports, port)
				end
			end

			if #missing_ports == 0 then
				return discovered
			end

			local lookups = {}
			for _, port in ipairs(missing_ports) do
				table.insert(lookups, M.get_server(port))
			end

			return Promise.all_settled(lookups):next(function(results)
				for _, result in ipairs(results) do
					if result.status == "fulfilled" then
						table.insert(discovered, result.value)
					end
				end
				return discovered
			end)
		end)
end

---@return Promise<opencode.cli.server.Server[]>
function M.sibling_servers()
	return M.servers_from_ports(M.sibling_ports())
end

return M
