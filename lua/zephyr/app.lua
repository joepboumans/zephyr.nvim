-- Finds the App around a path: the nearest directory whose CMakeLists.txt
-- calls find_package(Zephyr).
local workspace = require("zephyr.workspace")

local M = {}

---@class zephyr.App
---@field dir string the App's source directory
---@field name string basename of `dir`
---@field workspace zephyr.Workspace|nil the Workspace around `dir`, when the App lives inside one

local function is_app_dir(dir)
	local fd = io.open(dir .. "/CMakeLists.txt", "r")
	if not fd then
		return false
	end
	local text = fd:read("*a")
	fd:close()
	return text:lower():find("find_package%s*%(%s*zephyr") ~= nil
end

---Describe `dir` as an App without checking it.
---@param dir string
---@return zephyr.App
function M.from_dir(dir)
	dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("(.)/$", "%1")
	return { dir = dir, name = vim.fs.basename(dir), workspace = workspace.find(dir) }
end

---Find the App containing `path` (a file or directory).
---@param path? string defaults to the current buffer's file, or the cwd for special buffers
---@return zephyr.App|nil
function M.find(path)
	if not path then
		path = vim.api.nvim_buf_get_name(0)
		if path == "" or vim.bo.buftype ~= "" or path:match("^%w+://") then
			path = vim.fn.getcwd()
		end
	end
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("(.)/$", "%1")
	local start = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
	if is_app_dir(start) then
		return M.from_dir(start)
	end
	for dir in vim.fs.parents(start) do
		if is_app_dir(dir) then
			return M.from_dir(dir)
		end
	end
	return nil
end

return M
