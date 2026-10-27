-- Default UI for finding the App a command works on: the App around the
-- current file, else the Workspace's Active app (picked once when there is
-- none yet), and `:Zephyr build app` to pick another one.
local app_mod = require("zephyr.app")
local workspace = require("zephyr.workspace")

local M = {}

M.NOT_IN_APP = "not inside a Zephyr app (no CMakeLists.txt with find_package(Zephyr))"

local notify = require("zephyr.ui.notify")

local function label(ws, app)
	local rel = require("zephyr.settings").relative(ws.topdir, app.dir)
	return rel
end

---Pick the Active app of `ws` among its Apps.
---@param ws zephyr.Workspace
---@param on_choice? fun(app: zephyr.App|nil)
function M.pick(ws, on_choice)
	on_choice = on_choice or function() end
	local apps = app_mod.list(ws)
	if #apps == 0 then
		notify(("no Apps found in %s; open a file inside an App"):format(ws.manifest_dir), vim.log.levels.WARN)
		return on_choice(nil)
	end
	local active = app_mod.active(ws)
	vim.ui.select(apps, {
		prompt = "Active app",
		format_item = function(a)
			return ((active and active.dir == a.dir) and "* " or "  ") .. label(ws, a)
		end,
	}, function(choice)
		if choice then
			app_mod.activate(ws, choice)
			notify("active app: " .. label(ws, choice))
		end
		on_choice(choice)
	end)
end

---The App to work on: the one around the current file, else the Workspace's
---Active app, else one picked now (and remembered). Outside any Workspace and
---App it reports an error. `on_app` is not called when nothing was picked.
---@param on_app fun(app: zephyr.App)
function M.resolve(on_app)
	local app = app_mod.find()
	if app then
		return on_app(app)
	end
	local ws = workspace.find()
	if not ws then
		return notify(M.NOT_IN_APP, vim.log.levels.ERROR)
	end
	local active = app_mod.active(ws)
	if active then
		return on_app(active)
	end
	M.pick(ws, function(choice)
		if choice then
			on_app(choice)
		end
	end)
end

---`:Zephyr build app`: pick the Active app of the current Workspace.
function M.select()
	local ws = workspace.find()
	if not ws then
		return notify("not inside a west workspace", vim.log.levels.ERROR)
	end
	M.pick(ws)
end

return M
