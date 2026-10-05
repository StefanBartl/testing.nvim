-- Fixture (never a spec of this repo). Dialect E: everything that goes wrong outside a plain `it`.
-- luacheck: globals describe it before_each setup teardown assert
---@diagnostic disable: undefined-global

local trace = _G.__TESTING_FIXTURE_TRACE

describe("broken setup block", function()
  setup(function()
    error("setup exploded")
  end)
  it("never gets to pass", function()
    assert.is_true(true)
  end)
end)

describe("raising before_each", function()
  before_each(function()
    error("before_each exploded")
  end)
  it("ends as an error", function()
    assert.is_true(true)
  end)
end)

describe("describe body raises", function()
  error("body exploded")
end)

describe("teardown runs when the block ends", function()
  teardown(function()
    trace[#trace + 1] = "teardown"
  end)
  it("a", function()
    assert.is_true(true)
    trace[#trace + 1] = "a"
  end)
  it("b", function()
    assert.is_true(true)
    trace[#trace + 1] = "b"
  end)
end)
