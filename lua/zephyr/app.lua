-- Finds the App around a path: the nearest directory whose CMakeLists.txt
-- calls find_package(Zephyr). Keeps each Workspace's Active app: the App that
-- build, flash and RTT use when the current file is not inside one.
local workspace = require("zephyr.workspace")

local M = {}

---@class zephyr.App
---@field dir string the App's source directory
---@field name string basename of `dir`
---@field workspace zephyr.Workspace|nil the Workspace around `dir`, when the App lives inside one

local function is_app_dir(dir)
	if not dir then
		return false
	end
	local fd = io.open(dir .. "/CMakeLists.txt", "r")
	if not fd then
		return false
	end
	local text = fd:read("*a")
	fd:close()
	return text:lower():find("find_package%s*%(%s*zephyr") ~= nil
end

---Describe `dir` as an App without checking it.
---@param dir string
---@return zephyr.App
function M.from_dir(dir)
	dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("(.)/$", "%1")
	return { dir = dir, name = vim.fs.basename(dir), workspace = workspace.find(dir) }
end

---Find the App containing `path` (a file or directory).
---@param path? string defaults to the current buffer's file, or the cwd for special buffers
---@return zephyr.App|nil
function M.find(path)
	if not path then
		path = vim.api.nvim_buf_get_name(0)
		if path == "" or vim.bo.buftype ~= "" or path:match("^%w+://") then
			path = vim.fn.getcwd()
		end
	end
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("(.)/$", "%1")
	local start = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
	if is_app_dir(start) then
		return M.from_dir(start)
	end
	for dir in vim.fs.parents(start) do
		if is_app_dir(dir) then
			return M.from_dir(dir)
		end
	end
	return nil
end

---True when `dir` is an App (its CMakeLists.txt calls find_package(Zephyr)).
---@param dir string
function M.is_app(dir)
	return is_app_dir(dir)
end

---The Active app of `ws`: the one built last or picked, while it is still an App.
---@param ws zephyr.Workspace
---@return zephyr.App|nil
function M.active(ws)
	local dir = require("zephyr.state").get(ws.topdir).active_app
	if dir and is_app_dir(dir) then
		return M.from_dir(dir)
	end
	return nil
end

---Make `app` the Active app of `ws`. Fires ZephyrAppActivated (`ev.data`: workspace, app).
---@param ws zephyr.Workspace
---@param app zephyr.App
function M.activate(ws, app)
	local st = require("zephyr.state")
	if st.get(ws.topdir).active_app == app.dir then
		return
	end
	st.set(ws.topdir, { active_app = app.dir })
	require("zephyr.events").emit("AppActivated", { workspace = ws.topdir, app = app.dir })
end

-- Directories never searched for Apps.
local skip = { build = true, node_modules = true, __pycache__ = true }

---Apps of `ws` to pick an Active app from: those with Build configurations in
---the settings file, and those found in the manifest repository (not in
---Zephyr, NCS or other projects; build directories skipped).
---@param ws zephyr.Workspace
---@param opts? { depth?: integer } how deep to search the manifest repository (default 4)
---@return zephyr.App[] sorted by directory
function M.list(ws, opts)
	local depth = (opts and opts.depth) or 4
	local seen, out = {}, {}
	local function add(dir)
		dir = vim.fs.normalize(dir)
		if not seen[dir] and is_app_dir(dir) then
			seen[dir] = true
			table.insert(out, M.from_dir(dir))
		end
	end
	for _, dir in ipairs(require("zephyr.settings").apps(ws.topdir)) do
		add(dir)
	end
	local repo = ws.manifest_dir
	local zephyr_base = ws.zephyr_base and vim.fs.normalize(ws.zephyr_base)
	local function walk(dir, level)
		if zephyr_base and vim.fs.normalize(dir) == zephyr_base then
			return
		end
		if is_app_dir(dir) then
			add(dir)
			return -- an App's subdirectories are its own
		end
		if level >= depth then
			return
		end
		for name, type in vim.fs.dir(dir) do
			local sub = dir .. "/" .. name
			if
				type == "directory"
				and not name:match("^%.")
				and not skip[name]
				and not vim.uv.fs_stat(sub .. "/CMakeCache.txt")
			then
				walk(sub, level + 1)
			end
		end
	end
	if repo and vim.uv.fs_stat(repo) then
		walk(repo, 0)
	end
	table.sort(out, function(a, b)
		return a.dir < b.dir
	end)
	return out
end

return M
