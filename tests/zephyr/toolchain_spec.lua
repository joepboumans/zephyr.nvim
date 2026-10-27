local h = dofile("tests/helpers.lua")
local registry = require("zephyr.registry")
local state = require("zephyr.state")
local settings = require("zephyr.settings")
local toolchain = require("zephyr.toolchain")
local build_config = require("zephyr.build_config")
local app_mod = require("zephyr.app")

local function tc(provider, version)
	return {
		provider = provider,
		id = provider .. "-" .. version,
		name = provider .. " " .. version,
		version = version,
		path = "/tc/" .. version,
	}
end

describe("toolchain", function()
	local restore_state, topdir, ws, app, ncs, sdks

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		ws = require("zephyr.workspace").find(topdir)
		app = app_mod.from_dir(topdir .. "/app")
		ncs = { tc("ncs", "v3.1.0") }
		sdks = { tc("zephyr-sdk", "0.17.0"), tc("zephyr-sdk", "0.16.8") }
		registry._reset()
		registry.register("toolchain_provider", {
			name = "zephyr-sdk",
			fallback = true,
			find = function()
				return sdks
			end,
			rank = require("zephyr.sdk").rank,
			env = function(t)
				return { ZEPHYR_SDK_INSTALL_DIR = t.path }
			end,
		})
		registry.register("toolchain_provider", {
			name = "ncs",
			find = function()
				return ncs
			end,
			env = function(t)
				return t.version == "v0.0.0" and {} or { NCS_TOOLCHAIN = t.path }
			end,
		})
	end)

	after_each(function()
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		restore_state()
	end)

	it("lists toolchains from every provider", function()
		assert.are.equal(3, #toolchain.list())
	end)

	it("defaults to a vendor toolchain over the Zephyr SDK", function()
		local cfg = build_config.new(app, { board = "nrf5340dk/nrf5340/cpuapp" })
		local active, selected = toolchain.active(app, cfg)
		assert.are.equal("ncs-v3.1.0", active.id)
		assert.is_false(selected)
	end)

	it("uses the Zephyr SDK matching zephyr/SDK_VERSION when no other toolchain is installed", function()
		ncs = {}
		assert.are.equal("zephyr-sdk-0.16.8", toolchain.default(ws).id)
		vim.fn.delete(topdir .. "/zephyr/SDK_VERSION")
		assert.are.equal("zephyr-sdk-0.17.0", toolchain.default(ws).id)
	end)

	it("keeps today's order for providers without a ranking", function()
		ncs = { tc("ncs", "v2.6.1"), tc("ncs", "v3.0.0") }
		assert.are.equal("ncs-v2.6.1", toolchain.default(ws).id)
	end)

	it("keeps a toolchain per Build configuration and fires an event", function()
		local a = build_config.new(app, { board = "nrf5340dk/nrf5340/cpuapp" })
		local b = build_config.new(app, { board = "nrf52840dk/nrf52840" })
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrToolchainActivated",
			callback = function(ev)
				seen = ev.data
			end,
		})
		toolchain.activate(app, a, tc("zephyr-sdk", "0.16.8"))
		vim.api.nvim_del_autocmd(id)

		assert.are.equal(a.dir, seen.build_dir)
		assert.are.equal(app.dir, seen.app)
		assert.are.equal(topdir, seen.workspace)
		local got, selected = toolchain.active(app, build_config.get(app, a.dir))
		assert.are.equal("zephyr-sdk-0.16.8", got.id)
		assert.is_true(selected)
		assert.are.equal("ncs-v3.1.0", toolchain.active(app, build_config.get(app, b.dir)).id)
		-- Stored by provider and version, not by path.
		assert.are.same({ provider = "zephyr-sdk", version = "0.16.8" }, settings.get(app, a.dir).toolchain)
		-- Each build gets its own environment.
		assert.are.same({ ZEPHYR_SDK_INSTALL_DIR = "/tc/0.16.8" }, (toolchain.env(app, build_config.get(app, a.dir))))
		assert.are.same({ NCS_TOOLCHAIN = "/tc/v3.1.0" }, (toolchain.env(app, build_config.get(app, b.dir))))
	end)

	it("falls back to the default when the chosen toolchain is not installed, and says so", function()
		local cfg = build_config.new(app, { board = "x/y", toolchain = { provider = "ncs", version = "v2.6.1" } })
		local choice = toolchain.resolve(app, cfg)
		assert.are.equal("ncs-v3.1.0", choice.toolchain.id)
		assert.are.equal("default", choice.source)
		assert.are.same({ provider = "ncs", version = "v2.6.1" }, choice.missing)
		assert.matches("ncs v3.1.0 %(ncs, default%); ncs v2.6.1 from the settings is not installed", toolchain.describe(choice))
	end)

	it("migrates a Workspace's old toolchain choice once", function()
		local a = build_config.new(app, { board = "a/b" })
		local b = build_config.new(app, { board = "c/d", toolchain = { provider = "ncs", version = "v3.1.0" } })
		state.set(topdir, { toolchain = "zephyr-sdk-0.17.0" })
		assert.are.equal("zephyr-sdk-0.17.0", toolchain.active(app, a).id)
		assert.is_nil(state.get(topdir).toolchain)
		assert.are.same({ provider = "zephyr-sdk", version = "0.17.0" }, settings.get(app, a.dir).toolchain)
		assert.are.same({ provider = "ncs", version = "v3.1.0" }, settings.get(app, b.dir).toolchain)
		-- Configurations made later get the default.
		local c = build_config.new(app, { board = "e/f" })
		assert.are.equal("ncs-v3.1.0", toolchain.active(app, c).id)
	end)

	it("refuses an environment that cannot be resolved, naming toolchain and provider", function()
		ncs = { tc("ncs", "v0.0.0") }
		local cfg = build_config.new(app, { board = "a/b" })
		local env, err = toolchain.env(app, cfg)
		assert.is_nil(env)
		assert.matches("Toolchain provider 'ncs' gave no environment for ncs v0.0.0", err)
	end)

	it("gives no environment and no error when no toolchain is installed", function()
		ncs, sdks = {}, {}
		local cfg = build_config.new(app, { board = "a/b" })
		local env, err, choice = toolchain.env(app, cfg)
		assert.is_nil(env)
		assert.is_nil(err)
		assert.are.equal("none", choice.source)
		assert.matches("none found", toolchain.describe(choice))
	end)

	it("answers for a Workspace through its Active app", function()
		local cfg = build_config.new(app, { board = "a/b" })
		toolchain.activate(app, cfg, tc("zephyr-sdk", "0.17.0"))
		assert.are.equal("ncs-v3.1.0", toolchain.active(ws).id) -- no Active app yet
		app_mod.activate(ws, app)
		assert.are.equal("zephyr-sdk-0.17.0", toolchain.active(ws).id)
	end)

	it("skips a provider whose find() fails", function()
		registry.register("toolchain_provider", {
			name = "broken",
			find = function()
				error("boom")
			end,
			env = function() end,
		})
		assert.are.equal(3, #toolchain.list())
	end)
end)
