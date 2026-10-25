if vim.g.loaded_zephyr then
	return
end
vim.g.loaded_zephyr = true

require("zephyr.registry").register("toolchain_provider", require("zephyr.sdk").provider)
require("zephyr.registry").register("probe_finder", require("zephyr.probes.jlink").finder)

vim.api.nvim_create_user_command("Zephyr", function(opts)
	require("zephyr.commands").run(opts)
end, {
	nargs = "*",
	desc = "Zephyr: build, flash, rtt, update, sdk, clangd",
	complete = function(arglead, cmdline)
		return require("zephyr.commands").complete(arglead, cmdline)
	end,
})

-- Drift check: once per Workspace when one of its files is opened, and again
-- after its Manifest is written. Disable with setup({ drift = { auto_check = false } }).
local group = vim.api.nvim_create_augroup("zephyr_drift", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
	group = group,
	callback = function(ev)
		if vim.bo[ev.buf].buftype == "" then
			require("zephyr.ui.update").on_open(ev.file)
		end
	end,
})
vim.api.nvim_create_autocmd("BufWritePost", {
	group = group,
	callback = function(ev)
		require("zephyr.ui.update").on_write(ev.file)
	end,
})
