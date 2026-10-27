-- Lists Toolchains from every registered provider and resolves the Active
-- toolchain of a Build configuration: the one its settings name, else a default
-- picked from what is installed.
--
-- A Toolchain provider may add, besides `find` and `env`:
--   rank(toolchains, workspace) -> toolchains  best first for that Workspace
--   fallback = true                            only used when no other provider has a Toolchain
--   install({ workspace, version }, on_done)
local registry = require("zephyr.registry")
local state = require("zephyr.state")
local events = require("zephyr.events")
local settings = require("zephyr.settings")

local M = {}

---@class zephyr.Toolchain
---@field provider string name of the Toolchain provider
---@field id string unique across providers
---@field name string shown to people
---@field version string
---@field path string

local function found_by(provider)
	local ok, found = pcall(provider.find)
	return ok and type(found) == "table" and found or {}
end

---@return zephyr.Toolchain[]
function M.list()
	local out = {}
	for _, provider in ipairs(registry.list("toolchain_provider")) do
		vim.list_extend(out, found_by(provider))
	end
	return out
end

---Every Toolchain, best default first: providers by name with fallback
---providers (the Zephyr SDK) last, each provider's Toolchains in its own
---ranking for `workspace` when it has one.
---@param workspace? zephyr.Workspace
---@return zephyr.Toolchain[]
function M.ranked(workspace)
	local providers = registry.list("toolchain_provider")
	local first, last = {}, {}
	for _, p in ipairs(providers) do
		table.insert(p.fallback and last or first, p)
	end
	local out = {}
	for _, p in ipairs(vim.list_extend(first, last)) do
		local found = found_by(p)
		if workspace and type(p.rank) == "function" and #found > 0 then
			local ok, ranked = pcall(p.rank, vim.deepcopy(found), workspace)
			if ok and type(ranked) == "table" then
				found = ranked
			end
		end
		vim.list_extend(out, found)
	end
	return out
end

---The Toolchain used when a Build configuration names none.
---@param workspace? zephyr.Workspace
---@return zephyr.Toolchain|nil
function M.default(workspace)
	return M.ranked(workspace)[1]
end

---How settings name a Toolchain: by provider and version, never by path.
---@param tc zephyr.Toolchain
---@return zephyr.ToolchainRef
function M.ref(tc)
	return { provider = tc.provider, version = tc.version }
end

local function matches(tc, ref)
	return tc.provider == ref.provider and tc.version == ref.version
end

---The installed Toolchain `ref` names, if any.
---@param ref zephyr.ToolchainRef
---@param list? zephyr.Toolchain[]
---@return zephyr.Toolchain|nil
function M.lookup(ref, list)
	for _, tc in ipairs(list or M.list()) do
		if matches(tc, ref) then
			return tc
		end
	end
	return nil
end

local function workspace_of(app, cfg)
	local ws = app and app.workspace
	if not ws and cfg and cfg.zephyr_base then
		ws = require("zephyr.workspace").find(cfg.zephyr_base)
	end
	return ws
end

---Older versions kept one Toolchain per Workspace in personal state. It becomes
---the Toolchain of every Build configuration in the settings file that has
---none, once, and is then dropped.
---@param app zephyr.App
local function migrate(app)
	local ws = app.workspace
	local legacy = ws and state.get(ws.topdir).toolchain
	if not legacy then
		return
	end
	state.unset(ws.topdir, "toolchain")
	local tc
	for _, t in ipairs(M.list()) do
		if t.id == legacy then
			tc = t
		end
	end
	if tc then
		settings.update_all(settings.root(app), function(s)
			if not s.toolchain then
				s.toolchain = M.ref(tc)
				return true
			end
		end)
	end
end

---@class zephyr.ToolchainChoice
---@field toolchain zephyr.Toolchain|nil the Toolchain to use; nil when none is installed
---@field source "chosen"|"default"|"none"
---@field missing zephyr.ToolchainRef|nil the Toolchain the settings name, when it is not installed here
---@field workspace zephyr.Workspace|nil

---Which Toolchain `cfg` of `app` is built with.
---@param app zephyr.App
---@param cfg? zephyr.BuildConfig
---@return zephyr.ToolchainChoice
function M.resolve(app, cfg)
	local ws = workspace_of(app, cfg)
	local ref
	if cfg and cfg.settings then
		migrate(app)
		local s = settings.get(app, cfg.dir) or cfg.settings
		ref = s.toolchain
	end
	local all = M.ranked(ws)
	if ref then
		local tc = M.lookup(ref, all)
		if tc then
			return { toolchain = tc, source = "chosen", workspace = ws }
		end
	end
	return { toolchain = all[1], source = all[1] and "default" or "none", missing = ref, workspace = ws }
