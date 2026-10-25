local h = dofile("tests/helpers.lua")
local probes = require("zephyr.probes")
local registry = require("zephyr.registry")

local function finder(name, found)
	return {
		name = name,
		find = function()
			if type(found) == "function" then
				return found()
			end
			return found
		end,
	}
end

describe("probes", function()
	local restore_state

	before_each(function()
		restore_state = h.temp_state()
		registry._reset()
	end)

	after_each(function()
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		registry.register("probe_finder", require("zephyr.probes.jlink").finder)
		restore_state()
	end)

	it("merges every finder, skipping ones that error", function()
		registry.register("probe_finder", finder("a", { { finder = "a", serial = "1", name = "One" } }))
		registry.register("probe_finder", finder("b", function()
			error("boom")
		end))
		registry.register("probe_finder", finder("c", { { finder = "c", serial = "2", name = "Two" } }))
		assert.are.same({
			{ finder = "a", serial = "1", name = "One" },
			{ finder = "c", serial = "2", name = "Two" },
		}, probes.list())
	end)

	it("de-duplicates by serial, preferring a richer name", function()
		registry.register(
			"probe_finder",
			finder("jlink", {
				{ finder = "jlink", serial = "1050234567", name = "J-Link OB-nRF5340-NordicSemi" },
				{ finder = "jlink", serial = "683000000", name = "J-Link OB-SAM3U128-V2-NordicSemi" },
			})
		)
		registry.register(
			"probe_finder",
			finder("nrfutil", {
				{ finder = "nrfutil", serial = "1050234567", name = "nRF5340 DK (PCA10095)" },
				{ finder = "nrfutil", serial = "683000000", name = "J-Link 683000000" },
			})
		)
		assert.are.same({
			{ finder = "nrfutil", serial = "1050234567", name = "nRF5340 DK (PCA10095)" },
			{ finder = "jlink", serial = "683000000", name = "J-Link OB-SAM3U128-V2-NordicSemi" },
		}, probes.list())
	end)

	it("strips zero padding and fills in missing fields", function()
		registry.register("probe_finder", finder("x", { { serial = "000683000000" }, { name = "no serial" } }))
		assert.are.same({ { finder = "x", serial = "683000000", name = "J-Link 683000000" } }, probes.list())
	end)

	it("keeps the active probe per workspace and fires ZephyrProbeSelected", function()
		local seen
		vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrProbeSelected",
			once = true,
			callback = function(ev)
				seen = ev.data
			end,
		})
		local ws = { topdir = "/ws" }
		assert.is_nil(probes.active(ws))
		local probe = { finder = "jlink", serial = "683000000", name = "J-Link PRO" }
		probes.select(ws, probe)
		assert.are.same(probe, probes.active(ws))
		assert.is_nil(probes.active({ topdir = "/other" }))
		assert.are.same({ workspace = "/ws", probe = probe }, seen)
	end)
end)
