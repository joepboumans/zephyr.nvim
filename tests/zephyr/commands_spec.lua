local commands = require("zephyr.commands")

describe(":Zephyr", function()
	it("exists", function()
		assert.are.equal(2, vim.fn.exists(":Zephyr"))
	end)

	it("completes subcommands", function()
		assert.are.same({ "build" }, commands.complete("bu", "Zephyr bu"))
		assert.are.same(#commands.names(), #commands.complete("", "Zephyr "))
	end)

	it("completes sdk actions", function()
		assert.are.same({ "install" }, commands.complete("in", "Zephyr sdk in"))
		assert.are.same({ "list", "select", "install" }, commands.complete("", "Zephyr sdk "))
		assert.are.same({}, commands.complete("", "Zephyr sdk install "))
	end)

	it("completes build actions", function()
		assert.are.same({ "pristine", "select", "new", "edit", "app" }, commands.complete("", "Zephyr build "))
	end)

	it("completes flash actions", function()
		assert.are.same({ "erase", "probe" }, commands.complete("", "Zephyr flash "))
	end)

	it("completes output actions", function()
		assert.are.same({ "close" }, commands.complete("", "Zephyr output "))
	end)

	it("runs a subcommand's UI with the remaining args", function()
		local ui = require("zephyr.ui.build")
		local got
		local saved = ui.run
		ui.run = function(args) got = args end
		vim.cmd("Zephyr build pristine")
		ui.run = saved
		assert.are.same({ "pristine" }, got)
	end)

	it("reports an unknown action without running the subcommand", function()
		local ui = require("zephyr.ui.build")
		local ran, msg = false, nil
		local saved_run, saved_notify = ui.run, vim.notify
		ui.run = function() ran = true end
		vim.notify = function(m) msg = m end
		vim.cmd("Zephyr build bogus")
		ui.run, vim.notify = saved_run, saved_notify
		assert.is_false(ran)
		assert.are.equal("zephyr: unknown action 'bogus'; use pristine|select|new|edit|app", msg)
	end)

	it("passes any words to update, which takes project names", function()
		local ui = require("zephyr.ui.update")
		local got
		local saved = ui.run
		ui.run = function(args) got = args end
		vim.cmd("Zephyr update zephyr nrf")
		ui.run = saved
		assert.are.same({ "zephyr", "nrf" }, got)
	end)
end)
