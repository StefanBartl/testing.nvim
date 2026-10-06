-- TESTS/testing/discover_harness_profile_spec.lua -- the static profile of a project's harness.lua and the
-- question "may a fixed shim stand in for it?" (equivalent / differs / missing).

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local profile_mod = require("testing.discover.harness_profile")

  -- shapes taken from the fleet's harnesses
  local LIB = table.concat({
    "-- TESTS/harness.lua",
    "local H = {}",
    "---@param msg string|nil",
    "function H.eq(a, b, msg)",
    "  if a ~= b then",
    '    error(("FAIL %s: expected %s, got %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)',
    "  end",
    "end",
    "function H.ok(v, msg)",
    "  if not v then",
    '    error(("FAIL %s: expected truthy, got %s"):format(msg or "", vim.inspect(v)), 2)',
    "  end",
    "end",
    "function H.tmpfile(suffix)",
    '  return vim.fn.tempname() .. (suffix or ".tmp")',
    "end",
    "function H.read_lines(path)",
    "  return {}",
    "end",
    "return H",
  }, "\n")
  local p = profile_mod.profile(LIB)
  eq(p.funcs.eq.params, { "a", "b", "msg" }, "eq's parameters")
  eq(p.funcs.tmpfile.params, { "suffix" }, "tmpfile's parameters")
  eq(p.eq, "strict", "eq: a strict comparison")
  eq(p.ok, "truthy", "ok: a truthiness check")
  eq(p.collects, false, "no collector")

  eq(
    profile_mod.verdict(p, "a", { "eq", "ok", "tmpfile", "read_lines" }),
    "equivalent",
    "lib.nvim's harness is dialect a"
  )
  local verdict, reason = profile_mod.verdict(p, "a", { "eq", "with_patched" })
  eq(verdict, "missing", "a helper the harness does not define")
  has(reason, "with_patched", "is named")
  eq(profile_mod.verdict(p, "a", {}), "equivalent", "a file that uses no helper needs none")
  eq(profile_mod.verdict(p, "a", { "eq" }, true), "differs", "an H that escapes cannot be proven")
  eq(profile_mod.verdict(p, "zzz", { "eq" }), "differs", "an unknown dialect has no reference")

  -- tasks.nvim: eq compares tables deeply
  local DEEP = LIB:gsub("if a ~= b then", "if not vim.deep_equal(a, b) then")
  p = profile_mod.profile(DEEP)
  eq(p.eq, "deep", "a deep eq")
  verdict, reason = profile_mod.verdict(p, "a", { "eq" })
  eq(verdict, "differs", "differs from the shim's strict ==")
  has(reason, "deep comparison", "and says so")
  eq(
    profile_mod.verdict(p, "a", { "ok", "tmpfile" }),
    "equivalent",
    "files that never call eq are unaffected"
  )

  -- an `eq` that is not recognisably either
  local TOSTRING = LIB:gsub("if a ~= b then", "if tostring(a) ~= tostring(b) then")
  eq(profile_mod.profile(TOSTRING).eq, "strict", "a comparison with ~= counts as strict")
  local NONE = "local H = {}\nfunction H.eq(a, b)\n  return compare(a, b)\nend\nreturn H\n"
  p = profile_mod.profile(NONE)
  eq(p.eq, "unknown", "an eq without a comparison cannot be read")
  verdict, reason = profile_mod.verdict(p, "a", { "eq" })
  eq(verdict, "differs", "in doubt: differs")
  has(reason, "not recognisably", "and says why")

  -- ok that does not test truthiness
  p = profile_mod.profile("local H = {}\nfunction H.ok(v, msg)\n  return v\nend\nreturn H\n")
  eq(p.ok, "unknown", "an ok that only returns its value is not a check")
  eq(profile_mod.verdict(p, "a", { "ok" }), "differs", "in doubt: differs")

  -- signatures of the other helpers (diff.nvim = b, images.nvim = c, fileops/color_my_ascii = neither)
  local B = LIB .. "\n"
  B = B:gsub("return H\n$", "")
    .. table.concat({
      "function H.scratch(ft)",
      "end",
      "function H.tmpdir()",
      "end",
      "function H.canonical(path)",
      "end",
      "function H.write_file(path, lines)",
      "end",
      "return H",
    }, "\n")
  p = profile_mod.profile(B)
  eq(
    profile_mod.verdict(p, "b", { "eq", "scratch", "tmpdir", "canonical", "write_file" }),
    "equivalent",
    "diff.nvim's helpers are dialect b"
  )
  local C = LIB:gsub("return H$", "")
    .. table.concat({
      "function H.scratch(lines, ft)",
      "end",
      "function H.tmpdir(fn)",
      "end",
      "function H.write(path, content)",
      "end",
      "function H.falsy(v, msg)",
      "end",
      "function H.contains(haystack, needle, msg)",
      "end",
      "return H",
    }, "\n")
  p = profile_mod.profile(C)
  eq(
    profile_mod.verdict(p, "c", { "scratch", "tmpdir", "write", "falsy", "contains" }),
    "equivalent",
    "images.nvim's helpers are dialect c"
  )
  eq(
    profile_mod.verdict(p, "b", { "scratch" }),
    "differs",
    "scratch(lines, ft) is not b's scratch(ft)"
  )
  eq(profile_mod.verdict(p, "b", { "tmpdir" }), "differs", "tmpdir(fn) is not b's tmpdir()")

  local FILEOPS =
    B:gsub("function H.write_file%(path, lines%)", "function H.write_file(path, content)")
  verdict, reason = profile_mod.verdict(profile_mod.profile(FILEOPS), "b", { "write_file" })
  eq(verdict, "differs", "fileops' write_file(path, content) is not b's write_file(path, lines)")
  has(reason, "write_file(path, content)", "both signatures are shown")
  local COLOR = B:gsub("function H.scratch%(ft%)", "function H.scratch(ft, lines)")
  eq(
    profile_mod.verdict(profile_mod.profile(COLOR), "b", { "scratch" }),
    "differs",
    "color_my_ascii's scratch(ft, lines) is not b's scratch(ft)"
  )

  -- definition forms
  p = profile_mod.profile(
    "local M = {}\nM.eq = function(x, y)\n  if x ~= y then error('FAIL') end\nend\nfunction M:ok(v)\n  if not v then error('FAIL') end\nend\nreturn M\n"
  )
  eq(p.funcs.eq.params, { "x", "y" }, "M.name = function(...) is read")
  eq(p.funcs.ok.params, { "v" }, "function M:name(...) is read")
  eq(p.eq, "strict", "and classified")
  eq(
    profile_mod.profile("-- function H.eq(a, b)\nlocal s = 'function H.ok(v)'\nreturn {}").funcs,
    {},
    "a function in a comment or a string is no definition"
  )
  eq(
    profile_mod.profile(
      "\239\187\191local H = {}\nfunction H.ok(v) if not v then end end\nreturn H"
    ).ok,
    "truthy",
    "a BOM is skipped"
  )
  p = profile_mod.profile(
    "local H = {}\nH.failures = {}\nfunction H.check(n, f) pcall(f) end\nreturn H\n"
  )
  eq(p.collects, true, "check plus failures: the harness collects itself")
  eq(profile_mod.profile("").funcs, {}, "an empty text has no functions")
end
