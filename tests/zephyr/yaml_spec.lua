local yaml = require("zephyr.yaml")

describe("yaml", function()
	it("reads block mappings, sequences of mappings and flow lists", function()
		local doc = yaml.decode(table.concat({
			"manifest:",
			"  projects:",
			"    - name: nrf # a comment",
			"      revision: \"vt-v2.9.2-v1.5\"",
			"      import:",
			"        name-allowlist: [zephyr, 'mcu boot']",
			"    - name: zephyr",
			"      url: https://example.com/a#b",
			"  self:",
			"    path: app",
		}, "\n"))
		assert.are.same({
			manifest = {
				projects = {
					{ name = "nrf", revision = "vt-v2.9.2-v1.5", import = { ["name-allowlist"] = { "zephyr", "mcu boot" } } },
					{ name = "zephyr", url = "https://example.com/a#b" },
				},
				self = { path = "app" },
			},
		}, doc)
	end)

	it("reads booleans, empty values, sequences at the key's indent and block scalars", function()
		local doc = yaml.decode("a: true\nb:\nc: []\nd:\n- x\n- y\ne: |\n  one\n  two\nf: no-bool\n")
		assert.is_true(doc.a)
		assert.is_nil(doc.b)
		assert.are.same({}, doc.c)
		assert.are.same({ "x", "y" }, doc.d)
		assert.are.equal("one\ntwo", doc.e)
		assert.are.equal("no-bool", doc.f)
	end)

	it("gives nil for an empty document", function()
		assert.is_nil(yaml.decode("# nothing\n"))
	end)
end)
