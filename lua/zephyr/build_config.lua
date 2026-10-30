-- Build configurations of an App. Each one owns its settings (board, config
-- files, overlays, snippets, sysbuild, board roots, CMake arguments, Toolchain;
-- see zephyr.settings), and has a build directory once it has been configured.
-- Build directories found without settings (made by VS Code or by hand) are
-- imported once. Which one is active is personal state.
local state = require("zephyr.state")
local events = require("zephyr.events")
local settings = require("zephyr.settings")

local fs = require("zephyr.fs")

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
---@field overlays string[] devicetree overlays (`EXTRA_DTC_OVERLAY_FILE`)
---@field base_overlays string[] `DTC_OVERLAY_FILE`, Zephyr's own choice of overlays
---@field snippets string[] `SNIPPET`
---@field board_roots string[] `BOARD_ROOT` as cached
---@field zephyr_base string|nil
---@field settings zephyr.BuildSettings|nil what zephyr.nvim configures it with; these win over the cache


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
	local text = fs.read(dir .. "/CMakeCache.txt")
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
	local text = fs.read(dir .. "/domains.yaml")
	if not text then
		return dir
	end
	local domains = M.parse_domains(text)
	local name = domains.default
	for _, d in ipairs(domains.domains) do
		if d.name == name and fs.is_dir(d.build_dir) then
			return d.build_dir
		end
	end
	name = name or (app_dir and vim.fs.basename(app_dir))
	if name and fs.is_dir(dir .. "/" .. name) then
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
	local cfg = {
		dir = dir,
		name = vim.fs.basename(dir),
		exists = true,
		board = nonempty(cache.CACHED_BOARD) or nonempty(cache.BOARD) or key("CACHED_BOARD") or key("BOARD"),
		app_dir = app_dir or nonempty(image.APPLICATION_SOURCE_DIR),
		sysbuild = sysbuild,
		image_dir = image_dir,
		base_overlays = split_list(key("DTC_OVERLAY_FILE")),
		snippets = split_list(key("SNIPPET") or key("CACHED_SNIPPET")),
		zephyr_base = key("ZEPHYR_BASE"),
	}
	for _, field in ipairs(settings.fields) do
		if field.cmake then
			local value = key(field.cmake)
			for _, alias in ipairs(field.aliases or {}) do
				value = value or key(alias)
			end
			cfg[field.name] = split_list(value)
		end
	end
	return cfg
end

local function same_dir(a, b)
	return a and b and vim.fs.normalize(a) == vim.fs.normalize(b)
end

---Build directories found on disk for `app`: directly in the App, or one level
---deeper (as with `build.dir-fmt = build/{board}`). Those configured from
---another App are left out.
---@param app zephyr.App
---@return zephyr.BuildConfig[]
function M.scan(app)
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
	return out
end

-- Board roots -----------------------------------------------------------------

---Board roots passed on configure and to `west boards`, beyond the ones Zephyr
---finds itself (the App's `boards/`, modules' `board_root`): the topdir when
---`<topdir>/boards/` exists, the manifest repository when it has `boards/`, and
---the settings' `board_roots` (relative to the topdir).
---@param app zephyr.App
---@param s? zephyr.BuildSettings
---@return string[] absolute directories
function M.board_roots(app, s)
	local out, seen = {}, {}
	local function add(dir)
		dir = vim.fs.normalize(dir)
		if not seen[dir] then
			seen[dir] = true
			table.insert(out, dir)
		end
	end
	local ws = app.workspace
	if ws then
		if fs.is_dir(ws.topdir .. "/boards") then
			add(ws.topdir)
		end
		if ws.manifest_dir and fs.is_dir(ws.manifest_dir .. "/boards") then
			add(ws.manifest_dir)
		end
	end
	for _, r in ipairs(s and s.board_roots or {}) do
		add(settings.absolute(settings.root(app), r))
	end
	return out
end

-- Settings ↔ Build configurations ---------------------------------------------

---A Build configuration that is not on disk yet.
local function pending(app, dir, board)
	local cfg = {
		dir = dir,
		name = vim.fs.basename(dir),
		exists = false,
		board = board,
		app_dir = app.dir,
		sysbuild = false,
		image_dir = dir,
		base_overlays = {},
		snippets = {},
	}
	for _, field in ipairs(settings.fields) do
		if field.cmake then
			cfg[field.name] = {}
		end
	end
	return cfg
end

