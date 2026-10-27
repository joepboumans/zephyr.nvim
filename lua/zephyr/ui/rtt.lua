-- Default UI for `:Zephyr rtt` (the RTT viewer in a terminal split) and
-- `:Zephyr rtt stop`.
local build_config = require("zephyr.build_config")
local rtt = require("zephyr.rtt")

local M = {}

---@type zephyr.RttViewer|nil the viewer started by `:Zephyr rtt`
M.viewer = nil
---@type zephyr.RttStream|nil a stream started through the default UI
M.stream = nil

local function notify(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end

local function show(buf)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		return vim.api.nvim_set_current_win(win)
	end
	vim.cmd("botright 15split")
	vim.api.nvim_win_set_buf(0, buf)
end

---Open the RTT viewer for the active Build configuration of `app` in a bottom
---terminal split; with one already running, show it.
---@param app zephyr.App
function M.open(app)
	if M.viewer and vim.api.nvim_buf_is_valid(M.viewer.buf) then
		return show(M.viewer.buf)
	end
	local cfg = build_config.active(app)
	if not cfg or not cfg.exists then
		return notify("nothing built yet; run :Zephyr build first", vim.log.levels.WARN)
	end
	require("zephyr.ui.flash").resolve_probe(app, function(probe)
		vim.cmd("botright 15split")
		local win = vim.api.nvim_get_current_win()
		local mine
		rtt.open_viewer(app, cfg, {
			probe = probe,
			win = win,
			on_exit = function(code)
				if M.viewer ~= mine then
					return -- stopped by :Zephyr rtt stop (the pty hangs up, so the code is 129)
				end
				M.viewer = nil
				if code ~= 0 and code ~= 129 and code ~= 143 then
					notify(("RTT viewer exited with %d"):format(code), vim.log.levels.WARN)
				end
			end,
		}, function(viewer, err)
			if not viewer then
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
				return notify(err or "RTT viewer did not start", vim.log.levels.ERROR)
			end
			mine = viewer
			M.viewer = viewer
			pcall(vim.api.nvim_buf_set_name, viewer.buf, "zephyr://rtt")
			vim.wo[win].number = false
			vim.wo[win].relativenumber = false
		end)
	end)
end

---Stop the RTT viewer and stream started by the default UI.
function M.stop()
	if not M.viewer and not M.stream then
		return notify("no RTT viewer running")
	end
	if M.viewer then
		M.viewer.stop()
		M.viewer = nil
	end
	if M.stream then
		M.stream.close()
		M.stream = nil
	end
	notify("RTT stopped")
end

M.actions = { "stop" }

---@param args string[]
function M.run(args)
	local action = args[1]
	if action == "stop" then
		return M.stop()
	elseif action ~= nil then
		local msg = ("unknown action '%s'; use %s"):format(action, table.concat(M.actions, "|"))
		return notify(msg, vim.log.levels.ERROR)
	end
	require("zephyr.ui.app").resolve(M.open)
end

return M