end

-- An App, or a Workspace (its Active app's active Build configuration).
local function target(app_or_ws, cfg)
	if app_or_ws and app_or_ws.dir then
		return app_or_ws, cfg or require("zephyr.build_config").active(app_or_ws)
	end
	local app = app_or_ws and require("zephyr.app").active(app_or_ws)
	if app then
		return app, cfg or require("zephyr.build_config").active(app)
	end
	return nil, nil
end

---The Active toolchain of a Build configuration (by default the active one of
---`app`). Given a Workspace, that of its Active app, else the default.
---@param app_or_ws zephyr.App|zephyr.Workspace
---@param cfg? zephyr.BuildConfig
---@return zephyr.Toolchain|nil, boolean selected true when the settings name it
function M.active(app_or_ws, cfg)
	local app
	app, cfg = target(app_or_ws, cfg)
	if not app then
		return M.default(app_or_ws), false
	end
	local choice = M.resolve(app, cfg)
	return choice.toolchain, choice.source == "chosen"
end

---Make `toolchain` the Toolchain of `cfg` (a Build configuration of `app`).
---Fires ZephyrToolchainActivated (`ev.data`: workspace, app, build_dir, toolchain).
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
---@param toolchain zephyr.Toolchain
function M.activate(app, cfg, toolchain)
	local s = settings.get(app, cfg.dir) or cfg.settings
	if not s then
		s = require("zephyr.build_config").settings_from_disk(app, cfg)
	end
	s = vim.deepcopy(s)
	s.toolchain = M.ref(toolchain)
	settings.put(app, s)
	local ws = workspace_of(app, cfg)
	events.emit("ToolchainActivated", {
		workspace = ws and ws.topdir or nil,
		app = app.dir,
		build_dir = cfg.dir,
		toolchain = toolchain,
	})
end

---The build environment of `tc`.
---@param tc zephyr.Toolchain
---@return table<string, string>|nil env, string|nil err why there is none
function M.environment(tc)
	local provider = registry.get("toolchain_provider", tc.provider)
	if not provider then
		return nil, ("%s needs Toolchain provider '%s', which is not registered"):format(tc.name, tc.provider)
	end
	local ok, env = pcall(provider.env, tc)
	if not ok then
		return nil, ("Toolchain provider '%s' failed to give the environment of %s: %s"):format(tc.provider, tc.name, env)
	end
	if type(env) ~= "table" or next(env) == nil then
		return nil, ("Toolchain provider '%s' gave no environment for %s"):format(tc.provider, tc.name)
	end
	return env
end

---Environment for building `cfg` of `app` (or, given a Workspace, its Active
---app). With no Toolchain installed at all it is nil without an error, and
---commands run with Neovim's own environment.
---@param app_or_ws zephyr.App|zephyr.Workspace
---@param cfg? zephyr.BuildConfig
---@return table<string, string>|nil env, string|nil err, zephyr.ToolchainChoice choice
function M.env(app_or_ws, cfg)
	local app
	app, cfg = target(app_or_ws, cfg)
	local choice
	if app then
		choice = M.resolve(app, cfg)
	else
		local tc = M.default(app_or_ws)
		choice = { toolchain = tc, source = tc and "default" or "none", workspace = app_or_ws }
	end
	if not choice.toolchain then
		return nil, nil, choice
	end
	local env, err = M.environment(choice.toolchain)
	return env, err, choice
end

---One line naming the Toolchain a command runs with, for the Output window.
---@param choice zephyr.ToolchainChoice
---@return string
function M.describe(choice)
	local tc = choice.toolchain
	if not tc then
		return "Toolchain: none found, using Neovim's environment"
	end
	local line = ("Toolchain: %s (%s%s)"):format(tc.name, tc.provider, choice.source == "default" and ", default" or "")
	if choice.missing then
		line = line
			.. ("; %s %s from the settings is not installed"):format(choice.missing.provider, choice.missing.version)
	end
	return line
end

---Install the Toolchain `ref` names with its provider.
---@param ref zephyr.ToolchainRef
---@param workspace? zephyr.Workspace
---@param on_done fun(ok: boolean, message: string)
function M.install(ref, workspace, on_done)
	local provider = registry.get("toolchain_provider", ref.provider)
	if not provider then
		return on_done(false, ("Toolchain provider '%s' is not registered"):format(ref.provider))
	end
	if type(provider.install) ~= "function" then
		return on_done(false, ("Toolchain provider '%s' cannot install Toolchains"):format(ref.provider))
	end
	provider.install({ workspace = workspace, version = ref.version }, on_done)
end

return M
