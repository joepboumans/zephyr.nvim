-- One place where components start external commands, so tests can stub it.
local M = {}

---Run a command without blocking; `on_exit` gets the vim.SystemCompleted result
---on the main loop.
---@param cmd string[]
---@param opts? table passed to vim.system
---@param on_exit fun(res: vim.SystemCompleted)
function M.run(cmd, opts, on_exit)
	local ok, err = pcall(vim.system, cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(res)
		vim.schedule(function()
			on_exit(res)
		end)
	end)
	if not ok then
		vim.schedule(function()
			on_exit({ code = -1, signal = 0, stdout = "", stderr = tostring(err) })
		end)
	end
end

return M
