-- Runs `west update` in a Workspace as a Job, streaming its output line by line.
local job = require("zephyr.job")

local M = {}

---@class zephyr.UpdateOpts
---@field projects? string[] names or paths to update; all projects when empty
---@field args? string[] extra `west update` flags, e.g. { "--narrow" }
---@field on_start? fun(info: { cmd: string[] }) right before west starts
---@field on_output? fun(line: string, stream: "stdout"|"stderr") called on the main loop for each line

---@class zephyr.UpdateResult
---@field code integer exit code of west
---@field stopped boolean true when stopped through the returned handle
---@field duration number seconds
---@field output string[] every line, stdout and stderr interleaved
---@field err? string why west update did not start, e.g. another Job of the Workspace runs

---Run `west update` without blocking. Fires `ZephyrUpdateStarted` and `ZephyrUpdateFinished`
---({ workspace, projects, ok, code, stopped, duration }).
---@param workspace zephyr.Workspace
---@param opts? zephyr.UpdateOpts
---@param cb? fun(ok: boolean, result: zephyr.UpdateResult)
---@return { stop: fun() } handle stops west (and what it started); `cb` still runs, with ok false
function M.run(workspace, opts, cb)
	opts = opts or {}
	local cmd = { "west", "update" }
	vim.list_extend(cmd, opts.args or {})
	vim.list_extend(cmd, opts.projects or {})
	local started, err = job.start(workspace.topdir, cmd, {
		cwd = workspace.topdir,
		event = "Update",
		data = { workspace = workspace.topdir, projects = opts.projects or {} },
		on_start = opts.on_start and function()
			opts.on_start({ cmd = cmd })
		end,
		on_output = opts.on_output,
		on_exit = function(result)
			if cb then
				cb(result.ok, result)
			end
		end,
	})
	if not started and cb then
		cb(false, { ok = false, code = -1, stopped = false, duration = 0, output = {}, err = err })
	end
	return {
		stop = function()
			job.stop(workspace.topdir)
		end,
	}
end

return M
