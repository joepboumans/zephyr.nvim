-- Runs `west flash` for a Build configuration in the background with the
-- Active toolchain's environment, on the chosen Probe.
local events = require("zephyr.events")

local M = {}

---Parse the keys of runners.yaml that flashing needs.
---@param text string
---@return { runners: string[], flash_runner: string|nil, debug_runner: string|nil }
function M.parse_runners(text)
	local out, section = { runners = {} }, nil
	local function scalar(v)
		v = vim.trim((v:gsub("%s+#.*$", "")))
		return (v:match('^"(.*)"$') or v:match("^'(.*)'$") or v)
	end
	for line in vim.gsplit(text or "", "\n", { plain = true }) do
		line = line:gsub("\r$", "")
		local key, value = line:match("^([%w_-]+):%s*(.-)%s*$")
		if key then
			section = key
			if key == "flash-runner" and value ~= "" then
				out.flash_runner = scalar(value)
			elseif key == "debug-runner" and value ~= "" then
				out.debug_runner = scalar(value)
			end
		elseif section == "runners" then
			local item = line:match("^%s*%-%s*(.-)%s*$")
			if item and item ~= "" then
				table.insert(out.runners, scalar(item))
			end
		end
	end
	return out
end

---runners.yaml of the App's own image in `config`.
---@param config zephyr.BuildConfig
---@return string
function M.runners_file(config)
	return (config.image_dir or config.dir) .. "/zephyr/runners.yaml"
end

---The flash runner west uses by default for `config`, from its runners.yaml.
---@param config zephyr.BuildConfig
---@return string|nil runner, string|nil err
function M.default_runner(config)
	local path = M.runners_file(config)
	local fd = io.open(path, "r")
	if not fd then
		return nil, "no runners.yaml at " .. path
	end
	local text = fd:read("*a")
	fd:close()
	local runner = M.parse_runners(text).flash_runner
	if not runner then
		return nil, "no flash-runner in " .. path
	end
	return runner
end

---@class zephyr.FlashOpts
---@field runner? string flash with this runner (`-r`) instead of the flash-runner in runners.yaml
---@field probe? zephyr.Probe flash through this Probe (`--dev-id`); defaults to the Workspace's active Probe
---@field erase? boolean mass erase before flashing (`--erase`)
---@field on_output? fun(line: string, stream: "stdout"|"stderr") each output line, as it arrives
---@field on_exit? fun(result: zephyr.FlashResult)

---@class zephyr.FlashResult
---@field app string
---@field ok boolean
---@field code integer
---@field build_dir string
---@field runner string|nil
---@field probe zephyr.Probe|nil
---@field duration number seconds
---@field output string[] every output line

---The `west flash` command line for `config`.
---@param config zephyr.BuildConfig
---@param opts? { runner?: string, probe?: zephyr.Probe, erase?: boolean }
---@return string[]
function M.command(config, opts)
	opts = opts or {}
	local cmd = { "west", "flash", "-d", config.dir }
	if opts.runner then
		vim.list_extend(cmd, { "-r", opts.runner })
	end
	if opts.probe and opts.probe.serial then
		vim.list_extend(cmd, { "--dev-id", opts.probe.serial })
	end
	if opts.erase then
		table.insert(cmd, "--erase")
	end
	return cmd
end

local running = {}

---True while a flash of `build_dir` is running.
---@param build_dir string
function M.is_running(build_dir)
	return running[build_dir] == true
end

local function workspace_of(app, config)
	local ws = app.workspace
	if not ws and config.zephyr_base then
		ws = require("zephyr.workspace").find(config.zephyr_base)
	end
	return ws
end

---Flash `config` of `app`. Without `opts.runner`, west uses the flash-runner
---from runners.yaml (reported as `runner`). Fires ZephyrFlashStarted and
---ZephyrFlashFinished (`ev.data`: app, build_dir, runner, probe, ok, code, duration).
---@param app zephyr.App
---@param config zephyr.BuildConfig
---@param opts? zephyr.FlashOpts
---@return boolean started, string|nil err why it did not start
function M.run(app, config, opts)
	opts = opts or {}
	if running[config.dir] then
		return false, "already flashing " .. config.name
	end
	if not config.exists then
		return false, config.name .. " has not been built yet"
	end
	local ws = workspace_of(app, config)
	local probe = opts.probe
	if not probe then
		probe = require("zephyr.probes").active(ws or { topdir = app.dir })
	end
	local runner = opts.runner or M.default_runner(config)
	running[config.dir] = true

	local env = ws and require("zephyr.toolchain").env(ws) or nil
	local cmd = M.command(config, { runner = opts.runner, probe = probe, erase = opts.erase })
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
	local info = { app = app.dir, build_dir = config.dir, runner = runner, probe = probe }
	events.emit("FlashStarted", vim.tbl_extend("force", info, { cmd = cmd }))
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
		local result = vim.tbl_extend("force", info, {
			ok = res.code == 0,
			code = res.code,
			duration = (vim.uv.hrtime() - started) / 1e9,
		})
		events.emit("FlashFinished", result)
		result.output = output
		if opts.on_exit then
			opts.on_exit(result)
		end
	end)
	return true
end

return M
