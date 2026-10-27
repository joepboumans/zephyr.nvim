local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")

describe("importing build directories", function()
	local restore_state, root, app, imported, files_before

	local function files_outside_zephyr_dir()
		local out = {}
		for path, type in vim.fs.dir(root, { depth = 10 }) do
			if type == "file" and not path:match("^app/%.zephyr/") then
				table.insert(out, path)
			end
		end
		table.sort(out)
		return out
	end

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("import")
		app = app_mod.from_dir(root .. "/app")
		imported = {}
		vim.api.nvim_create_augroup("import_spec", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = "import_spec",
			pattern = "ZephyrBuildConfigImported",
			callback = function(ev)
				table.insert(imported, ev.data.name)
			end,
		})
		files_before = files_outside_zephyr_dir()
	end)

	after_each(function()
		vim.api.nvim_del_augroup_by_name("import_spec")
		restore_state()
	end)

	it("imports a sysbuild build directory made by VS Code", function()
		build_config.list(app)
		local s = settings.get(app, app.dir .. "/build_vt")
		assert.are.same({
			build_dir = "build_vt",
			board = "nrf5340dk/nrf5340/cpuapp",
			conf_files = {}, -- prj.conf is Zephyr's default
			extra_conf_files = { "debug.conf" },
			overlays = { "app.overlay" },
			snippets = { "rtt-console" },
			sysbuild = true,
			optimization = "debug",
			board_roots = { "../custom" },
			cmake_args = { "-DNCS_TOOLCHAIN_VERSION=NONE", "-DCONFIG_DEBUG_THREAD_INFO=y" },
		}, s)
	end)

	it("imports a plain build directory", function()
		build_config.list(app)
		local s = settings.get(app, app.dir .. "/build_plain")
		assert.are.equal("nrf52840dk/nrf52840", s.board)
		assert.are.same({ "prj.conf", "debug.conf" }, s.conf_files)
		assert.is_false(s.sysbuild)
		assert.are.same({}, s.board_roots)
		assert.are.same({}, s.cmake_args)
	end)

	it("imports once, with a notification event naming the Build configuration", function()
		build_config.list(app)
		build_config.list(app)
		build_config.active(app)
		table.sort(imported)
		assert.are.same({ "build_plain", "build_vt" }, imported)
	end)

	it("recreates the build directory from what it imported", function()
		local cfg = build_config.get(app, app.dir .. "/build_vt")
		local cmd = require("zephyr.build").command(cfg, { app = app, pristine = true })
		assert.is_true(vim.tbl_contains(cmd, "-DBOARD_ROOT=" .. root .. "/custom"))
		assert.is_true(vim.tbl_contains(cmd, "-DEXTRA_CONF_FILE=" .. app.dir .. "/debug.conf"))
		assert.is_true(vim.tbl_contains(cmd, "-DCONFIG_DEBUG_OPTIMIZATIONS=y"))
		assert.is_true(vim.tbl_contains(cmd, "rtt-console"))
		assert.are.same({}, build_config.differences(app, cfg))
	end)

	it("warns about a build directory configured differently afterwards", function()
		local cfg = build_config.get(app, app.dir .. "/build_plain")
		-- A `west build -- -DEXTRA_CONF_FILE=...` by hand.
		local cache = app.dir .. "/build_plain/CMakeCache.txt"
		local lines = vim.fn.readfile(cache)
		table.insert(lines, "EXTRA_CONF_FILE:STRING=" .. app.dir .. "/debug.conf")
		vim.fn.writefile(lines, cache)
		local diffs = build_config.differences(app, cfg)
		assert.are.equal(1, #diffs)
		assert.are.equal("extra_conf_files", diffs[1].field)
		assert.are.equal("(none)", diffs[1].settings)
	end)

	it("writes nothing outside <topdir>/.zephyr/", function()
		build_config.list(app)
		assert.are.same(files_before, files_outside_zephyr_dir())
	end)
end)

describe("the default UI on a build directory that differs from its settings", function()
	local restore_state, root, app, saved_select, saved_notify, calls

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("import")
		app = app_mod.from_dir(root .. "/app")
		saved_select, saved_notify = vim.ui.select, vim.notify
		vim.notify = function() end
		calls = h.stub_process(function()
			return { code = 0 }
		end)
	end)

	after_each(function()
		calls.restore()
		vim.ui.select, vim.notify = saved_select, saved_notify
		vim.cmd("silent! only")
		restore_state()
	end)

	it("offers a Pristine build", function()
		local cfg = build_config.get(app, app.dir .. "/build_plain")
		build_config.activate(app, cfg)
		local cache = app.dir .. "/build_plain/CMakeCache.txt"
		local lines = vim.fn.readfile(cache)
		table.insert(lines, "SNIPPET:STRING=cdc-acm-console")
		vim.fn.writefile(lines, cache)
		local offered
		vim.ui.select = function(items, _, on_choice)
			offered = items
			on_choice(items[1])
		end
		require("zephyr.ui.build").build(app)
		assert.are.equal("Pristine build with the settings", offered[1])
		assert.is_true(vim.tbl_contains(calls[1].cmd, "always"))
	end)
end)
