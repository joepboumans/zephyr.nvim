local h = dofile("tests/helpers.lua")
local job = require("zephyr.job")
local process = require("zephyr.process")

describe("zephyr.job", function()
	local events, saved_run, saved_kill

	before_each(function()
		saved_run, saved_kill = process.run, process.kill
		events = {}
		vim.api.nvim_create_augroup("job_spec", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = "job_spec",
			pattern = { "ZephyrBuildStarted", "ZephyrBuildFinished", "ZephyrFlashStarted", "ZephyrFlashFinished" },
			callback = function(ev)
				table.insert(events, { name = ev.match, data = ev.data })
			end,
		})
	end)

	after_each(function()
		vim.api.nvim_del_augroup_by_name("job_spec")
		process.run, process.kill = saved_run, saved_kill
	end)

	-- A process.run whose commands keep running until `held[i](res)` is called.
	local done = { code = 0, signal = 0, stdout = "", stderr = "" }
	local function hold()
		local held = {}
		process.run = function(_, _, on_exit)
			table.insert(held, on_exit)
			return "proc"
		end
		return held
	end

	it("runs the command in its own process group, streams lines and reports the result", function()
		local calls = h.stub_process(function()
			return { code = 0, stdout_lines = { "one" }, stderr_lines = { "two" } }
		end)
		local lines, result, started = {}, nil, false
		local ok = job.start("/a/build", { "west", "build" }, {
			cwd = "/a",
			env = { X = "1" },
			event = "Build",
			data = { build_dir = "/a/build" },
			on_start = function() started = true end,
			on_output = function(line, stream) table.insert(lines, stream .. ":" .. line) end,
			finish = function(r) return { count = #r.output } end,
			on_exit = function(r) result = r end,
		})
		calls.restore()
		assert.is_true(ok)
		assert.is_true(started)
		assert.is_true(calls[1].opts.group)
		assert.are.equal("/a", calls[1].opts.cwd)
		assert.are.same({ X = "1" }, calls[1].opts.env)
		assert.are.same({ "stdout:one", "stderr:two" }, lines)
		assert.is_true(result.ok)
		assert.are.equal(0, result.code)
		assert.is_false(result.stopped)
		assert.is_number(result.duration)
		assert.are.same({ "one", "two" }, result.output)
		assert.are.equal(2, result.count)
		assert.are.equal("ZephyrBuildStarted", events[1].name)
		assert.are.same({ build_dir = "/a/build", cmd = { "west", "build" } }, events[1].data)
		assert.are.equal("ZephyrBuildFinished", events[2].name)
		assert.are.equal("/a/build", events[2].data.build_dir)
		assert.are.equal(2, events[2].data.count)
		assert.is_nil(events[2].data.output)
		assert.is_false(job.is_running("/a/build"))
	end)

	it("stops a running Job; on_exit still runs, with stopped", function()
		local held = hold()
		local killed
		process.kill = function(p) killed = p end
		local result
		job.start("/a/build", { "west", "build" }, { event = "Build", on_exit = function(r) result = r end })
		assert.is_true(job.is_running("/a/build"))
		assert.is_true(job.stop("/a/build"))
		assert.are.equal("proc", killed)
		held[1]({ code = 0, signal = 15, stdout = "", stderr = "" })
		assert.is_false(result.ok)
		assert.is_true(result.stopped)
		assert.is_false(events[2].data.ok)
		assert.is_false(job.stop("/a/build"))
	end)

	it("reports a command that can't start as output", function()
		process.run = function(_, _, on_exit)
			on_exit({ code = -1, signal = 0, stdout = "", stderr = "ENOENT: no such file or directory (cmd): 'west'" })
		end
		local lines, result = {}, nil
		job.start("/a/build", { "west", "build" }, {
			event = "Build",
			on_output = function(line) table.insert(lines, line) end,
			on_exit = function(r) result = r end,
		})
		assert.are.same({ "ENOENT: no such file or directory (cmd): 'west'" }, lines)
		assert.are.same(lines, result.output)
		assert.is_false(result.ok)
	end)

	it("runs one Job per directory: a flash is refused while a build of it runs", function()
		local held = hold()
		assert.is_true(job.start("/a/build", { "west", "build" }, { event = "Build" }))
		local ok, err = job.start("/a/build", { "west", "flash" }, { event = "Flash" })
		assert.is_false(ok)
		assert.are.equal("build is busy (building)", err)
		assert.are.same({ "ZephyrBuildStarted" }, vim.tbl_map(function(e) return e.name end, events))
		assert.is_true(job.start("/a/other", { "west", "flash" }, { event = "Flash" }))
		held[2](done)
		assert.is_true(job.is_running("/a/build"))
		held[1](done)
		assert.is_false(job.is_running("/a/build"))
	end)
end)
