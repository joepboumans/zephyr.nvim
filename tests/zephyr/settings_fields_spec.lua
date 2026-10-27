-- Every row of settings.fields survives a round trip: settings -> `west build` command ->
-- what a configure records (CMake cache + build_info.yml) -> settings again.
local h = dofile("tests/helpers.lua")
local app_mod = require("zephyr.app")
local build = require("zephyr.build")
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")

-- A value for each row that differs from the base settings below.
local values = {
	board = "c/d",
	build_dir = "build_y",
	conf_files = { "debug.conf" },
	extra_conf_files = { "debug.conf" },
	overlays = { "app.overlay" },
	snippets = { "rtt-console" },
	sysbuild = true,
	optimization = "size",
	board_roots = { "extra-roots" },
	cmake_args = { "-DFOO=1", "-DBAR=two" },
	-- toolchain: a build directory does not record it; it lives only in settings.
}

describe("settings.fields round trip", function()
	local restore_state, topdir, app

	before_each(function()
		restore_state = h.temp_state()
		topdir = h.copy_fixture("ncsws")
		app = app_mod.from_dir(topdir .. "/app")
	end)

	after_each(function()
		restore_state()
	end)

	-- What `west build` would leave behind for `cmd`, minus the build itself.
	local function configure(cmd)
		local dir = cmd[4]
		vim.fn.mkdir(dir, "p")
		local cache = { "ZEPHYR_BASE:PATH=" .. topdir .. "/zephyr", "APPLICATION_SOURCE_DIR:PATH=" .. app.dir }
		local snippets, sysbuild, i = {}, false, 5
		while i <= #cmd do
			local w = cmd[i]
			if w == "-b" then
				i = i + 1
				table.insert(cache, "CACHED_BOARD:STRING=" .. cmd[i])
			elseif w == "-S" then
				i = i + 1
				table.insert(snippets, cmd[i])
			elseif w == "--sysbuild" then
				sysbuild = true
			else
				local name, value = w:match("^%-D([%w_]+)=(.*)$")
				if name then
					table.insert(cache, name .. ":STRING=" .. value)
				end
			end
			i = i + 1
		end
		if #snippets > 0 then
			table.insert(cache, "SNIPPET:STRING=" .. table.concat(snippets, ";"))
		end
		vim.fn.writefile(cache, dir .. "/CMakeCache.txt")
		vim.fn.writefile({ "west:", "  command: " .. table.concat(cmd, " ") }, dir .. "/build_info.yml")
		if sysbuild then
			vim.fn.writefile({ "default: app" }, dir .. "/domains.yaml")
		end
		return dir
	end

	for _, field in ipairs(settings.fields) do
		if values[field.name] ~= nil then
			it("keeps " .. field.name, function()
				local s = settings.normalize({ board = "a/b", build_dir = "build_x", sysbuild = false })
				s[field.name] = values[field.name]
				s = settings.normalize(s)
				local cfg = build_config.from_settings(app, s, false)
				local cmd = build.command(cfg, { app = app })

				local parsed = build_config.parse_west_command(cmd)
				assert.are.same(s.cmake_args, parsed.cmake_args, "settings' own -D variables are not extra arguments")
				if field.cmake then
					local passed = vim.tbl_filter(function(w)
						return vim.startswith(w, "-D" .. field.cmake .. "=")
					end, cmd)
					assert.are.equal(1, #passed)
				end

				local disk = build_config.read(configure(cmd))
				assert.are.same(s, build_config.settings_from_disk(app, disk))
			end)
		end
	end
end)
