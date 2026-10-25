local commands = require("zephyr.commands")

describe(":Zephyr", function()
	it("exists", function()
		assert.are.equal(2, vim.fn.exists(":Zephyr"))
	end)

	it("completes subcommands", function()
		assert.are.same({ "build" }, commands.complete("bu", "Zephyr bu"))
		assert.are.same(#commands.names(), #commands.complete("", "Zephyr "))
	end)

	it("runs an implemented subcommand with the remaining args", function()
		local got
		commands.subcommands.build = function(args) got = args end
		vim.cmd("Zephyr build --pristine")
		commands.subcommands.build = false
		assert.are.same({ "--pristine" }, got)
	end)
end)
