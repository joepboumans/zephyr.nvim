local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local registry = require("zephyr.registry")

local function find(items, pred)
	for _, i in ipairs(items) do
		if pred(i) then
			return i
		end
	end
end

describe("build.parse", function()
	it("parses GCC diagnostics, stripping colours and resolving relative paths", function()
		local items = build.parse(h.output("gcc.txt"), { cwd = "/ws/app/build" })
		assert.are.same({
			{ filename = "/ws/app/src/util.h", lnum = 1, col = 28, type = "E", text = "expected ';' before '}' token" },
			{
				filename = "/ws/app/src/main.c",
				lnum = 2,
				col = 21,
				type = "W",
				text = "implicit declaration of function 'g' [-Wimplicit-function-declaration]",
			},
			{ filename = "/ws/app/src/main.c", lnum = 3, col = 10, type = "E", text = "foo.h: No such file or directory" },
			{
				filename = "/ws/app/src/main.c",
				lnum = 3,
				col = 10,
				type = "N",
				text = "each undeclared identifier is reported only once",
			},
		}, items)
	end)

	it("parses linker errors", function()
		local items = build.parse(h.output("ld.txt"), { cwd = "/ws/app/build" })
		assert.are.equal(4, #items)
		assert.are.same(
			{ filename = "/ws/app/src/main.c", lnum = 2, col = 0, type = "E", text = "undefined reference to `ext'" },
			items[1]
		)
		assert.are.equal("/ws/app/build/main.c", items[2].filename)
		assert.are.equal("zephyr/zephyr_pre0.elf section `text' will not fit in region `FLASH'", items[3].text)
		assert.are.equal("region `FLASH' overflowed by 1234 bytes", items[4].text)
		assert.is_nil(items[4].filename)
	end)

	it("parses CMake, Kconfig and devicetree errors", function()
		local items = build.parse(h.output("cmake.txt"), { cwd = "/ws/app/build", source_dir = "/ws/app" })
		assert.are.equal(4, #items)
		assert.are.same({
			filename = "/ws/app/app.overlay",
			lnum = 12,
			col = 5,
			type = "E",
			text = "parse error: expected number or parenthesized expression",
		}, items[1])
		assert.are.same({
			filename = "/ws/app/prj.conf",
			lnum = 3,
			col = 0,
			type = "W",
			text = "attempt to assign the value 'y' to the undefined symbol FOO",
		}, items[2])
		assert.are.same({
			filename = "/ws/zephyr/cmake/modules/extensions.cmake",
			lnum = 2850,
			col = 0,
			type = "E",
			text = "BOARD is not being defined on the CMake command-line, in the environment or by the app.",
		}, items[3])
		assert.are.same(
			{ filename = "/ws/app/CMakeLists.txt", lnum = 7, col = 0, type = "W", text = "Something to look at" },
			items[4]
		)
	end)
end)

describe("build.parse on configure failures", function()
	local zephyr_base = vim.fn.getcwd() .. "/tests/fixtures/ncsws/zephyr"
	local items

	before_each(function()
		items = build.parse(h.output("kconfig.txt"), {
			cwd = "/ws/app/build/vt_connect",
			source_dir = "/ws/app",
			zephyr_base = zephyr_base,
		})
	end)

	it("puts the Kconfig message first, also without a file and line", function()
		assert.is_nil(items[1].filename)
		assert.are.equal("E", items[1].type)
		assert.matches("^WOCKEL_GPIO %(defined at .*%) was assigned the value 'y' but got the value 'n'", items[1].text)
		assert.are.same(
			{ filename = "/ws/app/prj.conf", lnum = 12, col = 0, type = "E", text = "attempt to assign the value 'y' to the undefined symbol VT_CONNECT_FEATURE" },
			items[2]
		)
	end)

	it("names the failing sysbuild image, resolving cmake/modules into the Workspace's Zephyr", function()
		assert.are.equal("CMake configure failed for Zephyr project: vt_connect", items[3].text)
		assert.are.equal(zephyr_base .. "/share/sysbuild/cmake/modules/sysbuild_extensions.cmake", items[3].filename)
		assert.are.equal(514, items[3].lnum)
	end)

	it("gives Kconfig's CMake error the Kconfig message instead of the return code", function()
		assert.are.equal("/ws/zephyr/cmake/modules/kconfig.cmake", items[4].filename)
		assert.matches("^Kconfig failed: WOCKEL_GPIO", items[4].text)
		assert.are.equal("No SOURCES given to Zephyr library: drivers__charger", items[5].text)
		assert.are.equal(5, #items)
	end)

	it("resolves cmake/modules into Zephyr even when the file is not there", function()
		local got = build.parse({ "CMake Error at cmake/modules/sysbuild_images.cmake:20 (message):", "  boom" }, {
			source_dir = "/ws/app",
			zephyr_base = "/nowhere/zephyr",
		})
		assert.are.equal("/nowhere/zephyr/share/sysbuild/cmake/modules/sysbuild_images.cmake", got[1].filename)
	end)
end)

describe("build.command", function()
	local existing = { dir = "/a/build", exists = true, board = "nrf52dk/nrf52832", app_dir = "/a" }
	local new = { dir = "/a/build_x", exists = false, board = "x/y", app_dir = "/a" }

	it("lets west read the board of an existing build dir", function()
		assert.are.same({ "west", "build", "-d", "/a/build" }, build.command(existing))
	end)

	it("passes the board and pristine flag", function()
		assert.are.same(
			{ "west", "build", "-d", "/a/build", "-b", "nrf52dk/nrf52832", "-p", "always" },
			build.command(existing, { pristine = true })
		)
	end)

	it("passes board and source dir for a new configuration", function()
		assert.are.same({ "west", "build", "-d", "/a/build_x", "-b", "x/y", "/a" }, build.command(new))
	end)
end)

describe("build.run", function()
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
		vim.api.nvim_create_augroup("build_spec", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = "build_spec",
			pattern = { "ZephyrBuildStarted", "ZephyrBuildFinished" },
			callback = function(ev)
				table.insert(events, { name = ev.match, data = ev.data })
			end,
		})
	end)

	after_each(function()
		vim.api.nvim_del_augroup_by_name("build_spec")
		if calls then
			calls.restore()
		end
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		restore_state()
	end)

	it("runs west build with the toolchain env, streams output and reports errors", function()
		calls = h.stub_process(function()
			return { code = 1, stdout_lines = { "[1/2] Building" }, stderr_lines = h.output("gcc.txt") }
		end)
		local cfg = build_config.read(root .. "/build")
		local lines, result = {}, nil
		local started = build.run(app, cfg, {
			pristine = true,
			on_output = function(line, stream)
				table.insert(lines, stream .. ":" .. line)
			end,
			on_exit = function(r)
				result = r
			end,
		})
		assert.is_true(started)
		assert.are.same(
			{ "west", "build", "-d", root .. "/build", "-b", "nrf52840dk/nrf52840", "-p", "always" },
			calls[1].cmd
		)
		assert.are.equal(root, calls[1].opts.cwd)
		assert.are.same({ ZEPHYR_SDK_INSTALL_DIR = "/tc" }, calls[1].opts.env)
		assert.are.equal("stdout:[1/2] Building", lines[1])
		assert.are.equal(1 + #h.output("gcc.txt"), #lines)

		assert.is_false(result.ok)
		assert.are.equal(4, #result.items)
		-- ../src/main.c from the image build dir
		assert.is_not_nil(find(result.items, function(i)
			return i.filename == root .. "/src/main.c" and i.type == "W"
		end))
		assert.are.same({ "ZephyrBuildStarted", "ZephyrBuildFinished" }, vim.tbl_map(function(e)
			return e.name
		end, events))
		local finished = events[2].data
		assert.are.equal(root .. "/build", finished.build_dir)
		assert.is_false(finished.ok)
		assert.is_number(finished.duration)
		assert.is_false(build.is_running(root .. "/build"))
	end)

	it("resolves relative paths against the sysbuild app image", function()
		calls = h.stub_process(function()
			return { code = 1, stderr_lines = { "../src/main.c:1:1: error: boom" } }
		end)
		local result
		build.run(app, build_config.read(root .. "/build_nrf5340dk_nrf5340_cpuapp"), {
			on_exit = function(r)
				result = r
			end,
		})
		-- ninja runs in <build>/app, so ../src is <build>/src
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp/src/main.c", result.items[1].filename)
	end)

	it("reports a successful build", function()
		calls = h.stub_process(function()
			return { code = 0 }
		end)
		local result
		build.run(app, build_config.read(root .. "/build"), {
			on_exit = function(r)
				result = r
			end,
		})
		assert.is_true(result.ok)
		assert.is_true(events[2].data.ok)
	end)
end)
