-- Regenerates the golden files of the contract `testing-export/1` from the synthetic fixture fleet.
--
--   nvim -n -i NONE --headless -u NONE -l TESTS/golden/regenerate_export.lua
--
-- A golden file is what a client of `testing-export/1` can rely on byte for byte: a change of one is a change of the
-- contract. Run this on purpose, read `git diff TESTS/golden`, and commit the files together with the code change.
-- The files are the export folder of the fixture as `testing.export.export` returns it (fleet.json,
-- repos/<key>.json, testing-export.json); TESTS/testing/export_contract_spec.lua compares them.

local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local plugin_root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.rtp:prepend(plugin_root)

local deps = require("testing.deps")
local lib = deps.resolve("lib.nvim", plugin_root)
if not lib then
  io.stderr:write("regenerate_export: lib.nvim was not found\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

local fixture = dofile(plugin_root .. "/TESTS/testing/export_fixture.lua")
local base = fixture.base("golden")
local fx = fixture.build(base)
local restore = fixture.install()
local bundle, err = require("testing.export").export(fixture.opts(fx))
restore()
vim.fn.delete(base, "rf")
if not bundle then
  io.stderr:write("regenerate_export: " .. tostring(err) .. "\n")
  os.exit(1)
end

vim.fn.delete(fixture.GOLDEN_DIR, "rf")
local files = vim.list_extend(vim.list_slice(bundle.files, 1), { bundle.manifest })
for _, f in ipairs(files) do
  fixture.write(fixture.GOLDEN_DIR .. "/" .. f.path, f.text)
  io.stdout:write(("wrote %s (%d bytes)\n"):format(f.path, f.bytes))
end
os.exit(0)
