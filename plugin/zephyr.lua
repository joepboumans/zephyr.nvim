if vim.g.loaded_zephyr then
	return
end
vim.g.loaded_zephyr = true

require("zephyr.registry").register("toolchain_provider", require("zephyr.sdk").provider)

vim.api.nvim_create_user_command("Zephyr", function(opts)
	require("zephyr.commands").run(opts)
end, {
	nargs = "*",
	desc = "Zephyr: build, flash, rtt, update, sdk, clangd",
	complete = function(arglead, cmdline)
		return require("zephyr.commands").complete(arglead, cmdline)
	end,
})
