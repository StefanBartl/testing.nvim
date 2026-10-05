-- TESTS/run.lua -- headless spec runner for testing.nvim (plain Lua, no plugin except lib.nvim).
--
-- Run from anywhere (scripts/test.sh wraps exactly this):
--   nvim -n -i NONE --headless -u NONE -l TESTS/run.lua
-- One spec only (a substring of its file name):
--   nvim -n -i NONE --headless -u NONE -l TESTS/run.lua config
--
-- Specs are TESTS/testing/*_spec.lua; each returns `function(H)` and raises on failure.
-- Exit 0: every spec passed. 1: a spec failed or lib.nvim is missing (see minimal_init.lua).
-- 2: no spec matched the given name(s).

local tests_dir =
  vim.fs.normalize(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

dofile(tests_dir .. "/minimal_init.lua")

local H = dofile(tests_dir .. "/harness.lua")

-- Isolated state: no spec may read or write the real stdpath("state"/"cache"/"data").
vim.env.XDG_STATE_HOME = vim.fn.tempname() .. "-state"
vim.env.XDG_CACHE_HOME = vim.fn.tempname() .. "-cache"

local specs = {}
local spec_dir = tests_dir .. "/testing"
for name, kind in vim.fs.dir(spec_dir) do
  if kind == "file" and name:match("_spec%.lua$") then
    specs[#specs + 1] = name
  end
end
table.sort(specs)

local wanted = {}
for i = 1, #(arg or {}) do
  wanted[#wanted + 1] = arg[i]
end

---Straight to stdout: `print` in a headless Neovim goes through the message area.
---@param s string
local function say(s)
  io.stdout:write(s, "\n")
end

local ran, failed = 0, 0
for _, name in ipairs(specs) do
  local selected = #wanted == 0
  for _, w in ipairs(wanted) do
    if name:find(w, 1, true) then
      selected = true
    end
  end
  if selected then
    ran = ran + 1
    local ok, err = pcall(function()
      dofile(spec_dir .. "/" .. name)(H)
    end)
    if ok then
      say(("ok    %s"):format(name))
    else
      failed = failed + 1
      say(("FAIL  %s\n      %s"):format(name, tostring(err)))
    end
  end
end

if ran == 0 then
  say("no spec matched the given name(s)")
  os.exit(2)
end
if failed > 0 then
  say(("\n%d of %d spec(s) failed"):format(failed, ran))
  os.exit(1)
end
say(("\nTESTING_TESTS_OK (%d spec(s))"):format(ran))
