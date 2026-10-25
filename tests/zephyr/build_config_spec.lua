local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")

describe("build_config", function()
	local root, app, restore_state

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
	end)

	after_each(function()
		restore_state()
	end)

	it("parses CMakeCache.txt, skipping comments", function()
		local cache = build_config.parse_cache("# c\n//doc\nBOARD:STRING=nrf52dk/nrf52832\nEMPTY:STRING=\nX:INTERNAL=a=b\n")
		assert.are.same({ BOARD = "nrf52dk/nrf52832", EMPTY = "", X = "a=b" }, cache)
	end)

	it("finds the App from a file inside it", function()
		local found = app_mod.find(root .. "/src/main.c")
		assert.are.equal(root, found.dir)
		assert.are.equal("app", found.name)
		assert.is_nil(app_mod.find(vim.fn.tempname()))
	end)

	it("tells Zephyr build dirs apart", function()
		assert.is_true(build_config.is_build_dir(root .. "/build"))
		assert.is_true(build_config.is_build_dir(root .. "/build_nrf5340dk_nrf5340_cpuapp"))
		assert.is_false(build_config.is_build_dir(root .. "/notzephyr"))
		assert.is_false(build_config.is_build_dir(root .. "/src"))
	end)

	it("reads a plain build configuration", function()
		local cfg = build_config.read(root .. "/build")
		assert.are.equal("build", cfg.name)
		assert.is_true(cfg.exists)
		assert.is_false(cfg.sysbuild)
		assert.are.equal("nrf52840dk/nrf52840", cfg.board)
		assert.are.equal(root, cfg.app_dir)
		assert.are.equal(root .. "/build", cfg.image_dir)
		assert.are.same({ root .. "/prj.conf" }, cfg.conf_files)
		assert.are.same({ root .. "/debug.conf" }, cfg.extra_conf_files)
		assert.are.same({ root .. "/app.overlay" }, cfg.overlays)
		assert.are.same({}, cfg.extra_overlays)
		assert.are.equal("/ws/zephyr", cfg.zephyr_base)
	end)

	it("reads a sysbuild build configuration", function()
		local dir = root .. "/build_nrf5340dk_nrf5340_cpuapp"
		local cfg = build_config.read(dir)
		assert.is_true(cfg.sysbuild)
		assert.are.equal("nrf5340dk/nrf5340/cpuapp", cfg.board)
		assert.are.equal(root, cfg.app_dir) -- APP_DIR, not share/sysbuild
		assert.are.equal(dir .. "/app", cfg.image_dir)
		assert.are.same({ root .. "/prj.conf", root .. "/debug.conf" }, cfg.conf_files)
		assert.are.same({}, cfg.overlays)
	end)

	it("finds the app image when domains.yaml points elsewhere", function()
		local dir = root .. "/build_nrf5340dk_nrf5340_cpuapp"
		vim.fn.writefile({ "default: app", "domains:", "  - name: app", "    build_dir: /moved/away" }, dir .. "/domains.yaml")
		assert.are.equal(dir .. "/app", build_config.image_dir(dir, root))
	end)

	it("parses domains.yaml", function()
		local d = build_config.parse_domains(table.concat(vim.fn.readfile(root .. "/build_nrf5340dk_nrf5340_cpuapp/domains.yaml"), "\n"))
		assert.are.equal("app", d.default)
		assert.are.same({ "mcuboot", "app" }, d.flash_order)
		assert.are.equal("mcuboot", d.domains[2].name)
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp/mcuboot", d.domains[2].build_dir)
	end)

	it("lists the App's build configurations, build first, nested ones too", function()
		local names = vim.tbl_map(function(c)
			return c.dir:sub(#root + 2)
		end, build_config.list(app))
		-- build_other belongs to another App; notzephyr is not a Zephyr build.
		assert.are.same({ "build", "build_nrf5340dk_nrf5340_cpuapp", "out/nrf52dk_nrf52832" }, names)
	end)

	it("defaults the active configuration to the first one found", function()
		local cfg, selected = build_config.active(app)
		assert.are.equal(root .. "/build", cfg.dir)
		assert.is_false(selected)
	end)

	it("keeps the active configuration per App and fires an event", function()
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrBuildConfigActivated",
			callback = function(ev)
				seen = ev.data
			end,
		})
		build_config.activate(app, build_config.read(root .. "/build_nrf5340dk_nrf5340_cpuapp"))
		vim.api.nvim_del_autocmd(id)
		local cfg, selected = build_config.active(app_mod.from_dir(root))
		assert.is_true(selected)
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp", cfg.dir)
		assert.are.equal(root, seen.app)
		assert.are.equal("nrf5340dk/nrf5340/cpuapp", seen.board)
	end)

	it("falls back when the chosen build dir is gone", function()
		build_config.activate(app, build_config.read(root .. "/out/nrf52dk_nrf52832"))
		vim.fn.delete(root .. "/out", "rf")
		assert.are.equal(root .. "/build", build_config.active(app).dir)
	end)

	it("names build dirs after the board", function()
		assert.are.equal("build_nrf5340dk_nrf5340_cpuapp_ns", build_config.dir_name("nrf5340dk/nrf5340/cpuapp/ns"))
		assert.are.equal("build_qemu_x86", build_config.dir_name("qemu_x86"))
	end)

	it("creates a new configuration that stays active until it is built", function()
		local cfg = build_config.new(app, { board = "nrf54l15dk/nrf54l15/cpuapp" })
		assert.are.equal(root .. "/build_nrf54l15dk_nrf54l15_cpuapp", cfg.dir)
		assert.is_false(cfg.exists)
		local active, selected = build_config.active(app)
		assert.is_true(selected)
		assert.is_false(active.exists)
		assert.are.equal("nrf54l15dk/nrf54l15/cpuapp", active.board)
		assert.are.equal(root, active.app_dir)
	end)

	it("reuses an existing build dir when creating one with its name", function()
		local cfg = build_config.new(app, { board = "nrf5340dk/nrf5340/cpuapp" })
		assert.is_true(cfg.exists)
		assert.is_true(cfg.sysbuild)
	end)

	it("lists boards with their qualifiers from west boards", function()
		local calls = h.stub_process(function()
			return { code = 0, stdout = table.concat(h.output("west_boards.txt"), "\n") }
		end)
		local got
		build_config.boards(app, function(b)
			got = b
		end)
		calls.restore()
		assert.are.same({ "west", "boards", "--format", "{name};{qualifiers}" }, calls[1].cmd)
		assert.are.equal(root, calls[1].opts.cwd)
		assert.are.same({
			"nrf52840dk/nrf52811",
			"nrf52840dk/nrf52840",
			"nrf5340dk/nrf5340/cpuapp",
			"nrf5340dk/nrf5340/cpuapp/ns",
			"nrf5340dk/nrf5340/cpunet",
			"qemu_x86",
		}, got)
	end)

	it("reports a failing west boards", function()
		local calls = h.stub_process(function()
			return { code = 1, stderr = "FATAL ERROR: no west workspace\n" }
		end)
		local boards, err
		build_config.boards(app, function(b, e)
			boards, err = b, e
		end)
		calls.restore()
		assert.is_nil(boards)
		assert.are.equal("FATAL ERROR: no west workspace", err)
	end)
end)
