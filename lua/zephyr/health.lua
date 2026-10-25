local M = {}

local function check_exe(name, args, required)
	if vim.fn.executable(name) == 0 then
		local report = required and vim.health.error or vim.health.warn
		report(("`%s` not found on PATH"):format(name))
		return
	end
	local ok, res = pcall(function()
		return vim.system({ name, unpack(args) }, { text = true }):wait(5000)
	end)
	local version = ok and res and vim.trim((res.stdout or ""):match("[^\n]*") or "") or ""
	vim.health.ok(("`%s` found %s"):format(name, version ~= "" and ("(" .. version .. ")") or ""))
end

function M.check()
	vim.health.start("zephyr.nvim")
	if vim.fn.has("nvim-0.10") == 1 then
		vim.health.ok("Neovim 0.10 or newer")
	else
		vim.health.error("zephyr.nvim needs Neovim 0.10 or newer")
	end

	vim.health.start("zephyr.nvim: tools")
	check_exe("west", { "--version" }, true)
	check_exe("cmake", { "--version" }, true)
	check_exe("ninja", { "--version" }, false)

	vim.health.start("zephyr.nvim: workspace")
	local ws = require("zephyr.workspace").find()
	if not ws then
		vim.health.info("Not inside a west workspace (no `.west/` above the current file or cwd)")
	else
		vim.health.ok("Workspace: " .. ws.topdir)
		if vim.uv.fs_stat(ws.manifest_file) then
			vim.health.ok("Manifest: " .. ws.manifest_file)
		else
			vim.health.error("Manifest not found: " .. ws.manifest_file)
		end
		local tc, selected = require("zephyr.toolchain").active(ws)
		if tc then
			vim.health.ok(("Active toolchain: %s (%s)%s"):format(tc.name, tc.path, selected and "" or ", default"))
		else
			vim.health.warn("No toolchain found", "Run `:Zephyr sdk install` or install the Zephyr SDK")
		end
	end

	vim.health.start("zephyr.nvim: registered extensions")
	local registry = require("zephyr.registry")
	for _, kind in ipairs({ "toolchain_provider", "probe_finder" }) do
		local names = vim.tbl_map(function(e)
			return e.name
		end, registry.list(kind))
		vim.health.info(("%s: %s"):format(kind, #names > 0 and table.concat(names, ", ") or "none"))
	end
end

return M
