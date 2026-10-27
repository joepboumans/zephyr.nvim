local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")

local function read_json(path)
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

describe("Build configuration settings", function()
	local restore_state, topdir, app

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		app = app_mod.from_dir(topdir .. "/app")
	end)

	after_each(function()
		restore_state()
	end)

	it("writes them to <topdir>/.zephyr/build-configs.json, git-ignored", function()
		build_config.new(app, {
			board = "nrf5340dk/nrf5340/cpuapp",
			extra_conf_files = { "debug.conf" },
			toolchain = { provider = "ncs", version = "v2.9.2" },
		})
		local data = read_json(topdir .. "/.zephyr/build-configs.json")
		local list = data.apps.app
		assert.are.equal(1, #list)
		assert.are.equal("build_nrf5340dk_nrf5340_cpuapp", list[1].build_dir)
		assert.are.same({ "debug.conf" }, list[1].extra_conf_files)
		assert.are.same({ provider = "ncs", version = "v2.9.2" }, list[1].toolchain)
		assert.are.same({ "*" }, vim.fn.readfile(topdir .. "/.zephyr/.gitignore"))
	end)

	it("keeps an existing .gitignore", function()
		vim.fn.mkdir(topdir .. "/.zephyr", "p")
		vim.fn.writefile({ "*", "!keep" }, topdir .. "/.zephyr/.gitignore")
		build_config.new(app, { board = "a/b" })
		assert.are.same({ "*", "!keep" }, vim.fn.readfile(topdir .. "/.zephyr/.gitignore"))
	end)

	it("stores paths relative to the App, so the file works elsewhere", function()
		assert.are.equal("debug.conf", settings.relative(app.dir, app.dir .. "/debug.conf"))
		assert.are.equal("../nrflib/x.conf", settings.relative(app.dir, topdir .. "/nrflib/x.conf"))
		assert.are.equal(topdir .. "/nrflib/x.conf", settings.absolute(app.dir, "../nrflib/x.conf"))
		local cfg = build_config.new(app, { board = "a/b", overlays = { "app.overlay" } })
		assert.are.same({ app.dir .. "/app.overlay" }, cfg.extra_overlays)
	end)

	it("passes every setting on every configure", function()
		local cfg = build_config.new(app, {
			board = "myboard/nrf5340/cpuapp",
			conf_files = { "prj.conf" },
			extra_conf_files = { "debug.conf" },
			overlays = { "app.overlay" },
			snippets = { "rtt-console" },
			sysbuild = true,
			optimization = "debug",
			board_roots = { "extra-roots" },
			cmake_args = { "-DFOO=1" },
		})
		local a = app.dir
		local expected = {
			"west", "build", "-d", a .. "/build_myboard_nrf5340_cpuapp", "-b", "myboard/nrf5340/cpuapp",
			"--sysbuild", "-S", "rtt-console", a, "--",
			"-DCONF_FILE=" .. a .. "/prj.conf",
			"-DEXTRA_CONF_FILE=" .. a .. "/debug.conf",
			"-DEXTRA_DTC_OVERLAY_FILE=" .. a .. "/app.overlay",
			-- topdir has boards/, the manifest repo (the App) has boards/, then the settings' roots.
			"-DBOARD_ROOT=" .. topdir .. ";" .. a .. ";" .. topdir .. "/extra-roots",
			"-DCONFIG_DEBUG_OPTIMIZATIONS=y",
			"-DFOO=1",
		}
		assert.are.same(expected, build.command(cfg, { app = app }))
	end)

	it("configures a Pristine build with every setting again", function()
		local cfg = build_config.new(app, { board = "a/b", sysbuild = false, board_roots = { "extra-roots" } })
		-- Pretend it was built.
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({ "CACHED_BOARD:STRING=a/b", "ZEPHYR_BASE:PATH=" .. topdir .. "/zephyr" }, cfg.dir .. "/CMakeCache.txt")
		cfg = build_config.get(app, cfg.dir)
		assert.is_true(cfg.exists)
		assert.are.same({ "west", "build", "-d", cfg.dir }, build.command(cfg, { app = app }))
		local cmd = build.command(cfg, { app = app, pristine = true })
		assert.are.same({ "-b", "a/b", "-p", "always", "--no-sysbuild" }, vim.list_slice(cmd, 5, 9))
		assert.are.equal("-DBOARD_ROOT=" .. topdir .. ";" .. app.dir .. ";" .. topdir .. "/extra-roots", cmd[#cmd])
	end)

	it("lets settings win over the CMake cache", function()
		local cfg = build_config.new(app, { board = "a/b", extra_conf_files = { "debug.conf" } })
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({
			"CACHED_BOARD:STRING=other/board",
			"EXTRA_CONF_FILE:STRING=" .. app.dir .. "/prj.conf",
			"ZEPHYR_BASE:PATH=/z",
		}, cfg.dir .. "/CMakeCache.txt")
		cfg = build_config.get(app, cfg.dir)
		assert.are.equal("a/b", cfg.board)
		assert.are.same({ app.dir .. "/debug.conf" }, cfg.extra_conf_files)
		local diffs = build_config.differences(app, cfg)
		local fields = vim.tbl_map(function(d)
			return d.field
		end, diffs)
		assert.are.same({ "board", "sysbuild", "extra_conf_files", "board_roots" }, fields)
	end)

	it("keeps which Build configuration is active in personal state", function()
		local cfg = build_config.new(app, { board = "a/b" })
		local data = read_json(topdir .. "/.zephyr/build-configs.json")
		assert.is_nil(data.active)
		assert.are.equal(cfg.dir, require("zephyr.state").get(topdir).build_configs[app.dir].dir)
	end)

	it("checks settings before saving", function()
		local s = settings.normalize({ board = "", build_dir = "b", conf_files = { "missing.conf" }, optimization = "fast" })
		local errs = build_config.validate(app, s)
		assert.are.equal(3, #errs)
		assert.matches("^board:", errs[1])
		assert.matches("missing.conf does not exist", errs[2])
		assert.matches("^optimization:", errs[3])
	end)

	it("tells which edits need a reconfigure", function()
		local old = settings.normalize({ board = "a/b", build_dir = "x" })
		assert.is_false(build_config.needs_reconfigure(old, vim.tbl_extend("force", old, {})))
		assert.is_true(build_config.needs_reconfigure(old, vim.tbl_extend("force", old, { snippets = { "s" } })))
		assert.is_true(
			build_config.needs_reconfigure(old, vim.tbl_extend("force", old, { toolchain = { provider = "p", version = "1" } }))
		)
	end)
end)

describe("board roots", function()
	local restore_state, topdir, app

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		app = app_mod.from_dir(topdir .. "/app")
	end)

	after_each(function()
		restore_state()
	end)

	it("adds the topdir and the manifest repository when they have boards/", function()
		assert.are.same({ topdir, app.dir }, build_config.board_roots(app))
		vim.fn.delete(topdir .. "/boards", "rf")
		vim.fn.delete(app.dir .. "/boards", "rf")
		assert.are.same({}, build_config.board_roots(app))
	end)

	it("adds board_roots from the settings, resolved against the topdir", function()
		local s = settings.normalize({ board = "a/b", board_roots = { "extra-roots" } })
		assert.are.same({ topdir, app.dir, topdir .. "/extra-roots" }, build_config.board_roots(app, s))
	end)

	it("lists custom boards with the same board roots", function()
		local calls = h.stub_process(function()
			return { code = 0, stdout = "myboard;nrf5340/cpuapp\n" }
		end)
		local got
		build_config.boards(app, function(b)
			got = b
		end, settings.normalize({ board_roots = { "extra-roots" } }))
		calls.restore()
		assert.are.same({
			"west", "boards", "--format", "{name};{qualifiers}",
			"--board-root", topdir, "--board-root", app.dir, "--board-root", topdir .. "/extra-roots",
		}, calls[1].cmd)
		assert.are.same({ "myboard/nrf5340/cpuapp" }, got)
	end)
end)
