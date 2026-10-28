-- Reading files and checking directories, in one place.
local M = {}

---The whole text of `path`, or nil when it can't be read.
---@param path string
---@return string|nil
function M.read(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local text = fd:read("*a")
	fd:close()
	return text
end

---Whether `path` is a directory. False for nil.
---@param path string|nil
---@return boolean
function M.is_dir(path)
	local st = path and vim.uv.fs_stat(path)
	return st ~= nil and st.type == "directory"
end

return M
