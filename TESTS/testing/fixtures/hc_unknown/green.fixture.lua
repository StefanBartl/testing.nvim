return function(H)
  H.ok(true, "one passing check")
  H.t("fine", function() end)
  H.lazy("fine too", function() end)
  H.quiet("and this", function() end)
end
