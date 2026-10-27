-- Finds the west Workspace around a path by reading `.west/config`.
local fs = require("zephyr.fs")

local M = {}

---@class zephyr.Workspace
---@field topdir string directory holding `.west/`
---@field manifest_dir string repository that holds the Manifest
---@field manifest_file string full path to the Manifest file
---@field zephyr_base string|nil Zephyr directory, when configured

---Parse the INI text of `.west/config`.
---@param text string
---@return table<string, table<string, string>>
function M.parse_config(text)
	local out, section = {}, nil
	for line in vim.gsplit(text, "\n", { plain = true }) do
		line = vim.trim(line)
		local name = line:match("^%[(.-)%]$")
		if name then
			section = vim.trim(name)
			out[section] = out[section] or {}
		elseif section and line ~= "" and not line:match("^[#;]") then
			local key, value = line:match("^([^=]-)%s*=%s*(.*)$")
			if key then
				out[section][vim.trim(key)] = value
			end
		end
	end
	return out
end

---Find the Workspace containing `path` (a file or directory).
---@param path? string defaults to the current buffer's file, or the cwd for special buffers
---@return zephyr.Workspace|nil
function M.find(path)
	if not path then
		path = vim.api.nvim_buf_get_name(0)
		-- Scratch and special buffers (health://, term://, ...) have no file on disk.
		if path == "" or vim.bo.buftype ~= "" or path:match("^%w+://") then
			path = vim.fn.getcwd()
		end
	end
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local west = vim.fs.find(".west", { path = path, upward = true, type = "directory" })[1]
	if not west then
		return nil
	end
	local topdir = vim.fs.dirname(west)
	local config = M.parse_config(fs.read(west .. "/config") or "")
	local manifest = config.manifest or {}
	if not manifest.path then
		return nil
	end
	local manifest_dir = vim.fs.joinpath(topdir, manifest.path)
	local zephyr = config.zephyr or {}
	return {
		topdir = topdir,
		manifest_dir = manifest_dir,
		manifest_file = vim.fs.joinpath(manifest_dir, manifest.file or "west.yml"),
		zephyr_base = zephyr.base and vim.fs.joinpath(topdir, zephyr.base) or nil,
	}
end

return M
