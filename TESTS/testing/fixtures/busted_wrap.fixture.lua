---@diagnostic disable: undefined-field
-- Fixture (never a spec of this repo). Dialect E: the body of an `it` is wrapped by a framework of another file
-- that runs it under a pcall of its own and keeps the error. That pcall is not the spec's: the failed check is
-- recorded. The second `it` asks with a pcall of its own and is answered.
-- luacheck: globals describe it assert
---@diagnostic disable: undefined-global

local support =
  dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/h/h_wrap_support.lua")

describe("wrapped", function()
  it(
    "swallowed by the framework",
    support.spec_swallow(function()
      assert.are.equal(1, 2) -- MARK:w1
    end)
  )

  it("asks itself", function()
    local ok = pcall(function()
      assert.are.equal(1, 2)
    end)
    assert.is_false(ok)
  end)
end)