---The Build configuration described by settings `s`, merged with what its build
---directory records. Settings win where both have a value.
---@param app zephyr.App
---@param s zephyr.BuildSettings
---@param disk? zephyr.BuildConfig|false already read from the build directory
---@return zephyr.BuildConfig
function M.from_settings(app, s, disk)
	s = settings.normalize(s)
	local dir = settings.absolute(app.dir, s.build_dir)
	if disk == nil then
		disk = M.read(dir)
	end
	local cfg = disk and vim.deepcopy(disk) or pending(app, dir, s.board)
	cfg.settings = s
	cfg.board = s.board or cfg.board
	cfg.app_dir = cfg.app_dir or app.dir
	if not cfg.exists then
		cfg.sysbuild = s.sysbuild
	end
	-- Board roots keep what the build directory records: configure adds zephyr.nvim's own too.
	for _, field in ipairs(settings.fields) do
		if field.kind == "list" and field.name ~= "board_roots" and cfg[field.name] and #s[field.name] > 0 then
			cfg[field.name] = settings.absolute_list(app, field, s[field.name])
		end
	end
	return cfg
end

---Read `build_info.yml` (Zephyr 3.7+) of a build directory.
---@param dir string
---@return table|nil
function M.build_info(dir)
	local info = require("zephyr.yaml").read(dir .. "/build_info.yml")
	return type(info) == "table" and info or nil
end

---Split a command line into words, honouring single and double quotes.
---@param line string
---@return string[]
function M.split_words(line)
	local out, word, quote, have = {}, {}, nil, false
	for c in (line or ""):gmatch(".") do
		if quote then
			if c == quote then
				quote = nil
			else
				table.insert(word, c)
			end
		elseif c == '"' or c == "'" then
			quote, have = c, true
		elseif c:match("%s") then
			if have or #word > 0 then
				table.insert(out, table.concat(word))
			end
			word, have = {}, false
		else
			table.insert(word, c)
		end
	end
	if have or #word > 0 then
		table.insert(out, table.concat(word))
	end
	return out
end

local optimization_symbols = {
	debug = "CONFIG_DEBUG_OPTIMIZATIONS",
	speed = "CONFIG_SPEED_OPTIMIZATIONS",
	size = "CONFIG_SIZE_OPTIMIZATIONS",
	none = "CONFIG_NO_OPTIMIZATIONS",
}
M.optimization_symbols = optimization_symbols

-- CMake variables a `west build` command line passes for settings: those of the
-- settings fields, and BOARD and SNIPPET, which settings take from `-b` and `-S`.
local function settings_variable(name)
	if name == "BOARD" or name == "SNIPPET" then
		return true
	end
	for _, field in ipairs(settings.fields) do
		if field.cmake == name or vim.tbl_contains(field.aliases or {}, name) then
			return true
		end
	end
	return false
end

---What a `west build` command line says beyond the cache: snippets (`-S`), the
---optimisation level and the other CMake arguments after `--`.
---@param words string[]
---@return { snippets: string[], optimization: string|nil, cmake_args: string[] }
function M.parse_west_command(words)
	local out = { snippets = {}, cmake_args = {} }
	local after = false
	local i = 1
	while i <= #words do
		local w = words[i]
		if after then
			local name, value = w:match("^%-D([%w_]+)[:%w]*=(.*)$")
			local level
			for l, sym in pairs(optimization_symbols) do
				if name == sym and value:lower():match("^y") then
					level = l
				end
			end
			if level then
				out.optimization = level
			elseif not (name and settings_variable(name)) then
				table.insert(out.cmake_args, w)
			end
		elseif w == "--" then
			after = true
		elseif w == "-S" or w == "--snippet" then
			i = i + 1
			if words[i] then
				table.insert(out.snippets, words[i])
			end
		else
			local snip = w:match("^%-%-snippet=(.*)$") or w:match("^%-S(.+)$")
			if snip then
				table.insert(out.snippets, snip)
			end
		end
		i = i + 1
	end
	return out
end

local function board_from_info(info)
	local board = info and type(info.cmake) == "table" and info.cmake.board
	if type(board) ~= "table" or type(board.name) ~= "string" then
		return nil
	end
	local target = board.name
	if type(board.qualifiers) == "string" and board.qualifiers ~= "" then
		target = target .. "/" .. board.qualifiers
	end
	return target
end

local function info_list(info, section, key)
	local s = info and type(info.cmake) == "table" and info.cmake[section]
	local v = type(s) == "table" and s[key] or nil
	if type(v) == "string" then
		return split_list(v)
	end
	return type(v) == "table" and v or nil
