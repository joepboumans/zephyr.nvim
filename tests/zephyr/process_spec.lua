local process = require("zephyr.process")

local function run(cmd, opts)
	local done
	process.run(cmd, opts, function(res)
		done = res
	end)
	vim.wait(5000, function()
		return done ~= nil
	end)
	return done
end

describe("process.run", function()
	it("collects output when nothing streams", function()
		local res = run({ "sh", "-c", "echo one; echo two" })
		assert.are.equal(0, res.code)
		assert.are.equal("one\ntwo\n", res.stdout)
	end)

	it("streams stdout and stderr line by line, before on_exit", function()
		local out, err, order = {}, {}, {}
		local res = run({ "sh", "-c", "printf 'a\\nb\\nc'; echo e1 >&2; exit 3" }, {
			on_stdout = function(l)
				table.insert(out, l)
				table.insert(order, l)
			end,
			on_stderr = function(l)
				table.insert(err, l)
			end,
		})
		assert.are.equal(3, res.code)
		assert.are.same({ "a", "b", "c" }, out)
		assert.are.same({ "e1" }, err)
		assert.are.equal("a\nb\nc", res.stdout)
		assert.are.equal("e1\n", res.stderr)
	end)

	it("reports a command that cannot start", function()
		local res = run({ "zephyr-nvim-no-such-command" })
		assert.are.equal(-1, res.code)
	end)
end)
