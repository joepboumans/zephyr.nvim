local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local ui = require("zephyr.ui.build")

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

	it("shows output in a split and opens quickfix on errors", function()
		calls = h.stub_process(function()
			return { code = 1, stderr_lines = h.output("gcc.txt") }
		end)
		ui.build(app, { pristine = true })
		local buf = vim.fn.bufnr("zephyr://build")
		assert.is_true(buf > 0)
		assert.are_not.equal(-1, vim.fn.bufwinid(buf))
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.matches("^%$ west build %-d .*%-p always$", lines[1])
		assert.matches("failed", lines[#lines])
		local qf = vim.fn.getqflist({ items = 0, winid = 0 })
		assert.are.equal(4, #qf.items)
		assert.are_not.equal(0, qf.winid)
	end)

	it("creates a configuration from the board picker", function()
		calls = h.stub_process(function()
			return { code = 0, stdout = table.concat(h.output("west_boards.txt"), "\n") }
		end)
		local offered
		vim.ui.select = function(items, _, on_choice)
			offered = items
			on_choice("nrf5340dk/nrf5340/cpunet")
		end
		ui.new(app)
		assert.are.equal("Other board…", offered[1])
		local active = build_config.active(app)
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpunet", active.dir)
		assert.are.equal("nrf5340dk/nrf5340/cpunet", active.board)
	end)

	it("selects the active configuration", function()
		vim.ui.select = function(items, _, on_choice)
			on_choice(items[2])
		end
		ui.select(app)
		assert.are.equal(root .. "/build_nrf5340dk_nrf5340_cpuapp", build_config.active(app).dir)
	end)
end)
