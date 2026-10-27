local fs = require("zephyr.fs")

describe("fs", function()
	it("reads nil for a missing file", function()
		assert.is_nil(fs.read(vim.fn.tempname() .. "/missing"))
	end)

	it("reads the whole text of a file", function()
		local path = vim.fn.tempname()
		vim.fn.writefile({ "one", "two" }, path)
		assert.are.equal("one\ntwo\n", fs.read(path))
	end)

	it("tells a directory from a file and nil", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local file = dir .. "/f"
		vim.fn.writefile({}, file)
		assert.is_true(fs.is_dir(dir))
		assert.is_false(fs.is_dir(file))
		assert.is_false(fs.is_dir(dir .. "/missing"))
		assert.is_false(fs.is_dir(nil))
	end)
end)
