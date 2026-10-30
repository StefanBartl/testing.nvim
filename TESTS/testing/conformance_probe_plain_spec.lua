-- TESTS/testing/conformance_probe_plain_spec.lua -- the facts the probe sends over msgpack: a function or userdata
-- becomes `true` (it is there), `vim.NIL` becomes nil (it is "no value", not a present one).

return function(H)
  local ok = H.ok
  local plain = require("testing.conformance.probe")._plain

  local out = plain({
    callback = function() end,
    nothing = vim.NIL,
    name = "x",
    nested = { inner = vim.NIL, fn = print },
  })
  ok(out.callback == true, "a function becomes true")
  ok(out.nothing == nil, "vim.NIL becomes nil, not true (got " .. vim.inspect(out.nothing) .. ")")
  ok(out.name == "x", "a string is kept")
  ok(out.nested.inner == nil, "vim.NIL below a table becomes nil as well")
  ok(out.nested.fn == true, "a function below a table becomes true")
  ok(plain(vim.NIL) == nil, "a bare vim.NIL becomes nil")
end
