local sdk = require("zephyr.sdk")
local fixtures = vim.fn.fnamemodify("tests/fixtures/sdks", ":p"):gsub("/$", "")

describe("Zephyr SDK provider", function()
	local saved_env
	before_each(function()
		saved_env = vim.env.ZEPHYR_SDK_INSTALL_DIR
		vim.env.ZEPHYR_SDK_INSTALL_DIR = nil
	end)
	after_each(function()
		vim.env.ZEPHYR_SDK_INSTALL_DIR = saved_env
	end)

	it("finds SDKs by their sdk_version file, newest first", function()
		local found = sdk.find({ fixtures })
		assert.are.same({ "0.17.0", "0.16.8" }, vim.tbl_map(function(t) return t.version end, found))
		assert.are.equal(fixtures .. "/zephyr-sdk-0.17.0", found[1].path)
		assert.are.equal("zephyr-sdk", found[1].provider)
	end)

	it("includes ZEPHYR_SDK_INSTALL_DIR once", function()
		vim.env.ZEPHYR_SDK_INSTALL_DIR = fixtures .. "/zephyr-sdk-0.16.8"
		assert.are.equal(2, #sdk.find({ fixtures }))
	end)

	it("builds the environment for a build", function()
		assert.are.same(
			{ ZEPHYR_TOOLCHAIN_VARIANT = "zephyr", ZEPHYR_SDK_INSTALL_DIR = "/opt/zephyr-sdk-0.17.0" },
			sdk.env({ path = "/opt/zephyr-sdk-0.17.0" })
		)
	end)

	it("installs with west sdk install inside the workspace", function()
		local process = require("zephyr.process")
		local real = process.run
		local got
		process.run = function(cmd, opts, on_exit)
			got = { cmd = cmd, cwd = opts.cwd }
			on_exit({ code = 0, stdout = "", stderr = "" })
		end
		local ok
		sdk.install({ workspace = { topdir = "/ws" }, version = "0.17.0" }, function(success) ok = success end)
		process.run = real
		assert.is_true(ok)
		assert.are.same({ cmd = { "west", "sdk", "install", "--version", "0.17.0" }, cwd = "/ws" }, got)
	end)

	it("reports a failed install with west's error", function()
		local process = require("zephyr.process")
		local real = process.run
		process.run = function(_, _, on_exit)
			on_exit({ code = 1, stdout = "", stderr = "west: unknown command \"sdk\"\n" })
		end
		local ok, msg
		sdk.install({ workspace = { topdir = "/ws" } }, function(a, b) ok, msg = a, b end)
		process.run = real
		assert.is_false(ok)
		assert.are.equal('west: unknown command "sdk"', msg)
	end)
end)
