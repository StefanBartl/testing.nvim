return function(H)
  H.ok(true, "one passing check")
  H.t("secretly broken", function()
    error("boom")
  end)
end
