---@module 'testing.dialect.busted'
---@brief Dialect E: the busted/plenary `describe` / `it` shim, so the fleet's busted specs run unchanged.
---@description
--- A busted spec is plain top-level code that calls `describe`, `it`, `before_each`, `after_each`,
--- `setup`, `teardown`, `pending` and the luassert `assert`. This module installs those globals for
--- the time of one file (and restores the previous values afterwards, whatever happens), runs the file
--- and turns every `it` into ONE case of the IR:
---
---   * case id `<file>::<describe>::...::<it>` (`result.case_id`); two cases with the same id in one
---     file get `#2`, `#3`, ... so ids stay unique;
---   * the file's `describe` blocks and `it` bodies run in source order, `it` right where it is
---     written, exactly like plenary.busted does (that is what the specs were written against; a
---     spec that reads state set by an earlier `it` in its describe body keeps working);
---   * `before_each` hooks of all enclosing blocks run before the body, outermost first;
---     `after_each` hooks run after it, in plenary's order (outermost first), also when the body
---     failed; a raise in a hook ends the case as `error`;
---   * `setup` runs when registered, `teardown` when its block ends; a failing `setup` marks the
---     block broken, every `it` in it then ends as `error` with that message (never a pass);
---   * assertions collect (`testing.dialect.luassert`): a failed check does not stop the body, a raise
---     does; a file or block that raises outside any `it` becomes an `error` case of its own, a file
---     that registers no case at all becomes a failing case (a spec that runs nothing proves nothing).
---
--- Policy: an `it` without assertions follows `opts.assertions` (`testing.policy`: error, or pass with a
--- warning) and, when it printed a `skip ...` line before returning, is a `skip`.
---
--- `pending(reason)` inside an `it` ends the body at once and the case as `skip` (never green); the
--- plenary form `pending(name, fn)` outside a body registers a skipped case; `it(name)` without a
--- function is the same. (plenary only printed "Pending" and carried on; busted aborts: the skip
--- here is the honest verdict.)
---
--- Unsupported constructs raise a clear error when used: `spy`, `stub`, `mock`, `insulate`,
--- `expose`, `finally`, `xdescribe`, `async`/`await`-style helpers, luassert extensions. Each is
--- listed in `M.UNSUPPORTED`; the fleet census found none of them in use.
---
--- Options: `opts.select(id)` runs only the cases it accepts (the others are not recorded);
--- `opts.dry` runs the describe bodies only and returns the case ids that WOULD run (`list`).

local luassert = require("testing.dialect.luassert")
local policy = require("testing.policy")
local result = require("testing.core.result")

local M = {}

---Busted globals that are not implemented; using one raises with this text.
---@type table<string, string>
M.UNSUPPORTED = {
  spy = "spies (luassert spy/stub/mock) are not supported by the busted dialect",
  stub = "stubs (luassert spy/stub/mock) are not supported by the busted dialect",
  mock = "mocks (luassert spy/stub/mock) are not supported by the busted dialect",
  insulate = "insulate/expose isolation is not supported by the busted dialect",
  expose = "insulate/expose isolation is not supported by the busted dialect",
  finally = "finally() is not supported by the busted dialect",
  xdescribe = "xdescribe is not supported by the busted dialect (use pending)",
}

---Globals the shim installs for the time of a file.
local GLOBALS = {
  "describe",
  "context",
  "it",
  "specify",
  "pending",
  "xit",
  "before_each",
  "after_each",
  "setup",
  "teardown",
  "lazy_setup",
  "lazy_teardown",
  "strict_setup",
  "strict_teardown",
  "assert",
  "spy",
  "stub",
  "mock",
  "insulate",
  "expose",
  "finally",
  "xdescribe",
}

---@class Testing.Busted.Frame
---@field name? string Describe name (nil for the file root).
---@field before (fun())[] before_each hooks.
---@field after (fun())[] after_each hooks.
---@field teardown (fun())[] teardown hooks.
---@field broken? string Why `setup` failed (every `it` below ends as error).

---@class Testing.Busted.Opts
---@field on_case? fun(case: Testing.Result.Case) Called after every case (progress output).
---@field select? fun(id: string): boolean Run only the cases this accepts.
---@field dry? boolean Only run the describe bodies; `list` of the return value holds the case ids.
---@field assertions? "error"|"warn" What an `it` without assertions is (`testing.policy`); default `error`.

---@class Testing.Busted.Listing
---@field id string
---@field describe string[]
---@field name string
---@field line integer|nil

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---@param e any
---@return any
local function with_traceback(e)
  if type(e) == "string" then
    return debug.traceback(e, 2)
  end
  return e
end

---Marker of `pending(...)` inside a body.
local PENDING = {}

---@param err any
---@return string message First line, deterministic for non-string values.
---@return string traceback
local function describe_error(err)
  if type(err) == "table" and err.message ~= nil then
    err = tostring(err.message)
  end
  if type(err) ~= "string" then
    local kind = type(err)
    return ("non-string error value (%s)"):format(kind),
      ("non-string error value (%s)"):format(kind)
  end
  return err:match("^[^\n]*") or err, err
