local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local probes = require("zephyr.probes")
local registry = require("zephyr.registry")
local ui = require("zephyr.ui.flash")

local found = {
	{ finder = "jlink", serial = "683000000", name = "J-Link OB-SAM3U128-V2-NordicSemi" },
	{ finder = "jlink", serial = "1050234567", name = "J-Link OB-nRF5340-NordicSemi" },
}

describe(":Zephyr flash (default UI)", function()
	local root, app, restore_state, calls, saved_select, saved_notify, finds, asked

	before_each(function()
		restore_state = h.temp_state()
		root = h.copy_fixture("builds/app")
		app = app_mod.from_dir(root)
		build_config.activate(app, build_config.read(root .. "/build"))
		saved_select, saved_notify = vim.ui.select, vim.notify
		vim.notify = function() end
		finds, asked = 0, 0
		registry._reset()
		registry.register("probe_finder", {
			name = "fake",
			find = function()
				finds = finds + 1
				return vim.deepcopy(found)
			end,
		})
		vim.ui.select = function(items, _, on_choice)
			asked = asked + 1
			on_choice(items[2])
		end
		calls = h.stub_process(function()
			return { code = 0, stdout_lines = { "Flashing done" } }
		end)
	end)

	after_each(function()
		calls.restore()
		vim.ui.select, vim.notify = saved_select, saved_notify
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		registry.register("probe_finder", require("zephyr.probes.jlink").finder)
		vim.cmd("silent! only")
		restore_state()
	end)

	it("asks once for a probe when several are connected, then flashes in a split", function()
		ui.flash(app, { erase = true })
		assert.are.equal(1, asked)
		assert.are.same({ "west", "flash", "-d", root .. "/build", "--dev-id", "1050234567", "--erase" }, calls[1].cmd)
		local buf = vim.fn.bufnr("zephyr://flash")
		assert.is_true(buf > 0)
		assert.are_not.equal(-1, vim.fn.bufwinid(buf))
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.matches("^%$ west flash %-d .*%-%-erase$", lines[1])
		assert.are.equal("Flashing done", lines[2])
		assert.matches("done", lines[#lines])

		ui.flash(app)
		assert.are.equal(1, asked) -- remembered
		assert.are.equal(1, finds)
		assert.are.same({ "west", "flash", "-d", root .. "/build", "--dev-id", "1050234567" }, calls[2].cmd)
	end)

	it("uses the only connected probe without asking", function()
		found = { found[1] }
		ui.flash(app)
		found = {
			{ finder = "jlink", serial = "683000000", name = "J-Link OB-SAM3U128-V2-NordicSemi" },
			{ finder = "jlink", serial = "1050234567", name = "J-Link OB-nRF5340-NordicSemi" },
		}
		assert.are.equal(0, asked)
		assert.are.same({ "west", "flash", "-d", root .. "/build", "--dev-id", "683000000" }, calls[1].cmd)
	end)

	it("picks the active probe with :Zephyr flash probe", function()
		ui.pick(app)
		assert.are.equal(1, asked)
		assert.are.equal("1050234567", probes.active({ topdir = app.dir }).serial)
		assert.are.equal(0, #calls)
	end)
end)
