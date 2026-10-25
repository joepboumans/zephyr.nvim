-- Extension points that vendor plugins register into (see docs/adr/0001).
local M = {}

---@alias zephyr.RegistryKind "toolchain_provider"|"probe_finder"

---Functions each kind of entry must provide.
local required = {
	toolchain_provider = { "find", "env" },
	probe_finder = { "find" },
}

local entries = {}

local function reset()
	for kind in pairs(required) do
		entries[kind] = {}
	end
end
reset()

local function check_kind(kind)
	if not required[kind] then
		error(("zephyr: unknown registry kind '%s'"):format(tostring(kind)), 3)
	end
end

---Register an entry. Registering the same name again replaces it.
---@param kind zephyr.RegistryKind
---@param spec table with a `name` and the functions its kind requires
function M.register(kind, spec)
	check_kind(kind)
	if type(spec) ~= "table" or type(spec.name) ~= "string" then
		error("zephyr: a registry entry needs a string `name`", 2)
	end
	for _, fn in ipairs(required[kind]) do
		if type(spec[fn]) ~= "function" then
			error(("zephyr: %s '%s' must provide %s()"):format(kind, spec.name, fn), 2)
		end
	end
	entries[kind][spec.name] = spec
	require("zephyr.events").emit("Registered", { kind = kind, name = spec.name })
end

---@param kind zephyr.RegistryKind
---@param name string
---@return table|nil
function M.get(kind, name)
	check_kind(kind)
	return entries[kind][name]
end

---@param kind zephyr.RegistryKind
---@return table[] entries sorted by name
function M.list(kind)
	check_kind(kind)
	local out = vim.tbl_values(entries[kind])
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

M._reset = reset

return M
