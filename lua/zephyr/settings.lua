-- Build configuration settings: what each Build configuration is built with,
-- stored per Workspace in `<topdir>/.zephyr/build-configs.json` (an App outside
-- a Workspace keeps its own `<app>/.zephyr/`). The `.zephyr/` directory holds a
-- `.gitignore` with `*`, so git ignores it without touching the team's files.
-- Paths are relative (to the App, board roots to the topdir), so the file
-- works on another machine.
local M = {}

M.DIR = ".zephyr"
M.FILE = "build-configs.json"
M.VERSION = 1

---@class zephyr.ToolchainRef
---@field provider string name of the Toolchain provider, e.g. "zephyr-sdk"
---@field version string

---@class zephyr.BuildSettings
---@field build_dir string build directory, relative to the App
---@field board string board target, e.g. "nrf5340dk/nrf5340/cpuapp"
---@field conf_files string[] Kconfig files (`CONF_FILE`); empty means Zephyr's default (prj.conf)
---@field extra_conf_files string[] extra Kconfig fragments (`EXTRA_CONF_FILE`)
---@field overlays string[] devicetree overlays (`EXTRA_DTC_OVERLAY_FILE`)
---@field snippets string[] (`-S`)
---@field sysbuild boolean `--sysbuild` or `--no-sysbuild`
---@field optimization string|nil "debug", "speed", "size" or "none"; nil keeps Zephyr's default
---@field board_roots string[] extra board roots, relative to the Workspace topdir
---@field cmake_args string[] extra CMake arguments, passed after `--`
---@field toolchain zephyr.ToolchainRef|nil nil means the default Toolchain

---Fields whose change needs CMake to configure again.
M.reconfigure_fields = {
	"board",
	"conf_files",
	"extra_conf_files",
	"overlays",
	"snippets",
	"sysbuild",
	"optimization",
	"board_roots",
	"cmake_args",
	"toolchain",
}

M.list_fields = { "conf_files", "extra_conf_files", "overlays", "snippets", "board_roots", "cmake_args" }

---Settings with every field present.
---@param s table
---@return zephyr.BuildSettings
function M.normalize(s)
	local out = vim.deepcopy(s or {})
	for _, f in ipairs(M.list_fields) do
		out[f] = type(out[f]) == "table" and vim.tbl_values(out[f]) or {}
	end
	if out.sysbuild == nil then
		out.sysbuild = true
	end
	if out.optimization == "" or out.optimization == "default" then
		out.optimization = nil
	end
	if type(out.toolchain) ~= "table" or not out.toolchain.provider then
		out.toolchain = nil
	end
	return out
end

---Directory the settings file of `app` lives under: its Workspace's topdir, else the App.
---@param app zephyr.App
---@return string
function M.root(app)
	return app.workspace and app.workspace.topdir or app.dir
end

---Path of the settings file under `root`.
---@param root string
function M.file(root)
	return vim.fs.joinpath(root, M.DIR, M.FILE)
end

