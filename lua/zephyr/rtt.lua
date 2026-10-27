-- RTT: the RTT viewer (`west rtt`, or JLinkGDBServer + JLinkRTTClient on
-- Zephyr older than 4.0, in a terminal) and the RTT stream (RTT output as
-- lines, read from the J-Link RTT telnet port).
local events = require("zephyr.events")
local flash = require("zephyr.flash")

local M = {}

M.default_host = "127.0.0.1"
M.default_port = 19021

-- Runners that support `west rtt` (Zephyr 4.0+).
local rtt_runners = { jlink = true, pyocd = true, openocd = true }

local function read_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local text = fd:read("*a")
	fd:close()
	return text
end

---Parse the jlink runner's arguments in runners.yaml (`args: jlink:`).
---@param text string
---@return { device: string|nil, speed: string|nil, iface: string|nil }
function M.parse_jlink_args(text)
	local out, in_args, in_jlink = {}, false, false
	for line in vim.gsplit(text or "", "\n", { plain = true }) do
		line = line:gsub("\r$", "")
		if line:match("^%S") then
			in_args, in_jlink = line:match("^args:") ~= nil, false
		elseif in_args and line:match("^  [%w_-]+:") then
			in_jlink = line:match("^  jlink:") ~= nil
		elseif in_jlink then
			local key, value = line:match("^%s*%-%s*%-%-([%w_-]+)[=%s]%s*(.-)%s*$")
			if key then
				value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
				if key == "device" then
					out.device = value
				elseif key == "speed" then
					out.speed = value
				elseif key == "iface" then
					out.iface = value
				end
			end
		end
	end
	return out
end

---The jlink runner's arguments for `config`, from its runners.yaml.
---@param config zephyr.BuildConfig
---@return { device: string|nil, speed: string|nil, iface: string|nil }
function M.jlink_args(config)
	return M.parse_jlink_args(read_file(flash.runners_file(config)) or "")
end

---The `west rtt` command line for `config`. When the board's debug-runner
---cannot do RTT but jlink is available, jlink is used (`-r jlink`).
---@param config zephyr.BuildConfig
---@param opts? { probe?: zephyr.Probe, runner?: string }
---@return string[]
function M.west_command(config, opts)
	opts = opts or {}
	local cmd = { "west", "rtt", "-d", config.dir }
	local runner = opts.runner
	if not runner then
		local runners = flash.parse_runners(read_file(flash.runners_file(config)) or "")
		local debug_runner = runners.debug_runner
		if debug_runner and not rtt_runners[debug_runner] and vim.tbl_contains(runners.runners, "jlink") then
			runner = "jlink"
		end
	end
	if runner then
		vim.list_extend(cmd, { "-r", runner })
	end
	if opts.probe and opts.probe.serial then
		vim.list_extend(cmd, { "--dev-id", opts.probe.serial })
	end
	return cmd
end

---The JLinkGDBServer command line that serves RTT for `config` on `port`
---without halting the target. The device comes from the jlink runner's
---`--device` in runners.yaml.
---@param config zephyr.BuildConfig
---@param opts? { probe?: zephyr.Probe, port?: integer }
---@return string[]
function M.server_command(config, opts)
	opts = opts or {}
	local args = M.jlink_args(config)
	local cmd = { "JLinkGDBServer", "-if", "SWD", "-speed", "auto" }
	if args.device then
		vim.list_extend(cmd, { "-device", args.device })
	end
	vim.list_extend(cmd, { "-rtttelnetport", tostring(opts.port or M.default_port), "-nohalt", "-nogui" })
	if opts.probe and opts.probe.serial then
		vim.list_extend(cmd, { "-select", "usb=" .. opts.probe.serial })
	end
	return cmd
end

---The JLinkRTTClient command line reading RTT from `port`.
---@param port? integer
---@return string[]
function M.client_command(port)
	return { "JLinkRTTClient", "-RTTTelnetPort", tostring(port or M.default_port) }
end

local function workspace_of(app, config)
	local ws = app.workspace
	if not ws and config.zephyr_base then
		ws = require("zephyr.workspace").find(config.zephyr_base)
	end
	return ws
end

---The Workspace, Probe and Active toolchain environment for `config`; `err`
---when the Toolchain's environment cannot be resolved.
local function context(app, config, probe)
	local ws = workspace_of(app, config)
	if not probe then
		probe = require("zephyr.probes").active(ws or { topdir = app.dir })
	end
	local env, err = require("zephyr.toolchain").env(app, config)
	return ws, probe, env, err
end

local west_rtt_cache = {}

