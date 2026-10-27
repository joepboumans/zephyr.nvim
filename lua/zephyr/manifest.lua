-- Reads a Workspace's Manifest (west.yml) from disk, without running west:
-- its projects, the revisions they are pinned at, and the Manifests they import.
local yaml = require("zephyr.yaml")

local M = {}

---@class zephyr.ManifestProject
---@field name string
---@field path string relative to the Workspace topdir (defaults to the name)
---@field revision string|nil as written, else the Manifest's default revision
---@field import any the project's `import:` value (true, a file, a mapping), if any

---@class zephyr.Manifest
---@field file string
---@field projects zephyr.ManifestProject[]
---@field default_revision string|nil `defaults: revision:`
---@field self_path string|nil `self: path:`

---Parse Manifest text.
---@param text string
---@param file? string where it came from
---@return zephyr.Manifest
function M.parse(text, file)
	local doc = yaml.decode(text) or {}
	local m = type(doc) == "table" and type(doc.manifest) == "table" and doc.manifest or {}
	local defaults = type(m.defaults) == "table" and m.defaults or {}
	local out = {
		file = file,
		projects = {},
		default_revision = type(defaults.revision) == "string" and defaults.revision or nil,
		self_path = type(m.self) == "table" and m.self.path or nil,
	}
	for _, p in ipairs(type(m.projects) == "table" and m.projects or {}) do
		if type(p) == "table" and type(p.name) == "string" then
			table.insert(out.projects, {
				name = p.name,
				path = type(p.path) == "string" and p.path or p.name,
				revision = type(p.revision) == "string" and p.revision or out.default_revision,
				import = p.import,
			})
		end
	end
	return out
end

---Read and parse a Manifest file.
---@param file string
---@return zephyr.Manifest|nil, string|nil err
function M.read(file)
	local fd = io.open(file, "r")
	if not fd then
		return nil, "cannot read " .. file
	end
	local text = fd:read("*a")
	fd:close()
	local ok, res = pcall(M.parse, text, file)
	if not ok then
		return nil, res
	end
	return res
end

---The Workspace's own Manifest.
---@param workspace zephyr.Workspace
---@return zephyr.Manifest|nil, string|nil err
function M.of(workspace)
	return M.read(workspace.manifest_file)
end

---The project called `name` in `manifest`.
---@param manifest zephyr.Manifest
---@param name string
---@return zephyr.ManifestProject|nil
function M.project(manifest, name)
	for _, p in ipairs(manifest.projects) do
		if p.name == name then
			return p
		end
	end
	return nil
end

---Absolute path of a project's checkout.
---@param workspace zephyr.Workspace
---@param project zephyr.ManifestProject
---@return string
function M.project_dir(workspace, project)
	return vim.fs.joinpath(workspace.topdir, project.path)
end

---The Manifest file a project's `import:` points at, or nil when it imports nothing.
---@param workspace zephyr.Workspace
---@param project zephyr.ManifestProject
---@return string|nil
function M.import_file(workspace, project)
	local imp = project.import
	local file
	if imp == true then
		file = "west.yml"
	elseif type(imp) == "string" then
		file = imp
	elseif type(imp) == "table" then
		file = type(imp.file) == "string" and imp.file or "west.yml"
	end
	return file and vim.fs.joinpath(M.project_dir(workspace, project), file) or nil
end

---@class zephyr.PinMismatch
---@field name string the project pinned twice, e.g. "zephyr"
---@field revision string what the Workspace's Manifest pins
---@field imported_revision string what the imported Manifest pins
---@field imported_from string the project whose Manifest was imported, e.g. "nrf"
---@field imported_file string that Manifest's path

---Pin mismatches: projects the Workspace's Manifest pins at another revision
---than a Manifest it imports pins them. Imported Manifests are read from their
---checkouts; one that is missing is skipped.
---@param workspace zephyr.Workspace
---@return zephyr.PinMismatch[]
function M.pin_mismatches(workspace)
	local top = M.of(workspace)
	if not top then
		return {}
	end
	local out = {}
	for _, importer in ipairs(top.projects) do
		local file = M.import_file(workspace, importer)
		local imported = file and M.read(file)
		if imported then
			for _, q in ipairs(imported.projects) do
				local p = M.project(top, q.name)
				if p and p ~= importer and p.revision and q.revision and p.revision ~= q.revision then
					table.insert(out, {
						name = q.name,
						revision = p.revision,
						imported_revision = q.revision,
						imported_from = importer.name,
						imported_file = file,
					})
				end
			end
		end
	end
	return out
end

return M
