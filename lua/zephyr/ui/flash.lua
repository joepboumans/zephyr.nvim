-- Default UI for `:Zephyr flash [erase]` and `:Zephyr flash probe`.
local build_config = require("zephyr.build_config")
local flash = require("zephyr.flash")
local probes = require("zephyr.probes")
local output = require("zephyr.ui.output")

local M = {}

local notify = require("zephyr.ui.notify")

-- The active Probe is kept per Workspace; an App outside one is keyed by itself.
local function workspace_of(app)
	return app.workspace or { topdir = app.dir }
end

local function label(probe)
	return ("%s  %s  (%s)"):format(probe.name, probe.serial, probe.finder)
end

---Ask which of `list` to use and make it the active Probe.
local function choose(app, list, on_choice)
	local active = probes.active(workspace_of(app))
	vim.ui.select(list, {
		prompt = "Probe for " .. app.name,
		format_item = function(p)
			return ((active and active.serial == p.serial) and "* " or "  ") .. label(p)
		end,
	}, function(choice)
		if choice then
			probes.select(workspace_of(app), choice)
			notify("active probe: " .. label(choice))
		end
		on_choice(choice)
	end)
end

---Pick the active Probe for `app`'s Workspace among the connected ones.
---@param app zephyr.App
---@param on_choice? fun(probe: zephyr.Probe|nil)
function M.pick(app, on_choice)
	on_choice = on_choice or function() end
	local list = probes.list()
	if #list == 0 then
		notify("no probes found", vim.log.levels.WARN)
		return on_choice(nil)
	end
	choose(app, list, on_choice)
end

---The Probe to use: the active one, else the only one connected; with several
---connected and none active, ask once. `on_probe` is not called when cancelled.
---@param app zephyr.App
---@param on_probe fun(probe: zephyr.Probe|nil)
function M.resolve_probe(app, on_probe)
	local active = probes.active(workspace_of(app))
	if active then
		return on_probe(active)
	end
	local list = probes.list()
	if #list <= 1 then
		return on_probe(list[1])
	end
	choose(app, list, function(choice)
		if choice then
			on_probe(choice)
		end
	end)
end

---Flash the active Build configuration of `app`.
---@param app zephyr.App
---@param opts? { erase?: boolean }
function M.flash(app, opts)
	opts = opts or {}
	local cfg = build_config.active(app)
	if not cfg or not cfg.exists then
		return notify("nothing built yet; run :Zephyr build first", vim.log.levels.WARN)
	end
	if flash.is_running(cfg.dir) then
		return notify(cfg.name .. " is busy", vim.log.levels.WARN)
	end
	M.resolve_probe(app, function(probe)
		local follow = output.follow("flash", {
			stop = function()
				flash.stop(cfg.dir)
			end,
			on_exit = function(res)
				local where = res.probe and (" on " .. res.probe.name) or ""
				if res.stopped then
					notify(("flash of %s%s stopped"):format(cfg.name, where), vim.log.levels.WARN)
				elseif res.ok then
					notify(("flashed %s%s (%.1fs)"):format(cfg.name, where, res.duration))
				else
					notify(("flash of %s%s failed"):format(cfg.name, where), vim.log.levels.ERROR)
				end
			end,
		})
		local started, err = flash.run(app, cfg, {
			probe = probe,
			erase = opts.erase,
			on_start = follow.on_start,
			on_output = follow.on_output,
			on_exit = follow.on_exit,
		})
		if not started then
			notify(err or "flash did not start", vim.log.levels.ERROR)
		end
	end)
end

M.actions = { "erase", "probe" }

---@param args string[]
function M.run(args)
	local action = args[1]
	require("zephyr.ui.app").resolve(function(app)
		if action == nil then
			M.flash(app)
		elseif action == "erase" then
			M.flash(app, { erase = true })
		elseif action == "probe" then
			M.pick(app)
		end
	end)
end

return M
