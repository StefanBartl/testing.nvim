-- Fixture (never a spec of this repo). The first of two files that share one harness table: it leaves a helper
-- of its own in it (a `pcall` that keeps the error) and passes. The helper's chunk is this file's, not the
-- harness's: the next file must not treat its protected call as a cleanup that raises again.

return function(H)
  H.swallow = function(fn)
    local ok = pcall(fn)
    return ok
  end
  H.eq(1, 1, "holds")
end
