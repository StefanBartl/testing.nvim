-- The spec writes a failure into the harness' own list without any wrapped call: the adapter did not
-- see it, the reconciliation must still make the file red.

return function(H)
  H.eq(1, 1, "a normal pass")
  H.failures[#H.failures + 1] = "recorded behind the adapter's back"
end
