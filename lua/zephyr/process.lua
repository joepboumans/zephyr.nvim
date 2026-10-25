-- One place where components start external commands, so tests can stub it.
local M = {}

---Turn a stream of chunks into whole lines; `flush` emits a trailing partial line.
local function line_splitter(on_line)
	local pending = ""
	local function feed(data)
		pending = pending .. data
		while true do
			local nl = pending:find("\n", 1, true)
			if not nl then
				break
			end
			on_line((pending:sub(1, nl - 1):gsub("\r$", "")))
			pending = pending:sub(nl + 1)
		end
	end
	local function flush()
		if pending ~= "" then
			on_line((pending:gsub("\r$", "")))
			pending = ""
		end
	end
	return feed, flush
end

---@class zephyr.ProcessOpts: vim.SystemOpts
---@field on_stdout? fun(line: string) called on the main loop for each stdout line
---@field on_stderr? fun(line: string) called on the main loop for each stderr line

---Run a command without blocking; `on_exit` gets the vim.SystemCompleted result
---on the main loop. With `on_stdout`/`on_stderr` the output is also streamed
---line by line; `res.stdout`/`res.stderr` still hold the whole output.
---@param cmd string[]
---@param opts? zephyr.ProcessOpts passed to vim.system
---@param on_exit fun(res: vim.SystemCompleted)
---@return vim.SystemObj|nil proc nil when the command could not be started
function M.run(cmd, opts, on_exit)
	opts = vim.tbl_extend("force", { text = true }, opts or {})
	local streams, flushers = {}, {}
	for _, name in ipairs({ "stdout", "stderr" }) do
		local on_line = opts["on_" .. name]
		opts["on_" .. name] = nil
		if on_line then
			local chunks = {}
			streams[name] = chunks
			local feed, flush = line_splitter(function(line)
				vim.schedule(function()
					on_line(line)
				end)
			end)
			table.insert(flushers, flush)
			opts[name] = function(_, data)
				if data then
					table.insert(chunks, data)
					feed(data)
				end
			end
		end
	end

	local ok, proc = pcall(vim.system, cmd, opts, function(res)
		for _, flush in ipairs(flushers) do
			flush()
		end
		for name, chunks in pairs(streams) do
			res[name] = table.concat(chunks)
		end
		vim.schedule(function()
			on_exit(res)
		end)
	end)
	if not ok then
		vim.schedule(function()
			on_exit({ code = -1, signal = 0, stdout = "", stderr = tostring(proc) })
		end)
		return nil
	end
	return proc
end

return M
