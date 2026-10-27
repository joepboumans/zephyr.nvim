-- Personal choices (active Build configuration, Active app, probe) kept in Neovim's data folder,
-- keyed by Workspace topdir. Nothing here is committed to a repo.
local fs = require("zephyr.fs")

local M = {}

M.path = vim.fs.joinpath(vim.fn.stdpath("data"), "zephyr", "state.json")

function M.load()
	local text = fs.read(M.path)
	if not text then
		return {}
	end
	local ok, data = pcall(vim.json.decode, text)
	return ok and type(data) == "table" and data or {}
end

function M.save(data)
	vim.fn.mkdir(vim.fs.dirname(M.path), "p")
	local fd = assert(io.open(M.path, "w"))
	fd:write(vim.json.encode(data))
	fd:close()
end

---@param topdir string
---@return table
function M.get(topdir)
	return M.load()[topdir] or {}
end

---@param topdir string
---@param values table merged into the Workspace's entry
function M.set(topdir, values)
	local data = M.load()
	data[topdir] = vim.tbl_extend("force", data[topdir] or {}, values)
	M.save(data)
end

---Remove `key` from the Workspace's entry.
---@param topdir string
---@param key string
function M.unset(topdir, key)
	local data = M.load()
	if data[topdir] and data[topdir][key] ~= nil then
		data[topdir][key] = nil
		M.save(data)
	end
end

return M
