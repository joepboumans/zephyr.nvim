local M = {}

---Subcommands of :Zephyr. Each is filled in by its component as it lands.
M.subcommands = {
	build = false,
	flash = false,
	rtt = false,
	update = false,
	sdk = false,
	clangd = false,
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

function M.complete(arglead, cmdline)
	if cmdline:match("^%s*Zephyr!?%s+%S+%s") then
		return {}
	end
	return vim.tbl_filter(function(n)
		return vim.startswith(n, arglead)
	end, M.names())
end

return M
