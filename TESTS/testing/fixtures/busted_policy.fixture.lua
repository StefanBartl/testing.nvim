-- Busted cases without assertions: one prints a skip line, one says nothing, one asserts.
-- luacheck: globals describe it assert
---@diagnostic disable: undefined-global

describe("policy", function()
  it("skips by early return", function()
    print("skip  optional sibling not on the runtimepath")
  end)

  it("asserts nothing", function()
    local _ = 1 + 1
  end)

  it("asserts", function()
    assert.equals(1, 1)
  end)
end)
