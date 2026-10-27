-- The edit buffer for `:Zephyr build new` and `:Zephyr build edit`: a float with
-- one `field: value` line per setting of a Build configuration. `<Tab>`
-- completes values, `<CR>` on a line opens a picker for that field, `:w` saves
-- and `q` cancels.
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")

local M = {}

-- Fields in the order they are shown.
M.fields = {
	"board",
	"build_dir",
	"conf_files",
	"extra_conf_files",
	"overlays",
	"snippets",
	"sysbuild",
	"optimization",
	"board_roots",
	"cmake_args",
	"toolchain",
}

local list_fields = {
	conf_files = true,
	extra_conf_files = true,
	overlays = true,
	snippets = true,
	board_roots = true,
}

M.optimizations = { "default", "debug", "speed", "size", "none" }

local notify = require("zephyr.ui.notify")

local function toolchain_text(ref)
	return ref and (ref.provider .. " " .. ref.version) or ""
end

---The buffer lines for settings `s`.
---@param app zephyr.App
---@param s zephyr.BuildSettings
---@param is_new boolean
---@return string[]
function M.render(app, s, is_new)
	local lines = {
		("# %s build configuration of %s. :w saves, q cancels, <Tab> completes, <CR> picks."):format(
			is_new and "New" or "Edit",
			app.name
		),
		"# Lists are comma separated (cmake_args: space separated). Empty means the default.",
	}
	for _, f in ipairs(M.fields) do
		local v = s[f]
		local text
		if f == "toolchain" then
			text = toolchain_text(v)
		elseif f == "cmake_args" then
			text = table.concat(v or {}, " ")
		elseif list_fields[f] then
			text = table.concat(v or {}, ", ")
		elseif f == "sysbuild" then
			text = tostring(v ~= false)
		elseif f == "optimization" then
			text = v or "default"
		else
			text = v or ""
		end
		table.insert(lines, f .. ": " .. text)
	end
	return lines
end

local function split_list(text)
	local out = {}
	for item in text:gmatch("[^,]+") do
		item = vim.trim(item)
		if item ~= "" then
			table.insert(out, item)
		end
	end
	return out
end

---Parse the buffer lines back into settings.
---@param lines string[]
---@return zephyr.BuildSettings|nil s, string[] errors
function M.parse(lines)
	local s, errs, seen = {}, {}, {}
	local known = {}
	for _, f in ipairs(M.fields) do
		known[f] = true
	end
	for i, line in ipairs(lines) do
		if not line:match("^%s*#") and not line:match("^%s*$") then
			local field, value = line:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
			if not field then
				table.insert(errs, ("line %d: expected `field: value`"):format(i))
			elseif not known[field] then
				table.insert(errs, ("line %d: unknown field '%s'"):format(i, field))
			elseif seen[field] then
				table.insert(errs, ("line %d: '%s' is given twice"):format(i, field))
			else
				seen[field] = true
				if field == "toolchain" then
					if value ~= "" and value ~= "default" then
						local provider, version = value:match("^(%S+)%s+(%S+)$")
						if provider then
							s.toolchain = { provider = provider, version = version }
						else
							table.insert(errs, ("line %d: toolchain: use `<provider> <version>`, or leave it empty"):format(i))
						end
					end
				elseif field == "cmake_args" then
					s.cmake_args = build_config.split_words(value)
				elseif list_fields[field] then
					s[field] = split_list(value)
				elseif field == "sysbuild" then
					if value == "true" or value == "yes" or value == "on" then
						s.sysbuild = true
					elseif value == "false" or value == "no" or value == "off" then
						s.sysbuild = false
					else
						s.sysbuild = value
					end
				elseif field == "optimization" then
					s.optimization = value ~= "" and value or nil
				else
					s[field] = value ~= "" and value or nil
				end
			end
		end
	end
	if #errs > 0 then
		return nil, errs
	end
	return s, errs
end

-- Candidates ------------------------------------------------------------------

local function files_in(app, suffix)
	local out = {}
	local function walk(dir, rel, depth)
		for name, type in vim.fs.dir(dir) do
			local path, r = dir .. "/" .. name, rel == "" and name or (rel .. "/" .. name)
			if type == "file" and vim.endswith(name, suffix) then
				table.insert(out, r)
			elseif
				type == "directory"
				and depth < 4
				and not name:match("^%.")
				and not vim.uv.fs_stat(path .. "/CMakeCache.txt")
			then
				walk(path, r, depth + 1)
			end
		end
	end
	walk(app.dir, "", 0)
	table.sort(out)
	return out
end

local function snippets(app)
	local dirs = { app.dir .. "/snippets" }
	local ws = app.workspace
	if ws then
		if ws.zephyr_base then
			table.insert(dirs, ws.zephyr_base .. "/snippets")
		end
		vim.list_extend(dirs, vim.fn.glob(ws.topdir .. "/*/snippets", true, true))
	end
	local seen, out = {}, {}
	for _, dir in ipairs(dirs) do
		for _, yml in ipairs(vim.fn.glob(dir .. "/*/snippet.yml", true, true)) do
			local name = vim.fs.basename(vim.fs.dirname(yml))
			if not seen[name] then
				seen[name] = true
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

local function toolchains(app)
	local out = {}
	for _, tc in ipairs(require("zephyr.toolchain").ranked(app.workspace)) do
		table.insert(out, toolchain_text({ provider = tc.provider, version = tc.version }))
	end
	return out
end

