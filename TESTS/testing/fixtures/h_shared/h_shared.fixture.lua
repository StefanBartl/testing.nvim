-- Fixture (never a spec of this repo). The spec leaves a helper of its own in the shared harness table, then
-- asks "does this fail?" with its own pcall. The helper's chunk is the spec's: it must not become part of the
-- harness for the next run of the same file. Both checks hold, on every run.

return function(H)
  H.spec_helper = function(fn)
    local ok = pcall(fn)
    return ok
  end
  local ok = pcall(function()
    H.eq(1, 2, "asked on a shared harness")
  end)
  H.eq(ok, false, "the spec's pcall is answered")
  H.eq(type(H.spec_helper), "function", "the helper is in the table")
end