end

---Settings that recreate the build directory `disk` of `app`, read from its
---CMake cache and `build_info.yml`.
---@param app zephyr.App
---@param disk zephyr.BuildConfig
---@return zephyr.BuildSettings
function M.settings_from_disk(app, disk)
	local image_info = M.build_info(disk.image_dir)
	local top_info = disk.image_dir ~= disk.dir and M.build_info(disk.dir) or image_info
	local west = (top_info and type(top_info.west) == "table" and top_info.west)
		or (image_info and type(image_info.west) == "table" and image_info.west)
		or {}
	local cmd = M.parse_west_command(M.split_words(type(west.command) == "string" and west.command or ""))

	local conf_files = disk.conf_files
	if #conf_files == 1 and same_dir(conf_files[1], app.dir .. "/prj.conf") then
		conf_files = {} -- Zephyr's default
	end

	-- Board roots zephyr.nvim adds anyway, or Zephyr finds itself, are not stored.
	local defaults = { [vim.fs.normalize(app.dir)] = true }
	for _, r in ipairs(M.board_roots(app)) do
		defaults[r] = true
	end
	if disk.zephyr_base then
		defaults[vim.fs.normalize(disk.zephyr_base)] = true
	end
	local roots = vim.tbl_filter(function(r)
		return not defaults[vim.fs.normalize(r)]
	end, disk.board_roots)

	-- What the build directory records for the `-D` fields, as absolute paths.
	local recorded = {
		conf_files = conf_files,
		extra_conf_files = info_list(image_info, "kconfig", "extra-user-files") or disk.extra_conf_files,
		overlays = info_list(image_info, "devicetree", "extra-user-files") or disk.overlays,
		board_roots = roots,
	}
	local out = {
		build_dir = settings.relative(app.dir, disk.dir),
		board = board_from_info(top_info) or board_from_info(image_info) or disk.board,
		snippets = #disk.snippets > 0 and vim.deepcopy(disk.snippets) or cmd.snippets,
		sysbuild = disk.sysbuild,
		optimization = cmd.optimization,
		cmake_args = cmd.cmake_args,
	}
	for _, field in ipairs(settings.fields) do
		if field.cmake then
			out[field.name] = settings.relative_list(app, field, recorded[field.name])
		end
	end
	return settings.normalize(out)
end

---Import the build directory `disk` (with no settings yet) into the settings file.
---Fires ZephyrBuildConfigImported (`ev.data`: app, build_dir, name, board).
---@param app zephyr.App
---@param disk zephyr.BuildConfig
---@return zephyr.BuildSettings
function M.import(app, disk)
	local s = M.settings_from_disk(app, disk)
	settings.put(app, s)
	events.emit("BuildConfigImported", { app = app.dir, build_dir = disk.dir, name = disk.name, board = s.board })
	return s
end

---The Build configuration of `app` in `dir`: from its settings, imported from
---the build directory when it has none, or nil when neither exists.
---@param app zephyr.App
---@param dir string
---@return zephyr.BuildConfig|nil
function M.get(app, dir)
	dir = vim.fs.normalize(dir)
	local s = settings.get(app, dir)
	if s then
		return M.from_settings(app, s)
	end
	local disk = M.read(dir)
	if disk and (not disk.app_dir or same_dir(disk.app_dir, app.dir)) then
		return M.from_settings(app, M.import(app, disk), disk)
	end
	return nil
end

---Every Build configuration of `app`: those in the settings file, and build
---directories on disk (imported the first time they are seen).
---@param app zephyr.App
---@return zephyr.BuildConfig[] sorted by name, `build` first
function M.list(app)
	local out, seen = {}, {}
	for _, s in ipairs(settings.list(app)) do
		local cfg = M.from_settings(app, s)
		if not seen[cfg.dir] then
			seen[cfg.dir] = true
			table.insert(out, cfg)
		end
	end
	for _, disk in ipairs(M.scan(app)) do
		if not seen[disk.dir] then
			seen[disk.dir] = true
			table.insert(out, M.from_settings(app, M.import(app, disk), disk))
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

