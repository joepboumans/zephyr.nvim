local M = {}

---@class zephyr.Config
---@field drift? { auto_check?: boolean } check for Drift when a Workspace file is opened or its Manifest written
M.config = {
	drift = { auto_check = true },
}

---@param opts? zephyr.Config
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
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
