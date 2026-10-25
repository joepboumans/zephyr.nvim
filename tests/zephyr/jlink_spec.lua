local h = dofile("tests/helpers.lua")
local jlink = require("zephyr.probes.jlink")

local function text(name)
	return table.concat(h.output(name), "\n")
end

describe("jlink probe finder", function()
	local saved_exe, calls

	before_each(function()
		saved_exe = jlink.executable
		jlink.executable = function()
			return "JLinkExe"
		end
	end)

	after_each(function()
		jlink.executable = saved_exe
		if calls then
			calls.restore()
			calls = nil
		end
	end)

	it("parses ShowEmuList output", function()
		assert.are.same({
			{ finder = "jlink", serial = "1050234567", name = "J-Link OB-nRF5340-NordicSemi" },
			{ finder = "jlink", serial = "683000000", name = "J-Link OB-SAM3U128-V2-NordicSemi" },
			{ finder = "jlink", serial = "801012345", name = "bench-left" },
		}, jlink.parse(text("jlink_showemulist.txt")))
		assert.are.same({}, jlink.parse(text("jlink_showemulist_none.txt")))
	end)

	it("runs J-Link Commander headless with a command file", function()
		local script
		calls = h.stub_process(function(call)
			script = vim.fn.readfile(call.cmd[#call.cmd])
			return { code = 0, stdout = text("jlink_showemulist.txt") }
		end)
		local found = jlink.finder.find()
		assert.are.equal(3, #found)
		assert.are.same({ "JLinkExe", "-NoGui", "1", "-CommandFile" }, vim.list_slice(calls[1].cmd, 1, 4))
		assert.are.same({ "ShowEmuList USB", "exit" }, script)
		assert.is_nil(vim.uv.fs_stat(calls[1].cmd[5])) -- removed afterwards
	end)

	it("returns nothing when JLinkExe is missing", function()
		jlink.executable = function()
			return nil
		end
		calls = h.stub_process()
		assert.are.same({}, jlink.finder.find())
		assert.are.equal(0, #calls)
	end)

	it("gives up after the timeout", function()
		local process = require("zephyr.process")
		local saved = process.run
		process.run = function() end -- never finishes
		local saved_timeout = jlink.timeout_ms
		jlink.timeout_ms = 50
		local ok, found = pcall(jlink.finder.find)
		process.run, jlink.timeout_ms = saved, saved_timeout
		assert.is_true(ok)
		assert.are.same({}, found)
	end)

	it("can stub the runner itself", function()
		local saved = jlink._run
		jlink._run = function()
			return { code = 0, stdout = text("jlink_showemulist_none.txt"), stderr = "" }
		end
		local found = jlink.finder.find()
		jlink._run = saved
		assert.are.same({}, found)
	end)
end)
