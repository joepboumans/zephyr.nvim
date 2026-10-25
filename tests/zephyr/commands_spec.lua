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
		assert.are.same({ "pristine", "select", "new" }, commands.complete("", "Zephyr build "))
	end)

	it("runs an implemented subcommand with the remaining args", function()
		local got
		local saved = commands.subcommands.build
		commands.subcommands.build = function(args) got = args end
		vim.cmd("Zephyr build --pristine")
		commands.subcommands.build = saved
		assert.are.same({ "--pristine" }, got)
	end)
end)
