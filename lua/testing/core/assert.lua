---@module 'testing.core.assert'
---@brief Collecting assertions: a failed check is recorded on the current case; raised only where the spec asks.
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
---     is not recorded but raised, so the spec can ask whether an assertion fails. Which protected call
---     counts, and where the rule stops, is `testing.core.protected`; the case body is entered through
---     `a.entry`, which marks where that search ends.
---
--- Pure Lua: no editor API. The clock defaults to `vim.uv.hrtime` when it exists and `os.clock`
--- otherwise; tests inject their own. Argument order is `(actual, expected, msg)`, the order of
--- the `H.eq` of dialect A, so the dialect shim maps one to one.

local protected = require("testing.core.protected")
local result = require("testing.core.result")

-- taken now, like in `testing.core.protected`: a spec that stubs `debug.getinfo` must not break (or send into an
-- endless walk) the location search of every assertion it makes
local getinfo = debug.getinfo
local running = coroutine.running
-- (same name on purpose: `protected.inside` recognises the `pcall` of `a.ask` by the name of its call site; a spec that
-- stubs the global must not make `a.ask` raise before it has left the question)
local pcall = pcall

local M = {}

-- =========================================================
-- Printing and comparing values (deterministic, no addresses)
-- =========================================================

local INSPECT_MAX_DEPTH = 6
local INSPECT_MAX_LEN = 2000

