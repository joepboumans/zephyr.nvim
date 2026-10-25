-- Default UI for `:Zephyr sdk list|select|install [version]`.
local toolchain = require("zephyr.toolchain")
local workspace = require("zephyr.workspace")

local M = {}

local function notify(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end

local function label(tc)
	return ("%s  (%s)"):format(tc.name, tc.path)
end

function M.list(ws)
	local active = toolchain.active(ws)
	local lines = {}
	for _, tc in ipairs(toolchain.list()) do
		local mark = active and tc.id == active.id and "* " or "  "
		table.insert(lines, mark .. label(tc))
	end
	notify(#lines > 0 and ("toolchains:\n" .. table.concat(lines, "\n")) or "no toolchains found; try :Zephyr sdk install")
end

function M.select(ws)
	local all = toolchain.list()
	if #all == 0 then
		return notify("no toolchains found; try :Zephyr sdk install", vim.log.levels.WARN)
	end
	vim.ui.select(all, { prompt = "Toolchain for " .. ws.topdir, format_item = label }, function(choice)
		if choice then
			toolchain.activate(ws, choice)
			notify("active toolchain: " .. choice.name)
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

M.actions = { "list", "select", "install" }

---@param args string[]
function M.run(args)
	local ws = workspace.find()
	if not ws then
		return notify("not inside a west workspace", vim.log.levels.ERROR)
	end
	local action = args[1] or "select"
	if action == "list" then
		M.list(ws)
	elseif action == "select" then
		M.select(ws)
	elseif action == "install" then
		M.install(ws, args[2])
	else
		notify(("unknown action '%s'; use %s"):format(action, table.concat(M.actions, "|")), vim.log.levels.ERROR)
	end
end

return M
