local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local flash = require("zephyr.flash")
local probes = require("zephyr.probes")
local registry = require("zephyr.registry")

local probe = { finder = "jlink", serial = "683000000", name = "J-Link PRO" }

describe("flash.parse_runners", function()
	it("reads the runner list and default runners", function()
		local text = table.concat(vim.fn.readfile(h.fixtures .. "/builds/app/build/zephyr/runners.yaml"), "\n")
		assert.are.same({
			runners = { "nrfjprog", "nrfutil", "jlink", "pyocd", "openocd" },
			flash_runner = "nrfjprog",
			debug_runner = "jlink",
		}, flash.parse_runners(text))
	end)

	it("copes with quotes and comments", function()
		local parsed = flash.parse_runners("flash-runner: 'jlink' # default\nrunners: [jlink]\n")
		assert.are.equal("jlink", parsed.flash_runner)
	end)
end)

describe("flash.command", function()
	local cfg = { dir = "/a/build" }

	it("lets west pick the runner and probe by default", function()
		assert.are.same({ "west", "flash", "-d", "/a/build" }, flash.command(cfg))
	end)

	it("passes runner, probe serial and erase", function()
		assert.are.same(
			{ "west", "flash", "-d", "/a/build", "-r", "jlink", "--dev-id", "683000000", "--erase" },
			flash.command(cfg, { runner = "jlink", probe = probe, erase = true })
		)
	end)
end)

describe("flash.run", function()
	local root, app, restore_state, calls, events

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
		app.workspace = { topdir = "/ws" }
		registry._reset()
		registry.register("toolchain_provider", {
			name = "fake",
			find = function()
				return { { provider = "fake", id = "fake-1", name = "Fake", version = "1", path = "/tc" } }
			end,
			env = function(tc)
				return { ZEPHYR_SDK_INSTALL_DIR = tc.path }
			end,
		})
		events = {}
		vim.api.nvim_create_augroup("flash_spec", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = "flash_spec",
			pattern = { "ZephyrFlashStarted", "ZephyrFlashFinished" },
			callback = function(ev)
				table.insert(events, { name = ev.match, data = ev.data })
			end,
		})
	end)

	after_each(function()
		vim.api.nvim_del_augroup_by_name("flash_spec")
		if calls then
			calls.restore()
			calls = nil
		end
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		registry.register("probe_finder", require("zephyr.probes.jlink").finder)
		restore_state()
	end)

	it("reads the default runner from runners.yaml of a plain build", function()
		assert.are.equal("nrfjprog", (flash.default_runner(build_config.read(root .. "/build"))))
	end)

	it("reads the default runner from the app image of a sysbuild build", function()
		local cfg = build_config.read(root .. "/build_nrf5340dk_nrf5340_cpuapp")
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp/app/zephyr/runners.yaml", flash.runners_file(cfg))
		assert.are.equal("nrfutil", (flash.default_runner(cfg)))
	end)

	it("reports a missing runners.yaml", function()
		local runner, err = flash.default_runner({ dir = root, image_dir = root })
		assert.is_nil(runner)
		assert.matches("no runners.yaml", err)
	end)

	it("runs west flash on the active probe with the toolchain env and streams output", function()
		probes.select(app.workspace, probe)
		calls = h.stub_process(function()
			return { code = 0, stdout_lines = { "-- west flash: using runner nrfjprog" }, stderr_lines = { "warn" } }
		end)
		local lines, result = {}, nil
		local started = flash.run(app, build_config.read(root .. "/build"), {
			erase = true,
			on_output = function(line, stream)
				table.insert(lines, stream .. ":" .. line)
			end,
			on_exit = function(r)
				result = r
			end,
		})
		assert.is_true(started)
		assert.are.same(
			{ "west", "flash", "-d", root .. "/build", "--dev-id", "683000000", "--erase" },
			calls[1].cmd
		)
		assert.are.equal(root, calls[1].opts.cwd)
		assert.are.same({ ZEPHYR_SDK_INSTALL_DIR = "/tc" }, calls[1].opts.env)
		assert.are.same({ "stdout:-- west flash: using runner nrfjprog", "stderr:warn" }, lines)
		assert.is_true(result.ok)
		assert.are.equal("nrfjprog", result.runner)
		assert.are.same(probe, result.probe)

		assert.are.same({ "ZephyrFlashStarted", "ZephyrFlashFinished" }, vim.tbl_map(function(e)
			return e.name
		end, events))
		assert.are.equal("nrfjprog", events[1].data.runner)
		assert.are.equal(root .. "/build", events[2].data.build_dir)
		assert.is_true(events[2].data.ok)
		assert.are.equal("683000000", events[2].data.probe.serial)
		assert.is_false(flash.is_running(root .. "/build"))
	end)

	it("uses an explicit runner and probe, and reports failure", function()
		calls = h.stub_process(function()
			return { code = 2 }
		end)
		local result
		flash.run(app, build_config.read(root .. "/build_nrf5340dk_nrf5340_cpuapp"), {
			runner = "jlink",
			probe = { finder = "nrfutil", serial = "1050234567", name = "nRF5340 DK" },
			on_exit = function(r)
				result = r
			end,
		})
		assert.are.same({
			"west",
			"flash",
			"-d",
			root .. "/build_nrf5340dk_nrf5340_cpuapp",
			"-r",
			"jlink",
			"--dev-id",
			"1050234567",
		}, calls[1].cmd)
		assert.is_false(result.ok)
		assert.are.equal(2, result.code)
		assert.are.equal("jlink", result.runner)
		assert.is_false(events[2].data.ok)
	end)

	it("refuses an unbuilt configuration and a second flash while one runs", function()
		local started, err = flash.run(app, { dir = root .. "/new", name = "new", exists = false })
		assert.is_false(started)
		assert.matches("not been built", err)

		local pending
		local process = require("zephyr.process")
		local saved = process.run
		process.run = function(_, _, on_exit)
			pending = on_exit
		end
		local cfg = build_config.read(root .. "/build")
		assert.is_true(flash.run(app, cfg))
		assert.is_false(flash.run(app, cfg))
		pending({ code = 0, stdout = "", stderr = "" })
		process.run = saved
		assert.is_false(flash.is_running(cfg.dir))
	end)
end)