---Forget which Zephyr versions have `west rtt`.
function M._reset_cache()
	west_rtt_cache = {}
end

---Find out (once per Zephyr base) whether `west rtt` exists, by its `--help` exit code.
---@param app zephyr.App
---@param config zephyr.BuildConfig
---@param cb fun(available: boolean)
function M.has_west_rtt(app, config, cb)
	local key = config.zephyr_base or (app.workspace and app.workspace.topdir) or app.dir
	if west_rtt_cache[key] ~= nil then
		return cb(west_rtt_cache[key])
	end
	local _, _, env = context(app, config, {})
	require("zephyr.process").run({ "west", "rtt", "--help" }, { cwd = app.dir, env = env }, function(res)
		west_rtt_cache[key] = res.code == 0
		cb(west_rtt_cache[key])
	end)
end

-- JLinkGDBServers we started. vim.system processes outlive Neovim, so they are
-- stopped on VimLeavePre; otherwise the server keeps the Probe and its ports.
local servers = {}

local function stop_server(server)
	if server and servers[server] then
		servers[server] = nil
		pcall(server.kill, server, 15)
	end
end

local function start_server(config, opts, cwd, env)
	local server
	server = require("zephyr.process").run(M.server_command(config, opts), { cwd = cwd, env = env }, function()
		if server then
			servers[server] = nil
		end
	end)
	if server then
		if next(servers) == nil then
			vim.api.nvim_create_autocmd("VimLeavePre", {
				group = vim.api.nvim_create_augroup("zephyr_rtt_servers", { clear = true }),
				callback = function()
					for s in pairs(servers) do
						stop_server(s)
					end
				end,
			})
		end
		servers[server] = true
	end
	return server
end

---@class zephyr.RttViewer
---@field buf integer terminal buffer
---@field job integer terminal job id
---@field mode "west"|"jlink" `west rtt`, or JLinkGDBServer + JLinkRTTClient
---@field cmd string[] the command in the terminal
---@field server vim.SystemObj|nil the JLinkGDBServer started for mode "jlink"
---@field stop fun() stop the viewer (and its JLinkGDBServer)

---@class zephyr.RttViewerOpts
---@field probe? zephyr.Probe read through this Probe; defaults to the Workspace's active Probe
---@field port? integer RTT telnet port for the JLinkGDBServer fallback (default 19021)
---@field win? integer window to show the terminal in (default: current)
---@field on_exit? fun(code: integer) when the terminal job ends

---Open the RTT viewer for `config` of `app` in a terminal buffer shown in
---`opts.win`: `west rtt` (Zephyr 4.0+), else JLinkGDBServer in the background
---with JLinkRTTClient in the terminal. Fires ZephyrRttStarted and ZephyrRttStopped
---(`ev.data`: kind "viewer", mode, app, build_dir, probe, cmd; code on stop).
---@param app zephyr.App
---@param config zephyr.BuildConfig
---@param opts? zephyr.RttViewerOpts
---@param cb fun(viewer: zephyr.RttViewer|nil, err: string|nil)
function M.open_viewer(app, config, opts, cb)
	opts = opts or {}
	if not config.exists then
		return cb(nil, config.name .. " has not been built yet")
	end
	local _, probe, env, err = context(app, config, opts.probe)
	if err then
		return cb(nil, err)
	end
	M.has_west_rtt(app, config, function(available)
		local port = opts.port or M.default_port
		local mode = available and "west" or "jlink"
		local cmd = available and M.west_command(config, { probe = probe }) or M.client_command(port)
		local win = opts.win or vim.api.nvim_get_current_win()
		if not vim.api.nvim_win_is_valid(win) then
			return cb(nil, "window closed")
		end

		local server
		if mode == "jlink" then
			server = start_server(config, { probe = probe, port = port }, app.dir, env)
		end

		local info = { kind = "viewer", mode = mode, app = app.dir, build_dir = config.dir, probe = probe, cmd = cmd }
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(win, buf)
		local viewer = { buf = buf, mode = mode, cmd = cmd, server = server }
		local job
		vim.api.nvim_buf_call(buf, function()
			job = require("zephyr.process").term(cmd, {
				cwd = app.dir,
				env = env,
				on_exit = function(_, code)
					stop_server(server)
					events.emit("RttStopped", vim.tbl_extend("force", info, { code = code }))
					if opts.on_exit then
						opts.on_exit(code)
					end
				end,
			})
		end)
		if not job or job <= 0 then
			stop_server(server)
			return cb(nil, "could not start " .. cmd[1])
		end
		viewer.job = job
		viewer.stop = function()
			pcall(vim.fn.jobstop, job)
		end
		events.emit("RttStarted", info)
		cb(viewer)
	end)
