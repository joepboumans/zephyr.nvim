local registry = require("zephyr.registry")
local state = require("zephyr.state")
local toolchain = require("zephyr.toolchain")

local function tc(provider, version)
	return { provider = provider, id = provider .. "-" .. version, name = provider .. " " .. version, version = version, path = "/tc/" .. version }
end

describe("toolchain", function()
	local ws = { topdir = "/ws/one" }
	local saved_path

	before_each(function()
		saved_path = state.path
		state.path = vim.fn.tempname() .. "/state.json"
		registry._reset()
		registry.register("toolchain_provider", {
			name = "zephyr-sdk",
			find = function() return { tc("zephyr-sdk", "0.17.0"), tc("zephyr-sdk", "0.16.8") } end,
			env = function(t) return { ZEPHYR_SDK_INSTALL_DIR = t.path } end,
		})
		registry.register("toolchain_provider", {
			name = "ncs",
			find = function() return { tc("ncs", "v3.1.0") } end,
			env = function(t) return { NCS_TOOLCHAIN = t.path } end,
		})
	end)

	after_each(function()
		state.path = saved_path
	end)

	it("lists toolchains from every provider", function()
		assert.are.equal(3, #toolchain.list())
	end)

	it("defaults to the first toolchain found", function()
		local active, selected = toolchain.active(ws)
		assert.are.equal("ncs-v3.1.0", active.id)
		assert.is_false(selected)
	end)

	it("remembers the activated toolchain per workspace and fires an event", function()
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrToolchainActivated",
			callback = function(ev) seen = ev.data end,
		})
		toolchain.activate(ws, tc("zephyr-sdk", "0.16.8"))
		vim.api.nvim_del_autocmd(id)

		local active, selected = toolchain.active(ws)
		assert.are.equal("zephyr-sdk-0.16.8", active.id)
		assert.is_true(selected)
		assert.are.equal("/ws/one", seen.workspace)
		assert.are.equal("zephyr-sdk-0.16.8", toolchain.active({ topdir = "/ws/one" }).id)
		assert.are.equal("ncs-v3.1.0", toolchain.active({ topdir = "/ws/two" }).id)
	end)

	it("falls back to the default when the selected toolchain is gone", function()
		state.set(ws.topdir, { toolchain = "zephyr-sdk-0.1.0" })
		assert.are.equal("ncs-v3.1.0", toolchain.active(ws).id)
	end)

	it("gives the active toolchain's build environment", function()
		toolchain.activate(ws, tc("zephyr-sdk", "0.17.0"))
		assert.are.same({ ZEPHYR_SDK_INSTALL_DIR = "/tc/0.17.0" }, toolchain.env(ws))
	end)

	it("skips a provider whose find() fails", function()
		registry.register("toolchain_provider", { name = "broken", find = function() error("boom") end, env = function() end })
		assert.are.equal(3, #toolchain.list())
	end)
end)
