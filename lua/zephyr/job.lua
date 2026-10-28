-- A Job: one west command (build, flash, update) running in the background for a
-- directory, with streamed output, a stop, and Started/Finished events.
local events = require("zephyr.events")
local process = require("zephyr.process")

local M = {}

---@class zephyr.JobOpts
---@field cwd? string
---@field env? table<string, string>
---@field event string fires `Zephyr<event>Started` (with `cmd`) and `Zephyr<event>Finished`
---@field data? table merged into both events' `ev.data` and into the result
---@field finish? fun(result: zephyr.JobResult): table|nil extra fields for the result and the Finished event
---@field on_start? fun() right before the command starts
---@field on_output? fun(line: string, stream: "stdout"|"stderr") each output line, as it arrives
---@field on_exit? fun(result: zephyr.JobResult)

---@class zephyr.JobResult
---@field ok boolean
---@field code integer
---@field stopped boolean true when stopped with job.stop()
---@field duration number seconds
---@field output string[] every output line

-- What each event's Job is doing, for the "busy" error.
local doing = { Build = "building", Flash = "flashing", Update = "updating" }

-- The running Job of each directory.
local running = {}

---True while a Job runs for `dir`.
---@param dir string
function M.is_running(dir)
	return running[dir] ~= nil
end

---Stop the Job of `dir`. Its on_exit and Finished event still come, with `stopped = true`.
---@param dir string
---@return boolean stopped false when no Job of it was running
function M.stop(dir)
	local job = running[dir]
	if not job then
		return false
	end
	job.stopped = true
	process.kill(job.proc)
	return true
end

---Start `cmd` for `dir`: a build directory (build, flash) or a Workspace topdir (update).
---One Job per directory runs at a time.
---@param dir string
---@param cmd string[]
---@param opts zephyr.JobOpts
---@return boolean started, string|nil err
function M.start(dir, cmd, opts)
	local busy = running[dir]
	if busy then
		return false, ("%s is busy (%s)"):format(vim.fs.basename(dir), doing[busy.event] or busy.event)
	end
	local job = { event = opts.event }
	running[dir] = job
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
		opts.on_start()
	end
	local data = opts.data or {}
	local started = vim.uv.hrtime()
	events.emit(opts.event .. "Started", vim.tbl_extend("force", data, { cmd = cmd }))
	job.proc = process.run(cmd, {
		cwd = opts.cwd,
		env = opts.env,
		group = true,
		on_stdout = on_line("stdout"),
		on_stderr = on_line("stderr"),
	}, function(res)
		running[dir] = nil
		if res.code == -1 and #output == 0 and res.stderr and res.stderr ~= "" then
			on_line("stderr")(res.stderr) -- the command could not be started
		end
		local result = vim.tbl_extend("force", data, {
			ok = res.code == 0 and (res.signal or 0) == 0 and not job.stopped,
			code = res.code,
			stopped = job.stopped == true,
			duration = (vim.uv.hrtime() - started) / 1e9,
			output = output,
		})
		result = vim.tbl_extend("force", result, opts.finish and opts.finish(result) or {})
		local finished = vim.tbl_extend("force", {}, result)
		finished.output = nil
		events.emit(opts.event .. "Finished", finished)
		if opts.on_exit then
			opts.on_exit(result)
		end
	end)
	return true
end

return M
