---@module 'testing.dialect.luassert'
---@brief The luassert subset the fleet's busted specs use, on top of the collecting assertions.
---@description
--- `assert.are.equal(expected, actual, msg)` and friends. The shape is luassert's: a chain of
--- modifier words (`is`, `are`, `has`, `does`, `not`, `no`, joined with `_` or `.`) and then the
--- assertion: `assert.is_not_nil(x)`, `assert.are_not.equal(a, b)`, `assert.has_no.errors(fn)`.
--- Every assertion records onto the case that is open (a failed check does not raise: all failures of
--- a case are visible), and maps its arguments onto the kernel (`testing.core.assert`):
--- luassert's `expected` comes first, the kernel's `actual` first.
---
--- Supported (the census of the fleet, `dialect_census.json`, found exactly these):
---
---   equal / equals, same, True, False (`is_true`, `is_false`), truthy, falsy, `nil`
---   (`is_nil`, `is_not_nil`), table, string, function, boolean, number, userdata, thread, matches /
---   match, error / errors (`has_error`, `has_no.errors`), near
---
--- Not supported: anything else (`spy`, `stub`, `mock`, custom assertion registration, `assert.message`,
--- `assert.are.unique`, ...). Using one raises "not supported" naming it: a spec that needs it must
--- fail loudly, never pass without having asserted.
---
--- The plain call `assert(value, msg)` (a luassert object is callable) keeps the builtin meaning: it
--- returns its arguments, raises on a falsy value. A call made from the spec file itself also counts
--- as a recorded assertion (a spec that only uses `assert(...)` did assert); a call from plugin code
--- is not the test's assertion and is not recorded.
---
--- Call sites: every function ends in a tail call, so the recorded `file:line` is the spec's own line.
---
--- Outside an open case (a bare `assert.is_true(x)` in a `describe` body) a held check records
--- nothing and a failed one raises, which is what luassert did there.

local assert_mod = require("testing.core.assert")

local inspect = assert_mod.inspect

local M = {}

---@alias Testing.Luassert.Scope table Assertion functions bound to the open case (`Context.scope()`), or the raising stand-in.

local MODIFIERS =
  { is = true, are = true, has = true, does = true, was = true, ["not"] = true, no = true }
local NEGATORS = { ["not"] = true, no = true }

-- =========================================================
-- Outside a case: raise on failure
-- =========================================================

