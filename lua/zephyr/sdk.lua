-- The Zephyr SDK Toolchain provider.
local fs = require("zephyr.fs")

local M = {}

---Places the Zephyr SDK is installed by default, as listed in Zephyr's getting started guide.
function M.search_dirs()
	local home = vim.uv.os_homedir()
	return {
		home,
		home .. "/.local",
		home .. "/.local/opt",
		home .. "/bin",
		"/opt",
		"/usr",
		"/usr/local",
	}
end

local function version_of(dir)
	local version = vim.trim(fs.read(dir .. "/sdk_version") or "")
	return version ~= "" and version or nil
end

---Compare dotted versions numerically, newest first.
local function newer(a, b)
	local pa, pb = vim.split(a.version, "%."), vim.split(b.version, "%.")
	for i = 1, math.max(#pa, #pb) do
		local x, y = tonumber(pa[i]) or 0, tonumber(pb[i]) or 0
		if x ~= y then
			return x > y
		end
	end
	return a.path < b.path
end

---@param dirs? string[] directories to scan for `zephyr-sdk-*`; defaults to search_dirs()
---@return zephyr.Toolchain[] newest first
function M.find(dirs)
	local candidates = {}
	if vim.env.ZEPHYR_SDK_INSTALL_DIR then
		table.insert(candidates, vim.env.ZEPHYR_SDK_INSTALL_DIR)
	end
	for _, dir in ipairs(dirs or M.search_dirs()) do
		vim.list_extend(candidates, vim.fn.glob(dir .. "/zephyr-sdk-*", true, true))
	end
	local seen, out = {}, {}
	for _, path in ipairs(candidates) do
		path = vim.fs.normalize(path)
		local version = not seen[path] and version_of(path)
		if version then
			seen[path] = true
			table.insert(out, {
				provider = "zephyr-sdk",
				id = "zephyr-sdk-" .. version .. "@" .. path,
				name = "Zephyr SDK " .. version,
				version = version,
				path = path,
			})
		end
	end
	table.sort(out, newer)
	return out
end

---Environment for building with this SDK.
---@param toolchain zephyr.Toolchain
function M.env(toolchain)
	return {
		ZEPHYR_TOOLCHAIN_VARIANT = "zephyr",
		ZEPHYR_SDK_INSTALL_DIR = toolchain.path,
	}
end

---Install an SDK with `west sdk install` (Zephyr 4.0+), run inside the Workspace.
---@param opts { workspace: zephyr.Workspace, version?: string }
---@param on_done fun(ok: boolean, message: string)
function M.install(opts, on_done)
	local cmd = { "west", "sdk", "install" }
	if opts.version then
		vim.list_extend(cmd, { "--version", opts.version })
	end
	require("zephyr.process").run(cmd, { cwd = opts.workspace.topdir }, function(res)
		if res.code == 0 then
			on_done(true, "Zephyr SDK installed")
		else
			on_done(false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout or "west sdk install failed"))
		end
	end)
end

---The Zephyr SDK version a Workspace's Zephyr asks for, from `<zephyr>/SDK_VERSION`.
---@param workspace zephyr.Workspace
---@return string|nil e.g. "0.16.8"
function M.wanted_version(workspace)
	local base = workspace and workspace.zephyr_base
	local version = vim.trim(base and fs.read(base .. "/SDK_VERSION") or "")
	return version ~= "" and (version:gsub("^v", "")) or nil
end

---Rank SDKs for `workspace`: the one matching `<zephyr>/SDK_VERSION` first, then newest first.
---@param toolchains zephyr.Toolchain[] newest first, as find() gives them
---@param workspace zephyr.Workspace
---@return zephyr.Toolchain[]
function M.rank(toolchains, workspace)
	local want = M.wanted_version(workspace)
	if not want then
		return toolchains
	end
	local first, rest = {}, {}
	for _, tc in ipairs(toolchains) do
		table.insert(tc.version == want and first or rest, tc)
	end
	return vim.list_extend(first, rest)
end

M.provider = {
	name = "zephyr-sdk",
	-- Vendor toolchains (such as NCS's) come first; the Zephyr SDK is used when none is installed.
	fallback = true,
	find = function()
		return M.find()
	end,
	env = M.env,
	rank = M.rank,
	install = M.install,
}

return M
