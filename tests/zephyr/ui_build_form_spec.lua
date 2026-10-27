local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")
local form_mod = require("zephyr.ui.build_form")
local ui = require("zephyr.ui.build")

describe("the Build configuration edit buffer", function()
	local restore_state, topdir, app, calls, saved_select, saved_notify, notes

	local function line_of(buf, field)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if vim.startswith(l, field .. ":") then
				return i
			end
		end
	end

	local function set(buf, field, value)
		local i = line_of(buf, field)
		vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { field .. ": " .. value })
	end

	local function form_buf()
		return vim.api.nvim_get_current_buf()
	end

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		app = app_mod.from_dir(topdir .. "/app")
		calls = h.stub_process(function(call)
			if call.cmd[2] == "boards" then
				return { code = 0, stdout = "myboard;nrf5340/cpuapp\nnrf52840dk;nrf52840\n" }
			end
			return { code = 0 }
		end)
		saved_select, saved_notify = vim.ui.select, vim.notify
		notes = {}
		vim.notify = function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end
		require("zephyr").setup({ build = { auto_pristine = false } })
	end)

	after_each(function()
		calls.restore()
		vim.ui.select, vim.notify = saved_select, saved_notify
		vim.cmd("silent! only")
		require("zephyr").setup({ build = { auto_pristine = false } })
		restore_state()
	end)

	it(":Zephyr build new opens a pre-filled float; :w creates and activates it", function()
		ui.new(app)
		local buf = form_buf()
		assert.are.equal("acwrite", vim.bo[buf].buftype)
		assert.are.equal("editor", vim.api.nvim_win_get_config(0).relative)
		assert.are.equal("sysbuild: true", vim.api.nvim_buf_get_lines(buf, line_of(buf, "sysbuild") - 1, line_of(buf, "sysbuild"), false)[1])
		set(buf, "board", "myboard/nrf5340/cpuapp")
		set(buf, "extra_conf_files", "debug.conf")
		vim.cmd("write")
		assert.is_false(vim.bo[buf].modified)
		local active = build_config.active(app)
		assert.are.equal(app.dir .. "/build_myboard_nrf5340_cpuapp", active.dir)
		assert.are.same({ "debug.conf" }, active.settings.extra_conf_files)
		-- The boards list included custom boards through the board roots.
		assert.is_true(vim.tbl_contains(calls[1].cmd, "--board-root"))
	end)

	it(":Zephyr build edit saves changes to the settings file", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = form_buf()
		set(buf, "overlays", "app.overlay")
		set(buf, "cmake_args", "-DFOO=1 -DBAR=2")
		set(buf, "toolchain", "ncs v2.9.2")
		vim.cmd("write")
		local s = settings.get(app, cfg.dir)
		assert.are.same({ "app.overlay" }, s.overlays)
		assert.are.same({ "-DFOO=1", "-DBAR=2" }, s.cmake_args)
		assert.are.same({ provider = "ncs", version = "v2.9.2" }, s.toolchain)
	end)

	it("reports invalid input on save and writes nothing", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = form_buf()
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "colour: blue" })
		set(buf, "conf_files", "nope.conf")
		vim.cmd("write")
		assert.is_true(vim.bo[buf].modified)
		assert.matches("unknown field 'colour'", notes[#notes].msg)
		assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
		vim.api.nvim_buf_set_lines(buf, -2, -1, false, {})
		vim.cmd("write")
		assert.matches("nope.conf does not exist", notes[#notes].msg)
		assert.are.same({}, settings.get(app, cfg.dir).conf_files)
	end)

	it("q closes without saving", function()
		ui.new(app)
		local buf = form_buf()
		set(buf, "board", "nrf52840dk/nrf52840")
		vim.api.nvim_feedkeys("q", "x", false)
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
		assert.is_nil(build_config.active(app))
	end)

	it("offers values for a field with <CR>, appending to lists", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = form_buf()
		local offered = {}
		vim.ui.select = function(items, opts, on_choice)
			offered[opts.prompt] = items
			on_choice(items[1])
		end
		for _, field in ipairs({ "board", "conf_files", "overlays", "snippets", "optimization" }) do
			vim.api.nvim_win_set_cursor(0, { line_of(buf, field), 0 })
			vim.api.nvim_feedkeys("\r", "x", false)
		end
		assert.are.same({ "myboard/nrf5340/cpuapp", "nrf52840dk/nrf52840" }, offered.board)
		assert.are.same({ "debug.conf", "prj.conf" }, offered.conf_files)
		assert.are.same({ "app.overlay" }, offered.overlays)
		assert.are.same({ "rtt-console" }, offered.snippets)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.are.equal("board: myboard/nrf5340/cpuapp", lines[line_of(buf, "board")])
		assert.are.equal("conf_files: debug.conf", lines[line_of(buf, "conf_files")])
		vim.api.nvim_win_set_cursor(0, { line_of(buf, "conf_files"), 0 })
		vim.ui.select = function(items, _, on_choice)
			on_choice(items[2])
		end
		vim.api.nvim_feedkeys("\r", "x", false)
		assert.are.equal("conf_files: debug.conf, prj.conf", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[line_of(buf, "conf_files")])
	end)

	it("completes values with <Tab>", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = form_buf()
		local form = { app = app, boards = { "myboard/nrf5340/cpuapp" } }
		assert.are.same({ "rtt-console" }, form_mod.candidates(form, "snippets"))
		assert.are.same({ "myboard/nrf5340/cpuapp" }, form_mod.candidates(form, "board"))
		set(buf, "overlays", "")
		vim.api.nvim_win_set_cursor(0, { line_of(buf, "overlays"), 0 })
		vim.api.nvim_feedkeys("A\t", "x", false)
		vim.wait(50)
		-- Completion finished with the only candidate.
		vim.api.nvim_feedkeys("\27", "x", false)
		assert.are.equal("overlays: app.overlay", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[line_of(buf, "overlays")])
	end)

	it("asks about a Pristine build after an edit that needs a reconfigure", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({ "CACHED_BOARD:STRING=nrf52840dk/nrf52840", "ZEPHYR_BASE:PATH=/z" }, cfg.dir .. "/CMakeCache.txt")
		local asked
		vim.ui.select = function(items, _, on_choice)
			asked = items
			on_choice(items[2]) -- On the next build
		end
		ui.edit(app)
		set(form_buf(), "snippets", "rtt-console")
		vim.cmd("write")
		-- Asked after :w has finished, not from inside BufWriteCmd, where a
		-- picker such as Telescope shows but can't be used.
		assert.is_nil(asked)
		vim.wait(200, function()
			return asked ~= nil
		end)
		assert.are.same({ "Pristine build now", "On the next build", "Not now" }, asked)
		assert.is_true(build_config.pristine_next(app, build_config.active(app)))
	end)

	it("doesn't ask with auto_pristine, and the next build is pristine", function()
		require("zephyr").setup({ build = { auto_pristine = true } })
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({ "CACHED_BOARD:STRING=nrf52840dk/nrf52840", "ZEPHYR_BASE:PATH=/z" }, cfg.dir .. "/CMakeCache.txt")
		local asked = false
		vim.ui.select = function()
			asked = true
		end
		ui.edit(app)
		set(form_buf(), "board", "myboard/nrf5340/cpuapp")
		vim.cmd("write")
		vim.wait(50)
		vim.cmd("close")
		assert.is_false(asked)
		ui.build(app)
		local cmd = calls[#calls].cmd
		assert.are.equal("west", cmd[1])
		assert.is_true(vim.tbl_contains(cmd, "always"))
		assert.is_true(vim.tbl_contains(cmd, "myboard/nrf5340/cpuapp"))
	end)
end)
