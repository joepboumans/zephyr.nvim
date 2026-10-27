local h = dofile("tests/helpers.lua")
local manifest = require("zephyr.manifest")
local drift = require("zephyr.drift")
local process = require("zephyr.process")
local workspace = require("zephyr.workspace")

describe("Pin mismatch", function()
	local topdir, ws, real

	before_each(function()
		topdir = h.copy_fixture("ncsws")
		ws = workspace.find(topdir)
		real = process.run
		-- Nothing drifted: every checkout is on its manifest-rev.
		process.run = function(cmd, _, on_exit)
			if cmd[1] == "west" then
				return on_exit({ code = 0, stdout = "", stderr = "" })
			end
			on_exit({ code = 0, stdout = "", stderr = "" })
		end
	end)

	after_each(function()
		process.run = real
	end)

	it("reads the Manifest's projects and revisions", function()
		local m = manifest.of(ws)
		assert.are.equal("vt-v2.9.2-v1.5", manifest.project(m, "nrf").revision)
		assert.are.equal("vt-3.7.99-ncs2-2-v1.7", manifest.project(m, "zephyr").revision)
		assert.are.equal(topdir .. "/nrf/west.yml", manifest.import_file(ws, manifest.project(m, "nrf")))
		assert.is_nil(manifest.import_file(ws, manifest.project(m, "zephyr")))
	end)

	it("names both revisions when the Manifest pins Zephyr differently from NCS", function()
		assert.are.same({
			{
				name = "zephyr",
				revision = "vt-3.7.99-ncs2-2-v1.7",
				imported_revision = "v3.7.99-ncs2",
				imported_from = "nrf",
				imported_file = topdir .. "/nrf/west.yml",
			},
		}, manifest.pin_mismatches(ws))
	end)

	it("gives no warning when the revisions are equal", function()
		local file = topdir .. "/nrf/west.yml"
		local text = table.concat(vim.fn.readfile(file), "\n"):gsub("v3%.7%.99%-ncs2\n", "vt-3.7.99-ncs2-2-v1.7\n")
		vim.fn.writefile(vim.split(text, "\n"), file)
		assert.are.same({}, manifest.pin_mismatches(ws))
	end)

	it("skips an imported Manifest that is not checked out", function()
		vim.fn.delete(topdir .. "/nrf", "rf")
		assert.are.same({}, manifest.pin_mismatches(ws))
	end)

	it("is reported with Drift, in ZephyrDriftDetected", function()
		local seen
		local id = vim.api.nvim_create_autocmd("User", {
			pattern = "ZephyrDriftDetected",
			callback = function(ev)
				seen = ev.data
			end,
		})
		local got
		drift.check(ws, function(drifted, _, mismatches)
			got = { drifted = drifted, mismatches = mismatches }
		end)
		vim.api.nvim_del_autocmd(id)
		assert.are.same({}, got.drifted)
		assert.are.equal(1, #got.mismatches)
		assert.are.same({}, seen.projects)
		assert.are.equal("zephyr", seen.pin_mismatches[1].name)
	end)

	it(":Zephyr update check lists Pin mismatches next to Drift", function()
		local notes = {}
		local saved = vim.notify
		vim.notify = function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end
		require("zephyr.ui.update").check(ws)
		vim.notify = saved
		assert.are.equal(2, #notes)
		assert.matches("zephyr is pinned at vt%-3%.7%.99%-ncs2%-2%-v1%.7 by the Manifest but at v3%.7%.99%-ncs2 by nrf's west.yml", notes[1].msg)
		assert.are.equal(vim.log.levels.WARN, notes[1].level)
		assert.matches("no drift", notes[2].msg)
	end)

	it("never blocks a build", function()
		local app = require("zephyr.app").from_dir(topdir .. "/app")
		local restore = h.temp_state()
		local cfg = require("zephyr.build_config").new(app, { board = "a/b" })
		local calls = h.stub_process(function()
			return { code = 0 }
		end)
		local started = require("zephyr.build").run(app, cfg)
		calls.restore()
		restore()
		assert.is_true(started)
	end)
end)