end

---Reason of the skip case of a file that registered no case (policy `warn`).
---@type string
M.NO_CASE_REASON = "no case registered on this platform"

---Note on that skip case; the terminal lists every case that carries it.
---@type string
M.NO_CASE_WARNING =
  "warning: no case registered on this platform (the file registered no it()/pending() case)"

---Run one busted spec file, case by case.
---@param a Testing.Assert.Context Full context (the shim opens a case per `it`).
---@param spec { path: string, rel: string } Absolute path and project-relative path.
---@param opts? Testing.Busted.Opts
---@return Testing.Result.Case[] cases In run order.
---@return Testing.Busted.Listing[] list Case ids (filled in `dry` mode and, for information, in a normal run too).
function M.run_file(a, spec, opts)
  opts = opts or {}
  local rel = slashes(spec.rel)
  local spec_source = "@" .. spec.path

  ---@type Testing.Result.Case[]
  local cases = {}
  ---@type Testing.Busted.Listing[]
  local list = {}
  local seen = {}
  ---@type Testing.Busted.Frame[]
  local frames = { { before = {}, after = {}, teardown = {} } }
  local in_case = false
  ---@type table|nil
  local scope

  local function top()
    return frames[#frames]
  end

  ---@return string[]
  local function path_names()
    local names = {}
    for i = 2, #frames do
      names[#names + 1] = frames[i].name
    end
    return names
  end

  local function is_timeout(message)
    return require("testing.run.timeout").is_timeout(message)
  end
  -- A real case already carries the run's timeout: the persistent timeout error of the deadline also
  -- fires in the rest of the describe body, and that second hit must not become a second timeout case
  -- ("one hung file, two timeouts").
  local timed_out = false

  ---@param case Testing.Result.Case
  local function emit(case)
    if case.error and is_timeout(case.error.message) then
      timed_out = true
    end
    cases[#cases + 1] = case
    if opts.on_case then
      opts.on_case(case)
    end
  end

  ---A case that exists only to carry an error that happened outside any `it`.
  ---@param name string
  ---@param err any
  local function error_case(name, err)
    local message, traceback = describe_error(err)
    if timed_out and is_timeout(message) then
      return
    end
    a.begin_case({ file = rel, describe = path_names(), name = name })
    local case = a.current() --[[@as Testing.Result.Case]]
    case.status = "error"
    case.error = { message = message, traceback = traceback }
    emit(a.end_case())
  end

  -- Every it()/pending() the file registered, whatever the selector later accepts: a file with
  -- none ran nothing, and that must never look like a pass.
  local registered = 0

  ---Unique id for a case about to run; the numeric suffix keeps duplicates apart.
  ---@param name string
  ---@return string|integer|nil param
  local function dedupe(name)
    registered = registered + 1
    local id = result.case_id({ file = rel, describe = path_names(), name = name })
    seen[id] = (seen[id] or 0) + 1
    return seen[id] > 1 and seen[id] or nil
  end

  ---@param name string
  ---@param reason string
  ---@param line integer|nil
  local function skipped_case(name, reason, line)
    local param = dedupe(name)
    local id = result.case_id({ file = rel, describe = path_names(), name = name, param = param })
    if opts.select and not opts.select(id) then
      return
    end
    if opts.dry then
      list[#list + 1] = { id = id, describe = path_names(), name = name, line = line }
      return
    end
    a.begin_case({ file = rel, describe = path_names(), name = name, param = param, line = line })
    local case = a.current() --[[@as Testing.Result.Case]]
    case.status = "skip"
    case.reason = reason
    emit(a.end_case())
  end

  -- -------------------------------------------------------
  -- The busted globals
  -- -------------------------------------------------------

  local function describe(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then
      error("testing: describe(name, fn) needs a string and a function", 2)
    end
    if in_case then
      error("testing: describe() inside an it() body is not supported", 2)
    end
    local parent = top()
    frames[#frames + 1] =
      { name = name, before = {}, after = {}, teardown = {}, broken = parent.broken }
    local ran, err = xpcall(fn, with_traceback)
    if not ran then
      error_case("<describe body>", err)
    end
    local frame = top()
    for _, hook in ipairs(frame.teardown) do
      local done, terr = xpcall(hook, with_traceback)
      if not done then
        error_case("<teardown>", terr)
      end
    end
    frames[#frames] = nil
  end

  ---@param hooks_of "before"|"after"
  local function hooks_run(hooks_of)
    for _, frame in ipairs(frames) do
      for _, hook in ipairs(frame[hooks_of]) do
        hook()
      end
    end
  end

  local function it(name, fn)
    if type(name) ~= "string" then
      error("testing: it(name, fn) needs a string name", 2)
    end
    if in_case then
      error("testing: it() inside an it() body is not supported", 2)
    end
    local line = debug.getinfo(2, "l").currentline
    if type(fn) ~= "function" then
      return skipped_case(name, "no test function (pending)", line)
    end
    local param = dedupe(name)
    local id = result.case_id({ file = rel, describe = path_names(), name = name, param = param })
    if opts.select and not opts.select(id) then
      return
    end
    if opts.dry then
      list[#list + 1] = { id = id, describe = path_names(), name = name, line = line }
      return
    end
    local broken = top().broken
    local case = policy.guard(opts, function()
      return a.run_case({
        file = rel,
        describe = path_names(),
        name = name,
        param = param,
        line = line,
      }, function()
        if broken then
          error("a setup() of an enclosing block failed: " .. broken, 0)
        end
        in_case = true
        scope = a.scope()
        local current = a.current() --[[@as Testing.Result.Case]]
        local ok, err = xpcall(function()
          hooks_run("before")
          fn()
        end, with_traceback)
        -- after_each hooks run in every case, in plenary's order (outermost block first)
        for _, frame in ipairs(frames) do
          for _, hook in ipairs(frame.after) do
            local done, herr = xpcall(hook, with_traceback)
            if not done and ok then
              ok, err = false, herr
            end
          end
        end
        in_case = false
        scope = nil
        if ok then
          return
        end
        if type(err) == "table" and err.__pending == PENDING then
          local failed = false
          for _, rec in ipairs(current.assertions) do
            if not rec.ok then
              failed = true
            end
          end
          if not failed then
            current.status = "skip"
            current.reason = err.reason
          end
          return
        end
        error(err, 0)
      end)
    end)
    in_case = false
    scope = nil
    emit(case)
  end

  local function pending(name, fn)
    local reason = type(name) == "string" and name or "pending"
    if in_case then
      error({ __pending = PENDING, reason = reason }, 0)
    end
    local line = debug.getinfo(2, "l").currentline
    return skipped_case(reason, "pending", line)
  end

  local function before_each(fn)
    local t = top().before
    t[#t + 1] = fn
  end

  local function after_each(fn)
    local t = top().after
    t[#t + 1] = fn
  end

  local function setup(fn)
    local frame = top()
    local ok, err = xpcall(fn, with_traceback)
    if not ok then
      frame.broken = (describe_error(err))
      error_case("<setup>", err)
    end
  end

  local function teardown(fn)
    local t = top().teardown
    t[#t + 1] = fn
  end

  local assert_obj = luassert.new({
    scope = function()
      return scope
    end,
    is_spec_frame = function(source)
      return source == spec_source
    end,
  })

  ---@type table<string, any>
  local installed = {
    describe = describe,
    context = describe,
    it = it,
    specify = it,
    pending = pending,
    xit = pending,
    before_each = before_each,
    after_each = after_each,
    setup = setup,
    lazy_setup = setup,
    strict_setup = setup,
    teardown = teardown,
    lazy_teardown = teardown,
    strict_teardown = teardown,
    assert = assert_obj,
  }
  for name, why in pairs(M.UNSUPPORTED) do
    -- callable AND indexable (`stub(...)`, `spy.on(...)`, `mock.new(...)`): any use raises
    local function refuse()
      error(("testing: %s is not supported: %s"):format(name, why), 2)
    end
    installed[name] = setmetatable({}, { __call = refuse, __index = refuse })
  end

  -- -------------------------------------------------------
  -- Install, run, restore
  -- -------------------------------------------------------

  local saved = {}
  for _, name in ipairs(GLOBALS) do
    saved[name] = rawget(_G, name)
    rawset(_G, name, installed[name])
  end
  local luassert_loaded = package.loaded["luassert"]
  package.loaded["luassert"] = assert_obj

  local function restore()
    for _, name in ipairs(GLOBALS) do
      rawset(_G, name, saved[name])
    end
    package.loaded["luassert"] = luassert_loaded
  end

  local ran, err = xpcall(function()
    local chunk, load_err = loadfile(spec.path)
    if not chunk then
      error(load_err, 0)
    end
    local ok_chunk, chunk_err = xpcall(chunk, with_traceback)
    if not ok_chunk then
      error_case(vim.fs.basename(rel), chunk_err)
    end
    for _, hook in ipairs(frames[1].teardown) do
      local done, terr = xpcall(hook, with_traceback)
      if not done then
        error_case("<teardown>", terr)
      end
    end
  end, with_traceback)
  restore()
  if not ran then
    error_case(vim.fs.basename(rel), err)
  end

  if registered == 0 and #cases == 0 and not opts.dry then
    -- a spec file that registers no case runs nothing: a failing case says so
    a.begin_case({ file = rel, name = vim.fs.basename(rel) })
    local case = a.current() --[[@as Testing.Result.Case]]
    if opts.assertions == "warn" then
      -- a spec that registers its cases per platform (`if windows then it(...)`) has none on the
      -- others: under `assertions = "warn"` that is a skip with a warning (never silent, never green
      -- under `--strict`), not a failure
      case.status = "skip"
      case.reason = M.NO_CASE_REASON
      case.notes[#case.notes + 1] = M.NO_CASE_WARNING
    else
      case.notes[#case.notes + 1] = "the file registered no it()/pending() case"
    end
    emit(a.end_case())
  end
  return cases, list
end

return M
