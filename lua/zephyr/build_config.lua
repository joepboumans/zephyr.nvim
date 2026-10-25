-- Build configurations of an App: build directories holding a Zephyr
-- CMakeCache.txt (plain or sysbuild), and the active one per App.
local state = require("zephyr.state")
local events = require("zephyr.events")

local M = {}

---@class zephyr.BuildConfig
---@field dir string the build directory (the sysbuild top level for sysbuild builds)
---@field name string basename of `dir`
---@field exists boolean false for a new Build configuration that has not been configured yet
---@field board string|nil board as recorded by CMake (`CACHED_BOARD`), or as chosen for a new one
---@field app_dir string|nil the App this was configured from
---@field sysbuild boolean
---@field image_dir string build directory of the App's own image; same as `dir` without sysbuild
---@field conf_files string[] Kconfig fragments (`CONF_FILE`)
---@field extra_conf_files string[] `EXTRA_CONF_FILE`
---@field overlays string[] devicetree overlays (`DTC_OVERLAY_FILE`)
---@field extra_overlays string[] `EXTRA_DTC_OVERLAY_FILE`
---@field zephyr_base string|nil

local function read_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local text = fd:read("*a")
	fd:close()
	return text
end

local function is_dir(path)
	local st = path and vim.uv.fs_stat(path)
	return st ~= nil and st.type == "directory"
end

---Parse CMakeCache.txt text into `{ KEY = value }`.
---@param text string
---@return table<string, string>
function M.parse_cache(text)
	local out = {}
	for line in vim.gsplit(text, "\n", { plain = true }) do
		if not line:match("^%s*//") and not line:match("^%s*#") then
			local key, value = line:match("^([^:=]+):[^=]*=(.*)$")
			if key then
				out[key] = (value:gsub("\r$", ""))
			end
		end
	end
	return out
end

---@param dir string
---@return table<string, string>|nil cache, nil when `dir` is not a Zephyr build directory
local function read_cache(dir)
	local text = read_file(dir .. "/CMakeCache.txt")
	if not text then
		return nil
	end
	local cache = M.parse_cache(text)
	-- Same test as west's build_helpers.is_zephyr_build().
	if not cache.ZEPHYR_BASE and not cache.ZEPHYR_TOOLCHAIN_VARIANT then
		return nil
	end
	return cache
end

---True when `dir` holds a Zephyr CMakeCache.txt.
---@param dir string
function M.is_build_dir(dir)
	return read_cache(dir) ~= nil
end

---Parse the few keys of sysbuild's domains.yaml.
---@param text string
---@return { default: string|nil, domains: { name: string, build_dir: string|nil }[], flash_order: string[] }
function M.parse_domains(text)
	local out, section, current = { domains = {}, flash_order = {} }, nil, nil
	for line in vim.gsplit(text, "\n", { plain = true }) do
		local top_key, top_value = line:match("^([%w_]+):%s*(.-)%s*$")
		if top_key then
			section = top_key
			if top_key == "default" then
				out.default = top_value
			end
		elseif section == "domains" then
			local key, value = line:match("^%s*%-?%s*([%w_]+):%s*(.-)%s*$")
			if key == "name" then
				current = { name = value }
				table.insert(out.domains, current)
			elseif key == "build_dir" and current then
				current.build_dir = value
			end
		elseif section == "flash_order" then
			local item = line:match("^%s*%-%s*(.-)%s*$")
			if item then
				table.insert(out.flash_order, item)
			end
		end
	end
	return out
end

---Build directory of the App's own image. With sysbuild this is the default
---domain from domains.yaml (`<dir>/<app basename>`); otherwise `dir` itself.
---@param dir string a build directory
---@param app_dir? string the App, used when domains.yaml names no default
---@return string
function M.image_dir(dir, app_dir)
	local text = read_file(dir .. "/domains.yaml")
	if not text then
		return dir
	end
	local domains = M.parse_domains(text)
	local name = domains.default
	for _, d in ipairs(domains.domains) do
		if d.name == name and is_dir(d.build_dir) then
			return d.build_dir
		end
	end
	name = name or (app_dir and vim.fs.basename(app_dir))
	if name and is_dir(dir .. "/" .. name) then
		return dir .. "/" .. name
	end
	return dir
end

local function split_list(value)
	local out = {}
	for item in (value or ""):gmatch("[^;%s]+") do
		table.insert(out, item)
	end
	return out
end

local function nonempty(v)
	return v ~= nil and v ~= "" and v or nil
end

---Read the Build configuration recorded in `dir`.
---@param dir string
---@return zephyr.BuildConfig|nil nil when `dir` is not a Zephyr build directory
function M.read(dir)
	dir = vim.fs.normalize(dir)
	local cache = read_cache(dir)
	if not cache then
		return nil
	end
	local sysbuild = vim.uv.fs_stat(dir .. "/domains.yaml") ~= nil
	-- West prefers APP_DIR (set by sysbuild); a sysbuild CMAKE_HOME_DIRECTORY is share/sysbuild.
	local app_dir = nonempty(cache.APP_DIR) or nonempty(cache.APPLICATION_SOURCE_DIR)
	if not app_dir and not sysbuild then
		app_dir = nonempty(cache.CMAKE_HOME_DIRECTORY)
	end
	local image_dir = M.image_dir(dir, app_dir)
	-- Conf files and overlays live in the image's cache under sysbuild.
	local image = image_dir ~= dir and read_cache(image_dir) or cache
	local function key(name)
		return nonempty(image[name]) or nonempty(cache[name])
	end
	return {
		dir = dir,
		name = vim.fs.basename(dir),
		exists = true,
		board = nonempty(cache.CACHED_BOARD) or nonempty(cache.BOARD) or key("CACHED_BOARD") or key("BOARD"),
		app_dir = app_dir or nonempty(image.APPLICATION_SOURCE_DIR),
		sysbuild = sysbuild,
		image_dir = image_dir,
		conf_files = split_list(key("CONF_FILE")),
		extra_conf_files = split_list(key("EXTRA_CONF_FILE") or key("OVERLAY_CONFIG")),
		overlays = split_list(key("DTC_OVERLAY_FILE")),
		extra_overlays = split_list(key("EXTRA_DTC_OVERLAY_FILE")),
		zephyr_base = key("ZEPHYR_BASE"),
	}
