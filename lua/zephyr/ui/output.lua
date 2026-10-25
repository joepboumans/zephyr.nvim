-- Output split shared by the default UI: one scratch buffer per name, shown at
-- the bottom and reused between runs.
local M = {}

local bufs = {}

---Open (or reuse) the `zephyr://<name>` buffer in a bottom split, cleared to `title`.
---@param name string e.g. "build"
---@param title string first line
---@return integer buf
function M.open(name, title)
	local buf = bufs[name]
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = vim.api.nvim_create_buf(false, true)
		bufs[name] = buf
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].filetype = "zephyr" .. name
		pcall(vim.api.nvim_buf_set_name, buf, "zephyr://" .. name)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { title })
	if vim.fn.bufwinid(buf) == -1 then
		local current = vim.api.nvim_get_current_win()
		vim.cmd("botright 12split")
		vim.api.nvim_win_set_buf(0, buf)
		vim.wo.number = false
		vim.wo.relativenumber = false
		vim.api.nvim_set_current_win(current)
	end
	return buf
end

---Append `line` (without ANSI colours) and keep the window scrolled to the end.
---@param buf integer
---@param line string
function M.append(buf, line)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { require("zephyr.build").strip_ansi(line) })
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
	end
end

return M
