-- Components report to everyone through `User` autocmds named `Zephyr<Event>`,
-- with details in `ev.data`.
local M = {}

---@param event string e.g. "BuildFinished"
---@param data? table
function M.emit(event, data)
	vim.api.nvim_exec_autocmds("User", { pattern = "Zephyr" .. event, data = data or {} })
end

return M