end

---@class zephyr.RttStreamOpts
---@field host? string default 127.0.0.1
---@field port? integer default 19021
---@field retries? integer connect attempts after the first (default 10); the server may still be starting
---@field retry_delay? integer ms between attempts (default 300)
---@field start_server? boolean start JLinkGDBServer first (needs `app` and `config`)
---@field app? zephyr.App
---@field config? zephyr.BuildConfig
---@field probe? zephyr.Probe for start_server; defaults to the Workspace's active Probe
---@field on_connect? fun()
---@field on_close? fun(err: string|nil) once, when the stream ends; err when it failed

---@class zephyr.RttStream
---@field send fun(text: string): boolean write `text` to the target's RTT down channel
---@field close fun() disconnect (and stop the JLinkGDBServer it started)
---@field is_connected fun(): boolean

---Read the RTT stream from the RTT telnet port as lines. `on_line` is called on
---the main loop for each line, without line endings. Fires ZephyrRttStarted on
---connect and ZephyrRttStopped on close (`ev.data`: kind "stream", host, port).
---@param opts? zephyr.RttStreamOpts
---@param on_line fun(line: string)
---@return zephyr.RttStream
function M.stream(opts, on_line)
	opts = opts or {}
	local host = opts.host or M.default_host
	local port = opts.port or M.default_port
	local retries = opts.retries or 10
	local delay = opts.retry_delay or 300
	local info = { kind = "stream", host = host, port = port }

	local tcp, timer, server
	local connected, closed, started = false, false, false
	local pending = ""

	local function deliver(line)
		vim.schedule(function()
			on_line(line)
		end)
	end

	local function feed(data)
		pending = pending .. data
		while true do
			local nl = pending:find("\n", 1, true)
			if not nl then
				break
			end
			deliver((pending:sub(1, nl - 1):gsub("\r$", "")))
			pending = pending:sub(nl + 1)
		end
	end

	local function finish(err)
		if closed then
			return
		end
		closed, connected = true, false
		if pending ~= "" then
			deliver((pending:gsub("\r$", "")))
			pending = ""
		end
		if timer and not timer:is_closing() then
			timer:close()
		end
		if tcp and not tcp:is_closing() then
			tcp:close()
		end
		stop_server(server)
		vim.schedule(function()
			if started then
				events.emit("RttStopped", vim.tbl_extend("force", info, { err = err }))
			end
			if opts.on_close then
				opts.on_close(err)
			end
		end)
	end

	local addr = host
	if not host:match("^%d+%.%d+%.%d+%.%d+$") and not host:find(":", 1, true) then
		local res = vim.uv.getaddrinfo(host, nil, { socktype = "stream" })
		addr = res and res[1] and res[1].addr or host
	end

	local attempt = 0
	local function connect()
		if closed then
			return
		end
		tcp = vim.uv.new_tcp()
		tcp:connect(addr, port, function(err)
			if closed then
				return
			end
			if err then
				tcp:close()
				if attempt >= retries then
					return finish(("could not connect to %s:%d: %s"):format(host, port, err))
				end
				attempt = attempt + 1
				timer = timer or vim.uv.new_timer()
				timer:start(delay, 0, connect)
				return
			end
			connected = true
			vim.schedule(function()
				if closed then
					return
				end
				started = true
				events.emit("RttStarted", info)
				if opts.on_connect then
					opts.on_connect()
				end
			end)
			tcp:read_start(function(rerr, data)
				if rerr then
					finish(rerr)
				elseif data then
					feed(data)
				else
					finish(nil) -- the server closed the connection
				end
			end)
		end)
	end

	if opts.start_server then
		assert(opts.app and opts.config, "start_server needs opts.app and opts.config")
		local _, probe, env, err = context(opts.app, opts.config, opts.probe)
		info.probe = probe
		if err then
			vim.schedule(function()
				if opts.on_close then
					opts.on_close(err)
				end
			end)
			closed = true
			return {
				send = function()
					return false
				end,
				close = function() end,
				is_connected = function()
					return false
				end,
			}
		end
		server = start_server(opts.config, { probe = probe, port = port }, opts.app.dir, env)
	end
	connect()

	return {
		send = function(text)
			if not connected or closed then
				return false
			end
			tcp:write(text)
			return true
		end,
		close = function()
			finish(nil)
		end,
		is_connected = function()
			return connected and not closed
		end,
	}
end

return M
