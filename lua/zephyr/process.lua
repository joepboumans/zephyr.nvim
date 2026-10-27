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
---@field group? boolean run in its own process group, so kill() also stops what it started
---(west's cmake and ninja); such commands are stopped when Neovim exits

-- Process groups started with `group = true` that are still running.
local groups = {}

local function kill_group(proc)
	if proc.pid then
		local ok, res = pcall(vim.uv.kill, -proc.pid, "sigterm")
		if ok and res == 0 then
			return
		end
	end
	pcall(proc.kill, proc, "sigterm")
end

---Stop a process started by run(): its whole process group when it has one.
---@param proc vim.SystemObj|nil
function M.kill(proc)
	if not proc then
		return
	end
	if groups[proc] then
		kill_group(proc)
	else
		pcall(proc.kill, proc, "sigterm")
	end
end

local function watch_exit()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("zephyr_process_groups", { clear = true }),
		callback = function()
			for proc in pairs(groups) do
				kill_group(proc)
			end
		end,
	})
end

---Run a command without blocking; `on_exit` gets the vim.SystemCompleted result
---on the main loop. With `on_stdout`/`on_stderr` the output is also streamed
---line by line; `res.stdout`/`res.stderr` still hold the whole output.
---@param cmd string[]
---@param opts? zephyr.ProcessOpts passed to vim.system
---@param on_exit fun(res: vim.SystemCompleted)
---@return vim.SystemObj|nil proc nil when the command could not be started
function M.run(cmd, opts, on_exit)
	opts = vim.tbl_extend("force", { text = true }, opts or {})
	local group = opts.group
	opts.group = nil
	if group then
		opts.detach = true
	end
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

	local proc_ref
	local ok, proc = pcall(vim.system, cmd, opts, function(res)
		if proc_ref then
			vim.schedule(function()
				groups[proc_ref] = nil
			end)
		end
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
	if group then
		if next(groups) == nil then
			watch_exit()
		end
		groups[proc] = true
		proc_ref = proc
	end
	return proc
end

---Start `cmd` as a terminal job in the current buffer (`jobstart` with `term` on 0.11+, `termopen` on 0.10).
---@param cmd string[]
---@param opts table jobstart options (cwd, env, on_exit, ...)
---@return integer job id, 0 or -1 when it could not be started
function M.term(cmd, opts)
	if vim.fn.has("nvim-0.11") == 1 then
		return vim.fn.jobstart(cmd, vim.tbl_extend("force", opts, { term = true }))
	end
	return vim.fn.termopen(cmd, opts)
end

return M
