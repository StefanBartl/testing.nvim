-- TESTS/testing/guard_deprecation_spec.lua -- the deprecation guard in a REAL child editor: warn by
-- default, error under strict / mode error, each API once per case, nothing when unused or off.

return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("deprecation")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
    eq(c.body_error, nil, name .. ": the scenario body itself ran without an error")
  end

  local c = r.red_deprecated_default_warn
  eq(#c.findings, 2, "two different APIs, the repeated one is reported once")
  eq(c.findings[1].id, "deprecation.used", "stable id")
  eq(c.findings[1].severity, "warn", "default severity is warn")
  eq(c.findings[1].count, 2, "the repetition is counted")
  ok(
    S.find(
      c,
      "deprecation.used",
      { "vim.old_function()", "use vim.new_function() instead", "Nvim 0.13" }
    ) ~= nil,
    "the finding names the API, the alternative and the removal version"
  )
  ok(
    S.find(c, "deprecation.used", { "other.thing", "plugin.nvim 2.0" }) ~= nil,
    "plugin deprecations too"
  )
  eq(c.collect.effects.deprecations ~= nil, true, "the ledger lists the deprecations")

  eq(r.red_strict_is_error.findings[1].severity, "error", "strict: error")
  eq(r.red_mode_error.findings[1].severity, "error", "mode error: error")

  eq(r.green_no_deprecated_api.findings, {}, "no deprecated API, no finding")
  eq(r.green_mode_off.value.patched, false, "mode off installs nothing")
end
