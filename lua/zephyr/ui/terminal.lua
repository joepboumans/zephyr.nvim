-- Default UI for `:Zephyr terminal`: the Toolchain terminal, a shell that runs
-- with the Active toolchain's environment. Uses toggleterm.nvim when installed,
-- else a built-in terminal in a bottom split.
local app_mod = require("zephyr.app")
local process = require("zephyr.process")
local toolchain = require("zephyr.toolchain")
local workspace = require("zephyr.workspace")

local M = {}

local notify = require("zephyr.ui.notify")

-- The open Toolchain terminal: { toolchain = ref|false, buf = n } or, with toggleterm, { toolchain, term }.
local current

-- What the terminal runs for: the App around the current file, else the
-- Workspace's Active app, else the Workspace itself. Returns it and its directory.
local function target()
	local app = app_mod.find()
	if app then
		return app, app.dir
	end
	local ws = workspace.find()
	if not ws then
		return nil
	end
	app = app_mod.active(ws)
	if app then
		return app, app.dir
	end
	return ws, ws.topdir
end

local function close()
	if current.term then
		current.term:shutdown()
	elseif vim.api.nvim_buf_is_valid(current.buf) then
		vim.api.nvim_buf_delete(current.buf, { force = true })
	end
	current = nil
end

-- Show or hide the built-in terminal's buffer.
local function toggle_split(buf)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		return pcall(vim.api.nvim_win_close, win, true)
	end
	vim.cmd("botright 15split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.cmd("startinsert")
end

local function open(dir, env, ref)
	local mine = { toolchain = ref }
	local function on_exit()
		vim.schedule(function()
			if current == mine then
				current = nil
				if mine.buf and vim.api.nvim_buf_is_valid(mine.buf) then
					pcall(vim.api.nvim_buf_delete, mine.buf, { force = true })
				end
			end
		end)
	end
	local ok, toggleterm = pcall(require, "toggleterm.terminal")
	if ok then
		mine.term = toggleterm.Terminal:new({ dir = dir, env = env, direction = "horizontal", on_exit = on_exit })
		mine.term:toggle()
	else
		vim.cmd("botright 15split")
		vim.cmd("enew")
		mine.buf = vim.api.nvim_get_current_buf()
		process.term({ vim.o.shell }, { cwd = dir, env = env, on_exit = on_exit })
		vim.cmd("startinsert")
	end
	current = mine
end

---Toggle the Toolchain terminal. When the Active toolchain changed since it
---opened, close it and open a fresh one.
function M.toggle()
	local target_, dir = target()
	if not target_ then
		return notify(require("zephyr.ui.app").NOT_IN_APP, vim.log.levels.ERROR)
	end
	local env, err, choice = toolchain.env(target_)
	if err then
		return notify(err, vim.log.levels.ERROR)
	end
	local ref = choice.toolchain and toolchain.ref(choice.toolchain) or false
	if current and current.buf and not vim.api.nvim_buf_is_valid(current.buf) then
		current = nil -- wiped by hand
	end
	if current and not vim.deep_equal(current.toolchain, ref) then
		close()
	end
	if current then
		if current.term then
			return current.term:toggle()
		end
		return toggle_split(current.buf)
	end
	if not choice.toolchain then
		notify(toolchain.describe(choice), vim.log.levels.WARN)
	end
	open(dir, env, ref)
end

M.actions = {}

function M.run()
	M.toggle()
end

return M
