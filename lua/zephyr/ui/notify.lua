---Tell the user something from the Default UI, prefixed with "zephyr: ".
---@param msg string
---@param level? integer vim.log.levels, INFO by default
return function(msg, level)
	vim.notify("zephyr: " .. msg, level or vim.log.levels.INFO)
end
