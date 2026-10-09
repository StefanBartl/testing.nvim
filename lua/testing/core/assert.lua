---@module 'testing.core.assert'
---@brief Collecting assertions: a failed check is recorded on the current case, never raised.
---@description
--- Problem P1 of the old runner: the first failed `H.eq` raised, so a file showed one failure at a
--- time. Here every assertion appends `{ ok, kind, msg, expected, actual, file, line }` to the case
--- that is currently bound and returns whether it held; the body runs on. Only a thrown error of
--- the test body itself ends it early (status `error`, traceback from `lib.lua.error.safe_call`).
---
--- Rules enforced together with `testing.core.result`:
---   * zero assertions in a case is a failure (`finish_case`, P4);
---   * an assertion with no case bound is a programming error and raises (a silent drop would hide
---     failures);
---   * a failed check inside a protected call that the SPEC wrote (`pcall(function() H.eq(1, 2) end)`)
---     is not recorded but raised, so the spec can ask whether an assertion fails (`testing.core.protected`).
---
--- Pure Lua: no editor API. The clock defaults to `vim.uv.hrtime` when it exists and `os.clock`
--- otherwise; tests inject their own. Argument order is `(actual, expected, msg)`, the order of
--- the `H.eq` of dialect A, so the dialect shim maps one to one.

local protected = require("testing.core.protected")
local result = require("testing.core.result")

local M = {}

-- =========================================================
-- Printing and comparing values (deterministic, no addresses)
-- =========================================================

local INSPECT_MAX_DEPTH = 6
local INSPECT_MAX_LEN = 2000

