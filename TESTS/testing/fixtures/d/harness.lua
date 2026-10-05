-- Fixture harness of dialect D: a miniature of spotlight.nvim's TESTS/harness.lua (collects failures,
-- counts passes, helpers that call the assertions inside).

local M = {}

M.failures = {}
M.passed = 0

---@param name string
---@param msg string
local function fail(name, msg)
  M.failures[#M.failures + 1] = ("%s: %s"):format(name, msg)
end

function M.ok(name, cond, msg)
  if cond then
    M.passed = M.passed + 1
    return true
  end
  fail(name, msg or "expected a truthy value")
  return false
end

function M.eq(name, got, want)
  if got == want then
    M.passed = M.passed + 1
    return true
  end
  fail(name, ("expected %s, got %s"):format(vim.inspect(want), vim.inspect(got)))
  return false
end

function M.contains(name, haystack, needle)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    M.passed = M.passed + 1
    return true
  end
  fail(name, ("expected %s to contain %s"):format(vim.inspect(haystack), vim.inspect(needle)))
  return false
end

---Helper that runs a callback (which asserts) and re-raises what it raised.
function M.with_modules(mods, fn)
  local saved = {}
  for name, replacement in pairs(mods) do
    saved[name] = package.loaded[name]
    package.loaded[name] = replacement
  end
  local ok, err = pcall(fn)
  for name, old in pairs(saved) do
    package.loaded[name] = old
  end
  if not ok then
    error(err, 0)
  end
end

---Not an assertion: returns a value.
function M.fixture(lines)
  return #lines
end

return M
