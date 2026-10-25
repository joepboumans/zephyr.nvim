local M = {}

---@class zephyr.Config
---@field drift? { auto_check?: boolean } check for Drift when a Workspace file is opened or its Manifest written
---@field clangd? zephyr.ClangdConfig `.clangd` generation; `remove`/`add` default to zephyr.clangd.default_remove/add
M.config = {
	drift = { auto_check = true },
	clangd = { auto_write = true },
}

---@param opts? zephyr.Config
function M.setup(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	-- Flag lists replace the defaults instead of being merged index by index.
	if opts.clangd then
		M.config.clangd.remove = opts.clangd.remove or M.config.clangd.remove
		M.config.clangd.add = opts.clangd.add or M.config.clangd.add
	end
end

M.registry = require("zephyr.registry")
M.events = require("zephyr.events")
M.drift = require("zephyr.drift")

---Run `west update` in `workspace`; see zephyr.update.run.
---@param workspace zephyr.Workspace
---@param opts? zephyr.UpdateOpts
---@param cb? fun(ok: boolean, result: zephyr.UpdateResult)
function M.update(workspace, opts, cb)
	return require("zephyr.update").run(workspace, opts, cb)
end

return M
