local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local probes = require("zephyr.probes")
local rtt = require("zephyr.rtt")

local probe = { finder = "jlink", serial = "683000000", name = "J-Link OB" }

-- A TCP server on 127.0.0.1 (a free port, or `port`) standing in for the RTT telnet port.
local function server(port)
	local srv = vim.uv.new_tcp()
	assert(srv:bind("127.0.0.1", port or 0))
	local s = { clients = {}, received = "" }
	srv:listen(8, function()
		local client = vim.uv.new_tcp()
		srv:accept(client)
		table.insert(s.clients, client)
		client:read_start(function(_, data)
			if data then
				s.received = s.received .. data
			end
		end)
	end)
	s.port = srv:getsockname().port
	s.close = function()
		for _, c in ipairs(s.clients) do
			if not c:is_closing() then
				c:close()
			end
		end
		srv:close()
	end
	return s
end

local function free_port()
	local s = server()
	local port = s.port
	s.close()
	return port
end

local function on_events(names)
	local got = {}
	local ids = {}
	for _, name in ipairs(names) do
		table.insert(
			ids,
			vim.api.nvim_create_autocmd("User", {
				pattern = name,
				callback = function(ev)
					table.insert(got, { name = name, data = ev.data })
				end,
			})
		)
	end
	got.clear = function()
		for _, id in ipairs(ids) do
			pcall(vim.api.nvim_del_autocmd, id)
		end
	end
	return got
end

describe("rtt command builders", function()
	local root, cfg

	before_each(function()
		root = h.copy_fixture("builds/app")
		cfg = build_config.read(root .. "/build")
	end)

	it("reads the jlink runner arguments from runners.yaml", function()
		assert.are.same({ device = "nRF52840_xxAA", speed = "4000" }, rtt.jlink_args(cfg))
		assert.are.same({}, rtt.parse_jlink_args("args:\n  nrfjprog:\n    - --device=x\n"))
	end)

	it("builds west rtt with the probe's serial", function()
		local want = { "west", "rtt", "-d", root .. "/build", "--dev-id", "683000000" }
		assert.are.same(want, rtt.west_command(cfg, { probe = probe }))
		assert.are.same({ "west", "rtt", "-d", root .. "/build" }, rtt.west_command(cfg))
	end)

	it("uses jlink when the debug-runner cannot do RTT", function()
		local path = root .. "/build/zephyr/runners.yaml"
		local text = table.concat(vim.fn.readfile(path), "\n"):gsub("debug%-runner: jlink", "debug-runner: nrfjprog")
		vim.fn.writefile(vim.split(text, "\n"), path)
		assert.are.same({ "west", "rtt", "-d", root .. "/build", "-r", "jlink" }, rtt.west_command(cfg))
	end)

	it("builds the JLinkGDBServer fallback and JLinkRTTClient", function()
		assert.are.same({
			"JLinkGDBServer", "-if", "SWD", "-speed", "auto", "-device", "nRF52840_xxAA",
			"-rtttelnetport", "19021", "-nohalt", "-nogui", "-select", "usb=683000000",
		}, rtt.server_command(cfg, { probe = probe }))
		assert.are.same({ "JLinkRTTClient", "-RTTTelnetPort", "19022" }, rtt.client_command(19022))
	end)
end)

