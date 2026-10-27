-- Default UI for `:Zephyr build [pristine]` and `:Zephyr build select|new|edit|app`.
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local output = require("zephyr.ui.output")

local M = {}

local notify = require("zephyr.ui.notify")

local function label(cfg)
	return ("%s  [%s]%s%s"):format(
		cfg.name,
		cfg.board or "?",
		cfg.sysbuild and "  sysbuild" or "",
		cfg.exists and "" or "  (not built yet)"
	)
end

local function start(app, cfg, opts)
	local buf
	local function stop()
		build.stop(cfg.dir)
	end
	local started, err = build.run(app, cfg, {
		pristine = opts.pristine,
		reconfigure = opts.reconfigure,
		on_start = function(info)
			local title = { require("zephyr.toolchain").describe(info.toolchain), "$ " .. table.concat(info.cmd, " ") }
			buf = output.open("build", title, { stop = stop })
			require("zephyr.ui.sdk").offer_install(info.toolchain)
		end,
		on_output = function(line)
			output.append(buf, line)
		end,
		on_exit = function(res)
			output.finish(stop)
			local status = res.stopped and "stopped" or (res.ok and "done" or ("failed, exit " .. res.code))
			output.append(buf, ("[%s in %.1fs]"):format(status, res.duration))
			if res.stopped then
				return notify(("build of %s stopped"):format(cfg.name), vim.log.levels.WARN)
			end
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
		notify(err or (cfg.name .. " did not start"), vim.log.levels.ERROR)
	end
end

local function describe_differences(cfg, diffs)
	local lines = { ("%s was configured differently from its settings:"):format(cfg.name) }
	for _, d in ipairs(diffs) do
		table.insert(lines, ("  %s: settings %s, build directory %s"):format(d.field, d.settings, d.build))
	end
	return table.concat(lines, "\n")
end

---Build the active Build configuration of `app`. When its build directory was
---configured differently from its settings, warn and offer a Pristine build.
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
	if opts.pristine or not cfg.exists or build_config.pristine_next(app, cfg) then
		return start(app, cfg, opts)
	end
	local diffs = build_config.differences(app, cfg)
	if #diffs == 0 then
		return start(app, cfg, opts)
	end
	notify(describe_differences(cfg, diffs), vim.log.levels.WARN)
	local choices = { "Pristine build with the settings", "Build without reconfiguring", "Cancel" }
	vim.ui.select(choices, { prompt = cfg.name .. " differs from its settings" }, function(choice)
		if choice == choices[1] then
			start(app, cfg, { pristine = true })
		elseif choice == choices[2] then
			start(app, cfg, opts)
		end
	end)
end

---Pick the active Build configuration of `app`.
---@param app zephyr.App
function M.select(app)
	local all = build_config.list(app)
	local active = build_config.active(app)
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

---After an edit that needs CMake to configure again: a Pristine build now, on
---the next build, or not at all. With `setup({ build = { auto_pristine = true } })`
---the next build is pristine without asking.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
function M.after_edit(app, cfg)
	local conf = require("zephyr").config.build or {}
	if conf.auto_pristine then
		build_config.set_pristine_next(app, cfg, true)
		return notify(("the next build of %s is a pristine build"):format(cfg.name))
	end
	local choices = { "Pristine build now", "On the next build", "Not now" }
	vim.ui.select(choices, { prompt = cfg.name .. " needs a pristine build" }, function(choice)
		if choice == choices[1] then
			start(app, cfg, { pristine = true })
		elseif choice == choices[2] then
			build_config.set_pristine_next(app, cfg, true)
			notify(("the next build of %s is a pristine build"):format(cfg.name))
		end
	end)
end

---Create a Build configuration in the edit buffer; `:w` creates it and makes it active.
---@param app zephyr.App
---@param on_created? fun(cfg: zephyr.BuildConfig)
function M.new(app, on_created)
	require("zephyr.ui.build_form").open(app, {
		on_save = function(cfg)
			notify(("active build configuration: %s (%s)"):format(cfg.name, cfg.board))
			if on_created then
				on_created(cfg)
			end
		end,
	})
end

---Edit the active Build configuration of `app` in the edit buffer.
---@param app zephyr.App
function M.edit(app)
	local cfg = build_config.active(app)
	if not cfg then
		return notify("no build configuration yet; try :Zephyr build new", vim.log.levels.WARN)
	end
	require("zephyr.ui.build_form").open(app, {
		cfg = cfg,
		on_save = function(saved, old)
			notify("saved build configuration " .. saved.name)
			if saved.exists and build_config.needs_reconfigure(old, saved.settings) then
				M.after_edit(app, saved)
			end
		end,
	})
end

M.actions = { "pristine", "select", "new", "edit", "app" }

---@param args string[]
function M.run(args)
	local action = args[1]
	if action == "app" then
		return require("zephyr.ui.app").select()
	end
	require("zephyr.ui.app").resolve(function(app)
		if action == nil then
			M.build(app)
		elseif action == "pristine" then
			M.build(app, { pristine = true })
		elseif action == "select" then
			M.select(app)
		elseif action == "new" then
			M.new(app)
		elseif action == "edit" then
			M.edit(app)
		end
	end)
end

return M
