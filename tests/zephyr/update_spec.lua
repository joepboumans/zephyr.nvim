local h = dofile("tests/helpers.lua")
local zephyr = require("zephyr")

describe("zephyr.update", function()
	local calls

	after_each(function()
		calls.restore()
	end)

	it("runs west update for the given projects in the topdir and streams its lines", function()
		calls = h.stub_process(function()
			return { code = 0, stdout_lines = { "=== updating zephyr (zephyr):" }, stderr_lines = { "warning: x" } }
		end)
		local lines, result, ok = {}, nil, nil
		zephyr.update({ topdir = "/ws" }, {
			projects = { "zephyr" },
			args = { "--narrow" },
			on_output = function(line, stream) table.insert(lines, stream .. ":" .. line) end,
		}, function(a, b) ok, result = a, b end)

		assert.are.same({ "west", "update", "--narrow", "zephyr" }, calls[1].cmd)
		assert.are.equal("/ws", calls[1].opts.cwd)
		assert.is_true(ok)
		assert.are.same({ "stdout:=== updating zephyr (zephyr):", "stderr:warning: x" }, lines)
		assert.are.equal(2, #result.output)
	end)

	it("fires ZephyrUpdateFinished with the outcome", function()
		calls = h.stub_process(function()
			return { code = 1, stderr_lines = { "ERROR: update failed for project mcuboot" } }
		end)
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrUpdateFinished",
			callback = function(ev) seen = ev.data end,
		})
		local ok
		zephyr.update({ topdir = "/ws" }, nil, function(a) ok = a end)
		vim.api.nvim_del_autocmd(id)
		assert.is_false(ok)
		assert.is_number(seen.duration)
		seen.duration = nil
		assert.are.same({ workspace = "/ws", projects = {}, ok = false, code = 1, stopped = false }, seen)
	end)

	it("stops west through the returned handle", function()
		local pending
		local process = require("zephyr.process")
		calls = { restore = function() end }
		local saved_run, saved_kill = process.run, process.kill
		process.run = function(_, _, on_exit)
			pending = on_exit
			return "proc"
		end
		local killed
		process.kill = function(p) killed = p end
		local ok, result
		local handle = zephyr.update({ topdir = "/ws" }, {}, function(a, b) ok, result = a, b end)
		handle.stop()
		pending({ code = 143, signal = 0, stdout = "", stderr = "" })
		process.run, process.kill = saved_run, saved_kill
		assert.are.equal("proc", killed)
		assert.is_false(ok)
		assert.is_true(result.stopped)
	end)
end)
