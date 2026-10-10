-- Fixture (never a spec of this repo). The second file on the shared harness table: the failed check runs
-- inside the helper that the first file left behind, which swallows what is raised. The check is not the
-- spec's question (the `pcall` of the spec is further out), so it must be recorded.

return function(H)
  pcall(function()
    H.swallow(function()
      H.eq(1, 2, "swallowed by a helper another file left behind") -- MARK:t1
    end)
  end)
  H.eq(1, 1, "holds")
end