end

local function same_dir(a, b)
	return a and b and vim.fs.normalize(a) == vim.fs.normalize(b)
end

---Build configurations found on disk for `app`: build directories directly in
---the App, or one level deeper (as with `build.dir-fmt = build/{board}`).
---Build directories configured from another App are left out.
---@param app zephyr.App
---@return zephyr.BuildConfig[] sorted by name, `build` first
function M.list(app)
	local out = {}
	local function consider(dir)
		local cfg = M.read(dir)
		if cfg and (not cfg.app_dir or same_dir(cfg.app_dir, app.dir)) then
			table.insert(out, cfg)
		end
		return cfg
	end
	for name, type in vim.fs.dir(app.dir) do
		if type == "directory" and not name:match("^%.") then
			local dir = app.dir .. "/" .. name
			if not consider(dir) then
				for sub, subtype in vim.fs.dir(dir) do
					if subtype == "directory" and not sub:match("^%.") then
						consider(dir .. "/" .. sub)
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.name == "build") ~= (b.name == "build") then
			return a.name == "build"
		end
		return a.dir < b.dir
	end)
	return out
end

-- Personal state is keyed by Workspace; an App outside one is keyed by itself.
local function state_key(app)
	return app.workspace and app.workspace.topdir or app.dir
end

local function stored(app)
	return (state.get(state_key(app)).build_configs or {})[app.dir]
end

local function store(app, value)
	local key = state_key(app)
	local all = vim.deepcopy(state.get(key).build_configs or {})
	all[app.dir] = value
	state.set(key, { build_configs = all })
end

---A Build configuration that is not on disk yet.
local function pending(app, dir, board)
	return {
		dir = dir,
		name = vim.fs.basename(dir),
		exists = false,
		board = board,
		app_dir = app.dir,
		sysbuild = false,
		image_dir = dir,
		conf_files = {},
		extra_conf_files = {},
		overlays = {},
		extra_overlays = {},
	}
end

---The active Build configuration of `app`: the one chosen for it if it is still
---there (or still to be built), else the first one found on disk.
---@param app zephyr.App
---@return zephyr.BuildConfig|nil, boolean selected true when chosen explicitly
function M.active(app)
	local chosen = stored(app)
	if chosen and chosen.dir then
		local cfg = M.read(chosen.dir)
		if cfg then
			return cfg, true
		end
		if chosen.board and not vim.uv.fs_stat(chosen.dir .. "/CMakeCache.txt") then
			return pending(app, chosen.dir, chosen.board), true
		end
	end
	return M.list(app)[1], false
end

---Make `config` the active Build configuration of `app`.
---@param app zephyr.App
---@param config zephyr.BuildConfig
function M.activate(app, config)
	store(app, { dir = config.dir, board = not config.exists and config.board or nil })
	events.emit("BuildConfigActivated", { app = app.dir, build_dir = config.dir, board = config.board })
end

---Build directory name for a board: `build_<board>` with `/` replaced.
---@param board string e.g. "nrf5340dk/nrf5340/cpuapp"
---@return string e.g. "build_nrf5340dk_nrf5340_cpuapp"
function M.dir_name(board)
	return "build_" .. board:gsub("[/@%s]", "_")
end

---Create a new Build configuration for `board` and make it active. It exists on
---disk once it has been built.
---@param app zephyr.App
---@param opts { board: string, dir?: string } `dir` defaults to `<app>/build_<board>`
---@return zephyr.BuildConfig
function M.new(app, opts)
	local dir = vim.fs.normalize(opts.dir or (app.dir .. "/" .. M.dir_name(opts.board)))
	local cfg = M.read(dir) or pending(app, dir, opts.board)
	M.activate(app, cfg)
	return cfg
end

---Parse `west boards --format '{name};{qualifiers}'` output into full board targets.
---@param text string
---@return string[] sorted, e.g. { "nrf52840dk/nrf52840", "nrf5340dk/nrf5340/cpuapp" }
function M.parse_boards(text)
	local seen, out = {}, {}
	local function add(b)
		if b ~= "" and not seen[b] then
			seen[b] = true
			table.insert(out, b)
		end
	end
	for line in vim.gsplit(text, "\n", { plain = true }) do
		local name, quals = line:match("^%s*([^;%s]+);?(.-)%s*$")
		if name then
			if quals == "" then
				add(name)
			else
				for q in quals:gmatch("[^,%s]+") do
					add(name .. "/" .. q)
				end
			end
		end
	end
	table.sort(out)
	return out
end

---List the boards west knows about, with their qualifiers.
---@param app zephyr.App
---@param on_done fun(boards: string[]|nil, err: string|nil)
function M.boards(app, on_done)
	local cmd = { "west", "boards", "--format", "{name};{qualifiers}" }
	require("zephyr.process").run(cmd, { cwd = app.dir }, function(res)
		if res.code ~= 0 then
			return on_done(nil, vim.trim((res.stderr or "") ~= "" and res.stderr or res.stdout or "west boards failed"))
		end
		on_done(M.parse_boards(res.stdout or ""))
	end)
end

return M