---The active Build configuration of `app`: the one chosen for it if it still
---exists (in the settings or on disk), else the first one found.
---@param app zephyr.App
---@return zephyr.BuildConfig|nil, boolean selected true when chosen explicitly
function M.active(app)
	local chosen = stored(app)
	if chosen and chosen.dir then
		local cfg = M.get(app, chosen.dir)
		if cfg then
			return cfg, true
		end
		-- Chosen with an older zephyr.nvim, before it had settings.
		if chosen.board and not vim.uv.fs_stat(chosen.dir .. "/CMakeCache.txt") then
			local s = settings.normalize({ build_dir = settings.relative(app.dir, chosen.dir), board = chosen.board })
			settings.put(app, s)
			store(app, { dir = chosen.dir })
			return M.from_settings(app, s, false), true
		end
	end
	return M.list(app)[1], false
end

---Make `config` the active Build configuration of `app`.
---@param app zephyr.App
---@param config zephyr.BuildConfig
function M.activate(app, config)
	store(app, { dir = config.dir })
	events.emit("BuildConfigActivated", { app = app.dir, build_dir = config.dir, board = config.board })
end

---Build directory name for a board: `build_<board>` with `/` replaced.
---@param board string e.g. "nrf5340dk/nrf5340/cpuapp"
---@return string e.g. "build_nrf5340dk_nrf5340_cpuapp"
function M.dir_name(board)
	return "build_" .. board:gsub("[/@%s]", "_")
end

---Settings for a new Build configuration: sysbuild on, Zephyr's default conf
---files and optimisation, the default Toolchain.
---@param app zephyr.App
---@param fields? table any zephyr.BuildSettings fields
---@return zephyr.BuildSettings
function M.defaults(app, fields)
	fields = fields or {}
	local s = settings.normalize(fields)
	if not fields.build_dir or fields.build_dir == "" then
		s.build_dir = s.board and M.dir_name(s.board) or "build"
	end
	return s
end

---Create a Build configuration and make it active. It exists on disk once it
---has been built. An existing build directory of that name is imported first,
---and `fields` override what it recorded.
---@param app zephyr.App
---@param fields { board: string, dir?: string } plus any zephyr.BuildSettings fields; `dir` (absolute)
---defaults to `<app>/build_<board>`
---@return zephyr.BuildConfig
function M.new(app, fields)
	fields = vim.deepcopy(fields)
	local dir = fields.dir
		or (fields.build_dir and fields.build_dir ~= "" and settings.absolute(app.dir, fields.build_dir))
		or (app.dir .. "/" .. M.dir_name(fields.board))
	dir = vim.fs.normalize(dir)
	fields.dir = nil
	local existing = M.get(app, dir)
	local s
	if existing then
		s = vim.tbl_extend("force", existing.settings, fields)
	else
		s = M.defaults(app, fields)
	end
	s.build_dir = settings.relative(app.dir, dir)
	settings.put(app, s)
	local cfg = M.from_settings(app, s)
	M.activate(app, cfg)
	return cfg
end

---Optimization levels besides Zephyr's default.
M.optimizations = { "debug", "speed", "size", "none" }

---Problems with settings `s` for `app`, such as a missing file.
---@param app zephyr.App
---@param s zephyr.BuildSettings
---@return string[] errors, empty when valid
function M.validate(app, s)
	local errs = {}
	if type(s.board) ~= "string" or s.board == "" then
		table.insert(errs, "board: a board is required")
	end
	if type(s.build_dir) ~= "string" or s.build_dir == "" or s.build_dir == "." then
		table.insert(errs, "build_dir: a build directory inside or next to the App is required")
	end
	for _, field in ipairs({ "conf_files", "extra_conf_files", "overlays" }) do
		for _, f in ipairs(s[field] or {}) do
			if not vim.uv.fs_stat(settings.absolute(app.dir, f)) then
				table.insert(errs, ("%s: %s does not exist"):format(field, f))
			end
		end
	end
	for _, r in ipairs(s.board_roots or {}) do
		if not fs.is_dir(settings.absolute(settings.root(app), r)) then
			table.insert(errs, ("board_roots: %s is not a directory"):format(r))
		end
	end
	if type(s.sysbuild) ~= "boolean" then
		table.insert(errs, "sysbuild: use true or false")
	end
	if s.optimization ~= nil and not vim.tbl_contains(M.optimizations, s.optimization) then
		table.insert(errs, "optimization: use default, debug, speed, size or none")
	end
	return errs
end

local function same_value(a, b)
	return vim.deep_equal(a, b)
end

---Whether going from settings `old` to `new` needs CMake to configure again.
---@param old zephyr.BuildSettings
---@param new zephyr.BuildSettings
---@return boolean
function M.needs_reconfigure(old, new)
	old, new = settings.normalize(old), settings.normalize(new)
	for _, f in ipairs(settings.fields) do
		if f.reconfigure and not same_value(old[f.name], new[f.name]) then
			return true
		end
	end
	return false