---@param value any
---@param depth integer
---@param seen table<table, boolean>
---@return string
local function inspect_value(value, depth, seen)
  local t = type(value)
  if t == "string" then
    return (("%q"):format(value):gsub("\\\n", "\\n"))
  elseif t == "number" then
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return ("%d"):format(value)
    end
    return ("%.14g"):format(value)
  elseif t ~= "table" then
    return t == "nil" and "nil" or (t == "boolean" and tostring(value) or ("<%s>"):format(t))
  end
  if seen[value] then
    return "<cycle>"
  end
  if depth >= INSPECT_MAX_DEPTH then
    return "{...}"
  end
  seen[value] = true
  local parts, n = {}, #value
  for i = 1, n do
    parts[#parts + 1] = inspect_value(value[i], depth + 1, seen)
  end
  local keys = {}
  for k in pairs(value) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
      return ta < tb
    end
    if ta == "number" then
      return a < b
    end
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local label = type(k) == "string" and k:match("^[%a_][%w_]*$") and k
      or ("[%s]"):format(inspect_value(k, depth + 1, seen))
    parts[#parts + 1] = ("%s = %s"):format(label, inspect_value(value[k], depth + 1, seen))
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

---Deterministic printable form of a value: keys sorted, no addresses, depth and length capped.
---(`lib.lua.dump` walks `pairs` order and prints function addresses: not stable enough for an IR.)
---@param value any
---@return string
function M.inspect(value)
  local s = inspect_value(value, 0, {})
  if #s > INSPECT_MAX_LEN then
    s = s:sub(1, INSPECT_MAX_LEN) .. "...(truncated)"
  end
  return s
end

---@param a any
---@param b any
---@param seen table<table, table<table, boolean>>
---@param depth integer
---@return boolean
local function deep_eq(a, b, seen, depth)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" or depth > 100 then
    return false
  end
  if seen[a] and seen[a][b] then
    return true
  end
  seen[a] = seen[a] or {}
  seen[a][b] = true
  for k, v in pairs(a) do
    if not deep_eq(v, b[k], seen, depth + 1) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---Deep equality like `vim.deep_equal`: same keys, equal values, metatables ignored.
---@param a any
---@param b any
---@return boolean
function M.deep_equal(a, b)
  return deep_eq(a, b, {}, 0)
end

-- =========================================================
-- Clock
-- =========================================================

---@return Testing.Assert.Clock
local function default_clock()
  local v = rawget(_G, "vim")
  local uv = type(v) == "table" and v.uv or nil
  if uv and uv.hrtime then
    return function()
      return uv.hrtime() / 1e6
    end
  end
  return function()
    return os.clock() * 1000
  end
end

-- =========================================================
-- Context
-- =========================================================

---Frames that carry the call but are not the test's call site: skipped while locating.
local SHIM_SOURCES = {
  "lua/testing/core/assert.lua",
  "lua/testing/dialect/harness_a.lua",
}

---Frames of the code that runs the case body: the walk stops here, because whatever is above is
---not the test (a spec whose last statement is a tail call has lost its own frame).
local BOUNDARY_SOURCES = {
  "lua/testing/run/inproc.lua",
  "lua/lib/lua/error/",
}

---@param file string Forward-slash path of the frame's source
---@param parts string[]
---@return boolean
local function source_in(file, parts)
  for _, part in ipairs(parts) do
    if file:find(part, 1, true) then
      return true
    end
  end
  return false
end

---Assertion functions that `scope()` binds to one case.
local SCOPED = {
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
}

---A new assertion context. One per runner worker; it binds one case at a time.
---@param opts? Testing.Assert.Opts
---@return Testing.Assert.Context
function M.new(opts)
  opts = opts or {}
  local clock = opts.clock or default_clock()

  local a = {}
  a.depth = 0

  ---@type Testing.Result.Case|nil
  local case
  local case_started = 0

  ---File and line of the code that called an assertion function. Must be called directly from
  ---the assertion function (frame 1 = here, 2 = the assertion, 3 = its caller); `a.depth` adds
  ---frames for a wrapper that is not a tail call.
  ---@return string|nil file
  ---@return integer|nil line
  local function locate()
    -- Frames of the shim (this file, the dialect shim) and C functions are never a call site;
    -- after a tail call (`return H.eq(...)`) the first frame can be one of them, so walk up to the
    -- first frame that is not. The driver / `safe_call` frames end the walk: no location is
    -- better than the wrong one.
    local level = 3 + a.depth
    while true do
      local info = debug.getinfo(level, "Sl")
      if not info then
        return nil, nil
      end
      local src = info.source
      local file = (src:sub(1, 1) == "@" and src:sub(2) or info.short_src):gsub("\\", "/")
      if source_in(file, BOUNDARY_SOURCES) then
        return nil, nil
      end
      -- C frames (`pcall(H.eq, ...)`) and the shim itself are transparent.
      if info.what ~= "C" and not source_in(file, SHIM_SOURCES) then
        return file, info.currentline > 0 and info.currentline or nil
      end
      level = level + 1
    end
  end

  ---Append one assertion to the bound case.
  ---@param entry Testing.Result.Assertion
  ---@return boolean ok
  local function append(entry)
    if not case then
      error(
        ("testing: assertion '%s' called outside a case (%s:%s); bind one with begin_case/run_case"):format(
          entry.kind,
          tostring(entry.file),
          tostring(entry.line)
        ),
        4
      )
    end
    case.assertions[#case.assertions + 1] = entry
    return entry.ok
  end

  ---@param file string|nil
  ---@param line integer|nil
  ---@param kind string
  ---@param msg string|nil
  ---@return boolean ok always true
  local function pass(file, line, kind, msg)
    return append({ ok = true, kind = kind, msg = msg, file = file, line = line })
  end

  ---Record a failure. `expected`/`actual` are printable strings; without a caller message the
  ---generated one is `fmt:format(expected, actual)`.
  ---@param file string|nil
  ---@param line integer|nil
  ---@param kind string
  ---@param msg string|nil
  ---@param fmt string
  ---@param expected string
  ---@param actual string
  ---@return boolean ok always false
  local function fail(file, line, kind, msg, fmt, expected, actual)
    if protected.inside(a.entry_height) then
      -- the spec asked "does this fail?": answer with the raise of the old harnesses, record nothing
      error(("FAIL %s: %s"):format(msg or "", fmt:format(expected, actual)), 0)
    end
    return append({
      ok = false,
      kind = kind,
      msg = msg or fmt:format(expected, actual),
      expected = expected,
      actual = actual,
      file = file,
      line = line,
    })
  end

  local EXPECTED_GOT = "expected %s, got %s"

  function a.eq(actual, expected, msg)
    local file, line = locate()
    if actual == expected then
      return pass(file, line, "eq", msg)
    end
    return fail(file, line, "eq", msg, EXPECTED_GOT, M.inspect(expected), M.inspect(actual))
  end

  function a.same(actual, expected, msg)
    local file, line = locate()
    if M.deep_equal(actual, expected) then
      return pass(file, line, "same", msg)
    end
    return fail(file, line, "same", msg, EXPECTED_GOT, M.inspect(expected), M.inspect(actual))
  end

  function a.deep_eq(actual, expected, msg)
    local file, line = locate()
    if M.deep_equal(actual, expected) then
      return pass(file, line, "same", msg)
    end
    return fail(file, line, "same", msg, EXPECTED_GOT, M.inspect(expected), M.inspect(actual))
  end

  function a.ok(value, msg)
    local file, line = locate()
    if value then
      return pass(file, line, "ok", msg)
    end
    return fail(file, line, "ok", msg, "expected a %s value, got %s", "truthy", M.inspect(value))
  end

  function a.not_ok(value, msg)
    local file, line = locate()
    if not value then
      return pass(file, line, "not_ok", msg)
    end
    return fail(file, line, "not_ok", msg, "expected a %s value, got %s", "falsy", M.inspect(value))
  end

  function a.is_nil(value, msg)
    local file, line = locate()
    if value == nil then
      return pass(file, line, "is_nil", msg)
    end
    return fail(file, line, "is_nil", msg, EXPECTED_GOT, "nil", M.inspect(value))
  end

  function a.not_nil(value, msg)
    local file, line = locate()
    if value ~= nil then
      return pass(file, line, "not_nil", msg)
    end
    return fail(file, line, "not_nil", msg, "expected %s, got %s", "a non-nil value", "nil")
  end

  function a.matches(str, pattern, msg)
    local file, line = locate()
    local fmt = "expected a string matching %s, got %s"
    if type(str) ~= "string" then
      return fail(file, line, "matches", msg, fmt, M.inspect(pattern), M.inspect(str))
    end
    local called, found = pcall(string.find, str, pattern)
    if not called then
      local text = "invalid pattern " .. M.inspect(pattern) .. ": " .. tostring(found)
      return fail(file, line, "matches", msg, "%s (%s)", text, M.inspect(str))
    end
    if found then
      return pass(file, line, "matches", msg)
    end
    return fail(file, line, "matches", msg, fmt, M.inspect(pattern), M.inspect(str))
  end

  function a.has(haystack, needle, msg)
    local file, line = locate()
    if
      type(haystack) == "string"
      and type(needle) == "string"
      and haystack:find(needle, 1, true)
    then
      return pass(file, line, "has", msg)
    end
    return fail(
      file,
      line,
      "has",
      msg,
      "expected a string containing %s, got %s",
      M.inspect(needle),
      M.inspect(haystack)
    )
  end

  a["error"] = function(fn, pattern, msg)
    local file, line = locate()
    local called, err = pcall(fn)
    if called then
      local want = pattern ~= nil and ("an error matching " .. M.inspect(pattern)) or "an error"
      return fail(file, line, "error", msg, EXPECTED_GOT, want, "no error")
    end
    local text = tostring(err)
    if pattern ~= nil and not text:find(pattern) then
      local want = "an error matching " .. M.inspect(pattern)
      return fail(file, line, "error", msg, EXPECTED_GOT, want, M.inspect(text))
    end
    return pass(file, line, "error", msg)
  end

  function a.no_error(fn, msg)
    local file, line = locate()
    local called, res = pcall(fn)
    if called then
      pass(file, line, "no_error", msg)
      return true, res
    end
    fail(file, line, "no_error", msg, EXPECTED_GOT, "no error", M.inspect(tostring(res)))
    return false, nil
  end

  function a.fail(msg)
    local file, line = locate()
    return append({ ok = false, kind = "fail", msg = msg, file = file, line = line })
  end

  -- -------------------------------------------------------
  -- Case binding
  -- -------------------------------------------------------

  function a.current()
    return case
  end

  ---Assertions that late callers (a timer, `vim.schedule`) cannot misattribute: a view of the
  ---assertion functions bound to the case that is open NOW. Once that case has ended, a call
  ---through the view is recorded in `a.late` and raises, instead of landing on whatever case is
  ---open at that moment. Call it inside the case body.
  ---@return table scoped Same functions as the context, bound to the current case
  function a.scope()
    local owner = case
    if not owner then
      error("testing: scope() without an open case", 2)
    end
    local scoped = {}
    for _, name in ipairs(SCOPED) do
      local fn = a[name]
      scoped[name] = function(...)
        if case ~= owner then
          local file, line = locate()
          local msg = ("assertion '%s' called after its case '%s' ended (%s:%s)"):format(
            name,
            owner.id,
            tostring(file),
            tostring(line)
          )
          a.late[#a.late + 1] =
            { case_id = owner.id, kind = name, file = file, line = line, msg = msg }
          error("testing: " .. msg, 2)
        end
        return fn(...)
      end
    end
    return scoped
  end

  ---Assertions that arrived after their case ended (see `scope`).
  ---@type { case_id: string, kind: string, file: string|nil, line: integer|nil, msg: string }[]
  a.late = {}

  function a.begin_case(case_opts)
    if case then
      error(
        ("testing: begin_case('%s') while case '%s' is still open"):format(case_opts.name, case.id),
        2
      )
    end
    case = result.new_case(case_opts)
    case_started = clock()
    return case
  end

  function a.end_case(finish)
    if not case then
      error("testing: end_case without an open case", 2)
    end
    local done = case
    case = nil
    done.duration_ms = math.floor((clock() - case_started) * 1000 + 0.5) / 1000
    return result.finish_case(done, finish)
  end

  function a.run_case(case_opts, body, finish)
    local bound = a.begin_case(case_opts)
    local safe_call = require("lib.lua.error").safe_call
    -- Defensive: should safe_call ever raise itself (its `error.new` insists on a string message),
    -- the case still ends as an error instead of taking the runner down.
    local function entered(...)
      a.entry_height = protected.entry_height()
      return body(...)
    end
    local guarded, called, err = pcall(safe_call, entered, a)
    a.entry_height = nil
    if not guarded or not called then
      local traceback = guarded and tostring(type(err) == "table" and err.message or err)
        or tostring(called)
      local first = traceback:match("^[^\n]*") or traceback
      -- A thrown table/function reaches here as "table: 0x..." (an address: not deterministic).
      local kind = first:match("^(%a+): 0x%x+$")
      if kind then
        first = ("non-string error value (%s)"):format(kind)
      end
      bound.status = "error"
      bound.error = { message = first, traceback = traceback }
    end
    return a.end_case(finish)
  end

  return a --[[@as Testing.Assert.Context]]
end

return M
