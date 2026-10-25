local drift = require("zephyr.drift")
local process = require("zephyr.process")

local function fixture(name)
	local fd = assert(io.open("tests/fixtures/west/" .. name, "r"))
	local text = fd:read("*a")
	fd:close()
	return text
end

local A = ("a"):rep(40)
local B = ("b"):rep(40)
local C = ("c"):rep(40)
local ZEPHYR = "0d3b8f8b5e1b1a6c2d4e5f60718293a4b5c6d7e8"

-- git rev-parse HEAD manifest-rev per checkout
local checkouts = {
	["/ws/zephyr"] = { ZEPHYR, ZEPHYR },
	["/ws/bootloader/mcuboot"] = { A, B }, -- moved off manifest-rev
	["/ws/nrfxlib"] = { C, C },
	["/ws/modules/hal/nordic"] = { C, C }, -- Manifest pins a new SHA, not updated yet
}

describe("drift", function()
	local real, calls, list_result

	before_each(function()
		real = process.run
		calls = {}
		list_result = { code = 0, stdout = fixture("list.txt"), stderr = "" }
		process.run = function(cmd, opts, on_exit)
			table.insert(calls, { cmd = cmd, opts = opts })
			if cmd[1] == "west" then
				return on_exit(list_result)
			end
			local shas = checkouts[cmd[3]]
			if not shas then
				return on_exit({ code = 128, stdout = "", stderr = "fatal: not a git repository" })
			end
			on_exit({ code = 0, stdout = table.concat(shas, "\n") .. "\n", stderr = "" })
		end
	end)

	after_each(function()
		process.run = real
	end)

	it("parses west list output, leaving out the manifest repository", function()
		local projects = drift.parse_list(fixture("list.txt"))
		assert.are.equal(5, #projects)
		assert.are.same({
			name = "mcuboot",
			path = "bootloader/mcuboot",
			abspath = "/ws/bootloader/mcuboot",
			revision = "v2.1.0-ncs3",
			cloned = true,
		}, projects[2])
		assert.is_false(projects[5].cloned)
	end)

	it("lists projects in the workspace without {sha}", function()
		drift.check({ topdir = "/ws" }, function() end)
		assert.are.same({ "west", "list", "-f", drift.list_format }, calls[1].cmd)
		assert.are.equal("/ws", calls[1].opts.cwd)
		assert.is_nil(drift.list_format:find("{sha}", 1, true))
	end)

	it("returns drifted projects and skips uncloned ones", function()
		local got
		drift.check({ topdir = "/ws" }, function(drifted) got = drifted end)
		assert.are.same({
			{ name = "mcuboot", path = "bootloader/mcuboot", abspath = "/ws/bootloader/mcuboot", expected = B, actual = A },
			{
				name = "hal_nordic",
				path = "modules/hal/nordic",
				abspath = "/ws/modules/hal/nordic",
				expected = "5c8d109371ebb740fbef1f440a3b59e488a36717",
				actual = C,
			},
		}, got)
		for _, call in ipairs(calls) do
			assert.are_not.equal("/ws/modules/hal/cmsis", call.cmd[3])
		end
		assert.are.same({ "git", "-C", "/ws/zephyr", "rev-parse", "HEAD", "manifest-rev^{commit}" }, calls[2].cmd)
	end)

	it("fires ZephyrDriftDetected only when something drifted", function()
		local seen = {}
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrDriftDetected",
			callback = function(ev) table.insert(seen, ev.data) end,
		})
		drift.check({ topdir = "/ws" }, function() end)
		checkouts["/ws/bootloader/mcuboot"], checkouts["/ws/modules/hal/nordic"] = { B, B }, nil
		local none
		drift.check({ topdir = "/ws" }, function(d) none = d end)
		checkouts["/ws/bootloader/mcuboot"], checkouts["/ws/modules/hal/nordic"] = { A, B }, { C, C }
		vim.api.nvim_del_autocmd(id)

		assert.are.equal(1, #seen)
		assert.are.equal("/ws", seen[1].workspace)
		assert.are.equal(2, #seen[1].projects)
		assert.are.same({}, none)
	end)

	it("treats a project never updated (no manifest-rev) as not drifted", function()
		local got
		drift.compare({ name = "x", path = "x", abspath = "/ws/new", revision = "main", cloned = true }, function(d) got = d end)
		assert.is_nil(got)
	end)

	it("reports west errors", function()
		list_result = { code = 1, stdout = "", stderr = "FATAL ERROR: no west workspace found\n" }
		local drifted, err = "unset", nil
		drift.check({ topdir = "/ws" }, function(d, e) drifted, err = d, e end)
		assert.is_nil(drifted)
		assert.are.equal("FATAL ERROR: no west workspace found", err)
	end)

	it("limits how many git calls run at once", function()
		local pending, peak, running = {}, 0, 0
		process.run = function(cmd, _, on_exit)
			if cmd[1] == "west" then
				return on_exit(list_result)
			end
			running = running + 1
			peak = math.max(peak, running)
			table.insert(pending, function()
				running = running - 1
				on_exit({ code = 0, stdout = A .. "\n" .. A .. "\n" })
			end)
		end
		local saved = drift.concurrency
		drift.concurrency = 2
		local done
		drift.check({ topdir = "/ws" }, function(d) done = d end)
		while #pending > 0 do
			table.remove(pending, 1)()
		end
		drift.concurrency = saved
		assert.are.equal(2, peak)
		assert.are.same({ "zephyr", "hal_nordic" }, vim.tbl_map(function(d) return d.name end, done))
	end)
end)
