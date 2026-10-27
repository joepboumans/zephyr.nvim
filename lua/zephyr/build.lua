-- Runs `west build` for a Build configuration in the background with the
-- Active toolchain's environment, and turns its output into quickfix items.
local events = require("zephyr.events")

local M = {}

---Strip ANSI colour codes (Zephyr builds with -fdiagnostics-color=always).
---@param line string
---@return string
function M.strip_ansi(line)
	return (line:gsub("\27%[[%d;]*[mK]", ""):gsub("\r$", ""))
end

local severity = { ["fatal error"] = "E", error = "E", warning = "W", note = "N" }

local function is_absolute(file)
	return file:match("^/") or file:match("^%a:[/\\]")
end

local function resolve(file, cwd)
	if cwd and not is_absolute(file) then
		return vim.fs.normalize(cwd .. "/" .. file)
	end
	return file
end

-- A relative path in a CMake message: relative to the App, or (for sysbuild's
-- `cmake/modules/...`) to Zephyr's `share/sysbuild` or Zephyr itself.
local function resolve_cmake(file, opts)
	if is_absolute(file) then
		return file
	end
	local zb = opts.zephyr_base
	local candidates = { opts.source_dir }
	if zb then
		vim.list_extend(candidates, { zb .. "/share/sysbuild", zb })
	end
	for _, base in ipairs(candidates) do
		local path = vim.fs.normalize(base .. "/" .. file)
		if vim.uv.fs_stat(path) then
			return path
		end
	end
	if zb and file:match("^cmake/") then
		local base = vim.fs.basename(file):match("^sysbuild") and (zb .. "/share/sysbuild") or zb
		return vim.fs.normalize(base .. "/" .. file)
	end
	return resolve(file, opts.source_dir or opts.cwd)
end

