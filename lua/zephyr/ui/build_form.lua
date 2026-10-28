-- The settings panel for `:Zephyr build new` and `:Zephyr build edit`: a
-- read-only float with one labelled row per Build configuration setting.
-- `<CR>` or `i` on a row changes that setting through `vim.ui.select` or
-- `vim.ui.input`, `x` resets it, `<C-s>` saves and closes, `q` closes.
local build_config = require("zephyr.build_config")
local settings = require("zephyr.settings")
local notify = require("zephyr.ui.notify")

local M = {}

local ns = vim.api.nvim_create_namespace("zephyr.build_form")

local optimizations = { "default", "debug", "speed", "size", "none" }

local keys_help = {
	"<CR>/i  change the setting under the cursor",
	"x       reset it to its default",
	"<C-s>   save and close",
	"q       close without saving",
	"<Esc>   close when nothing changed",
	"g?      this help",
}

local LABEL_WIDTH, VALUE_WIDTH = 20, 25

local field_of = {}
for _, f in ipairs(settings.fields) do
	field_of[f.name] = f
end

-- Fields without a list of values to pick from: they are typed in.
local typed = { build_dir = true, board_roots = true, cmake_args = true }

local function toolchain_text(ref)
	return ref.provider .. " " .. ref.version
end

-- CMake arguments can hold commas, so they are separated by spaces.
local function list_text(field, values)
	return table.concat(values, field.name == "cmake_args" and " " or ", ")
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

---Values offered for `field`: board targets, files and snippets in the App,
---optimization levels, or Toolchains as `<provider> <version>`, best first.
---Empty for fields that are typed in.
---@param form table the open panel
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
		return vim.tbl_map(toolchain_text, require("zephyr.toolchain").ranked(app.workspace))
	elseif field == "optimization" then
		return optimizations
	end
	return {}
end

-- Rendering -------------------------------------------------------------------

-- The value and dim hint shown on the row of `field`.
local function show(form, field)
	local v = form.s[field.name]
	if field.name == "build_dir" and not v then
		return form.s.board and build_config.dir_name(form.s.board) or "—", "(from board)"
	elseif field.kind == "bool" then
		return v and "✓ on" or "off"
	elseif field.kind == "toolchain" then
		if v then
			return toolchain_text(v)
		end
		return form.default_toolchain or "—", "(default)"
	elseif field.kind == "list" then
		if #v == 0 then
			return "—", field.name == "conf_files" and "(prj.conf)" or nil
		end
		return list_text(field, v)
	elseif field.name == "optimization" then
		return v or "default"
	end
	return v or "—"
end

local function pad(text, width)
	return text .. (" "):rep(math.max(1, width - vim.fn.strdisplaywidth(text)))
end

local function title(form)
	local name = form.cfg and form.cfg.name or "New build configuration"
	return (" %s · %s %s"):format(name, form.app.name, form.dirty and "[+] " or "")
end

local function render(form)
	local buf = form.buf
	local lines, hints = {}, {}
	for i, f in ipairs(settings.fields) do
		local value, hint = show(form, f)
		local line = pad(f.label, LABEL_WIDTH) .. value
		if hint then
			hints[i] = #pad(line, LABEL_WIDTH + VALUE_WIDTH)
			line = pad(line, LABEL_WIDTH + VALUE_WIDTH) .. hint
		end
		lines[i] = line
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for i, f in ipairs(settings.fields) do
		if hints[i] then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, hints[i], { end_col = #lines[i], hl_group = "Comment" })
		end
		if form.errors[f.name] then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
				virt_text = { { "  " .. form.errors[f.name], "DiagnosticError" } },
				virt_text_pos = "eol",
			})
		end
	end
	if vim.api.nvim_win_is_valid(form.win) then
		vim.api.nvim_win_set_config(form.win, { title = title(form), title_pos = "center" })
	end
end

-- Editing ---------------------------------------------------------------------

local list_boards

local function set(form, name, value)
	form.s[name] = value
	form.dirty = true
	form.errors = {}
	render(form)
	if name == "board_roots" then
		list_boards(form)
	end
end

-- The toggle picker of a list: `Done` first, then every item with `✓` when chosen.
local function toggle_list(form, field)
	local chosen = form.s[field.name]
	local items = { "Done" }
	local values = M.candidates(form, field.name)
	for _, v in ipairs(chosen) do
		if not vim.tbl_contains(values, v) then
			table.insert(values, v) -- no longer a candidate, but it can still be removed
		end
	end
	for _, v in ipairs(values) do
		table.insert(items, (vim.tbl_contains(chosen, v) and "✓ " or "  ") .. v)
	end
	vim.ui.select(items, { prompt = field.label, kind = "zephyr." .. field.name }, function(_, idx)
		if not idx or idx == 1 or not vim.api.nvim_buf_is_valid(form.buf) then
			return
		end
		local v = values[idx - 1]
		local new = vim.tbl_filter(function(c)
			return c ~= v
		end, chosen)
		if #new == #chosen then
			table.insert(new, v)
		end
		set(form, field.name, new)
		toggle_list(form, field)
	end)
end

local function pick_one(form, field)
	if field.name == "board" and not form.boards then
		return notify("still listing boards ...", vim.log.levels.WARN)
	end
	local items = M.candidates(form, field.name)
	if #items == 0 then
		return notify("nothing to pick for " .. field.label, vim.log.levels.WARN)
	end
	local refs = field.kind == "toolchain" and require("zephyr.toolchain").ranked(form.app.workspace)
	vim.ui.select(items, { prompt = field.label, kind = "zephyr." .. field.name }, function(choice, idx)
		if not choice or not vim.api.nvim_buf_is_valid(form.buf) then
			return
		end
		if refs then
			choice = require("zephyr.toolchain").ref(refs[idx])
		elseif field.name == "optimization" and choice == "default" then
			choice = nil
		end
		set(form, field.name, choice)
	end)