---`path` relative to `base`, with `..` when it is outside; absolute paths elsewhere stay absolute.
---@param base string
---@param path string
---@return string
function M.relative(base, path)
	base, path = vim.fs.normalize(base), vim.fs.normalize(path)
	if not path:match("^/") then
		return path
	end
	if path == base then
		return "."
	end
	if vim.startswith(path, base .. "/") then
		return path:sub(#base + 2)
	end
	local b, p = vim.split(base, "/", { trimempty = true }), vim.split(path, "/", { trimempty = true })
	local i = 1
	while b[i] and p[i] and b[i] == p[i] do
		i = i + 1
	end
	if i <= 2 then
		return path -- only `/` in common: keep it absolute
	end
	local parts = {}
	for _ = i, #b do
		table.insert(parts, "..")
	end
	vim.list_extend(parts, vim.list_slice(p, i))
	return table.concat(parts, "/")
end

---Resolve a stored path against `base`.
---@param base string
---@param path string
---@return string
function M.absolute(base, path)
	if path:match("^/") or path:match("^~") then
		return vim.fs.normalize(path)
	end
	return vim.fs.normalize(vim.fn.simplify(base .. "/" .. path))
end

---The App's key in the settings file: its path relative to the root.
---@param app zephyr.App
function M.app_key(app)
	return M.relative(M.root(app), app.dir)
end

---@param root string
---@return { version: integer, apps: table<string, zephyr.BuildSettings[]> }
function M.load(root)
	local fd = io.open(M.file(root), "r")
	if not fd then
		return { version = M.VERSION, apps = {} }
	end
	local text = fd:read("*a")
	fd:close()
	local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
	if not ok or type(data) ~= "table" then
		return { version = M.VERSION, apps = {} }
	end
	data.apps = type(data.apps) == "table" and data.apps or {}
	return data
end

---@param root string
---@param data table
function M.save(root, data)
	local dir = vim.fs.joinpath(root, M.DIR)
	vim.fn.mkdir(dir, "p")
	local ignore = vim.fs.joinpath(dir, ".gitignore")
	if not vim.uv.fs_stat(ignore) then
		local fd = assert(io.open(ignore, "w"))
		fd:write("*\n")
		fd:close()
	end
	data.version = M.VERSION
	local fd = assert(io.open(M.file(root), "w"))
	fd:write(vim.json.encode(data))
	fd:close()
end

---Every stored Build configuration of `app`.
---@param app zephyr.App
---@return zephyr.BuildSettings[]
function M.list(app)
	local out = {}
	for _, s in ipairs(M.load(M.root(app)).apps[M.app_key(app)] or {}) do
		table.insert(out, M.normalize(s))
	end
	return out
end

---The stored settings of the Build configuration in `build_dir` (absolute) of `app`.
---@param app zephyr.App
---@param build_dir string
---@return zephyr.BuildSettings|nil
function M.get(app, build_dir)
	local rel = M.relative(app.dir, build_dir)
	for _, s in ipairs(M.list(app)) do
		if s.build_dir == rel then
			return s
		end
	end
	return nil
end

---Store `settings` for `app`, replacing the entry with the same build directory
---(or with `replaces`, the old build directory when it was renamed).
---@param app zephyr.App
---@param settings zephyr.BuildSettings
---@param replaces? string build directory (relative to the App) the entry had before
function M.put(app, settings, replaces)
	local root = M.root(app)
	local data = M.load(root)
	local key = M.app_key(app)
	local list = data.apps[key] or {}
	local s = M.normalize(settings)
	local old = replaces or s.build_dir
	local out, placed = {}, false
	for _, existing in ipairs(list) do
		if existing.build_dir == old and not placed then
			table.insert(out, s)
			placed = true
		elseif existing.build_dir ~= s.build_dir then
			table.insert(out, existing)
		end
	end
	if not placed then
		table.insert(out, s)
	end
	list = out
	data.apps[key] = list
	M.save(root, data)
end

---Remove the settings of `build_dir` (absolute) of `app`.
---@param app zephyr.App
---@param build_dir string
function M.remove(app, build_dir)
	local root = M.root(app)
	local data = M.load(root)
	local key = M.app_key(app)
	local rel = M.relative(app.dir, build_dir)
	data.apps[key] = vim.tbl_filter(function(e)
		return e.build_dir ~= rel
	end, data.apps[key] or {})
	M.save(root, data)
end

---Every App (by absolute directory) with stored Build configurations under `root`.
---@param root string
---@return string[]
function M.apps(root)
	local out = {}
	for key, list in pairs(M.load(root).apps) do
		if type(list) == "table" and #list > 0 then
			table.insert(out, M.absolute(root, key))
		end
	end
	table.sort(out)
	return out
end

---Apply `fn(settings)` to every stored Build configuration under `root` and save.
---@param root string
---@param fn fun(s: zephyr.BuildSettings): boolean|nil return true when it changed `s`
---@return integer changed
function M.update_all(root, fn)
	local data = M.load(root)
	local changed = 0
	for _, list in pairs(data.apps) do
		for i, s in ipairs(list) do
			local n = M.normalize(s)
			if fn(n) then
				list[i] = n
				changed = changed + 1
			end
		end
	end
	if changed > 0 then
		M.save(root, data)
	end
	return changed
end

return M