---Parse build output into quickfix items: GCC, LD, CMake, Kconfig and devicetree messages.
---When CMake configure failed on Kconfig or in sysbuild, the reason comes first:
---the Kconfig messages (also those without a file), then the failing sysbuild image.
---@param lines string[]
---@param opts? { cwd?: string, source_dir?: string, zephyr_base?: string } relative paths are resolved
---against `cwd` (the image build dir, where Ninja runs), and those in CMake messages against `source_dir`
---(the App) or, for Zephyr's own CMake modules, `zephyr_base`
---@return vim.quickfix.entry[]
function M.parse(lines, opts)
	opts = opts or {}
	local items, cmake = {}, nil
	local kconfig_items, in_kconfig = {}, false
	local function add(file, lnum, col, kind, text, base)
		local filename
		if file then
			filename = base == "cmake" and resolve_cmake(file, opts) or resolve(file, base or opts.cwd)
		end
		table.insert(items, {
			filename = filename,
			lnum = tonumber(lnum) or 0,
			col = tonumber(col) or 0,
			type = kind,
			text = text,
		})
		return items[#items]
	end
	for _, raw in ipairs(lines) do
		local line = M.strip_ansi(raw)
		if cmake then
			-- CMake messages continue on lines indented by two spaces, up to a blank line.
			local more = line:match("^  (.*)$")
			if more and not line:match("^Call Stack") then
				local text = vim.trim(more)
				if text ~= "" then
					cmake.text = cmake.text == "" and text or (cmake.text .. " " .. text)
				end
				goto continue
			end
			cmake = nil
		end
		do
			local kind, file, lnum, msg
			-- CMake Error at /abs/file.cmake:12 (message):
			kind, file, lnum = line:match("^CMake ([%a ]-) at (.-):(%d+) %([%w_]+%):%s*$")
			if kind then
				in_kconfig = false
				cmake = add(file, lnum, 0, kind:find("Error") and "E" or "W", "", "cmake")
				goto continue
			end
			kind, file = line:match("^CMake ([%a ]-) in (.-):%s*$")
			if kind then
				in_kconfig = false
				cmake = add(file, 0, 0, kind:find("Error") and "E" or "W", "", "cmake")
				goto continue
			end
			-- Kconfig prints "Parsing <Kconfig>" before its own messages.
			if line:match("^Parsing .*Kconfig%s*$") then
				in_kconfig = true
				goto continue
			end
			if line:match("^%-%- ") then
				in_kconfig = false
			end
			if line:match("^error: Aborting due to Kconfig warnings") then
				goto continue
			end
			if in_kconfig then
				local ksev, kmsg = line:match("^(%a+): (.*)$")
				if ksev == "warning" or ksev == "error" then
					kconfig_items[add(nil, 0, 0, severity[ksev], kmsg)] = true
					goto continue
				end
			end
			msg = line:match("^CMake Error: (.*)$")
			if msg then
				add(nil, 0, 0, "E", msg)
				goto continue
			end
			-- devicetree error: /abs/app.overlay:12 (column 5): parse error: ...
			local col
			file, lnum, col, msg = line:match("^devicetree error: (.-):(%d+) %(column (%d+)%): (.*)$")
			if file then
				add(file, lnum, col, "E", msg)
				goto continue
			end
			msg = line:match("^devicetree error: (.*)$")
			if msg then
				add(nil, 0, 0, "E", msg)
				goto continue
			end
			-- GCC: file:line:col: error: msg
			local sev
			file, lnum, col, sev, msg = line:match("^(.-):(%d+):(%d+): (%a[%a ]-): (.*)$")
			if file and severity[sev] then
				add(file, lnum, col, severity[sev], msg)
				goto continue
			end
			-- Kconfig: /abs/prj.conf:3: warning: msg
			file, lnum, sev, msg = line:match("^(.-):(%d+): (%a[%a ]-): (.*)$")
			if file and severity[sev] then
				local item = add(file, lnum, 0, severity[sev], msg)
				if in_kconfig or file:match("%.conf$") or file:match("Kconfig[^/]*$") then
					kconfig_items[item] = true
				end
				goto continue
			end
			-- LD with debug info: /abs/b.c:2:(.text+0x9): undefined reference to `ext'
			file, lnum, msg = line:match("^(.-):(%d+):%([^)]*%): (.*)$")
			if file then
				add(file, lnum, 0, "E", msg)
				goto continue
			end
			-- LD without debug info: b.c:(.text+0x9): undefined reference to `ext'
			file, msg = line:match("^([^%s:]+):%([^)]*%): (.*)$")
			if file then
				add(file, 0, 0, "E", msg)
				goto continue
			end
			-- LD memory region errors, which have no source location.
			msg = line:match("^%S*ld%S*: (.*overflowed by.*)$")
				or line:match("^%S*ld%S*: (.*will not fit in region.*)$")
			if msg then
				add(nil, 0, 0, "E", msg)
			end
		end
		::continue::
	end
	return M.reason_first(items, kconfig_items)
end

---When configure failed on Kconfig or in sysbuild, move the reason to the front:
---Kconfig messages, then the failing sysbuild image, then Kconfig's CMake error
---(with the Kconfig message as its text), then everything else.
---@param items vim.quickfix.entry[]
---@param kconfig table<vim.quickfix.entry, true>
---@return vim.quickfix.entry[]
function M.reason_first(items, kconfig)
	local kconfig_failed, sysbuild = {}, {}
	for _, item in ipairs(items) do
		if item.type == "E" and item.filename and item.filename:match("/kconfig%.cmake$") then
			kconfig_failed[item] = true
		elseif item.type == "E" and item.text:match("^CMake configure failed for Zephyr project") then
			sysbuild[item] = true
		end
	end
	if next(kconfig_failed) == nil and next(sysbuild) == nil then
		return items
	end
	local first_kconfig
	for _, item in ipairs(items) do
		if kconfig[item] and (not first_kconfig or (item.type == "E" and first_kconfig.type ~= "E")) then
			first_kconfig = item
		end
	end
	if next(kconfig_failed) ~= nil then
		-- Kconfig aborted on them, so its warnings are the errors.
		for item in pairs(kconfig) do
			item.type = "E"
		end
	end
	for item in pairs(kconfig_failed) do
		item.text = first_kconfig and ("Kconfig failed: " .. first_kconfig.text)
			or ("Kconfig failed (" .. item.text .. "); see the Output window")
	end
	local out = {}
	for _, group in ipairs({ kconfig, sysbuild, kconfig_failed }) do
		for _, item in ipairs(items) do
			if group[item] then
				table.insert(out, item)
			end
		end
	end
	for _, item in ipairs(items) do
		if not (kconfig[item] or sysbuild[item] or kconfig_failed[item]) then
			table.insert(out, item)
		end
	end
	return out
end

---@class zephyr.BuildOpts
---@field pristine? boolean pass `-p always`
---@field reconfigure? boolean configure with every setting even when the build directory exists
---@field on_start? fun(info: { cmd: string[], toolchain: zephyr.ToolchainChoice, pristine: boolean }) right before west starts
---@field on_output? fun(line: string, stream: "stdout"|"stderr") each output line, as it arrives
---@field on_exit? fun(result: zephyr.BuildResult)

---@class zephyr.BuildResult
---@field ok boolean
---@field code integer
---@field stopped boolean true when stopped with build.stop()
---@field build_dir string
---@field duration number seconds
---@field items vim.quickfix.entry[] errors and warnings parsed from the output
---@field output string[] every output line
---@field toolchain zephyr.Toolchain|nil

---True when building `config` configures CMake: it was not built yet, or a
---Pristine build or a reconfigure was asked for.
---@param config zephyr.BuildConfig
---@param opts? { pristine?: boolean, reconfigure?: boolean }
function M.configures(config, opts)
	opts = opts or {}
	return not config.exists or opts.pristine == true or opts.reconfigure == true
end

local function join(list)
	return table.concat(list, ";")
end

---The `west build` command line for `config`. A build that configures passes
---every setting of the Build configuration, so a Pristine build recreates the
---build directory exactly; an incremental build lets west reuse the cache.
---@param config zephyr.BuildConfig
---@param opts? { pristine?: boolean, reconfigure?: boolean, app?: zephyr.App }
---@return string[]
function M.command(config, opts)
	opts = opts or {}
	local cmd = { "west", "build", "-d", config.dir }
	local s = config.settings
	if not s then
		-- A build directory without settings: only what west needs.
		if config.board and M.configures(config, opts) then
			vim.list_extend(cmd, { "-b", config.board })
		end
		if opts.pristine then
			vim.list_extend(cmd, { "-p", "always" })
		end
		if not config.exists and config.app_dir then
			table.insert(cmd, config.app_dir)
		end
		return cmd
	end
	if not M.configures(config, opts) then
		return cmd
	end
	local settings = require("zephyr.settings")
	local build_config = require("zephyr.build_config")
	local app = opts.app or require("zephyr.app").from_dir(config.app_dir)
	local function abs(list)
		return vim.tbl_map(function(p)
			return settings.absolute(app.dir, p)
		end, list)
	end
	vim.list_extend(cmd, { "-b", s.board or config.board })
	if opts.pristine then
		vim.list_extend(cmd, { "-p", "always" })
	end
	table.insert(cmd, s.sysbuild and "--sysbuild" or "--no-sysbuild")
	for _, snippet in ipairs(s.snippets) do
		vim.list_extend(cmd, { "-S", snippet })
	end
	table.insert(cmd, app.dir)
	local cmake = {}
	if #s.conf_files > 0 then
		table.insert(cmake, "-DCONF_FILE=" .. join(abs(s.conf_files)))
	end
	if #s.extra_conf_files > 0 then
		table.insert(cmake, "-DEXTRA_CONF_FILE=" .. join(abs(s.extra_conf_files)))
	end
	if #s.overlays > 0 then
		table.insert(cmake, "-DEXTRA_DTC_OVERLAY_FILE=" .. join(abs(s.overlays)))
	end
	local roots = build_config.board_roots(app, s)
	if #roots > 0 then
		table.insert(cmake, "-DBOARD_ROOT=" .. join(roots))
	end
	local symbol = s.optimization and build_config.optimization_symbols[s.optimization]
	if symbol then
		table.insert(cmake, "-D" .. symbol .. "=y")
	end
	vim.list_extend(cmake, s.cmake_args)
	if #cmake > 0 then
		table.insert(cmd, "--")
		vim.list_extend(cmd, cmake)
	end
	return cmd
end

local running = {}

---True while a build of `build_dir` is running.
---@param build_dir string
function M.is_running(build_dir)
	return running[build_dir] ~= nil
end

---Stop the running build of `build_dir`. Its ZephyrBuildFinished still fires, with `ok = false`.
---@param build_dir string
---@return boolean stopped false when no build of it was running
function M.stop(build_dir)
	local r = running[build_dir]
	if not r then
		return false
	end
	r.stopped = true
	require("zephyr.process").kill(r.proc)
	return true
end

---Build `config` of `app` with its Active toolchain's environment. Fires
---ZephyrBuildStarted and ZephyrBuildFinished (`ev.data`: build_dir, ok,
---duration, code, items). A Pristine build asked for "on the next build"
---happens now. The App becomes its Workspace's Active app.
---@param app zephyr.App
---@param config zephyr.BuildConfig
---@param opts? zephyr.BuildOpts
---@return boolean started, string|nil err why it did not start
function M.run(app, config, opts)
	opts = opts or {}
	if running[config.dir] then
		return false, config.name .. " is already building"
	end
	local build_config = require("zephyr.build_config")
	local env, err, choice = require("zephyr.toolchain").env(app, config)
	if err then
		return false, err
	end
	local pristine = opts.pristine or build_config.pristine_next(app, config)
	local cmd = M.command(config, { pristine = pristine, reconfigure = opts.reconfigure, app = app })
	local r = {}
	running[config.dir] = r
	if pristine then
		build_config.set_pristine_next(app, config, false)
	end
	if app.workspace then
		require("zephyr.app").activate(app.workspace, app)
	end

	local output = {}
	local function on_line(stream)
		return function(line)
			table.insert(output, line)
			if opts.on_output then
				opts.on_output(line, stream)
			end
		end
	end

	if opts.on_start then
		opts.on_start({ cmd = cmd, toolchain = choice, pristine = pristine == true })
	end
	local started = vim.uv.hrtime()
	events.emit("BuildStarted", {
		app = app.dir,
		build_dir = config.dir,
		board = config.board,
		cmd = cmd,
		toolchain = choice.toolchain,
	})
	r.proc = require("zephyr.process").run(cmd, {
		cwd = app.dir,
		env = env,
		group = true,
		on_stdout = on_line("stdout"),
		on_stderr = on_line("stderr"),
	}, function(res)
		running[config.dir] = nil
		if res.code == -1 and #output == 0 and res.stderr and res.stderr ~= "" then
			on_line("stderr")(res.stderr) -- west could not be started
		end
		-- Ninja runs in the image's build dir, so relative paths are relative to it.
		local image_dir = build_config.image_dir(config.dir, config.app_dir)
		local zephyr_base = config.zephyr_base or (app.workspace and app.workspace.zephyr_base)
		local result = {
			ok = res.code == 0 and (res.signal or 0) == 0 and not r.stopped,
			code = res.code,
			stopped = r.stopped == true,
			build_dir = config.dir,
			duration = (vim.uv.hrtime() - started) / 1e9,
			items = M.parse(output, { cwd = image_dir, source_dir = config.app_dir or app.dir, zephyr_base = zephyr_base }),
			output = output,
			toolchain = choice.toolchain,
		}
		events.emit("BuildFinished", {
			app = app.dir,
			build_dir = result.build_dir,
			ok = result.ok,
			code = result.code,
			stopped = result.stopped,
			duration = result.duration,
			items = result.items,
		})
		if opts.on_exit then
			opts.on_exit(result)
		end
	end)
	return true
end

return M