describe("rtt.has_west_rtt", function()
	local calls
	after_each(function()
		calls.restore()
		rtt._reset_cache()
	end)

	it("checks west rtt --help once per Zephyr base", function()
		calls = h.stub_process(function()
			return { code = 1 }
		end)
		local app = { dir = "/a", name = "a" }
		local cfg = { dir = "/a/build", zephyr_base = "/nonexistent/zephyr" }
		local got = {}
		rtt.has_west_rtt(app, cfg, function(ok) table.insert(got, ok) end)
		rtt.has_west_rtt(app, cfg, function(ok) table.insert(got, ok) end)
		assert.are.same({ false, false }, got)
		assert.are.equal(1, #calls)
		assert.are.same({ "west", "rtt", "--help" }, calls[1].cmd)
	end)
end)

describe("rtt.stream", function()
	local srv, events

	before_each(function()
		events = on_events({ "ZephyrRttStarted", "ZephyrRttStopped" })
	end)

	after_each(function()
		events.clear()
		if srv then
			srv.close()
			srv = nil
		end
	end)

	it("splits chunks into lines, sends, and closes", function()
		srv = server()
		local lines, connected = {}, false
		local stream = rtt.stream({ port = srv.port, on_connect = function() connected = true end }, function(line)
			table.insert(lines, line)
		end)
		assert.is_true(vim.wait(2000, function() return connected and #srv.clients == 1 end))
		assert.is_true(stream.is_connected())
		local c = srv.clients[1]
		c:write("hello\r\nwor")
		c:write("ld\npart")
		c:write("ial\r\n\nlast")
		assert.is_true(vim.wait(2000, function() return #lines == 4 end))
		assert.are.same({ "hello", "world", "partial", "" }, lines)

		assert.is_true(stream.send("reset\n"))
		assert.is_true(vim.wait(2000, function() return srv.received == "reset\n" end))

		stream.close()
		assert.is_true(vim.wait(2000, function() return #events == 2 end))
		assert.are.same({ "hello", "world", "partial", "", "last" }, lines) -- the partial line is flushed
		assert.are.equal("ZephyrRttStarted", events[1].name)
		assert.are.same({ kind = "stream", host = "127.0.0.1", port = srv.port }, events[1].data)
		assert.are.equal("ZephyrRttStopped", events[2].name)
		assert.is_false(stream.is_connected())
		assert.is_false(stream.send("x"))
	end)

	it("ends when the server closes the connection", function()
		srv = server()
		local closed, err = false, "unset"
		rtt.stream({ port = srv.port, on_close = function(e) closed, err = true, e end }, function() end)
		assert.is_true(vim.wait(2000, function() return #srv.clients == 1 end))
		srv.clients[1]:close()
		assert.is_true(vim.wait(2000, function() return closed end))
		assert.is_nil(err)
		assert.are.equal("ZephyrRttStopped", events[#events].name)
	end)

	it("retries until the server listens", function()
		local port = free_port()
		local lines, connected = {}, false
		local opts = { port = port, retries = 20, retry_delay = 50, on_connect = function() connected = true end }
		local stream = rtt.stream(opts, function(l)
			table.insert(lines, l)
		end)
		vim.wait(200)
		assert.is_false(connected)
		srv = server(port)
		assert.is_true(vim.wait(3000, function() return connected and #srv.clients == 1 end))
		srv.clients[1]:write("up\n")
		assert.is_true(vim.wait(2000, function() return #lines == 1 end))
		stream.close()
		assert.is_true(vim.wait(2000, function() return #events == 2 end))
	end)

	it("gives up after the retries", function()
		local port = free_port()
		local err
		rtt.stream({ port = port, retries = 2, retry_delay = 10, on_close = function(e) err = e end }, function() end)
		assert.is_true(vim.wait(2000, function() return err ~= nil end))
		assert.matches("could not connect", err)
		assert.are.equal(0, #events) -- never started, so no Stopped either
	end)

	it("starts JLinkGDBServer first with start_server and stops it on close", function()
		local restore_state = h.temp_state()
		local root = h.copy_fixture("builds/app")
		local app = app_mod.from_dir(root)
		local cfg = build_config.read(root .. "/build")
		probes.select({ topdir = app.dir }, probe)
		local killed = false
		local process = require("zephyr.process")
		local saved = process.run
		local cmd
		process.run = function(c)
			cmd = c
			return { kill = function() killed = true end }
		end
		srv = server()
		local connected = false
		local stream = rtt.stream(
			{ port = srv.port, start_server = true, app = app, config = cfg, on_connect = function()
				connected = true
			end },
			function() end
		)
		process.run = saved
		assert.are.equal("JLinkGDBServer", cmd[1])
		assert.are.equal("usb=683000000", cmd[#cmd])
		assert.is_true(vim.tbl_contains(cmd, tostring(srv.port)))
		assert.is_true(vim.wait(2000, function() return connected end))
		stream.close()
		assert.is_true(killed)
		assert.is_true(vim.wait(2000, function() return #events == 2 end))
		assert.are.equal("683000000", events[1].data.probe.serial)
		restore_state()
	end)
end)

describe("rtt viewer", function()
	local root, app, cfg, calls, saved_jobstart, saved_termopen, started, help_code, restore_state

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
		cfg = build_config.read(root .. "/build")
		build_config.activate(app, cfg)
		probes.select({ topdir = app.dir }, probe)
		help_code = 0
		calls = h.stub_process(function(call)
			if call.cmd[2] == "rtt" then
				return { code = help_code }
			end
			return { code = 0 }
		end)
		started = {}
		saved_jobstart, saved_termopen = vim.fn.jobstart, vim.fn.termopen
		local function fake(cmd, opts)
			table.insert(started, { cmd = cmd, opts = opts, buf = vim.api.nvim_get_current_buf() })
			return 42
		end
		vim.fn.jobstart, vim.fn.termopen = fake, fake
	end)

	after_each(function()
		vim.fn.jobstart, vim.fn.termopen = saved_jobstart, saved_termopen
		calls.restore()
		rtt._reset_cache()
		require("zephyr.ui.rtt").viewer = nil
		vim.cmd("silent! only")
		restore_state()
	end)

	it("runs west rtt in a terminal with the active probe", function()
		local events = on_events({ "ZephyrRttStarted", "ZephyrRttStopped" })
		local viewer
		rtt.open_viewer(app, cfg, {}, function(v) viewer = v end)
		assert.are.equal("west", viewer.mode)
		assert.are.same({ "west", "rtt", "-d", root .. "/build", "--dev-id", "683000000" }, started[1].cmd)
		assert.are.equal(viewer.buf, started[1].buf)
		assert.are.equal(app.dir, started[1].opts.cwd)
		assert.are.equal("viewer", events[1].data.kind)
		started[1].opts.on_exit(42, 0)
		assert.are.equal("ZephyrRttStopped", events[2].name)
		events.clear()
	end)

	it("falls back to JLinkGDBServer + JLinkRTTClient without west rtt", function()
		help_code = 2
		local viewer
		rtt.open_viewer(app, cfg, {}, function(v) viewer = v end)
		assert.are.equal("jlink", viewer.mode)
		assert.are.same({ "west", "rtt", "--help" }, calls[1].cmd)
		assert.are.equal("JLinkGDBServer", calls[2].cmd[1])
		assert.are.same({ "JLinkRTTClient", "-RTTTelnetPort", "19021" }, started[1].cmd)
	end)

	it(":Zephyr rtt opens a split and :Zephyr rtt stop stops it", function()
		local ui = require("zephyr.ui.rtt")
		local saved_notify, saved_jobstop = vim.notify, vim.fn.jobstop
		vim.notify = function() end
		local stopped
		vim.fn.jobstop = function(id) stopped = id end
		local wins = #vim.api.nvim_list_wins()
		ui.open(app)
		assert.are.equal(wins + 1, #vim.api.nvim_list_wins())
		assert.are.equal(1, #started)
		assert.are.equal(vim.fn.bufwinid(ui.viewer.buf), vim.api.nvim_get_current_win())
		ui.open(app) -- already running: shown, not started again
		assert.are.equal(1, #started)
		ui.run({ "stop" })
		assert.are.equal(42, stopped)
		assert.is_nil(ui.viewer)
		vim.notify, vim.fn.jobstop = saved_notify, saved_jobstop
	end)
end)
