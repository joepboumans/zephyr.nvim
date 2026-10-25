local zephyr = require("zephyr")
local ui = require("zephyr.ui.update")
local commands = require("zephyr.commands")

local root = vim.fn.getcwd() .. "/tests/fixtures/workspace"

describe("drift default UI", function()
	local real_check, real_update, real_notify, real_select, checks, notes

	before_each(function()
		real_check, real_update, real_notify, real_select = zephyr.drift.check, zephyr.update, vim.notify, vim.ui.select
		checks, notes = {}, {}
		ui.checked = {}
		zephyr.drift.check = function(ws, cb)
			table.insert(checks, ws.topdir)
			cb({ { name = "mcuboot", path = "bootloader/mcuboot", expected = ("b"):rep(40), actual = ("a"):rep(40) } })
		end
		vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
	end)

	after_each(function()
		zephyr.drift.check, zephyr.update, vim.notify, vim.ui.select = real_check, real_update, real_notify, real_select
		zephyr.setup({ drift = { auto_check = true } })
	end)

	it("checks a workspace once per session when its files are opened", function()
		vim.cmd("edit " .. root .. "/app/src/main.c")
		vim.cmd("edit " .. root .. "/app/west.yml")
		vim.cmd("bwipeout! " .. root .. "/app/src/main.c")
		assert.are.same({ root }, checks)
		assert.are.equal(1, #notes)
		assert.matches("1 project%(s%) drifted", notes[1].msg)
		assert.matches(":Zephyr update", notes[1].msg)
	end)

	it("checks again after the Manifest is written, without updating", function()
		local updated = false
		zephyr.update = function() updated = true end
		ui.checked[root] = true
		ui.on_write(root .. "/app/src/main.c")
		assert.are.same({}, checks)
		ui.on_write(root .. "/app/west.yml")
		assert.are.same({ root }, checks)
		assert.is_false(updated)
	end)

	it("can be turned off in setup", function()
		zephyr.setup({ drift = { auto_check = false } })
		ui.on_open(root .. "/app/src/main.c")
		ui.on_write(root .. "/app/west.yml")
		assert.are.same({}, checks)
	end)

	it(":Zephyr update shows drift first and only updates after confirming", function()
		local items, ran
		zephyr.update = function(ws, opts) ran = { topdir = ws.topdir, projects = opts.projects } end
		vim.ui.select = function(choices, _, on_choice)
			items = vim.tbl_map(function(c) return c.label end, choices)
			on_choice(choices[2])
		end
		vim.cmd("edit " .. root .. "/app/src/main.c")
		ui.checked = {}
		checks = {}
		vim.cmd("Zephyr update")
		vim.cmd("only")
		vim.cmd("bwipeout! " .. root .. "/app/src/main.c")
		assert.are.same({ "Update all projects (west update)", "Update drifted projects only", "Cancel" }, items)
		assert.matches("mcuboot", notes[1].msg)
		assert.are.same({ topdir = root, projects = { "mcuboot" } }, ran)
	end)

	it(":Zephyr update does nothing when cancelled", function()
		local ran = false
		zephyr.update = function() ran = true end
		vim.ui.select = function(choices, _, on_choice) on_choice(nil) end
		ui.confirm({ topdir = root }, {})
		assert.is_false(ran)
	end)

	it(":Zephyr update check reports no drift too", function()
		zephyr.drift.check = function(_, cb) cb({}) end
		ui.check({ topdir = root })
		assert.matches("no drift", notes[1].msg)
	end)

	it("completes update actions", function()
		assert.are.same({ "check" }, commands.complete("c", "Zephyr update c"))
	end)
end)
