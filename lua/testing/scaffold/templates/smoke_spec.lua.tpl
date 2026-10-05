-- TESTS/@@PLUGIN@@/load_spec.lua -- the module of the plugin loads. A starting point: replace it
-- with real specs. `H` is the harness testing.nvim hands to a `return function(H) ... end` spec.

return function(H)
  local ok, err = pcall(require, @@PLUGIN|lua@@)
  H.ok(ok, "require(" .. @@PLUGIN|lua@@ .. ") loads: " .. tostring(err))
end
