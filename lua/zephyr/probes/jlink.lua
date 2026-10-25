-- J-Link Probe finder: lists connected J-Link Probes with J-Link Commander's
-- `ShowEmuList USB`, run headless from a command file.
local M = {}

---How long find() waits for J-Link Commander before giving up.
M.timeout_ms = 3000

---J-Link Commander's executable on this OS, or nil when it is not on PATH.
---@return string|nil
function M.executable()
	local name = vim.fn.has("win32") == 1 and "JLink.exe" or "JLinkExe"
	return vim.fn.executable(name) == 1 and name or nil
end

---Run `cmd` and wait up to `timeout` ms. The registry's find() is synchronous,
---so this waits on zephyr.process.run; tests stub either one.
---@param cmd string[]
---@param timeout integer milliseconds
---@return vim.SystemCompleted|nil res nil on timeout
function M._run(cmd, timeout)
	local done
	local proc = require("zephyr.process").run(cmd, {}, function(res)
		done = res
	end)
	if
		not vim.wait(timeout, function()
			return done ~= nil
		end, 20)
	then
		if proc then
			pcall(proc.kill, proc, 9)
		end
		return nil
	end
	return done
end

---Parse `ShowEmuList` output. SEGGER does not document the format, so this reads
---each line loosely, e.g.
---`J-Link[0]: Connection: USB, Serial number: 683000000, ProductName: J-Link OB-nRF5340-NordicSemi`.
---@param text string
---@return zephyr.Probe[]
function M.parse(text)
	local out, seen = {}, {}
	for line in vim.gsplit(text or "", "\n", { plain = true }) do
		local serial = line:match("[Ss]erial [Nn]umber:%s*(%d+)") or line:match("S/N:%s*(%d+)")
		if serial then
			serial = serial:gsub("^0+(%d)", "%1")
			local product = line:match("ProductName:%s*([^,\r]-)%s*,") or line:match("ProductName:%s*([^,\r]-)%s*$")
			local nickname = line:match("Nickname:%s*([^,\r]-)%s*,") or line:match("Nickname:%s*([^,\r]-)%s*$")
			local name = (nickname ~= nil and nickname ~= "" and nickname)
				or (product ~= nil and product ~= "" and product)
				or ("J-Link " .. serial)
			if not seen[serial] then
				seen[serial] = true
				table.insert(out, { finder = "jlink", serial = serial, name = name })
			end
		end
	end
	return out
end

M.finder = {
	name = "jlink",
	---Connected J-Link Probes. Blocks for up to `timeout_ms`; returns {} when
	---J-Link Commander is missing, fails or times out.
	---@return zephyr.Probe[]
	find = function()
		local exe = M.executable()
		if not exe then
			return {}
		end
		local script = vim.fn.tempname() .. ".jlink"
		vim.fn.writefile({ "ShowEmuList USB", "exit" }, script)
		local res = M._run({ exe, "-NoGui", "1", "-CommandFile", script }, M.timeout_ms)
		os.remove(script)
		if not res then
			return {}
		end
		return M.parse((res.stdout or "") .. "\n" .. (res.stderr or ""))
	end,
}

return M
