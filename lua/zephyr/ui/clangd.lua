-- Default UI for `:Zephyr clangd`: write the App's .clangd and say what happened.
local app_mod = require("zephyr.app")
local clangd = require("zephyr.clangd")

local M = {}

local function notify(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end

---Write the `.clangd` of `app` and report the result.
---@param app zephyr.App
function M.write(app)
	local ok, res = clangd.write(app)
	local rel = vim.fn.fnamemodify(res.path, ":~:.")
	if res.status == "no-build-config" then
		return notify("no build configuration yet; try :Zephyr build new", vim.log.levels.WARN)
	elseif res.status == "hand-written" then
		return notify(
			("%s was not written by zephyr.nvim, so it is left alone. Point CompileFlags.CompilationDatabase at %s"):format(
				rel,
				res.database
			),
			vim.log.levels.WARN
		)
	end
	local msg = ("%s %s -> %s"):format(res.status == "written" and "wrote" or "kept", rel, res.database)
	if not res.has_database then
		msg = msg .. " (no compile_commands.json yet; run :Zephyr build)"
	end
	notify(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
end

---@param args string[]
function M.run(args)
	local app = app_mod.find()
	if not app then
		return notify("not inside a Zephyr app (no CMakeLists.txt with find_package(Zephyr))", vim.log.levels.ERROR)
	end
	if args[1] ~= nil then
		return notify(("unknown action '%s'; :Zephyr clangd takes none"):format(args[1]), vim.log.levels.ERROR)
	end
	M.write(app)
end

return M
