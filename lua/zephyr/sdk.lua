-- The Zephyr SDK Toolchain provider.
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
	local fd = io.open(dir .. "/sdk_version", "r")
	if not fd then
		return nil
	end
	local version = vim.trim(fd:read("*a"))
	fd:close()
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

M.provider = {
	name = "zephyr-sdk",
	find = function()
		return M.find()
	end,
	env = M.env,
	install = M.install,
}

return M