end

local function type_in(form, field)
	local v = form.s[field.name]
	local text = field.kind == "list" and list_text(field, v) or (v or "")
	vim.ui.input({
		prompt = field.label .. ": ",
		default = text,
		completion = field.name == "board_roots" and "dir" or nil,
	}, function(input)
		if not input or not vim.api.nvim_buf_is_valid(form.buf) then
			return
		end
		if field.name == "cmake_args" then
			set(form, field.name, build_config.split_words(input))
		elseif field.kind == "list" then
			set(form, field.name, vim.tbl_filter(function(item)
				return item ~= ""
			end, vim.tbl_map(vim.trim, vim.split(input, ",", { plain = true }))))
		else
			input = vim.trim(input)
			set(form, field.name, input ~= "" and input or nil)
		end
	end)
end

local function field_under_cursor(form)
	return settings.fields[vim.api.nvim_win_get_cursor(form.win)[1]]
end

local function change(form, field)
	if field.kind == "bool" then
		set(form, field.name, not form.s[field.name])
	elseif typed[field.name] then
		type_in(form, field)
	elseif field.kind == "list" then
		toggle_list(form, field)
	else
		pick_one(form, field)
	end
end

local function reset(form, field)
	set(form, field.name, field.kind == "list" and {} or field.default)
end

local function close(form)
	if vim.api.nvim_win_is_valid(form.win) then
		vim.api.nvim_win_close(form.win, true)
	end
end

local function save(form)
	local app = form.app
	-- An unset build directory is named after the board.
	local s = build_config.defaults(app, form.s)
	local errs = build_config.validate(app, s)
	if #errs > 0 then
		form.errors = {}
		for _, e in ipairs(errs) do
			local name, msg = e:match("^([%w_]+): (.*)$")
			if name then
				form.errors[name] = msg
			end
		end
		render(form)
		return notify("not saved:\n" .. table.concat(errs, "\n"), vim.log.levels.ERROR)
	end
	local old = form.cfg and form.cfg.settings
	local cfg = form.cfg and build_config.save(app, s, form.cfg.dir) or build_config.new(app, s)
	close(form)
	if form.on_save then
		form.on_save(cfg, old)
	end
end

-- List the boards for the panel's board roots, then call `then_`.
function list_boards(form, then_)
	form.boards = nil
	build_config.boards(form.app, function(boards, err)
		if err then
			notify(err, vim.log.levels.WARN)
		end
		form.boards = boards or {}
		if then_ and vim.api.nvim_buf_is_valid(form.buf) then
			then_()
		end
	end, form.s)
end

---Open the settings panel for `opts.cfg` of `app`, or for a new Build
---configuration, which starts with the board picker. `on_save` runs after the
---panel has closed.
---@param app zephyr.App
---@param opts? { cfg?: zephyr.BuildConfig, on_save?: fun(cfg: zephyr.BuildConfig, old: zephyr.BuildSettings|nil) }
function M.open(app, opts)
	opts = opts or {}
	local cfg = opts.cfg
	local s
	if cfg then
		s = cfg.settings or build_config.settings_from_disk(app, cfg)
		cfg = vim.tbl_extend("force", cfg, { settings = s })
	else
		s = build_config.defaults(app, {})
		s.build_dir = nil -- follows the board until it is set
	end
	local form = { app = app, cfg = cfg, on_save = opts.on_save, s = settings.normalize(s), errors = {} }
	local tc = require("zephyr.toolchain").default(app.workspace)
	form.default_toolchain = tc and toolchain_text(tc)

	local buf = vim.api.nvim_create_buf(false, true)
	form.buf = buf
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local name = ("zephyr://build-config/%s/%s"):format(app.name, cfg and cfg.name or "new")
	if not pcall(vim.api.nvim_buf_set_name, buf, name) then
		pcall(vim.api.nvim_buf_set_name, buf, name .. "-" .. buf)
	end

	local width = math.min(100, math.max(60, math.floor(vim.o.columns * 0.7)))
	local height = #settings.fields
	form.win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = title(form),
		title_pos = "center",
		footer = " <CR>/i change · x reset · <C-s> save · q close · g? help ",
	})
	vim.wo[form.win].cursorline = true
	render(form)
	vim.bo[buf].filetype = "zephyrbuildconfig"
	vim.api.nvim_win_set_cursor(form.win, { 1, 0 }) -- the board

	local function map(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "zephyr: " .. desc })
	end
	local function change_here()
		change(form, field_under_cursor(form))
	end
	map("<CR>", change_here, "change this setting")
	map("i", change_here, "change this setting")
	map("x", function()
		reset(form, field_under_cursor(form))
	end, "reset this setting")
	map("<C-s>", function()
		save(form)
	end, "save and close")
	map("q", function()
		close(form)
	end, "close without saving")
	map("<Esc>", function()
		if form.dirty then
			return notify("unsaved changes: <C-s> saves, q discards them", vim.log.levels.WARN)
		end
		close(form)
	end, "close when unchanged")
	map("g?", function()
		notify("settings panel keys:\n" .. table.concat(keys_help, "\n"))
	end, "show keys")

	list_boards(form, not cfg and function()
		pick_one(form, field_of.board)
	end or nil)
end

return M
