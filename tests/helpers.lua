-- Shared test helpers, loaded with dofile("tests/helpers.lua").
local M = {}

M.fixtures = vim.fn.fnamemodify("tests/fixtures", ":p"):gsub("/$", "")

---Copy a fixture tree to a fresh temp dir, replacing `@APP@` with the copy's path.
---@param name string path under tests/fixtures
---@return string the copy's absolute path
function M.copy_fixture(name)
	local src = M.fixtures .. "/" .. name
	local dst = vim.fs.normalize(vim.fn.tempname() .. "/" .. vim.fs.basename(name))
	for path, type in vim.fs.dir(src, { depth = 10 }) do
		local target = dst .. "/" .. path
		if type == "directory" then
			vim.fn.mkdir(target, "p")
		else
			vim.fn.mkdir(vim.fs.dirname(target), "p")
			local text = table.concat(vim.fn.readfile(src .. "/" .. path, "b"), "\n")
			vim.fn.writefile(vim.split(text:gsub("@APP@", dst), "\n", { plain = true }), target, "b")
		end
	end
	return dst
end

---Lines of a recorded output file under tests/fixtures/output.
function M.output(name)
	return vim.fn.readfile(M.fixtures .. "/output/" .. name)
end

---Replace zephyr.process.run; calls are recorded in the returned table.
---`respond(call)` returns { code, stdout_lines?, stderr_lines?, stdout? }.
function M.stub_process(respond)
	local process = require("zephyr.process")
	local saved = process.run
	local calls = {}
	process.run = function(cmd, opts, on_exit)
		local call = { cmd = cmd, opts = opts or {} }
		table.insert(calls, call)
		local r = respond and respond(call) or {}
		for _, line in ipairs(r.stdout_lines or {}) do
			if call.opts.on_stdout then
				call.opts.on_stdout(line)
			end
		end
		for _, line in ipairs(r.stderr_lines or {}) do
			if call.opts.on_stderr then
				call.opts.on_stderr(line)
			end
		end
		on_exit({ code = r.code or 0, signal = 0, stdout = r.stdout or "", stderr = r.stderr or "" })
	end
	calls.restore = function()
		process.run = saved
	end
	return calls
end

---Point zephyr.state at a fresh file; returns a function restoring it.
function M.temp_state()
	local state = require("zephyr.state")
	local saved = state.path
	state.path = vim.fn.tempname() .. "/state.json"
	return function()
		state.path = saved
	end
end

return M
