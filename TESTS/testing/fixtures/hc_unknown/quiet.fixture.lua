return function(H)
  H.ok(true, "one passing check")
  H.quiet("only printed", function()
    error("printed boom")
  end)
end
