return function(H)
  H.ok(true, "one passing check")
  H.lazy("created late", function()
    error("late boom")
  end)
end
