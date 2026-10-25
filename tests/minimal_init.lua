local plenary = vim.env.PLENARY_DIR or "/tmp/plenary.nvim"
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/zephyr.lua")
