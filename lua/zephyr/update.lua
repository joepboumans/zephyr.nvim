-- Runs `west update` in a Workspace, streaming its output line by line.
local process = require("zephyr.process")
local events = require("zephyr.events")

local M = {}

---@class zephyr.UpdateOpts
---@field projects? string[] names or paths to update; all projects when empty
---@field args? string[] extra `west update` flags, e.g. { "--narrow" }
---@field on_output? fun(line: string, stream: "stdout"|"stderr") called on the main loop for each line

---@class zephyr.UpdateResult
---@field code integer exit code of west
---@field output string[] every line, stdout and stderr interleaved

---Turn chunks from vim.system into whole lines.
local function line_splitter(stream, on_line)
	local partial = ""
	return function(data, flush)
		local text = partial .. (data or "")
		local lines = vim.split(text, "\n", { plain = true })
		local rest = table.remove(lines) -- text after the last newline
		partial = flush and "" or rest
		if flush and rest ~= "" then
			table.insert(lines, rest)
		end
		for _, line in ipairs(lines) do
			on_line((line:gsub("\r$", "")), stream)
		end
	end
end

---Run `west update` without blocking. Fires `ZephyrUpdateFinished`
---({ workspace, projects, ok, code }).
---@param workspace zephyr.Workspace
---@param opts? zephyr.UpdateOpts
---@param cb? fun(ok: boolean, result: zephyr.UpdateResult)
function M.run(workspace, opts, cb)
	opts = opts or {}
	local cmd = { "west", "update" }
	vim.list_extend(cmd, opts.args or {})
	vim.list_extend(cmd, opts.projects or {})

	local output = {}
	local function on_line(line, stream)
		table.insert(output, line)
		if opts.on_output then
			opts.on_output(line, stream)
		end
	end
	local splitters = { stdout = line_splitter("stdout", on_line), stderr = line_splitter("stderr", on_line) }
	-- vim.system calls these off the main loop; hop back before touching anything.
	local function reader(stream)
		return function(_, data)
			if data then
				vim.schedule(function()
					splitters[stream](data, false)
				end)
			end
		end
	end

	process.run(cmd, { cwd = workspace.topdir, stdout = reader("stdout"), stderr = reader("stderr") }, function(res)
		-- Text in res means it was not streamed (e.g. west could not be started).
		splitters.stdout(type(res.stdout) == "string" and res.stdout or nil, true)
		splitters.stderr(type(res.stderr) == "string" and res.stderr or nil, true)
		local ok = res.code == 0
		events.emit("UpdateFinished", {
			workspace = workspace.topdir,
			projects = opts.projects or {},
			ok = ok,
			code = res.code,
		})
		if cb then
			cb(ok, { code = res.code, output = output })
		end
	end)
end

return M
