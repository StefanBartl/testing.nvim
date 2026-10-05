-- Fixture (never a spec of this repo). Dialect E: plain `assert(...)` of the spec, the module
-- `luassert`, and a describe-level assertion.
-- luacheck: globals describe it assert
---@diagnostic disable: undefined-global

local luassert = require("luassert")

describe("plain assert", function()
  it("counts as an assertion of the case", function()
    local fh = assert(io.open(vim.fn.tempname(), "wb"))
    fh:close()
    assert(true)
  end)

  it("the luassert module is the same object", function()
    luassert.is_true(luassert == assert)
  end)

  it("a failing plain assert ends the body", function()
    assert(false, "plain assert message")
    luassert.is_true(false) -- never reached
  end)
end)
