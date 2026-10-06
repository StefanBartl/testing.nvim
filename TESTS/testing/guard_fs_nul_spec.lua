-- TESTS/testing/guard_fs_nul_spec.lua -- the fs guard lets only the Windows null device through: exactly `nul`
-- (or its `\.\` / `//./` forms) and only on Windows; a file named `nul` anywhere else is judged like any other.

return function(H)
  local ok, eq = H.ok, H.eq
  local fs = require("testing.guard.fs")

  eq(fs.is_null_device("nul", true), true, "nul on Windows")
  eq(fs.is_null_device("NUL", true), true, "case-insensitive")
  eq(fs.is_null_device("\\\\.\\nul", true), true, "the backslash device form")
  eq(fs.is_null_device("//./nul", true), true, "//./nul")
  eq(fs.is_null_device("nul", false), false, "a file called nul is an ordinary file off Windows")
  eq(fs.is_null_device("/home/u/nul", false), false, "no exception for /home/u/nul on POSIX")
  eq(fs.is_null_device("/home/u/nul", true), false, "nor for a path below a directory")
  eq(fs.is_null_device("C:/proj/nul", true), false, "nor for C:/proj/nul")
  eq(fs.is_null_device("nul.txt", true), false, "nor for nul.txt")
  eq(fs.is_null_device(nil, true), false, "a non-string is not the device")

  -- the guard itself: a resolved key that ends in `nul` is no longer allowed
  ---@diagnostic disable-next-line: missing-fields
  local g = fs.new({ cfg = { tmp = {} } }, { allow = {}, allow_patterns = {}, mode = "error" })
  g.allowed = {}
  eq(g:is_allowed("/home/u/nul"), false, "is_allowed does not know a `nul` exception any more")
  ok(true, "done")
end
