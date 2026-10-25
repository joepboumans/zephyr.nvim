local M = {}

---@class zephyr.Config
M.config = {}

---@param opts? zephyr.Config
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

M.registry = require("zephyr.registry")
M.events = require("zephyr.events")

return M
