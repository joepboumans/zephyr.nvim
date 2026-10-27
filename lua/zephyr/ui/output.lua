-- The Output window of the default UI: one `zephyr://output` scratch buffer
-- that build, flash and update stream into, shown in a bottom split and reused
-- between runs. Only `q` closes it: while a command runs, `q` stops the command
-- and closes the window; once it has finished, `q` just closes the window.
-- Every other key works as usual, so the output can be scrolled and searched.
local M = {}

M.NAME = "zephyr://output"
M.height = 12

local buf
local stopper -- stops the running command, while there is one

local function close_windows()
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if not pcall(vim.api.nvim_win_close, win, true) then
			-- The last window: show another buffer in it instead.
			vim.api.nvim_win_call(win, function()
				local alt = vim.fn.bufnr("#")
				if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) then
					vim.api.nvim_win_set_buf(win, alt)
				else
					vim.cmd("enew")
				end
			end)
		end
	end
end

---Close the Output window, first stopping the command still running in it.
function M.close()
	if stopper then
		local stop = stopper
		stopper = nil
		pcall(stop)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		close_windows()
	end
end

---True while a command started with open() has not finished.
function M.is_running()
	return stopper ~= nil
end

local function ensure_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	pcall(vim.api.nvim_buf_set_name, buf, M.NAME)
	vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, desc = "zephyr: stop the command and close" })
	return buf
end

---Show the Output window (if it is hidden) without changing the current window.
---@return integer buf
function M.show()
	local b = ensure_buf()
	if vim.fn.bufwinid(b) == -1 then
		local current = vim.api.nvim_get_current_win()
		vim.cmd("botright " .. M.height .. "split")
		vim.api.nvim_win_set_buf(0, b)
		vim.wo.number = false
		vim.wo.relativenumber = false
		vim.api.nvim_set_current_win(current)
	end
	return b
end

---Clear the Output window to `title` for a new command and show it.
---@param name string the kind of command, e.g. "build"; sets the filetype to `zephyr<name>`
---@param title string|string[] first line(s)
---@param opts? { stop?: fun() } how `q` stops the command while it runs
---@return integer buf
function M.open(name, title, opts)
	if stopper then
		-- A command still streams here: it keeps running, but `q` no longer stops it.
		stopper = nil
	end
	local b = ensure_buf()
	if vim.bo[b].filetype ~= "zephyr" .. name then
		vim.bo[b].filetype = "zephyr" .. name
	end
	vim.api.nvim_buf_set_lines(b, 0, -1, false, type(title) == "table" and title or { title })
	stopper = opts and opts.stop or nil
	M.show()
	return b
end

---Mark the command in the Output window as finished, so `q` only closes it.
---@param stop? fun() only finish when the running command is still this one
function M.finish(stop)
	if stop == nil or stopper == stop then
		stopper = nil
	end
end

---Append `line` (without ANSI colours) and keep the window scrolled to the end.
---@param b integer
---@param line string
function M.append(b, line)
	if not vim.api.nvim_buf_is_valid(b) then
		return
	end
	vim.api.nvim_buf_set_lines(b, -1, -1, false, { require("zephyr.build").strip_ansi(line) })
	local win = vim.fn.bufwinid(b)
	if win ~= -1 then
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(b), 0 })
	end
end

return M
