-- Default UI for `:Zephyr sdk list|select|install [version]`. `list` and
-- `select` work on the active Build configuration of the current App (or the
-- Active app); `install` on the Workspace.
local toolchain = require("zephyr.toolchain")
local workspace = require("zephyr.workspace")

local M = {}

local function notify(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end

local function label(tc)
	return ("%s  (%s)"):format(tc.name, tc.path)
end

-- The App and its active Build configuration, or nothing (with a message).
local function with_config(on_config)
	require("zephyr.ui.app").resolve(function(app)
		local cfg = require("zephyr.build_config").active(app)
		if not cfg then
			return notify("no build configuration yet; try :Zephyr build new", vim.log.levels.WARN)
		end
		on_config(app, cfg)
	end)
end

---Show the Toolchains of every provider; `*` marks the active Build configuration's.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
function M.list(app, cfg)
	local choice = toolchain.resolve(app, cfg)
	local active = choice.toolchain
	local lines = {}
	for _, tc in ipairs(toolchain.ranked(choice.workspace)) do
		local mark = active and tc.id == active.id and "* " or "  "
		table.insert(lines, mark .. label(tc))
	end
	if #lines == 0 then
		return notify("no toolchains found; try :Zephyr sdk install")
	end
	local head = ("toolchains for %s (%s):"):format(cfg.name, choice.source == "chosen" and "chosen" or "default")
	notify(head .. "\n" .. table.concat(lines, "\n"))
end

---Pick the Toolchain of the active Build configuration.
---@param app zephyr.App
---@param cfg zephyr.BuildConfig
function M.select(app, cfg)
	local all = toolchain.ranked(app.workspace)
	if #all == 0 then
		return notify("no toolchains found; try :Zephyr sdk install", vim.log.levels.WARN)
	end
	vim.ui.select(all, { prompt = "Toolchain for " .. cfg.name, format_item = label }, function(choice)
		if choice then
			toolchain.activate(app, cfg, choice)
			notify(("toolchain of %s: %s"):format(cfg.name, choice.name))
		end
	end)
end

function M.install(ws, version)
	notify("installing Zephyr SDK" .. (version and (" " .. version) or "") .. " ...")
	require("zephyr.sdk").install({ workspace = ws, version = version }, function(ok, msg)
		notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		if ok then
			require("zephyr.events").emit("ToolchainInstalled", { provider = "zephyr-sdk", version = version })
		end
	end)
end

-- Toolchains already offered for install this session, so the offer is made once.
M.offered = {}

---When the settings name a Toolchain that is not installed, warn that the
---default is used instead and offer to install the missing one (once per session).
---@param choice zephyr.ToolchainChoice
function M.offer_install(choice)
	local ref = choice.missing
	if not ref then
		return
	end
	local what = ("%s %s"):format(ref.provider, ref.version)
	local instead = choice.toolchain and ("; using %s until it is"):format(choice.toolchain.name) or ""
	notify(("toolchain %s from the settings is not installed%s"):format(what, instead), vim.log.levels.WARN)
	if M.offered[what] then
		return
	end
	M.offered[what] = true
	local yes = "Install " .. what
	vim.ui.select({ yes, "Not now" }, { prompt = "Missing toolchain" }, function(pick)
		if pick ~= yes then
			return
		end
		notify("installing " .. what .. " ...")
		toolchain.install(ref, choice.workspace, function(ok, msg)
			notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		end)
	end)
end

M.actions = { "list", "select", "install" }

---@param args string[]
function M.run(args)
	local action = args[1] or "select"
	if action == "install" then
		local ws = workspace.find()
		if not ws then
			return notify("not inside a west workspace", vim.log.levels.ERROR)
		end
		return M.install(ws, args[2])
	end
	if action ~= "list" and action ~= "select" then
		return notify(
			("unknown action '%s'; use %s"):format(action, table.concat(M.actions, "|")),
			vim.log.levels.ERROR
		)
	end
	with_config(function(app, cfg)
		if action == "list" then
			M.list(app, cfg)
		else
			M.select(app, cfg)
		end
	end)
end

return M