---Values offered for `field`.
---@param form table the open form
---@param field string
---@return string[]
function M.candidates(form, field)
	local app = form.app
	if field == "board" then
		return form.boards or {}
	elseif field == "conf_files" or field == "extra_conf_files" then
		return files_in(app, ".conf")
	elseif field == "overlays" then
		return files_in(app, ".overlay")
	elseif field == "snippets" then
		return snippets(app)
	elseif field == "toolchain" then
		return toolchains(app)
	elseif field == "sysbuild" then
		return { "true", "false" }
	elseif field == "optimization" then
		return M.optimizations
	elseif field == "build_dir" then
		local board = form.current_board and form.current_board()
		return board and { build_config.dir_name(board) } or {}
	end
	return {}
end

-- The open form ------------------------------------------------------------------

local function field_at(line)
	return line:match("^%s*([%w_]+)%s*:")
end

local function set_value(buf, lnum, field, value, append)
	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	local current = vim.trim(line:match(":%s*(.*)$") or "")
	local new = value
	if append and current ~= "" then
		local items = split_list(current)
		if vim.tbl_contains(items, value) then
			return
		end
		new = current .. ", " .. value
	end
	vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { field .. ": " .. new })
end

local function complete(form)
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local field = field_at(line)
	local colon = line:find(":", 1, true)
	if not field or not colon or col < colon then
		return false
	end
	local before = line:sub(1, col)
	local start = colon + 1
	if list_fields[field] then
		local last = before:match(".*(),")
		if last and last > start then
			start = last + 1
		end
	end
	while before:sub(start, start) == " " do
		start = start + 1
	end
	local base = before:sub(start)
	local matches = vim.tbl_filter(function(c)
		return vim.startswith(c, base)
	end, M.candidates(form, field))
	if field == "board" and not form.boards then
		notify("still listing boards ...")
	end
	vim.fn.complete(start, matches)
	return true
end

local function pick(form)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(form.buf, lnum - 1, lnum, false)[1] or ""
	local field = field_at(line)
	if not field then
		return
	end
	local items = M.candidates(form, field)
	if field == "board" and not form.boards then
		return notify("still listing boards ...", vim.log.levels.WARN)
	end
	if #items == 0 then
		return notify("nothing to pick for " .. field, vim.log.levels.WARN)
	end
	vim.ui.select(items, { prompt = field }, function(choice)
		if choice and vim.api.nvim_buf_is_valid(form.buf) then
			set_value(form.buf, lnum, field, choice, list_fields[field])
		end
	end)
end

local function save(form)
	local lines = vim.api.nvim_buf_get_lines(form.buf, 0, -1, false)
	local s, errs = M.parse(lines)
	local app = form.app
	if s then
		if not s.build_dir and s.board then
			s.build_dir = build_config.dir_name(s.board)
		end
		s = settings.normalize(s)
		errs = build_config.validate(app, s)
	end
	if #errs > 0 then
		notify("not saved:\n" .. table.concat(errs, "\n"), vim.log.levels.ERROR)
		return false
	end
	local old = form.cfg and form.cfg.settings
	local cfg
	if form.cfg then
		cfg = build_config.save(app, s, form.cfg.dir)
	else
		cfg = build_config.new(app, s)
	end
	form.cfg = cfg
	vim.bo[form.buf].modified = false
	if form.on_save then
		form.on_save(cfg, old)
	end
	return true
end

---Open the edit buffer for `opts.cfg` of `app`, or for a new Build configuration.
---@param app zephyr.App
---@param opts? { cfg?: zephyr.BuildConfig, on_save?: fun(cfg: zephyr.BuildConfig, old: zephyr.BuildSettings|nil) }
---@return table form { buf, win, app, cfg }
function M.open(app, opts)
	opts = opts or {}
	local cfg = opts.cfg
	local s = cfg and (cfg.settings or build_config.settings_from_disk(app, cfg)) or build_config.defaults(app, {})
	if not cfg then
		s.build_dir = nil -- named after the board on save
	end
	if cfg and not cfg.settings then
		cfg = vim.tbl_extend("force", cfg, { settings = s })
	end
	local form = { app = app, cfg = cfg, on_save = opts.on_save }

	local buf = vim.api.nvim_create_buf(false, true)
	form.buf = buf
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local name = ("zephyr://build-config/%s/%s"):format(app.name, cfg and cfg.name or "new")
	if not pcall(vim.api.nvim_buf_set_name, buf, name) then
		pcall(vim.api.nvim_buf_set_name, buf, name .. "-" .. buf)
	end
	local lines = M.render(app, s, cfg == nil)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.bo[buf].filetype = "zephyrbuildconfig"

	local width = math.min(100, math.max(60, math.floor(vim.o.columns * 0.7)))
	local height = #lines + 1
	form.win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = cfg and (" " .. cfg.name .. " ") or " New build configuration ",
		title_pos = "center",
	})
	-- Start on the first value to fill in: the board of a new one.
	vim.api.nvim_win_set_cursor(form.win, { 3, #lines[3] })

	function form.current_board()
		for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			local b = line:match("^%s*board%s*:%s*(.-)%s*$")
			if b and b ~= "" then
				return b
			end
		end
	end

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			save(form)
		end,
	})
	local map = function(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, desc = "zephyr: " .. desc })
	end
	map("n", "q", function()
		vim.bo[buf].modified = false
		if vim.api.nvim_win_is_valid(form.win) then
			vim.api.nvim_win_close(form.win, true)
		end
	end, "close without saving")
	map("n", "<CR>", function()
		pick(form)
	end, "pick a value for this field")
	map("i", "<Tab>", function()
		if vim.fn.pumvisible() == 1 then
			return vim.api.nvim_feedkeys(vim.keycode("<C-n>"), "n", false)
		end
		if not complete(form) then
			vim.api.nvim_feedkeys("\t", "n", false)
		end
	end, "complete this field")

	build_config.boards(app, function(boards)
		form.boards = boards or {}
	end, s)
	return form
end

return M
