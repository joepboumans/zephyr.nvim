-- Detects Drift: projects whose checkout is not on the revision the Manifest
-- names, and Pin mismatches: projects the Manifest pins differently from a
-- Manifest it imports.
-- Portable across west versions: list projects with `west list`, then compare
-- `HEAD` with `manifest-rev` (set by the last `west update`) in each checkout.
local process = require("zephyr.process")
local events = require("zephyr.events")

local M = {}

-- `{sha}` is avoided: it aborts on uncloned projects and is slow. A literal `|`
-- separates fields because west does not interpret `\t`.
M.list_format = "{name}|{path}|{abspath}|{revision}|{cloned}"

-- How many `git rev-parse` run at once.
M.concurrency = 8

---@class zephyr.WestProject
---@field name string
---@field path string relative to the Workspace topdir
---@field abspath string
---@field revision string as written in the Manifest
---@field cloned boolean

---@class zephyr.DriftedProject
---@field name string
---@field path string
---@field abspath string
---@field expected string commit the Manifest names
---@field actual string commit checked out (HEAD)

---Parse `west list -f M.list_format` output. The manifest repository is left
---out: it has no manifest-rev.
---@param text string
---@return zephyr.WestProject[]
function M.parse_list(text)
	local out = {}
	for line in vim.gsplit(text or "", "\n", { plain = true }) do
		local f = vim.split(vim.trim(line), "|", { plain = true })
		if #f >= 5 and f[1] ~= "manifest" then
			table.insert(out, {
				name = f[1],
				path = f[2],
				abspath = f[3],
				revision = f[4],
				cloned = f[5] == "cloned",
			})
		end
	end
	return out
end

local function is_sha(rev)
	return rev and #rev >= 7 and #rev <= 40 and rev:match("^%x+$") ~= nil
end

---Compare one project's HEAD with its manifest-rev. When the Manifest pins a
---SHA it is used as the expected commit, which also catches a Manifest edited
---since the last `west update`.
---@param project zephyr.WestProject
---@param cb fun(drifted: zephyr.DriftedProject|nil)
function M.compare(project, cb)
	local cmd = { "git", "-C", project.abspath, "rev-parse", "HEAD", "manifest-rev^{commit}" }
	process.run(cmd, {}, function(res)
		local lines = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
		if res.code ~= 0 or #lines < 2 then
			return cb(nil) -- not cloned, or never updated: nothing to compare
		end
		local head, manifest_rev = vim.trim(lines[1]), vim.trim(lines[2])
		local expected = manifest_rev
		if is_sha(project.revision) and not vim.startswith(manifest_rev, project.revision:lower()) then
			expected = project.revision:lower()
		end
		if vim.startswith(head, expected) then
			return cb(nil)
		end
		cb({ name = project.name, path = project.path, abspath = project.abspath, expected = expected, actual = head })
	end)
end

---Run `fn(item, done)` over `items` with at most `limit` running at once.
local function each_limited(items, limit, fn, on_all)
	local results, next_i, running, finished = {}, 1, 0, 0
	if #items == 0 then
		return on_all(results)
	end
	local function start()
		while running < limit and next_i <= #items do
			local i = next_i
			next_i, running = next_i + 1, running + 1
			fn(items[i], function(value)
				results[i] = value or false
				running, finished = running - 1, finished + 1
				if finished == #items then
					on_all(results)
				else
					start()
				end
			end)
		end
	end
	start()
end

---Pin mismatches of `workspace` (see zephyr.manifest.pin_mismatches); never raises.
---@param workspace zephyr.Workspace
---@return zephyr.PinMismatch[]
function M.pin_mismatches(workspace)
	if not workspace.manifest_file then
		return {}
	end
	local ok, found = pcall(require("zephyr.manifest").pin_mismatches, workspace)
	return ok and found or {}
end

---Find drifted projects and Pin mismatches in `workspace` without blocking.
---Fires `ZephyrDriftDetected` ({ workspace, projects, pin_mismatches }) when
---any project drifted or is pinned differently by an imported Manifest. Pin
---mismatches are only reported; they never block anything.
---@param workspace zephyr.Workspace
---@param cb fun(drifted: zephyr.DriftedProject[]|nil, err: string|nil, mismatches: zephyr.PinMismatch[])
---drifted is nil when west fails
function M.check(workspace, cb)
	cb = cb or function() end
	local mismatches = M.pin_mismatches(workspace)
	process.run({ "west", "list", "-f", M.list_format }, { cwd = workspace.topdir }, function(res)
		if res.code ~= 0 then
			local err = vim.trim((res.stderr or "") ~= "" and res.stderr or res.stdout or "")
			if #mismatches > 0 then
				events.emit("DriftDetected", { workspace = workspace.topdir, projects = {}, pin_mismatches = mismatches })
			end
			return cb(nil, err ~= "" and err or "west list failed", mismatches)
		end
		local projects = vim.tbl_filter(function(p)
			return p.cloned
		end, M.parse_list(res.stdout))
		each_limited(projects, M.concurrency, M.compare, function(results)
			local drifted = vim.tbl_filter(function(r)
				return r ~= false
			end, results)
			if #drifted > 0 or #mismatches > 0 then
				events.emit(
					"DriftDetected",
					{ workspace = workspace.topdir, projects = drifted, pin_mismatches = mismatches }
				)
			end
			cb(drifted, nil, mismatches)
		end)
	end)
end

return M
