---@diagnostic disable: undefined-field
-- Fixture (never a spec of this repo). Dialect E: a check in the message handler of an xpcall. The handler runs on
-- top of the frame the error is thrown from and a raise there is lost ("error in error handling"), so the failed
-- check is recorded: after error(), after a coroutine.wrap that rethrows, after a failing require. The last `it`
-- checks in the body of the xpcall, where the raise is caught and answered.
-- luacheck: globals describe it assert
---@diagnostic disable: undefined-global

describe("handler", function()
  it("after error", function()
    xpcall(function()
      error("x", 0)
    end, function(e)
      assert.are.equal(1, 2) -- MARK:h1
      return e
    end)
  end)

  it("after a wrap rethrow", function()
    xpcall(function()
      coroutine.wrap(function()
        error("x", 0)
      end)()
    end, function(e)
      assert.are.equal(1, 2) -- MARK:h2
      return e
    end)
  end)

  it("after a failing require", function()
    xpcall(function()
      require("testing_no_such_module_for_the_handler_spec")
    end, function(e)
      assert.are.equal(1, 2) -- MARK:h3
      return e
    end)
  end)

  it("in the body", function()
    local ok = xpcall(function()
      assert.are.equal(1, 2)
    end, function(e)
      return e
    end)
    assert.is_false(ok)
  end)
end)
