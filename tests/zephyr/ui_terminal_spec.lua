local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build_config = require("zephyr.build_config")
local registry = require("zephyr.registry")
local toolchain = require("zephyr.toolchain")
local ui = require("zephyr.ui.terminal")

local function tc(version)
	return { provider = "fake", id = "fake-" .. version, name = "fake " .. version, version = version, path = "/tc/" .. version }
end

-- The environment and working directory of the shell running in `buf`.
local function shell_of(buf)
	local pid = vim.fn.jobpid(vim.b[buf].terminal_job_id)
	local env = {}
	vim.wait(2000, function()
		local f = io.open("/proc/" .. pid .. "/environ")
		local text = f and f:read("*a") or ""
		if f then
			f:close()
		end
		env = {}
		for kv in text:gmatch("[^%z]+") do
			local k, v = kv:match("^([^=]+)=(.*)$")
			if k then
				env[k] = v
			end
		end
		return env.FAKE_TOOLCHAIN ~= nil
	end)
	return env, vim.uv.fs_readlink("/proc/" .. pid .. "/cwd")
end

local function terminal_bufs()
	return vim.tbl_filter(function(b)
		return vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal"
	end, vim.api.nvim_list_bufs())
end

describe(":Zephyr terminal (default UI)", function()
	local restore_state, topdir, app, toolchains, saved_shell, saved_notify, warnings

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		app = app_mod.from_dir(topdir .. "/app")
		build_config.activate(app, build_config.new(app, { board = "nrf52840dk/nrf52840" }))
		toolchains = { tc("1.0") }
		registry._reset()
		registry.register("toolchain_provider", {
			name = "fake",
			find = function()
				return toolchains
			end,
			env = function(t)
				return { FAKE_TOOLCHAIN = t.version, PATH = t.path .. "/bin:" .. vim.env.PATH }
			end,
		})
		saved_shell, saved_notify = vim.o.shell, vim.notify
		vim.o.shell = "sh"
		warnings = {}
		vim.notify = function(msg, level)
			-- Only the terminal's own warnings; opening a file in the fixture can warn about pins.
			if level == vim.log.levels.WARN and msg:match("Toolchain") then
				table.insert(warnings, msg)
			end
		end
		vim.cmd.edit(topdir .. "/app/prj.conf")
	end)

	after_each(function()
		for _, b in ipairs(terminal_bufs()) do
			vim.api.nvim_buf_delete(b, { force = true })
		end
		vim.cmd("silent! only")
		vim.cmd("silent! %bwipeout!")
		vim.o.shell, vim.notify = saved_shell, saved_notify
		registry._reset()
		registry.register("toolchain_provider", require("zephyr.sdk").provider)
		restore_state()
	end)

	it("opens a shell in the App directory with the Active toolchain's environment", function()
		ui.toggle()
		local buf = vim.api.nvim_get_current_buf()
		assert.are.equal("terminal", vim.bo[buf].buftype)
		local env, cwd = shell_of(buf)
		assert.are.equal("1.0", env.FAKE_TOOLCHAIN)
		assert.matches("^/tc/1.0/bin:", env.PATH)
		assert.are.equal(app.dir, cwd)
		assert.are.same({}, warnings)
	end)

	it("toggles one terminal, and opens a new one when the Active toolchain changed", function()
		vim.cmd("silent! only")
		ui.toggle()
		local buf = vim.api.nvim_get_current_buf()
		assert.are.equal(2, #vim.api.nvim_list_wins())

		vim.cmd.wincmd("p")
		ui.toggle() -- hide
		assert.are.equal(-1, vim.fn.bufwinid(buf))
		ui.toggle() -- show the same one
		assert.are_not.equal(-1, vim.fn.bufwinid(buf))
		assert.are.equal(1, #terminal_bufs())

		toolchains = { tc("1.0"), tc("2.0") }
		toolchain.activate(app, build_config.active(app), tc("2.0"))
		vim.cmd.wincmd("p")
		ui.toggle()
		local fresh = vim.api.nvim_get_current_buf()
		assert.are_not.equal(buf, fresh)
		assert.is_false(vim.api.nvim_buf_is_valid(buf))
		assert.are.equal("2.0", shell_of(fresh).FAKE_TOOLCHAIN)
	end)

	it("opens in the Workspace top directory with Neovim's environment and warns without a toolchain", function()
		toolchains = {}
		vim.cmd.edit(topdir .. "/nrf/west.yml")
		ui.toggle()
		assert.are.equal(1, #warnings)
		assert.matches("none found", warnings[1])
		local pid = vim.fn.jobpid(vim.b.terminal_job_id)
		vim.wait(2000, function()
			return vim.uv.fs_readlink("/proc/" .. pid .. "/cwd") == topdir
		end)
		assert.are.equal(topdir, vim.uv.fs_readlink("/proc/" .. pid .. "/cwd"))
	end)

	it("uses toggleterm when it is installed", function()
		local made = {}
		local Terminal = {}
		function Terminal:new(opts)
			local t = setmetatable({ opts = opts, toggles = 0 }, { __index = self })
			table.insert(made, t)
			return t
		end
		function Terminal:toggle()
			self.toggles = self.toggles + 1
		end
		function Terminal:shutdown()
			self.shut = true
		end
		package.loaded["toggleterm.terminal"] = { Terminal = Terminal }
		local ok, err = pcall(function()
			ui.toggle()
			ui.toggle()
			assert.are.equal(1, #made)
			assert.are.equal(2, made[1].toggles)
			assert.are.equal(app.dir, made[1].opts.dir)
			assert.are.equal("1.0", made[1].opts.env.FAKE_TOOLCHAIN)

			toolchains = { tc("1.0"), tc("2.0") }
			toolchain.activate(app, build_config.active(app), tc("2.0"))
			ui.toggle()
			assert.is_true(made[1].shut)
			assert.are.equal("2.0", made[2].opts.env.FAKE_TOOLCHAIN)
			made[2]:shutdown()
		end)
		package.loaded["toggleterm.terminal"] = nil
		assert(ok, err)
	end)
end)
