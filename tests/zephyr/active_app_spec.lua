local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local ui_build = require("zephyr.ui.build")

describe("Active app", function()
	local restore_state, topdir, ws, calls, saved_select, saved_notify, notes, offered

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		ws = require("zephyr.workspace").find(topdir)
		calls = h.stub_process(function()
			return { code = 0 }
		end)
		saved_select, saved_notify = vim.ui.select, vim.notify
		notes, offered = {}, nil
		vim.notify = function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end
		vim.ui.select = function(items, _, on_choice)
			offered = items
			on_choice(items[1])
		end
	end)

	after_each(function()
		calls.restore()
		vim.ui.select, vim.notify = saved_select, saved_notify
		vim.cmd("silent! %bwipeout!")
		restore_state()
	end)

	local function edit(path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
	end

	it("lists the Apps of the manifest repository", function()
		local dirs = vim.tbl_map(function(a)
			return a.dir
		end, app_mod.list(ws))
		-- The App is the manifest repository; its samples/blinky sits inside it and is not listed.
		assert.are.same({ topdir .. "/app" }, dirs)
	end)

	it("asks once from outside an App, remembers it, and builds it", function()
		local app = app_mod.from_dir(topdir .. "/app")
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		edit(topdir .. "/nrflib/lib.c")
		vim.cmd("Zephyr build")
		assert.are.equal(topdir .. "/app", offered[1].dir)
		assert.are.equal(topdir .. "/app", app_mod.active(ws).dir)
		assert.are.equal(topdir .. "/app", calls[#calls].opts.cwd)
		offered = nil
		vim.cmd("Zephyr build")
		assert.is_nil(offered)
		local builds = vim.tbl_filter(function(c)
			return type(c) == "table" and c.cmd[2] == "build"
		end, calls)
		assert.are.equal(2, #builds)
	end)

	it("makes an App built from inside it the Active app", function()
		local blinky = topdir .. "/app/samples/blinky"
		build_config.new(app_mod.from_dir(blinky), { board = "nrf52840dk/nrf52840" })
		edit(blinky .. "/src/main.c")
		vim.cmd("Zephyr build")
		assert.are.equal(blinky, app_mod.active(ws).dir)
		edit(topdir .. "/nrflib/lib.c")
		vim.cmd("Zephyr build")
		assert.are.equal(blinky, calls[#calls].opts.cwd)
	end)

	it("lists Apps that have Build configurations, and :Zephyr build app switches", function()
		local blinky = topdir .. "/app/samples/blinky"
		build_config.new(app_mod.from_dir(blinky), { board = "x/y" })
		edit(topdir .. "/nrflib/lib.c")
		vim.ui.select = function(items, _, on_choice)
			offered = items
			on_choice(items[2])
		end
		vim.cmd("Zephyr build app")
		assert.are.same({ topdir .. "/app", blinky }, vim.tbl_map(function(a)
			return a.dir
		end, offered))
		assert.are.equal(blinky, app_mod.active(ws).dir)
	end)

	it("flashes the Active app from outside it", function()
		local app = app_mod.from_dir(topdir .. "/app")
		app_mod.activate(ws, app)
		edit(topdir .. "/nrflib/lib.c")
		vim.cmd("Zephyr flash")
		assert.matches("nothing built yet", notes[#notes].msg)
	end)

	it("keeps today's error outside any Workspace", function()
		edit(vim.fn.tempname() .. "/x.c")
		vim.cmd("Zephyr build")
		assert.matches("not inside a Zephyr app", notes[#notes].msg)
		assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
	end)

	it("is personal state", function()
		app_mod.activate(ws, app_mod.from_dir(topdir .. "/app"))
		assert.are.equal(topdir .. "/app", require("zephyr.state").get(topdir).active_app)
		assert.is_nil(vim.uv.fs_stat(topdir .. "/.zephyr/build-configs.json"))
	end)
end)
