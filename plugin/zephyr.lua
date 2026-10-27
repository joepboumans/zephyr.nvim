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

-- Keep a generated .clangd pointing at the active Build configuration.
-- Disable with setup({ clangd = { auto_write = false } }).
local clangd_group = vim.api.nvim_create_augroup("zephyr_clangd", { clear = true })
vim.api.nvim_create_autocmd("User", {
	group = clangd_group,
	pattern = { "ZephyrBuildConfigActivated", "ZephyrBuildFinished" },
	callback = function(ev)
		local data = ev.data or {}
		if ev.match == "ZephyrBuildFinished" and not data.ok then
			return
		end
		require("zephyr.clangd").refresh(data.app)
	end,
})

-- Say when a build directory without settings (made by VS Code or by hand) was imported.
vim.api.nvim_create_autocmd("User", {
	group = vim.api.nvim_create_augroup("zephyr_import", { clear = true }),
	pattern = "ZephyrBuildConfigImported",
	callback = function(ev)
		local data = ev.data or {}
		vim.schedule(function()
			vim.notify(
				("zephyr: imported build configuration %s (%s) into the settings"):format(data.name, data.board or "?"),
				vim.log.levels.INFO
			)
		end)
	end,
})
