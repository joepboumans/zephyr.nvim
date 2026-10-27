-- Runs `west flash` for a Build configuration in the background with the
-- Active toolchain's environment, on the chosen Probe.
local fs = require("zephyr.fs")

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
	local text = fs.read(path)
	if not text then
		return nil, "no runners.yaml at " .. path
	end
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
---@field on_start? fun(info: { cmd: string[], toolchain: zephyr.ToolchainChoice }) right before west starts
---@field on_output? fun(line: string, stream: "stdout"|"stderr") each output line, as it arrives
---@field on_exit? fun(result: zephyr.FlashResult)

---@class zephyr.FlashResult
---@field app string
---@field ok boolean
---@field code integer
---@field stopped boolean true when stopped with flash.stop()
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

---True while a Job (a flash or a build) of `build_dir` is running.
---@param build_dir string
function M.is_running(build_dir)
	return require("zephyr.job").is_running(build_dir)
end

---Stop the running flash of `build_dir`. Its ZephyrFlashFinished still fires, with `ok = false`.
---@param build_dir string
---@return boolean stopped false when no flash of it was running
function M.stop(build_dir)
	return require("zephyr.job").stop(build_dir)
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
	if not config.exists then
		return false, config.name .. " has not been built yet"
	end
	local ws = workspace_of(app, config)
	local probe = opts.probe
	if not probe then
		probe = require("zephyr.probes").active(ws or { topdir = app.dir })
	end
	local runner = opts.runner or M.default_runner(config)
	local env, err, choice = require("zephyr.toolchain").env(app, config)
	if err then
		return false, err
	end
	local cmd = M.command(config, { runner = opts.runner, probe = probe, erase = opts.erase })
	return require("zephyr.job").start(config.dir, cmd, {
		cwd = app.dir,
		env = env,
		event = "Flash",
		data = { app = app.dir, build_dir = config.dir, runner = runner, probe = probe },
		on_start = opts.on_start and function()
			opts.on_start({ cmd = cmd, toolchain = choice })
		end,
		on_output = opts.on_output,
		on_exit = opts.on_exit,
	})
end

return M
