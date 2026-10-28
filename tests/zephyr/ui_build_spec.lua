local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local ui = require("zephyr.ui.build")
local output = require("zephyr.ui.output")

describe(":Zephyr build (default UI)", function()
	local root, app, restore_state, calls, saved_select, saved_notify

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
		saved_select, saved_notify = vim.ui.select, vim.notify
		vim.notify = function() end
	end)

	after_each(function()
		if calls then
			calls.restore()
			calls = nil
		end
		vim.ui.select, vim.notify = saved_select, saved_notify
		vim.cmd("cclose")
		vim.cmd("silent! only")
		restore_state()
	end)

	it("shows output in the Output window, toolchain first, and opens quickfix on errors", function()
		calls = h.stub_process(function()
			return { code = 1, stderr_lines = h.output("gcc.txt") }
		end)
		ui.build(app, { pristine = true })
		local buf = vim.fn.bufnr("zephyr://output")
		assert.is_true(buf > 0)
		assert.are_not.equal(-1, vim.fn.bufwinid(buf))
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.matches("^Toolchain: ", lines[1])
		assert.matches("^%$ west build %-d .*%-p always", lines[2])
		assert.matches("failed", lines[#lines])
		local qf = vim.fn.getqflist({ items = 0, winid = 0 })
		assert.are.equal(4, #qf.items)
		assert.are_not.equal(0, qf.winid)
	end)

	it("selects the active configuration", function()
		vim.ui.select = function(items, _, on_choice)
			on_choice(items[2])
		end
		ui.select(app)
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp", build_config.active(app).dir)
	end)

	it("does not start a build whose toolchain environment can't be resolved", function()
		local registry = require("zephyr.registry")
		registry._reset()
		registry.register("toolchain_provider", {
			name = "ncs",
			find = function()
				return { { provider = "ncs", id = "ncs-1", name = "NCS toolchain v2.9.2", version = "v2.9.2", path = "/t" } }
			end,
			env = function()
				return nil -- e.g. nrfutil missing
			end,
		})
		calls = h.stub_process(function()
			return { code = 0 }
		end)
		local notes = {}
		vim.notify = function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end
		ui.build(app)
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		assert.are.equal(0, #calls)
		assert.matches("Toolchain provider 'ncs' gave no environment for NCS toolchain v2.9.2", notes[#notes].msg)
		assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
	end)

	it("runs the next build pristine when asked to", function()
		calls = h.stub_process(function()
			return { code = 0 }
		end)
		local cfg = build_config.active(app)
		build_config.set_pristine_next(app, cfg, true)
		ui.build(app)
		ui.build(app)
		assert.is_true(vim.tbl_contains(calls[1].cmd, "always"))
		assert.is_false(vim.tbl_contains(calls[2].cmd, "always"))
	end)
end)

describe("the Output window", function()
	local root, app, restore_state, saved_notify, pending, killed, events

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
		saved_notify = vim.notify
		vim.notify = function() end
		killed = 0
		local process = require("zephyr.process")
		pending = {}
		process._saved_run, process._saved_kill = process.run, process.kill
		process.run = function(_, _, on_exit)
			local proc = { pid = 1 }
			pending[#pending + 1] = function(code, signal)
				on_exit({ code = code, signal = signal or 0, stdout = "", stderr = "" })
			end
			return proc
		end
		process.kill = function()
			killed = killed + 1
			pending[#pending](0, 15)
		end
		events = {}
		vim.api.nvim_create_augroup("output_spec", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = "output_spec",
			pattern = { "ZephyrBuildFinished", "ZephyrFlashFinished", "ZephyrUpdateFinished" },
			callback = function(ev)
				table.insert(events, { name = ev.match, ok = ev.data.ok, stopped = ev.data.stopped })
			end,
		})
	end)

	after_each(function()
		local process = require("zephyr.process")
		process.run, process.kill = process._saved_run, process._saved_kill
		vim.api.nvim_del_augroup_by_name("output_spec")
		vim.notify = saved_notify
		vim.cmd("silent! only")
		restore_state()
	end)

	local function press_q()
		local buf = vim.fn.bufnr(output.NAME)
		vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
		vim.api.nvim_feedkeys("q", "x", false)
	end

	it("q during a build stops west and closes the window; BuildFinished has ok = false", function()
		ui.build(app)
		assert.is_true(build.is_running(root .. "/build"))
		press_q()
		assert.are.equal(1, killed)
		assert.is_false(build.is_running(root .. "/build"))
		assert.are.equal(-1, vim.fn.bufwinid(output.NAME))
		assert.are.same({ { name = "ZephyrBuildFinished", ok = false, stopped = true } }, events)
	end)

	it("q during a flash stops it the same way", function()
		local probes = require("zephyr.probes")
		probes.select({ topdir = root }, { finder = "jlink", serial = "1", name = "J" })
		require("zephyr.ui.flash").flash(app)
		press_q()
		assert.are.equal(1, killed)
		assert.is_false(events[1].ok)
		assert.are.equal("ZephyrFlashFinished", events[1].name)
	end)

	it("q during an update stops it the same way, in the same window", function()
		require("zephyr.ui.update").update({ topdir = root }, {})
		local lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(output.NAME), 0, -1, false)
		assert.are.same({ "$ west update" }, lines)
		press_q()
		assert.are.equal(1, killed)
		assert.are.same({ { name = "ZephyrUpdateFinished", ok = false, stopped = true } }, events)
	end)

	it("q after a finished command only closes the window, and it can be shown again", function()
		ui.build(app)
		pending[1](0)
		assert.is_false(output.is_running())
		press_q()
		assert.are.equal(0, killed)
		assert.are.equal(-1, vim.fn.bufwinid(output.NAME))
		output.show()
		assert.are_not.equal(-1, vim.fn.bufwinid(output.NAME))
		assert.matches("done", vim.api.nvim_buf_get_lines(vim.fn.bufnr(output.NAME), -2, -1, false)[1])
	end)

	it("<Esc> during a build stops west and closes the window, like q", function()
		ui.build(app)
		vim.api.nvim_set_current_win(vim.fn.bufwinid(vim.fn.bufnr(output.NAME)))
		vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
		assert.are.equal(1, killed)
		assert.are.equal(-1, vim.fn.bufwinid(output.NAME))
	end)

	it(":Zephyr output close stops the build and closes every Output window from another window", function()
		local code_win = vim.api.nvim_get_current_win()
		ui.build(app)
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, vim.fn.bufnr(output.NAME))
		vim.api.nvim_set_current_win(code_win)
		vim.cmd("Zephyr output close")
		assert.are.equal(1, killed)
		assert.are.same({}, vim.fn.win_findbuf(vim.fn.bufnr(output.NAME)))
		assert.are.same({ { name = "ZephyrBuildFinished", ok = false, stopped = true } }, events)
	end)

	it(":Zephyr output close with no Output window open does nothing", function()
		ui.build(app)
		pending[1](0)
		press_q()
		vim.cmd("Zephyr output close")
		assert.are.equal(0, killed)
		assert.are.equal(-1, vim.fn.bufwinid(output.NAME))
	end)

	it("other keys don't close it", function()
		ui.build(app)
		pending[1](0)
		local buf = vim.fn.bufnr(output.NAME)
		vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
		vim.api.nvim_feedkeys("ggG/done\r", "x", false)
		assert.are_not.equal(-1, vim.fn.bufwinid(output.NAME))
	end)
end)
