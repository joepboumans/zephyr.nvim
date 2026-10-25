-- Probes: lists them from every registered Probe finder and keeps the active
-- Probe per Workspace.
local registry = require("zephyr.registry")
local state = require("zephyr.state")
local events = require("zephyr.events")

local M = {}

---@class zephyr.Probe
---@field finder string name of the Probe finder that found it
---@field serial string J-Link serial number, without leading zeros
---@field name string shown to people

-- Finders fall back to "J-Link <serial>" or a J-Link product name when they know nothing better.
local function generic(name)
	return type(name) ~= "string" or name == "" or vim.startswith(name, "J-Link ")
end

---Connected Probes from every Probe finder, one per serial number. Finders that
---error are skipped. When two finders see the same Probe, the one with the
---more telling name (one not starting with "J-Link ") wins.
---Finders run synchronously, so this can block for a few seconds.
---@return zephyr.Probe[]
function M.list()
	local out, by_serial = {}, {}
	for _, finder in ipairs(registry.list("probe_finder")) do
		local ok, found = pcall(finder.find)
		if ok and type(found) == "table" then
			for _, probe in ipairs(found) do
				if type(probe) == "table" and type(probe.serial) == "string" and probe.serial ~= "" then
					-- J-Link tools and `west flash --dev-id` use serials without zero padding.
					local serial = probe.serial:gsub("^0+(%d)", "%1")
					probe = vim.tbl_extend("force", { finder = finder.name, name = "J-Link " .. serial }, probe)
					probe.serial = serial
					local i = by_serial[probe.serial]
					if not i then
						table.insert(out, probe)
						by_serial[probe.serial] = #out
					elseif generic(out[i].name) and not generic(probe.name) then
						out[i] = probe
					end
				end
			end
		end
	end
	return out
end

---The active Probe of `workspace`, as last selected. It is not checked to be connected.
---@param workspace zephyr.Workspace|{ topdir: string }
---@return zephyr.Probe|nil
function M.active(workspace)
	local probe = state.get(workspace.topdir).probe
	if type(probe) == "table" and type(probe.serial) == "string" then
		return probe
	end
	return nil
end

---Make `probe` the active Probe of `workspace`. Fires ZephyrProbeSelected
---(`ev.data`: workspace, probe).
---@param workspace zephyr.Workspace|{ topdir: string }
---@param probe zephyr.Probe
function M.select(workspace, probe)
	probe = { finder = probe.finder, serial = probe.serial, name = probe.name }
	state.set(workspace.topdir, { probe = probe })
	events.emit("ProbeSelected", { workspace = workspace.topdir, probe = probe })
end

return M
