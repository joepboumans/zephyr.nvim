local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local registry = require("zephyr.registry")
local settings = require("zephyr.settings")
local ui = require("zephyr.ui.build")

describe("the Build configuration settings panel", function()
	local restore_state, topdir, app, calls, saved_select, saved_input, saved_notify, notes
	local answers, asked

	-- Row of the field with `label`.
	local function row_of(label)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
			if vim.startswith(l, label) then
				return i
			end
		end
	end

	local function text_of(label)
		return vim.api.nvim_buf_get_lines(0, row_of(label) - 1, row_of(label), false)[1]
	end

	local function on(label)
		vim.api.nvim_win_set_cursor(0, { row_of(label), 0 })
	end

	local function press(keys)
		vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
	end

	-- Queue answers for vim.ui.select (an item, shown without its ✓) and vim.ui.input; nil cancels.
	local function answer(...)
		for _, a in ipairs({ ... }) do
			table.insert(answers, a == nil and vim.NIL or a)
		end
	end

	local function next_answer()
		local a = table.remove(answers, 1)
		if a == vim.NIL then
			return nil
		end
		return a
	end

	local function eol_text()
		local out = {}
		local ns = vim.api.nvim_get_namespaces()["zephyr.build_form"]
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
			for _, chunk in ipairs(m[4].virt_text or {}) do
				out[m[2] + 1] = (out[m[2] + 1] or "") .. chunk[1]
			end
		end
		return out
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
		saved_select, saved_input, saved_notify = vim.ui.select, vim.ui.input, vim.notify
		answers, asked, notes = {}, {}, {}
		vim.ui.select = function(items, opts, on_choice)
			table.insert(asked, { items = items, prompt = opts.prompt, kind = opts.kind })
			local a = next_answer()
			for i, item in ipairs(items) do
				if a and (item == a or vim.trim((item:gsub("^✓", ""))) == a) then
					return on_choice(item, i)
				end
			end
			on_choice(nil, nil)
		end
		vim.ui.input = function(opts, on_confirm)
			table.insert(asked, { prompt = opts.prompt, default = opts.default, completion = opts.completion })
			on_confirm(next_answer())
		end
		vim.notify = function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end
		require("zephyr").setup({ build = { auto_pristine = false } })
	end)

	after_each(function()
		calls.restore()
		vim.ui.select, vim.ui.input, vim.notify = saved_select, saved_input, saved_notify
		vim.cmd("silent! only")
		require("zephyr").setup({ build = { auto_pristine = false } })
		restore_state()
	end)

	it(":Zephyr build new opens the board picker, and <C-s> creates and activates it", function()
		answer("myboard/nrf5340/cpuapp")
		ui.new(app)
		assert.are.equal("editor", vim.api.nvim_win_get_config(0).relative)
		assert.are.equal("zephyr.board", asked[1].kind)
		-- The board list included custom boards through the board roots.
		assert.is_true(vim.tbl_contains(calls[1].cmd, "--board-root"))
		assert.are.same({ "myboard/nrf5340/cpuapp", "nrf52840dk/nrf52840" }, asked[1].items)
		assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
		assert.matches("myboard/nrf5340/cpuapp", text_of("Board target"))
		assert.matches("build_myboard_nrf5340_cpuapp.*%(from board%)", text_of("Build directory"))
		assert.matches("—.*%(prj.conf%)", text_of("Kconfig files"))
		assert.matches("✓ on", text_of("Sysbuild"))
		assert.matches("%[%+%]", vim.api.nvim_win_get_config(0).title[1][1])
		local buf = vim.api.nvim_get_current_buf()
		press("<C-s>")
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
		local active = build_config.active(app)
		assert.are.equal(app.dir .. "/build_myboard_nrf5340_cpuapp", active.dir)
		assert.are.equal("myboard/nrf5340/cpuapp", active.board)
	end)

	it("keeps the panel open with an empty board when the board picker is cancelled", function()
		answer(nil)
		ui.new(app)
		assert.are.equal("zephyrbuildconfig", vim.bo.filetype)
		assert.matches("^Board target%s+—", text_of("Board target"))
	end)

	it("refuses to save without a board, marks the board row and stays open", function()
		answer(nil)
		ui.new(app)
		local buf = vim.api.nvim_get_current_buf()
		press("<C-s>")
		assert.is_true(vim.api.nvim_buf_is_valid(buf))
		assert.is_nil(build_config.active(app))
		assert.matches("board is required", eol_text()[row_of("Board target")])
		assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
		assert.matches("board is required", notes[#notes].msg)
	end)

	it("shows a validation error on its own row", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		on("Board roots")
		answer("no-such-dir")
		press("<CR>")
		press("<C-s>")
		assert.matches("is not a directory", eol_text()[row_of("Board roots")])
		assert.is_nil(eol_text()[row_of("Board target")])
	end)

	it(":Zephyr build edit opens the active Build configuration without a picker", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840", extra_conf_files = { "debug.conf" } })
		ui.edit(app)
		assert.are.same({}, asked)
		assert.matches("nrf52840dk/nrf52840", text_of("Board target"))
		assert.matches("debug.conf", text_of("Extra Kconfig files"))
		assert.is_nil(text_of("Build directory"):match("from board"))
		assert.is_nil(vim.api.nvim_win_get_config(0).title[1][1]:match("%[%+%]"))
	end)

	it(":Zephyr build edit without a Build configuration points at :Zephyr build new", function()
		ui.edit(app)
		assert.matches("try :Zephyr build new", notes[#notes].msg)
	end)

	it("is read-only and has no :w", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		assert.is_false(vim.bo.modifiable)
		assert.are.equal("nofile", vim.bo.buftype)
		assert.has_error(function()
			vim.cmd("write")
		end)
	end)

	it("toggles sysbuild with <CR> and picks optimization and board from a list", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		on("Sysbuild")
		press("<CR>")
		assert.matches("off", text_of("Sysbuild"))
		on("Optimization")
		answer("size")
		press("i")
		assert.are.same({ "default", "debug", "speed", "size", "none" }, asked[1].items)
		assert.are.equal("zephyr.optimization", asked[1].kind)
		on("Board target")
		answer("myboard/nrf5340/cpuapp")
		press("<CR>")
		press("<C-s>")
		local s = settings.get(app, cfg.dir)
		assert.is_false(s.sysbuild)
		assert.are.equal("size", s.optimization)
		-- An existing build directory doesn't follow the board.
		assert.are.equal("myboard/nrf5340/cpuapp", s.board)
	end)

	it("toggles list items in a picker, keeping the picking order", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		on("Kconfig files")
		answer("prj.conf", "debug.conf", "Done")
		press("<CR>")
		assert.are.equal("zephyr.conf_files", asked[1].kind)
		assert.are.same({ "Done", "  debug.conf", "  prj.conf" }, asked[1].items)
		assert.are.same({ "Done", "  debug.conf", "✓ prj.conf" }, asked[2].items)
		assert.matches("prj.conf, debug.conf", text_of("Kconfig files"))
		-- Picking a chosen item removes it; cancelling keeps the toggles so far.
		answer("prj.conf", nil)
		press("<CR>")
		assert.matches("debug.conf", text_of("Kconfig files"))
		assert.is_nil(text_of("Kconfig files"):match("prj"))
		on("Snippets")
		answer("rtt-console", "Done")
		press("<CR>")
		assert.are.equal("zephyr.snippets", asked[#asked].kind)
		press("<C-s>")
		local s = settings.get(app, cfg.dir)
		assert.are.same({ "debug.conf" }, s.conf_files)
		assert.are.same({ "rtt-console" }, s.snippets)
	end)

	it("enters CMake arguments space separated, keeping commas", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840", cmake_args = { "-DOLD=1" } })
		ui.edit(app)
		on("CMake arguments")
		answer("-DFOO=a,b  -DBAR=2")
		press("<CR>")
		assert.are.equal("-DOLD=1", asked[1].default)
		press("<C-s>")
		assert.are.same({ "-DFOO=a,b", "-DBAR=2" }, settings.get(app, cfg.dir).cmake_args)
	end)

	it("completes Board roots as directories", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		on("Board roots")
		answer(nil)
		press("<CR>")
		assert.are.equal("dir", asked[1].completion)
	end)

	it("resets a field to its default with x", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840", sysbuild = false, overlays = { "app.overlay" } })
		ui.edit(app)
		on("Sysbuild")
		press("x")
		on("DT overlays")
		press("x")
		assert.matches("—", text_of("DT overlays"))
		press("<C-s>")
		local s = settings.get(app, cfg.dir)
		assert.is_true(s.sysbuild)
		assert.are.same({}, s.overlays)
	end)

	it("lets the build directory follow the board until it is set", function()
		answer("nrf52840dk/nrf52840")
		ui.new(app)
		on("Build directory")
		answer("out")
		press("<CR>")
		on("Board target")
		answer("myboard/nrf5340/cpuapp")
		press("<CR>")
		assert.matches("out", text_of("Build directory"))
		assert.is_nil(text_of("Build directory"):match("from board"))
		press("<C-s>")
		assert.are.equal(app.dir .. "/out", build_config.active(app).dir)
	end)

	it("offers the Toolchains of every Toolchain provider", function()
		registry.register("toolchain_provider", {
			name = "vendor",
			find = function()
				return { { provider = "vendor", id = "v-1", name = "Vendor", version = "v2.9.2", path = "/tc" } }
			end,
			env = function()
				return {}
			end,
		})
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		assert.matches("vendor v2.9.2.*%(default%)", text_of("Toolchain"))
		on("Toolchain")
		answer("vendor v2.9.2")
		press("<CR>")
		assert.are.equal("zephyr.toolchain", asked[1].kind)
		assert.are.equal("vendor v2.9.2", asked[1].items[1])
		press("<C-s>")
		assert.are.same({ provider = "vendor", version = "v2.9.2" }, settings.get(app, cfg.dir).toolchain)
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
	end)

	it("q closes without saving", function()
		answer("nrf52840dk/nrf52840")
		ui.new(app)
		local buf = vim.api.nvim_get_current_buf()
		press("q")
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
		assert.is_nil(build_config.active(app))
	end)

	it("<Esc> closes an unchanged panel, and warns with unsaved changes", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = vim.api.nvim_get_current_buf()
		on("Sysbuild")
		press("<CR>")
		press("<Esc>")
		assert.is_true(vim.api.nvim_buf_is_valid(buf))
		assert.are.equal(vim.log.levels.WARN, notes[#notes].level)
		assert.matches("unsaved", notes[#notes].msg)
		press("q")
		ui.edit(app)
		buf = vim.api.nvim_get_current_buf()
		press("<Esc>")
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
	end)

	it("leaves no buffer behind when closed with :q", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		local buf = vim.api.nvim_get_current_buf()
		vim.cmd("quit")
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
	end)

	it("g? lists the keys", function()
		build_config.new(app, { board = "nrf52840dk/nrf52840" })
		ui.edit(app)
		press("g?")
		assert.matches("<C%-s>", notes[#notes].msg)
	end)

	it("asks about a Pristine build after the panel closes", function()
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({ "CACHED_BOARD:STRING=nrf52840dk/nrf52840", "ZEPHYR_BASE:PATH=/z" }, cfg.dir .. "/CMakeCache.txt")
		ui.edit(app)
		local buf = vim.api.nvim_get_current_buf()
		on("Snippets")
		answer("rtt-console", "Done")
		press("<CR>")
		local open_when_asked
		vim.ui.select = function(items, _, on_choice)
			asked.pristine = items
			open_when_asked = vim.api.nvim_buf_is_valid(buf)
			on_choice(items[2]) -- On the next build
		end
		press("<C-s>")
		assert.are.same({ "Pristine build now", "On the next build", "Not now" }, asked.pristine)
		assert.is_false(open_when_asked)
		assert.is_true(build_config.pristine_next(app, build_config.active(app)))
	end)

	it("doesn't ask with auto_pristine, and the next build is pristine", function()
		require("zephyr").setup({ build = { auto_pristine = true } })
		local cfg = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		vim.fn.mkdir(cfg.dir, "p")
		vim.fn.writefile({ "CACHED_BOARD:STRING=nrf52840dk/nrf52840", "ZEPHYR_BASE:PATH=/z" }, cfg.dir .. "/CMakeCache.txt")
		ui.edit(app)
		on("Board target")
		answer("myboard/nrf5340/cpuapp")
		press("<CR>")
		local n = #asked
		press("<C-s>")
		assert.are.equal(n, #asked)
		ui.build(app)
		local cmd = calls[#calls].cmd
		assert.are.equal("west", cmd[1])
		assert.is_true(vim.tbl_contains(cmd, "always"))
		assert.is_true(vim.tbl_contains(cmd, "myboard/nrf5340/cpuapp"))
	end)
end)
