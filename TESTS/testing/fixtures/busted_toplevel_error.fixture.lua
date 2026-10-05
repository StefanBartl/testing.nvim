-- Fixture (never a spec of this repo). Dialect E: top-level code raises after one case ran.
-- luacheck: globals describe it assert
---@diagnostic disable: undefined-global

describe("before the error", function()
  it("ran", function()
    assert.is_true(true)
  end)
end)

error("top-level boom")
