local registry = require("zephyr.registry")

describe("registry", function()
	before_each(function()
		registry._reset()
	end)

	local function provider(name)
		return { name = name, find = function() return {} end, env = function() return {} end }
	end

	it("registers and lists toolchain providers sorted by name", function()
		registry.register("toolchain_provider", provider("zephyr-sdk"))
		registry.register("toolchain_provider", provider("ncs"))
		local names = vim.tbl_map(function(e) return e.name end, registry.list("toolchain_provider"))
		assert.are.same({ "ncs", "zephyr-sdk" }, names)
		assert.are.equal("ncs", registry.get("toolchain_provider", "ncs").name)
	end)

	it("rejects a provider without the required functions", function()
		assert.has_error(function()
			registry.register("toolchain_provider", { name = "broken", find = function() end })
		end)
	end)

	it("rejects unknown kinds", function()
		assert.has_error(function()
			registry.register("debugger", provider("x"))
		end)
	end)

	it("fires a ZephyrRegistered event", function()
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrRegistered",
			callback = function(ev) seen = ev.data end,
		})
		registry.register("probe_finder", { name = "jlink", find = function() return {} end })
		vim.api.nvim_del_autocmd(id)
		assert.are.same({ kind = "probe_finder", name = "jlink" }, seen)
	end)
end)
