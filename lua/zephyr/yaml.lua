-- A small YAML reader for the files zephyr.nvim needs to read (west.yml,
-- build_info.yml): block mappings and sequences, flow `[...]` and `{...}`,
-- quoted and plain scalars, comments and block scalars (`|`, `>`, without
-- blank lines inside).
-- Anchors, tags and multiple documents are not supported.
local M = {}

local function strip_comment(s)
	local quote
	for i = 1, #s do
		local c = s:sub(i, i)
		if quote then
			if c == quote then
				quote = nil
			end
		elseif c == '"' or c == "'" then
			quote = c
		elseif c == "#" and (i == 1 or s:sub(i - 1, i - 1):match("%s")) then
			return (s:sub(1, i - 1):gsub("%s+$", ""))
		end
	end
	return (s:gsub("%s+$", ""))
end

local function unquote(s)
	local d = s:match('^"(.*)"$')
	if d then
		return (d:gsub('\\(.)', { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }))
	end
	local q = s:match("^'(.*)'$")
	if q then
		return (q:gsub("''", "'"))
	end
	return nil
end

-- Parse a flow collection or scalar starting at `pos` of `s`.
local function flow(s, pos)
	pos = s:find("%S", pos) or #s + 1
	local c = s:sub(pos, pos)
	if c == "[" or c == "{" then
		local is_map, out = c == "{", {}
		pos = pos + 1
		while true do
			pos = s:find("%S", pos) or #s + 1
			local ch = s:sub(pos, pos)
			if ch == "]" or ch == "}" or ch == "" then
				return out, pos + 1
			end
			if ch == "," then
				pos = pos + 1
			elseif is_map then
				local key
				key, pos = flow(s, pos)
				pos = s:find("%S", pos) or #s + 1
				local value = nil
				if s:sub(pos, pos) == ":" then
					value, pos = flow(s, pos + 1)
				end
				out[tostring(key)] = value
			else
				local value
				value, pos = flow(s, pos)
				table.insert(out, value)
			end
		end
	end
	if c == '"' or c == "'" then
		local i = pos + 1
		while i <= #s do
			local ch = s:sub(i, i)
			if ch == "\\" and c == '"' then
				i = i + 1
			elseif ch == c then
				if c == "'" and s:sub(i + 1, i + 1) == "'" then
					i = i + 1
				else
					break
				end
			end
			i = i + 1
		end
		return unquote(s:sub(pos, i)), i + 1
	end
	-- Plain scalar inside a flow collection: up to `,`, `]`, `}` or `: `.
	local stop = pos
	while stop <= #s do
		local ch = s:sub(stop, stop)
		if ch == "," or ch == "]" or ch == "}" or (ch == ":" and s:sub(stop + 1, stop + 1):match("[%s]")) then
			break
		end
		stop = stop + 1
	end
	return M.scalar(vim.trim(s:sub(pos, stop - 1))), stop
end

---Turn a scalar's text into a Lua value: booleans and null are converted, everything else stays a string.
---@param s string
---@return any
function M.scalar(s)
	if s == "" or s == "~" or s == "null" or s == "Null" or s == "NULL" then
		return nil
	end
	if s == "true" or s == "True" or s == "TRUE" then
		return true
	end
	if s == "false" or s == "False" or s == "FALSE" then
		return false
	end
	local q = unquote(s)
	if q then
		return q
	end
	local first = s:sub(1, 1)
	if first == "[" or first == "{" then
		return (flow(s, 1))
	end
	return s
end

local parse_node

local function is_item(text)
	return text == "-" or text:sub(1, 2) == "- "
end

-- `key: rest`, `key:`; keys may be quoted.
local function split_key(text)
	local key, rest = text:match('^(".-"):%s+(.*)$')
	if not key then
		key, rest = text:match("^('.-'):%s+(.*)$")
	end
	if not key then
		key = text:match('^(".-"):$') or text:match("^('.-'):$")
		rest = key and ""
	end
	if not key then
		key, rest = text:match("^([^%s#][^:]-):%s+(.*)$")
	end
	if not key then
		key = text:match("^([^%s#][^:]-):$")
		rest = key and ""
	end
	if not key then
		return nil
	end
	return unquote(key) or vim.trim(key), rest
end

local function block_scalar(lines, i, indent, style)
	local parts = {}
	while lines[i] and lines[i].indent > indent do
		table.insert(parts, lines[i].raw:sub(indent + 3))
		i = i + 1
	end
	local sep = style:sub(1, 1) == ">" and " " or "\n"
	return table.concat(parts, sep), i
end

-- Value after `key:` or `- `, which may be inline or on the following lines.
local function value_after(lines, i, indent, rest, allow_same_indent_seq)
	if rest:match("^[|>][-+]?%d*$") then
		return block_scalar(lines, i + 1, indent, rest)
	end
	if rest ~= "" then
		return M.scalar(rest), i + 1
	end
	local nxt = lines[i + 1]
	if nxt and (nxt.indent > indent or (allow_same_indent_seq and nxt.indent == indent and is_item(nxt.text))) then
		return parse_node(lines, i + 1, nxt.indent)
	end
	return nil, i + 1
end

local function parse_map(lines, i, indent)
	local out = {}
	while lines[i] and lines[i].indent == indent and not is_item(lines[i].text) do
		local key, rest = split_key(lines[i].text)
		if not key then
			i = i + 1
		else
			out[key], i = value_after(lines, i, indent, rest, true)
		end
	end
	return out, i
end

local function parse_seq(lines, i, indent)
	local out = {}
	while lines[i] and lines[i].indent == indent and is_item(lines[i].text) do
		local rest = vim.trim(lines[i].text:sub(2))
		if rest ~= "" and not rest:match("^[%[{\"']") and split_key(rest) then
			-- `- key: value` starts a mapping indented to where `key` begins.
			local offset = #lines[i].text - #rest
			lines[i] = { indent = indent + offset, text = rest, raw = lines[i].raw }
			local value
			value, i = parse_map(lines, i, indent + offset)
			table.insert(out, value)
		else
			local value
			value, i = value_after(lines, i, indent, rest, false)
			out[#out + 1] = value
		end
	end
	return out, i
end

parse_node = function(lines, i, indent)
	if is_item(lines[i].text) then
		return parse_seq(lines, i, indent)
	end
	if not split_key(lines[i].text) then
		return M.scalar(lines[i].text), i + 1
	end
	return parse_map(lines, i, indent)
end

---Parse YAML text.
---@param text string
---@return any value nil for an empty document
function M.decode(text)
	local lines = {}
	for raw in vim.gsplit(text or "", "\n", { plain = true }) do
		raw = raw:gsub("\r$", ""):gsub("\t", "  ")
		local stripped = strip_comment(raw)
		if not stripped:match("^%s*$") and not stripped:match("^%-%-%-") and not stripped:match("^%.%.%.") then
			local indent = #stripped:match("^%s*")
			table.insert(lines, { indent = indent, text = stripped:sub(indent + 1), raw = raw })
		end
	end
	if #lines == 0 then
		return nil
	end
	return (parse_node(lines, 1, lines[1].indent))
end

---Read and parse a YAML file.
---@param path string
---@return any|nil value, string|nil err
function M.read(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil, "cannot read " .. path
	end
	local text = fd:read("*a")
	fd:close()
	local ok, value = pcall(M.decode, text)
	if not ok then
		return nil, ("cannot parse %s: %s"):format(path, value)
	end
	return value
end

return M
