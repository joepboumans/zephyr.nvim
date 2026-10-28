local M = {}

local notify = require("zephyr.ui.notify")

-- Each subcommand of :Zephyr is run by a Default UI module. A module lists the words that can follow
-- its subcommand in `M.actions`; those are checked here. A module that also takes other words (update
-- takes project names) sets `M.any_args`.
local modules = {
	build = "zephyr.ui.build",
	flash = "zephyr.ui.flash",
	rtt = "zephyr.ui.rtt",
	update = "zephyr.ui.update",
	sdk = "zephyr.ui.sdk",
	clangd = "zephyr.ui.clangd",
	output = "zephyr.ui.output",
}

function M.names()
	local names = vim.tbl_keys(modules)
	table.sort(names)
	return names
end

function M.run(opts)
	local name = opts.fargs[1]
	if not name then
		vim.notify("Usage: :Zephyr {" .. table.concat(M.names(), "|") .. "}", vim.log.levels.INFO)
		return
	end
	if not modules[name] then
		return notify(("unknown subcommand '%s'"):format(name), vim.log.levels.ERROR)
	end
	local ui = require(modules[name])
	local args = vim.list_slice(opts.fargs, 2)
	local action = args[1]
	if action and ui.actions and not ui.any_args and not vim.tbl_contains(ui.actions, action) then
		return notify(
			("unknown action '%s'; use %s"):format(action, table.concat(ui.actions, "|")),
			vim.log.levels.ERROR
		)
	end
	ui.run(args, opts)
end

local function matching(words, arglead)
	return vim.tbl_filter(function(w)
		return vim.startswith(w, arglead)
	end, words)
end

function M.complete(arglead, cmdline)
	local words = vim.split(vim.trim(cmdline), "%s+")
	local typed = #words - (arglead == "" and 0 or 1) -- words before the one being completed
	if typed <= 1 then
		return matching(M.names(), arglead)
	end
	if typed == 2 and modules[words[2]] then
		return matching(require(modules[words[2]]).actions or {}, arglead)
	end
	return {}
end

return M
