-- Default UI for `:Zephyr build [pristine]` and `:Zephyr build select|new`.
local app_mod = require("zephyr.app")
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local output = require("zephyr.ui.output")

local M = {}

local function notify(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end

local function label(cfg)
	return ("%s  [%s]%s%s"):format(
		cfg.name,
		cfg.board or "?",
		cfg.sysbuild and "  sysbuild" or "",
		cfg.exists and "" or "  (not built yet)"
	)
end

---Build the active Build configuration of `app`.
---@param app zephyr.App
---@param opts? { pristine?: boolean }
function M.build(app, opts)
	opts = opts or {}
	local cfg = build_config.active(app)
	if not cfg then
		return M.new(app, function()
			M.build(app, opts)
		end)
	end
	local buf = output.open("build", ("$ %s"):format(table.concat(build.command(cfg, opts), " ")))
	local started = build.run(app, cfg, {
		pristine = opts.pristine,
		on_output = function(line)
			output.append(buf, line)
		end,
		on_exit = function(res)
			output.append(
				buf,
				("[%s in %.1fs]"):format(res.ok and "done" or ("failed, exit " .. res.code), res.duration)
			)
			local errors = vim.tbl_filter(function(i)
				return i.type == "E"
			end, res.items)
			vim.fn.setqflist({}, " ", { title = "Zephyr build " .. cfg.name, items = res.items })
			if #errors > 0 then
				vim.cmd("botright copen")
			end
			if res.ok then
				notify(("built %s (%.1fs)"):format(cfg.name, res.duration))
			else
				notify(("build of %s failed (%d errors)"):format(cfg.name, #errors), vim.log.levels.ERROR)
			end
		end,
	})
	if not started then
		notify(cfg.name .. " is already building", vim.log.levels.WARN)
	end
end

---Pick the active Build configuration of `app`.
---@param app zephyr.App
function M.select(app)
	local all = build_config.list(app)
	local active = build_config.active(app)
	if active and not active.exists then
		table.insert(all, 1, active)
	end
	if #all == 0 then
		return notify("no build configurations yet; try :Zephyr build new", vim.log.levels.WARN)
	end
	vim.ui.select(all, {
		prompt = "Build configuration for " .. app.name,
		format_item = function(cfg)
			return ((active and cfg.dir == active.dir) and "* " or "  ") .. label(cfg)
		end,
	}, function(choice)
		if choice then
			build_config.activate(app, choice)
			notify("active build configuration: " .. choice.name)
		end
	end)
end

local OTHER = "Other board…"

---Create a Build configuration from a board picked from `west boards` or typed in.
---@param app zephyr.App
---@param on_created? fun(cfg: zephyr.BuildConfig)
function M.new(app, on_created)
	local function create(board)
		board = board and vim.trim(board)
		if not board or board == "" then
			return
		end
		local cfg = build_config.new(app, { board = board })
		notify(("active build configuration: %s (%s)"):format(cfg.name, board))
		if on_created then
			on_created(cfg)
		end
	end
	local function type_board()
		vim.ui.input({ prompt = "Board: " }, create)
	end
	notify("listing boards ...")
	build_config.boards(app, function(boards, err)
		if not boards or #boards == 0 then
			if err then
				notify("west boards failed: " .. err, vim.log.levels.WARN)
			end
			return type_board()
		end
		table.insert(boards, 1, OTHER)
		vim.ui.select(boards, { prompt = "Board for " .. app.name }, function(choice)
			if choice == OTHER then
				type_board()
			else
				create(choice)
			end
		end)
	end)
end

M.actions = { "pristine", "select", "new" }

---@param args string[]
function M.run(args)
	local app = app_mod.find()
	if not app then
		return notify("not inside a Zephyr app (no CMakeLists.txt with find_package(Zephyr))", vim.log.levels.ERROR)
	end
	local action = args[1]
	if action == nil then
		M.build(app)
	elseif action == "pristine" then
		M.build(app, { pristine = true })
	elseif action == "select" then
		M.select(app)
	elseif action == "new" then
		M.new(app)
	else
		notify(("unknown action '%s'; use %s"):format(action, table.concat(M.actions, "|")), vim.log.levels.ERROR)
	end
end

return M
