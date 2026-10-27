-- Default UI for Drift: `:Zephyr update [check | PROJECT...]` and the automatic
-- check on opening a Workspace file. Never updates without asking.
local zephyr = require("zephyr")
local workspace = require("zephyr.workspace")

local M = {}

-- Workspaces (by topdir) already checked automatically this session.
M.checked = {}

local notify = require("zephyr.ui.notify")

local function describe(p)
	return ("%s (%s): %s -> %s"):format(p.name, p.path, p.actual:sub(1, 12), p.expected:sub(1, 12))
end

local function drift_message(drifted)
	local lines = { ("%d project(s) drifted from the Manifest; run :Zephyr update"):format(#drifted) }
	for _, p in ipairs(drifted) do
		table.insert(lines, "  " .. describe(p))
	end
	return table.concat(lines, "\n")
end

---The warning for Pin mismatches, naming both revisions.
---@param mismatches zephyr.PinMismatch[]
---@return string
function M.mismatch_message(mismatches)
	local lines = {}
	for _, m in ipairs(mismatches) do
		table.insert(
			lines,
			("%s is pinned at %s by the Manifest but at %s by %s's west.yml (builds still use %s)"):format(
				m.name,
				m.revision,
				m.imported_revision,
				m.imported_from,
				m.revision
			)
		)
	end
	return table.concat(lines, "\n")
end

local function report_mismatches(mismatches)
	if mismatches and #mismatches > 0 then
		notify(M.mismatch_message(mismatches), vim.log.levels.WARN)
	end
end

---`:Zephyr update check`: report Drift, also when there is none, and Pin mismatches.
---@param ws zephyr.Workspace
function M.check(ws)
	zephyr.drift.check(ws, function(drifted, err, mismatches)
		report_mismatches(mismatches)
		if not drifted then
			return notify("drift check failed: " .. err, vim.log.levels.ERROR)
		end
		if #drifted == 0 then
			notify("no drift: every project is on its Manifest revision")
		else
			notify(drift_message(drifted), vim.log.levels.WARN)
		end
	end)
end

---Check quietly, only telling about Drift and Pin mismatches that were found.
---@param ws zephyr.Workspace
function M.check_quiet(ws)
	zephyr.drift.check(ws, function(drifted, _, mismatches)
		report_mismatches(mismatches)
		if drifted and #drifted > 0 then
			notify(drift_message(drifted), vim.log.levels.WARN)
		end
	end)
end

local function enabled()
	return (zephyr.config.drift or {}).auto_check ~= false
end

---Autocmd hook for a file being opened: check its Workspace once per session.
---@param path string
function M.on_open(path)
	if not enabled() or path == "" or path:match("^%w+://") then
		return
	end
	local ws = workspace.find(path)
	if ws and not M.checked[ws.topdir] then
		M.checked[ws.topdir] = true
		M.check_quiet(ws)
	end
end

---Autocmd hook for a file being written: check again when it is the Manifest.
---@param path string
function M.on_write(path)
	if not enabled() or path == "" or path:match("^%w+://") then
		return
	end
	local ws = workspace.find(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	if ws and path == vim.fs.normalize(ws.manifest_file) then
		M.checked[ws.topdir] = true
		M.check_quiet(ws)
	end
end

---Run `west update`, streaming its output into the Output window.
---@param ws zephyr.Workspace
---@param projects string[]
function M.update(ws, projects)
	local output = require("zephyr.ui.output")
	local cmd = "$ west update" .. (#projects > 0 and (" " .. table.concat(projects, " ")) or "")
	local handle
	local function stop()
		if handle then
			handle.stop()
		end
	end
	local buf = output.open("update", cmd, { stop = stop })
	handle = zephyr.update(ws, {
		projects = projects,
		on_output = function(line)
			output.append(buf, line)
		end,
	}, function(ok, res)
		output.finish(stop)
		output.append(buf, res.stopped and "[stopped]" or (ok and "[done]" or ("[failed, exit " .. res.code .. "]")))
		if res.stopped then
			notify("west update stopped", vim.log.levels.WARN)
		elseif ok then
			notify("west update finished")
		else
			notify(("west update failed (exit %d); see the Output window"):format(res.code), vim.log.levels.ERROR)
		end
	end)
end

---`:Zephyr update [PROJECT...]`: show Drift first, then ask before updating.
---@param ws zephyr.Workspace
---@param projects string[] limit the update to these; empty means all
function M.confirm(ws, projects)
	zephyr.drift.check(ws, function(drifted, err)
		local header
		if not drifted then
			header = "drift check failed: " .. err
		elseif #drifted == 0 then
			header = "no drift detected"
		else
			header = drift_message(drifted):gsub("; run :Zephyr update", "")
		end
		notify(header, drifted and #drifted > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

		local choices = {}
		if #projects > 0 then
			table.insert(choices, { label = "Update " .. table.concat(projects, ", "), projects = projects })
		else
			table.insert(choices, { label = "Update all projects (west update)", projects = {} })
			if drifted and #drifted > 0 then
				local names = vim.tbl_map(function(p)
					return p.name
				end, drifted)
				table.insert(choices, { label = "Update drifted projects only", projects = names })
			end
		end
		table.insert(choices, { label = "Cancel" })
		vim.ui.select(choices, {
			prompt = "west update in " .. ws.topdir,
			format_item = function(c)
				return c.label
			end,
		}, function(choice)
			if choice and choice.projects then
				M.update(ws, choice.projects)
			end
		end)
	end)
end

M.actions = { "check" }
M.any_args = true -- project names to update

---@param args string[]
function M.run(args)
	local ws = workspace.find()
	if not ws then
		return notify("not inside a west workspace", vim.log.levels.ERROR)
	end
	if args[1] == "check" then
		M.check(ws)
	else
		M.confirm(ws, args)
	end
end

return M
