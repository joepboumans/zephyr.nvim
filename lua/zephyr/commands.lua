local M = {}

---Subcommands of :Zephyr. Each is filled in by its component as it lands.
M.subcommands = {
	build = function(args)
		require("zephyr.ui.build").run(args)
	end,
	flash = function(args)
		require("zephyr.ui.flash").run(args)
	end,
	rtt = false,
	update = function(args)
		require("zephyr.ui.update").run(args)
	end,
	sdk = function(args)
		require("zephyr.ui.sdk").run(args)
	end,
	clangd = function(args)
		require("zephyr.ui.clangd").run(args)
	end,
}

function M.names()
	local names = vim.tbl_keys(M.subcommands)
	table.sort(names)
	return names
end

function M.run(opts)
	local name = opts.fargs[1]
	if not name then
		vim.notify("Usage: :Zephyr {" .. table.concat(M.names(), "|") .. "}", vim.log.levels.INFO)
		return
	end
	local impl = M.subcommands[name]
	if impl == nil then
		vim.notify(("zephyr: unknown subcommand '%s'"):format(name), vim.log.levels.ERROR)
	elseif impl == false then
		vim.notify(("zephyr: '%s' is not implemented yet"):format(name), vim.log.levels.WARN)
	else
		impl(vim.list_slice(opts.fargs, 2), opts)
	end
end

---Words that can follow a subcommand.
M.actions = {
	build = { "pristine", "select", "new" },
	flash = { "erase", "probe" },
	sdk = { "list", "select", "install" },
	update = { "check" },
}

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
	if typed == 2 then
		return matching(M.actions[words[2]] or {}, arglead)
	end
	return {}
end

return M