---@param value any
---@param depth integer
---@param seen table<table, boolean>
---@param budget { n: integer } Characters still worth producing. Only text that certainly ends up in the result is
---  counted (strings, two per element), so an exhausted budget means `M.inspect` cuts the rest anyway.
---@return string
local function inspect_value(value, depth, seen, budget)
  local t = type(value)
  if t == "string" then
    -- `%q` never shortens: the first INSPECT_MAX_LEN bytes are all that can be seen of the quoted string
    local s = (("%q"):format(value:sub(1, INSPECT_MAX_LEN)):gsub("\\\n", "\\n"))
    budget.n = budget.n - #s
    return s
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
    if budget.n < 0 then
      break
    end
    parts[#parts + 1] = inspect_value(value[i], depth + 1, seen, budget)
    budget.n = budget.n - 2
  end
  local keys = {}
  -- nothing left to show: neither collect nor sort the keys of a huge table
  for k in pairs(budget.n >= 0 and value or {}) do
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
    if budget.n < 0 then
      break
    end
    local label = type(k) == "string" and k:match("^[%a_][%w_]*$") and k
      or ("[%s]"):format(inspect_value(k, depth + 1, seen, budget))
    parts[#parts + 1] = ("%s = %s"):format(label, inspect_value(value[k], depth + 1, seen, budget))
    budget.n = budget.n - 2
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

---Deterministic printable form of a value: keys sorted, no addresses, depth and length capped.
---(`lib.lua.dump` walks `pairs` order and prints function addresses: not stable enough for an IR.)
---@param value any
---@return string
function M.inspect(value)
  local s = inspect_value(value, 0, {}, { n = INSPECT_MAX_LEN })
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
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  if depth > 100 then
    -- undecided, not "different": `deep_equal` reports it as raised, so a negated check does not pass on it
    error("compared more than 100 levels deep", 0)
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

---Deep equality like `vim.deep_equal`: same keys, equal values, metatables not compared (an `__index` is
---consulted, as `vim.deep_equal` does; one that raises, as on a strict-mode table, makes the values unequal
---instead of making the check throw out of a protected call that would swallow it). The second result tells that
---the comparison raised: a caller that NEGATES the answer (`are_not.same`) must not read "raised" as "differs".
---@param a any
---@param b any
---@return boolean equal
---@return boolean raised
function M.deep_equal(a, b)
  local called, equal = pcall(deep_eq, a, b, {}, 0)
  return called and equal == true, not called
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
  "ask",
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
  -- the explicit question (`a.ask`): thread -> `protected.entry()` of the innermost question that runs on it. Per thread,
  -- weak: a coroutine that yields inside a question and is never resumed takes its entry along, and a question that
  -- started on one thread can never leave another thread (the main one) in "asking" mode
  ---@type table<thread|table, Testing.Protected.Entry>
  local ASKS = setmetatable({}, { __mode = "k" })
  local MAIN = {}
  -- failed checks raised only because the stack heuristic took a `pcall` of the spec for a question (this case)
  a.guessed = 0

  ---@type Testing.Result.Case|nil
  local case
  local case_started = 0

  -- chunk name -> normalized file name: every assertion walks the stack and would normalize the same few names again
  local FILES, files_seen = {}, 0

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
      local info = getinfo(level, "Sl")
      if not info then
        return nil, nil
      end
      local src = info.source
      local file = FILES[src]
      if not file then
        file = (src:sub(1, 1) == "@" and src:sub(2) or info.short_src):gsub("\\", "/")
        -- (a chunk name maps to the same file every time; few exist, but a generator of chunks must not grow this)
        if src:sub(1, 1) == "@" then
          if files_seen >= 1024 then
            FILES, files_seen = {}, 0
          end
          FILES[src], files_seen = file, files_seen + 1
        end
      end
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
    if entry.msg ~= nil and type(entry.msg) ~= "string" then
      -- a number (`H.eq(got[i], want[i], i)`) or a table as the message: the IR holds strings only, and a
      -- message it rejects would end every run that writes a report as an infrastructure error
      entry.msg = M.inspect(entry.msg)
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

  ---Does a failed check raise now? Yes inside an explicit question (`a.ask`) unless a protected call of the code under
  ---test lies between the check and the question (it may keep the error: the failed check would vanish); else when the
  ---protected call that would catch the raise is one the spec wrote (`testing.core.protected`, a guess, counted).
  ---@return boolean raises
  ---@return boolean guessed True when only the stack heuristic took a `pcall` of the spec for a question (counted).
  local function raises()
    local question = ASKS[running() or MAIN]
    if question then
      return protected.inside(question, nil, true), false
    end
    if protected.inside(a.entry) then
      a.guessed = a.guessed + 1
      return true, true
    end
    return false, false
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
    local entry = {
      ok = false,
      kind = kind,
      msg = msg or fmt:format(expected, actual),
      expected = expected,
      actual = actual,
      file = file,
      line = line,
    }
    local raised, guessed = raises()
    if raised then
      -- the spec asked "does this fail?": answer with the raise of the old harnesses, record nothing
      local text = ("FAIL %s: %s"):format(msg or "", fmt:format(expected, actual))
      -- (remembered: should the raise get out of the spec, `run_case` books it as this failed check)
      a.raised = { text = text, entry = entry, guessed = guessed }
      error(text, 0)
    end
    return append(entry)
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

  ---Leave the question: restore the outer one of this thread and hand the results of `pcall` on.
  local function end_ask(key, outer, ...)
    ASKS[key] = outer
    return ...
  end

  ---The explicit question "does this fail?": runs `fn(...)` like `pcall` does, and a failed check inside it RAISES (and
  ---is caught here) whether or not a `pcall` stands further out and whatever the stack looks like. The recommended way
  ---to ask; the stack heuristic stays for specs written before it. Nests; a check on another thread is not asked.
  ---@param fn function
  ---@param ... any
  ---@return boolean ok
  ---@return any ... What `fn` returned, or the error.
  function a.ask(fn, ...)
    local key = running() or MAIN
    local outer = ASKS[key]
    ASKS[key] = protected.entry(a.entry and a.entry.spec or nil)
    -- (the results of pcall go through a function: no table, so a nil in the middle or at the end survives)
    return end_ask(key, outer, pcall(fn, ...))
  end

  a["error"] = function(fn, pattern, msg)
    local file, line = locate()
    local called, err = a.ask(fn)
    if called then
      local want = pattern ~= nil and ("an error matching " .. M.inspect(pattern)) or "an error"
      return fail(file, line, "error", msg, EXPECTED_GOT, want, "no error")
    end
    local text = tostring(err)
    if pattern ~= nil then
      -- like `matches`: a malformed pattern is a failed check, not an error thrown out of the check
      local searched, found = pcall(string.find, text, pattern)
      if not searched then
        local bad = "invalid pattern " .. M.inspect(pattern) .. ": " .. tostring(found)
        return fail(file, line, "error", msg, "%s (%s)", bad, M.inspect(text))
      end
      if not found then
        local want = "an error matching " .. M.inspect(pattern)
        return fail(file, line, "error", msg, EXPECTED_GOT, want, M.inspect(text))
      end
    end
    return pass(file, line, "error", msg)
  end

  function a.no_error(fn, msg)
    local file, line = locate()
    local called, res = a.ask(fn)
    if called then
      pass(file, line, "no_error", msg)
      return true, res
    end
    fail(file, line, "no_error", msg, EXPECTED_GOT, "no error", M.inspect(tostring(res)))
    return false, nil
  end

  function a.fail(msg)
    local file, line = locate()
    local raised, guessed = raises()
    if raised then
      -- an explicit failure (the negated checks of the luassert shim end here) answers the spec's question too
      a.raised = {
        text = msg or "FAIL",
        entry = { ok = false, kind = "fail", msg = msg, file = file, line = line },
        guessed = guessed,
      }
      error(msg or "FAIL", 0)
    end
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
    -- no question outlives its case: one that was left open (an error from a count hook of the deadline guard can fire
    -- between the `pcall` of `a.ask` and the line that leaves the question) must not change the checks of the next case
    for thread in pairs(ASKS) do
      ASKS[thread] = nil
    end
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
    a.raised = nil
    a.guessed = 0
    local safe_call = require("lib.lua.error").safe_call
    -- Defensive: should safe_call ever raise itself (its `error.new` insists on a string message),
    -- the case still ends as an error instead of taking the runner down.
    local function entered(...)
      a.entry = protected.entry(case_opts.spec_path and ("@" .. case_opts.spec_path) or nil)
      return body(...)
    end
    local guarded, called, err = pcall(safe_call, entered, a)
    a.entry = nil
    if not guarded or not called then
      local traceback = guarded and tostring(type(err) == "table" and err.message or err)
        or tostring(called)
      local first = traceback:match("^[^\n]*") or traceback
      -- A thrown table/function reaches here as "table: 0x..." (an address: not deterministic).
      local kind = first:match("^(%a+): 0x%x+$")
      if kind then
        first = ("non-string error value (%s)"):format(kind)
      end
      local raised = a.raised
      -- A check the spec asked about whose raise got out of the spec (it cleaned up in a pcall of its own and raised
      -- the error again, `error(err, 0)`, `error(err)` or `assert(ok, err)`): a failure of that check, with its
      -- line, not a broken spec. `error(err)` and `assert` may put `file:line: ` in front of the text.
      -- (`first` is one line: a message with line breaks is compared by its first line)
      local want = raised ~= nil and type(raised.text) == "string" and raised.text:match("^[^\n]*")
        or nil
      local escaped = want ~= nil and (first == want or first:gsub("^[^\n]-:%d+: ", "", 1) == want)
      if escaped then
        append(raised.entry)
        -- it is in the case now: nothing was swallowed, so there is nothing to hint at
        if raised.guessed then
          a.guessed = a.guessed - 1
        end
      else
        bound.status = "error"
        bound.error = { message = first, traceback = traceback }
      end
    end
    a.raised = nil
    if a.guessed > 0 and bound.status ~= "error" then
      -- a raised check leaves no trace in the case: if something swallowed it, this is the only hint
      bound.notes[#bound.notes + 1] = ("%d failed check(s) were raised into a pcall of the spec (guessed from the stack: `ask` makes the question explicit)"):format(
        a.guessed
      )
    end
    a.guessed = 0
    return a.end_case(finish)
  end

  return a --[[@as Testing.Assert.Context]]
end

return M
