-- Fixture (never a spec of this repository). Dialects a, b and c: the spec asks "does this fail?" with the explicit
-- question, `H.ask`, which answers whatever the stack looks like.
return function(H)
  local ok, err = H.ask(function()
    H.eq(1, 2, "asked")
  end)
  H.eq(ok, false, "the question saw the failed check")
  H.eq(err, "FAIL asked: expected 2, got 1", "with the message of the old harnesses")
  H.eq(1, 1, "the file goes on")
end