end

---Save edited settings of `app`; `old_dir` is the build directory (absolute)
---they had before, when it changed. Keeps the Build configuration active if it was.
---@param app zephyr.App
---@param s zephyr.BuildSettings
---@param old_dir? string
---@return zephyr.BuildConfig
function M.save(app, s, old_dir)
	s = settings.normalize(s)
	settings.put(app, s, old_dir and settings.relative(app.dir, old_dir) or nil)
	local cfg = M.from_settings(app, s)
	local chosen = stored(app)
	if old_dir and chosen and same_dir(chosen.dir, old_dir) and not same_dir(old_dir, cfg.dir) then
		M.activate(app, cfg)
	end
	return cfg
end

local function set_of(list)
	local out = {}
	for _, v in ipairs(list or {}) do
		out[vim.fs.normalize(v)] = true
	end
	return out
end

local function same_set(a, b)
	return vim.deep_equal(set_of(a), set_of(b))
end

local function show(list)
	return #list > 0 and table.concat(list, ";") or "(none)"
end

---@class zephyr.BuildConfigDifference
---@field field string settings field
---@field settings string the value in the settings
---@field build string the value the build directory was configured with

---Where the build directory of `cfg` was configured differently from its
---settings, for example by a `west build` run by hand. Empty when it was not
---built yet.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
---@return zephyr.BuildConfigDifference[]
function M.differences(app, cfg)
	local disk = cfg.exists and M.read(cfg.dir)
	local s = cfg.settings
	if not disk or not s then
		return {}
	end
	local out = {}
	local function add(field, want, have)
		table.insert(out, { field = field, settings = want, build = have })
	end
	if s.board and disk.board and s.board ~= disk.board then
		add("board", s.board, disk.board)
	end
	if s.sysbuild ~= disk.sysbuild then
		add("sysbuild", tostring(s.sysbuild), tostring(disk.sysbuild))
	end
	for _, field in ipairs(settings.fields) do
		local have = disk[field.name]
		if field.kind == "list" and have then
			local want = settings.absolute_list(app, field, s[field.name])
			local differs
			if field.name == "board_roots" then
				-- The build directory needs every root, also those zephyr.nvim adds itself.
				want = M.board_roots(app, s)
				local recorded = set_of(have)
				differs = #vim.tbl_filter(function(r)
					return not recorded[r]
				end, want) > 0
			elseif field.name == "conf_files" and #want == 0 then
				differs = false -- Zephyr's default
			else
				differs = not same_set(want, have)
			end
			if differs then
				add(field.name, show(want), show(have))
			end
		end
	end
	return out
end

-- A Pristine build asked for "on the next build", per build directory.
local function pristine_state(app)
	return vim.deepcopy(state.get(state_key(app)).pristine_next or {})
end

---Make (or stop making) the next build of `cfg` a Pristine build.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
---@param on boolean
function M.set_pristine_next(app, cfg, on)
	local all = pristine_state(app)
	all[cfg.dir] = on or nil
	state.set(state_key(app), { pristine_next = all })
end

---True when the next build of `cfg` should be a Pristine build.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
function M.pristine_next(app, cfg)
	return pristine_state(app)[cfg.dir] == true
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

---The `west boards` command line listing boards for `app`, with the board roots
---of `s` (or of the active Build configuration).
---@param app zephyr.App
---@param s? zephyr.BuildSettings
---@return string[]
function M.boards_command(app, s)
	local cmd = { "west", "boards", "--format", "{name};{qualifiers}" }
	for _, r in ipairs(M.board_roots(app, s)) do
		vim.list_extend(cmd, { "--board-root", r })
	end
	return cmd
end

---List the boards west knows about, with their qualifiers, custom boards included.
---@param app zephyr.App
---@param on_done fun(boards: string[]|nil, err: string|nil)
---@param s? zephyr.BuildSettings settings whose board roots to search too
function M.boards(app, on_done, s)
	require("zephyr.process").run(M.boards_command(app, s), { cwd = app.dir }, function(res)
		if res.code ~= 0 then
			return on_done(nil, vim.trim((res.stderr or "") ~= "" and res.stderr or res.stdout or "west boards failed"))
		end
		on_done(M.parse_boards(res.stdout or ""))
	end)
end

return M
