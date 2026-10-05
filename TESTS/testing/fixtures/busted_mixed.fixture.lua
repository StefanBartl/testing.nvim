-- Fixture (never a spec of this repo). Dialect E (plenary.busted): nested describes, hooks, every
-- status the shim can produce. Hook order is written to _G.__TESTING_FIXTURE_TRACE.
-- luacheck: globals describe it before_each after_each pending assert
---@diagnostic disable: undefined-global

local trace = _G.__TESTING_FIXTURE_TRACE

describe("outer", function()
  before_each(function()
    trace[#trace + 1] = "outer:before"
  end)
  after_each(function()
    trace[#trace + 1] = "outer:after"
  end)

  it("passes", function()
    assert.are.equal(1, 1)
    assert.is_true(true)
  end)

  it("collects every failure of the body", function()
    assert.are.equal(1, 2) -- MARK:e1
    assert.is_true(false) -- MARK:e2
    assert.are.same({ 1 }, { 1 })
    assert.is_nil(5) -- MARK:e3
  end)

  describe("inner", function()
    before_each(function()
      trace[#trace + 1] = "inner:before"
    end)
    after_each(function()
      trace[#trace + 1] = "inner:after"
    end)

    it("nested pass", function()
      assert.truthy(true)
    end)

    it("raises", function()
      assert.is_true(true)
      error("boom") -- MARK:e4
    end)

    it("skips", function()
      pending("not today")
      assert.is_true(false) -- never reached
    end)

    it("same name", function()
      assert.is_true(true)
    end)

    it("same name", function()
      assert.is_true(true)
    end)
  end)

  pending("registered pending")
  it("without a function")
end)

describe("second", function()
  it("uses has_no.errors and is_not", function()
    assert.has_no.errors(function() end)
    assert.is_not.equal(1, 2)
    assert.are_not.same({ 1 }, { 2 })
    assert.is_not_nil(1)
    assert.matches("^ab", "abc")
    assert.has_error(function()
      error("x")
    end)
  end)
end)