---Assertion functions for code that runs outside any case. A held check is silent, a failed one
---raises its message.
---@return Testing.Luassert.Scope
local function outside_scope()
  local ctx = assert_mod.new()
  local case = ctx.begin_case({ file = "<outside a case>", name = "outside" })
  local scope = {}
  for _, name in ipairs({
    "eq",
    "same",
    "deep_eq",
    "ok",
    "not_ok",
    "is_nil",
    "not_nil",
    "matches",
    "has",
    "error",
    "no_error",
    "fail",
  }) do
    local fn = ctx[name]
    scope[name] = function(...)
      local res, extra = fn(...)
      local last = case.assertions[#case.assertions]
      for i = #case.assertions, 1, -1 do
        case.assertions[i] = nil
      end
      if res == false then
        error(last and last.msg or "assertion failed", 0)
      end
      return res, extra
    end
  end
  return scope
end

-- =========================================================
-- The assertions: fn(S, negated, ...)
-- =========================================================

---@type table<string, fun(S: Testing.Luassert.Scope, neg: boolean, ...): any>
local A = {}

---@param v any
---@return string|nil
local function msg_of(v)
  if v == nil then
    return nil
  end
  return type(v) == "string" and v or tostring(v)
end

A.equal = function(S, neg, expected, actual, msg)
  if not neg then
    return S.eq(actual, expected, msg_of(msg))
  end
  if actual ~= expected then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(msg_of(msg) or ("expected values to differ, both are " .. inspect(actual)))
end
A.equals = A.equal

A.same = function(S, neg, expected, actual, msg)
  if not neg then
    return S.same(actual, expected, msg_of(msg))
  end
  if not assert_mod.deep_equal(actual, expected) then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(msg_of(msg) or ("expected values to differ, both are " .. inspect(actual)))
end

A["true"] = function(S, neg, value, msg)
  if not neg then
    return S.eq(value, true, msg_of(msg))
  end
  if value ~= true then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(msg_of(msg) or "expected anything but true, got true")
end

A["false"] = function(S, neg, value, msg)
  if not neg then
    return S.eq(value, false, msg_of(msg))
  end
  if value ~= false then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(msg_of(msg) or "expected anything but false, got false")
end

A.truthy = function(S, neg, value, msg)
  if not neg then
    return S.ok(value, msg_of(msg))
  end
  return S.not_ok(value, msg_of(msg))
end

A.falsy = function(S, neg, value, msg)
  if not neg then
    return S.not_ok(value, msg_of(msg))
  end
  return S.ok(value, msg_of(msg))
end

A["nil"] = function(S, neg, value, msg)
  if not neg then
    return S.is_nil(value, msg_of(msg))
  end
  return S.not_nil(value, msg_of(msg))
end

for _, kind in ipairs({ "table", "string", "function", "boolean", "number", "userdata", "thread" }) do
  A[kind] = function(S, neg, value, msg)
    if (type(value) == kind) ~= neg then
      return S.ok(true, msg_of(msg))
    end
    return S.fail(
      msg_of(msg)
        or (
          neg and ("expected anything but a %s, got %s"):format(kind, inspect(value))
          or ("expected a %s, got %s"):format(kind, inspect(value))
        )
    )
  end
end

A.matches = function(S, neg, pattern, actual, ...)
  -- luassert: matches(pattern, actual [, init [, plain]]); the message is the trailing string
  local init, plain, msg
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "number" then
      init = v
    elseif type(v) == "boolean" then
      plain = v
    elseif type(v) == "string" then
      msg = v
    end
  end
  local subject = (type(actual) == "string" or type(actual) == "number") and tostring(actual) or nil
  if not neg and subject and init == nil and not plain then
    return S.matches(subject, pattern, msg)
  end
  local found = false
  if subject and type(pattern) == "string" then
    local called, res = pcall(string.find, subject, pattern, init, plain)
    found = called and res ~= nil
  end
  if found ~= neg then
    return S.ok(true, msg)
  end
  return S.fail(
    msg
      or ("expected %s a string matching %s, got %s"):format(
        neg and "NOT" or "",
        inspect(pattern),
        inspect(actual)
      )
  )
end
A.match = A.matches

---luassert's comparison of a raised error with the expected one: strings compare with or without the
---`file:line: ` prefix, tables deeply.
---@param err any
---@param expected any
---@return boolean
local function error_matches(err, expected)
  if type(err) == "string" and type(expected) == "string" then
    if err == expected then
      return true
    end
    return (err:gsub("^[^\n]-:%d+: ", "")) == expected
  end
  return assert_mod.deep_equal(err, expected)
end

A.error = function(S, neg, fn, expected, msg)
  if type(fn) ~= "function" then
    return S.fail("expected a function that raises an error, got " .. inspect(fn))
  end
  if neg then
    -- `has_no.errors(fn, "text")`: the fleet passes a message here; the check is the stricter "no error at all"
    return S.no_error(fn, msg_of(type(expected) == "string" and expected or msg))
  end
  if expected == nil then
    return S.error(fn, nil, msg_of(msg))
  end
  local called, err = pcall(fn)
  if called then
    return S.fail(msg_of(msg) or ("expected an error %s, got no error"):format(inspect(expected)))
  end
  if error_matches(err, expected) then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(
    msg_of(msg) or ("expected error %s, got %s"):format(inspect(expected), inspect(err))
  )
end
A.errors = A.error

A.near = function(S, neg, expected, actual, tolerance, msg)
  local close = type(expected) == "number"
    and type(actual) == "number"
    and type(tolerance) == "number"
    and math.abs(expected - actual) <= tolerance
  if (close and true or false) ~= neg then
    return S.ok(true, msg_of(msg))
  end
  return S.fail(
    msg_of(msg)
      or ("expected %s within %s of %s, got %s"):format(
        inspect(actual),
        inspect(tolerance),
        inspect(expected),
        neg and "a closer value" or "a farther value"
      )
  )
end

---Names of the supported assertions (sorted), for messages and docs.
---@return string[]
function M.supported()
  local names = {}
  for name in pairs(A) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- =========================================================
-- The chain object
-- =========================================================

---@param get_scope fun(): Testing.Luassert.Scope
---@param neg boolean
---@param call? fun(self: table, ...): ...
---@return table
local function chain(get_scope, neg, call)
  return setmetatable({}, {
    __index = function(_, key)
      local tokens = {}
      for tok in tostring(key):gmatch("[^_]+") do
        tokens[#tokens + 1] = tok
      end
      local flip, i = false, 1
      while i <= #tokens and MODIFIERS[tokens[i]] do
        if NEGATORS[tokens[i]] then
          flip = not flip
        end
        i = i + 1
      end
      local negated = (neg ~= flip)
      if i > #tokens then
        return chain(get_scope, negated)
      end
      local name = table.concat(tokens, "_", i)
      local fn = A[name]
      if not fn then
        error(
          ("testing: luassert assertion '%s' is not supported by the busted dialect (supported: %s)"):format(
            tostring(key),
            table.concat(M.supported(), ", ")
          ),
          2
        )
      end
      return function(...)
        return fn(get_scope(), negated, ...)
      end
    end,
    __call = call,
  })
end

---@class Testing.Luassert.Opts
---@field scope fun(): Testing.Luassert.Scope|nil Scoped assertions of the open case (nil: none open).
---@field is_spec_frame fun(source: string): boolean Is a `debug.getinfo` source the spec file being run (plain `assert(...)` from it counts)?

---Build the `assert` object of one busted run.
---@param opts Testing.Luassert.Opts
---@return table assert
function M.new(opts)
  local outside
  ---@return Testing.Luassert.Scope
  local function get_scope()
    local s = opts.scope()
    if s then
      return s
    end
    outside = outside or outside_scope()
    return outside
  end

  ---Plain `assert(value, msg, ...)`: the builtin's contract, plus a recorded check for the spec's own calls.
  local function call(_, ...)
    local value, msg = ...
    local info = debug.getinfo(2, "S")
    local from_spec = info ~= nil and opts.is_spec_frame(info.source)
    if value then
      if from_spec then
        get_scope().ok(true, nil)
      end
      return ...
    end
    error(msg == nil and "assertion failed!" or msg, 0)
  end

  return chain(get_scope, false, call)
end

return M
