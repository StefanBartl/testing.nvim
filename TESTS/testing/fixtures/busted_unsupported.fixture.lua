-- Fixture (never a spec of this repo). Dialect E: constructs the shim does not implement must fail
-- loudly and name themselves; they must never pass.
-- luacheck: globals describe it assert stub spy
---@diagnostic disable: undefined-global
---@diagnostic disable: param-type-mismatch, missing-parameter

describe("unsupported", function()
  it("uses a luassert stub", function()
    stub(_G, "print")
  end)

  it("uses a luassert spy", function()
    spy.on(_G, "print")
  end)

  it("uses an assertion that does not exist here", function()
    assert.are.unique({ 1, 2 })
  end)

  it("uses assert.spy", function()
    assert.spy(print).was.called()
  end)
end)
