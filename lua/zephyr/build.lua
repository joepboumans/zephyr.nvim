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

local function resolve(file, cwd)
	if cwd and not file:match("^/") and not file:match("^%a:[/\\]") then
		return vim.fs.normalize(cwd .. "/" .. file)
	end
	return file
end

---Parse build output into quickfix items: GCC, LD, CMake, Kconfig and devicetree messages.
---@param lines string[]
---@param opts? { cwd?: string, source_dir?: string } relative paths are resolved against `cwd` (the image
---build dir, where Ninja runs), and those in CMake messages against `source_dir` (the App)
---@return vim.quickfix.entry[]
function M.parse(lines, opts)
	opts = opts or {}
	local items, cmake = {}, nil
	local function add(file, lnum, col, kind, text, base)
		table.insert(items, {
			filename = file and resolve(file, base or opts.cwd) or nil,
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
				cmake = add(file, lnum, 0, kind:find("Error") and "E" or "W", "", opts.source_dir)
				goto continue
			end
			kind, file = line:match("^CMake ([%a ]-) in (.-):%s*$")
			if kind then
				cmake = add(file, 0, 0, kind:find("Error") and "E" or "W", "", opts.source_dir)
				goto continue
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
				add(file, lnum, 0, severity[sev], msg)
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
	return items
end

---@class zephyr.BuildOpts
---@field pristine? boolean pass `-p always`
---@field on_output? fun(line: string, stream: "stdout"|"stderr") each output line, as it arrives
---@field on_exit? fun(result: zephyr.BuildResult)

---@class zephyr.BuildResult
---@field ok boolean
---@field code integer
---@field build_dir string
---@field duration number seconds
---@field items vim.quickfix.entry[] errors and warnings parsed from the output
---@field output string[] every output line

---The `west build` command line for `config`.
---@param config zephyr.BuildConfig
---@param opts? { pristine?: boolean }
---@return string[]
function M.command(config, opts)
	local cmd = { "west", "build", "-d", config.dir }
	if config.board and (not config.exists or (opts and opts.pristine)) then
		vim.list_extend(cmd, { "-b", config.board })
	end
	if opts and opts.pristine then
		vim.list_extend(cmd, { "-p", "always" })
	end
	if not config.exists and config.app_dir then
		table.insert(cmd, config.app_dir)
	end
	return cmd
end

local running = {}

---True while a build of `build_dir` is running.
---@param build_dir string
function M.is_running(build_dir)
	return running[build_dir] == true
end

---Build `config` of `app`. Fires ZephyrBuildStarted and ZephyrBuildFinished
---(`ev.data`: build_dir, ok, duration, code, items).
---@param app zephyr.App
---@param config zephyr.BuildConfig
---@param opts? zephyr.BuildOpts
---@return boolean started false when a build of this directory is already running
function M.run(app, config, opts)
	opts = opts or {}
	if running[config.dir] then
		return false
	end
	running[config.dir] = true

	local ws = app.workspace
	if not ws and config.zephyr_base then
		ws = require("zephyr.workspace").find(config.zephyr_base)
	end
	local env = ws and require("zephyr.toolchain").env(ws) or nil
	local cmd = M.command(config, opts)
	local output = {}
	local function on_line(stream)
		return function(line)
			table.insert(output, line)
			if opts.on_output then
				opts.on_output(line, stream)
			end
		end
	end

	local started = vim.uv.hrtime()
	events.emit("BuildStarted", { app = app.dir, build_dir = config.dir, board = config.board, cmd = cmd })
	require("zephyr.process").run(cmd, {
		cwd = app.dir,
		env = env,
		on_stdout = on_line("stdout"),
		on_stderr = on_line("stderr"),
	}, function(res)
		running[config.dir] = nil
		if res.code == -1 and #output == 0 and res.stderr and res.stderr ~= "" then
			on_line("stderr")(res.stderr) -- west could not be started
		end
		-- Ninja runs in the image's build dir, so relative paths are relative to it.
		local image_dir = require("zephyr.build_config").image_dir(config.dir, config.app_dir)
		local result = {
			ok = res.code == 0,
			code = res.code,
			build_dir = config.dir,
			duration = (vim.uv.hrtime() - started) / 1e9,
			items = M.parse(output, { cwd = image_dir, source_dir = config.app_dir or app.dir }),
			output = output,
		}
		events.emit("BuildFinished", {
			app = app.dir,
			build_dir = result.build_dir,
			ok = result.ok,
			code = result.code,
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
