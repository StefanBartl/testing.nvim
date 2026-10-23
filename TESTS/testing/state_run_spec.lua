-- TESTS/testing/state_run_spec.lua -- the stored result (`testing.state`) of a real run belongs to the spec file as it was
-- BEFORE the run: a spec that is saved while the run is going must show as outdated afterwards, never as a current result.
---@diagnostic disable: missing-fields, need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local cli = require("testing.cli")
  local state = require("testing.state")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  local proj = tmp .. "/proj"
  local sdir = tmp .. "/state"
  S.write(proj .. "/.testing.lua", "return { guards = { fs = 'off' }, isolated = 'none' }\n")
  -- the second spec rewrites the first one's file while the run is still going
  S.write(proj .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  S.write(
    proj .. "/TESTS/b_spec.lua",
    ([[
return function(H)
  local f = assert(io.open(%q, "ab"))
  f:write("-- saved during the run, and longer\n")
  f:close()
  H.ok(true, "b")
end
]]):format(proj .. "/TESTS/a_spec.lua")
  )

  local code = cli.main({ proj }, {
    out = function() end,
    err = function() end,
    state_dir = sdir,
    cache_dir = tmp .. "/cache",
    color = false,
  })
  eq(code, 0, "the run is green")
  local st = state.load(proj, { state_dir = sdir })
  ok(#st.cases >= 2, "both specs are in the stored result")
  local stale, why = state.is_stale(st, "TESTS/a_spec.lua")
  ok(stale == true and why == "changed", "the file saved during the run is outdated, not current")
  eq(state.is_stale(st, "TESTS/b_spec.lua"), false, "the file nobody touched is current")
  vim.fn.delete(tmp, "rf")
end
