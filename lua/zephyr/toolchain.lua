-- Lists Toolchains from every registered provider and keeps the Active
-- toolchain per Workspace.
local registry = require("zephyr.registry")
local state = require("zephyr.state")
local events = require("zephyr.events")

local M = {}

---@class zephyr.Toolchain
---@field provider string name of the Toolchain provider
---@field id string unique across providers
---@field name string shown to people
---@field version string
---@field path string

---@return zephyr.Toolchain[]
function M.list()
	local out = {}
	for _, provider in ipairs(registry.list("toolchain_provider")) do
		local ok, found = pcall(provider.find)
		if ok and type(found) == "table" then
			vim.list_extend(out, found)
		end
	end
	return out
end

---The Active toolchain of a Workspace: the one selected for it, if still
---installed, else the first one found.
---@param workspace zephyr.Workspace
---@return zephyr.Toolchain|nil, boolean selected true when chosen explicitly
function M.active(workspace)
	local chosen = state.get(workspace.topdir).toolchain
	local all = M.list()
	if chosen then
		for _, tc in ipairs(all) do
			if tc.id == chosen then
				return tc, true
			end
		end
	end
	return all[1], false
end

---Make `toolchain` the Active toolchain of `workspace`.
---@param workspace zephyr.Workspace
---@param toolchain zephyr.Toolchain
function M.activate(workspace, toolchain)
	state.set(workspace.topdir, { toolchain = toolchain.id })
	events.emit("ToolchainActivated", { workspace = workspace.topdir, toolchain = toolchain })
end

---Environment variables for building in `workspace`.
---@param workspace zephyr.Workspace
---@return table<string, string>|nil
function M.env(workspace)
	local tc = M.active(workspace)
	if not tc then
		return nil
	end
	local provider = registry.get("toolchain_provider", tc.provider)
	return provider and provider.env(tc) or nil
end

return M
