local zephyr = require("zephyr")
local process = require("zephyr.process")

describe("zephyr.update", function()
	local real

	before_each(function()
		real = process.run
	end)

	after_each(function()
		process.run = real
	end)

	local function stub(code, chunks)
		local got = {}
		process.run = function(cmd, opts, on_exit)
			got.cmd, got.cwd = cmd, opts.cwd
			for _, c in ipairs(chunks) do
				opts[c[1]](nil, c[2])
			end
			-- Streamed output reaches the main loop before on_exit, as with vim.system.
			vim.schedule(function()
				on_exit({ code = code, signal = 0 })
			end)
		end
		return got
	end

	it("runs west update for the given projects and streams whole lines", function()
		local got = stub(0, {
			{ "stdout", "=== updating zephyr (zephyr):\n--- zephyr: fet" },
			{ "stdout", "ching\nHEAD is now at 0d3b8f8b5e drivers: fix" },
			{ "stderr", "warning: something\n" },
		})
		local lines, result, ok = {}, nil, nil
		zephyr.update({ topdir = "/ws" }, {
			projects = { "zephyr" },
			on_output = function(line, stream) table.insert(lines, stream .. ":" .. line) end,
		}, function(a, b) ok, result = a, b end)
		vim.wait(1000, function() return ok ~= nil end)

		assert.are.same({ "west", "update", "zephyr" }, got.cmd)
		assert.are.equal("/ws", got.cwd)
		assert.is_true(ok)
		assert.are.same({
			"stdout:=== updating zephyr (zephyr):",
			"stdout:--- zephyr: fetching",
			"stderr:warning: something",
			"stdout:HEAD is now at 0d3b8f8b5e drivers: fix",
		}, lines)
		assert.are.equal(4, #result.output)
	end)

	it("fires ZephyrUpdateFinished with the outcome", function()
		stub(1, { { "stderr", "ERROR: update failed for project mcuboot\n" } })
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrUpdateFinished",
			callback = function(ev) seen = ev.data end,
		})
		local ok
		zephyr.update({ topdir = "/ws" }, nil, function(a) ok = a end)
		vim.wait(1000, function() return ok ~= nil end)
		vim.api.nvim_del_autocmd(id)
		assert.is_false(ok)
		assert.are.same({ workspace = "/ws", projects = {}, ok = false, code = 1 }, seen)
	end)

	it("reports output that was not streamed, such as west missing", function()
		process.run = function(_, _, on_exit)
			on_exit({ code = -1, signal = 0, stdout = "", stderr = "ENOENT: no such file or directory (cmd): 'west'" })
		end
		local result
		zephyr.update({ topdir = "/ws" }, {}, function(_, r) result = r end)
		assert.are.same({ "ENOENT: no such file or directory (cmd): 'west'" }, result.output)
	end)
end)
