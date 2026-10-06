---@module 'testing.dialect.harness_project'
---@brief Dialect `h`: `return function(H)` specs run on the project's OWN `TESTS/harness.lua`, collecting.
---@description
--- The fleet's `return function(H)` specs run on an `H` that each project builds itself, with helpers
--- the fixed shims `a`, `b`, `c` do not have (`H.match`, `H.editable`, `H.fixture`, `H.check`, ...) or
--- implement differently (`H.eq` comparing tables deeply, `H.scratch(ft, lines)`, `H.write_file(path,
--- string)`). Dialect `h` keeps the project's harness and changes only what the runner needs:
---
---   * the harness file is loaded (`dofile`) and every function of its table is replaced IN PLACE by a
---     wrapper, so the table, its counters and its internal state stay one coherent object;
---   * an error that the harness' failure convention recognises (`testing.dialect.harness_conventions`)
---     is RECORDED as a failed assertion of the open case and the call returns `false`: the spec keeps
---     running, all failures are visible;
---   * a call to an assertion that returned normally is recorded as a passed assertion. Which helpers
---     are assertions is read from the harness source (a function whose body says `FAIL`), learned at
---     run time (it raised a failure, or it raised one of the harness' counters);
---   * a collector helper (`H.check(name, fn)`: it pcalls `fn` and appends to `H.failures` itself) is
---     recorded as ONE assertion, failed when the harness collected a failure or `fn` raised, with the
---     callback's own error as the message;
---   * any other error is not an assertion failure (a helper's own bug, an error raised by a callback):
---     it propagates untouched and ends the file as an `error`.
---
--- NEVER GREENER THAN THE PROJECT. After the file ran, the harness' own bookkeeping is reconciled with
--- what the adapter recorded: failures that appeared in a collected list (`H.failures`) or a failure
--- counter without the adapter having seen the call that caused them, and failure lines the harness
--- printed (`[FAIL] ...`) beyond the failed assertions recorded, are added as failed assertions. A
--- spec whose own harness says "7 failed" is therefore red here with those 7, never green.
---
--- The adapter also hands the printed lines to the assertion policy (`testing.policy`): a file that
--- asserts nothing and printed `skip ...` is a skip.
---
--- Limits, honestly: a helper that calls other assertions and fails in the middle stops there; a
--- harness whose failures are neither `FAIL ...` errors nor collected anywhere the conventions know is
--- not recognised and its errors end the file as `error` (loud, never green). New conventions are data:
--- see `testing.dialect.harness_conventions`.

local conventions = require("testing.dialect.harness_conventions")
local policy = require("testing.policy")

local M = {}

local unpack_fn = table.unpack or unpack

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---@param ... any
---@return table
local function pack(...)
  return { n = select("#", ...), ... }
end

---Names of the functions in the harness source whose body raises a message mentioning `FAIL` (static scan).
---@param text string
---@return table<string, boolean>
function M.assertion_names(text)
  local names = {}
  -- `function H.name(`, `function M.name(` and `H.name = function(`
  local starts = {}
  for pos, name in text:gmatch("()function%s+[%a_][%w_]*%.([%a_][%w_]*)%s*%(") do
    starts[#starts + 1] = { pos = pos, name = name }
  end
  for pos, name in text:gmatch("()[%a_][%w_]*%.([%a_][%w_]*)%s*=%s*function") do
    starts[#starts + 1] = { pos = pos, name = name }
  end
  table.sort(starts, function(x, y)
    return x.pos < y.pos
  end)
  for i, s in ipairs(starts) do
    local stop = starts[i + 1] and starts[i + 1].pos - 1 or #text
    local body = text:sub(s.pos, stop)
    -- an assertion raises (`error(`) a message that says FAIL; a helper that only prints one is none
    if body:find("FAIL", 1, true) and body:find("error%s*%(") then
      names[s.name] = true
    end
  end
  return names
end

---Directory walk upwards from a spec to the first `harness.lua`, never above the project root.
---@param spec_path string Absolute spec path.
---@param root string Absolute project root.
---@return string|nil path
function M.find_harness(spec_path, root)
  local uv = vim.uv or vim.loop
  root = slashes(root):gsub("/+$", "")
  local dir = vim.fs.dirname(slashes(spec_path))
  while dir and #dir >= #root do
    local candidate = dir .. "/harness.lua"
    local st = uv.fs_stat(candidate)
    if st and st.type == "file" then
      return candidate
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---@class Testing.HarnessProject.State
---@field a Testing.Assert.Context
---@field harness table The project's harness table (wrapped in place).
---@field file? string Path of the harness file (its frames are never a call site).
---@field resolved Testing.Harness.Resolved
---@field assertions table<string, boolean> Helpers known to be assertions.
---@field active boolean False once the file ended: late calls pass straight through.
---@field in_assert integer Nesting of known assertion helpers (an assertion inside one is not recorded twice).
---@field depth integer Nesting of wrapped calls.
---@field recorded integer Assertions recorded so far (passed or failed): a helper that wraps a callback is told apart from an assertion by it.
---@field base table<string, integer> Length of every collected list when the file started.
---@field attributed table<string, integer> Failures per list that the adapter recorded itself.
---@field base_fail integer Failure counters when the file started.
---@field generic_base table<string, integer> Size of every field that looks like a failure record when the file started.
---@field attributed_fail integer Failure-counter growth the adapter recorded itself.
---@field printed_fail integer Failure lines printed inside wrapped calls.
---@field printed_lines string[] The first of them.
---@field capture? Testing.Policy.Capture
---@field error_site? { err: string, file?: string, line?: integer } Where the spec called the helper that raised `err` (innermost first).

---File and line of the first frame that is neither C, this module nor the harness file.
---@param state Testing.HarnessProject.State
---@return string|nil file
---@return integer|nil line
local function call_site(state)
  local level = 2
  while level < 30 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      return nil, nil
    end
    local src = info.source
    local file = slashes(src:sub(1, 1) == "@" and src:sub(2) or info.short_src)
    local skip = info.what == "C"
      or file:find("lua/testing/dialect/harness_project.lua", 1, true) ~= nil
      or (state.file ~= nil and file == state.file)
    if not skip then
      return file, info.currentline > 0 and info.currentline or nil
    end
    level = level + 1
  end
  return nil, nil
end

---Where a recorded check happened: the call site of the wrapper, refined by the position the error
---itself carries (`error(msg, 2)` points at the spec's call of the assertion) unless that position lies
---in the harness file or was shortened by Lua (`...`) and cannot be trusted as a path.
---@param state Testing.HarnessProject.State
---@param efile? string
---@param eline? integer
---@return string|nil file
---@return integer|nil line
local function site_of(state, efile, eline)
  local file, line = call_site(state)
  if eline and efile and not efile:find("^%.%.%.") and efile ~= state.file then
    return efile, eline
  end
  return file, line
end

---@param state Testing.HarnessProject.State
---@return integer
local function fail_counter_sum(state)
  local n = 0
  for _, name in ipairs(state.resolved.fail_counters) do
    local v = rawget(state.harness, name)
    if type(v) == "number" then
      n = n + v
    end
  end
  return n
end

---@param state Testing.HarnessProject.State
---@return integer
local function pass_counter_sum(state)
  local n = 0
  for _, name in ipairs(state.resolved.pass_counters) do
    local v = rawget(state.harness, name)
    if type(v) == "number" then
      n = n + v
    end
  end
  return n
end

---@param state Testing.HarnessProject.State
---@param name string
---@return integer
local function list_len(state, name)
  local list = rawget(state.harness, name)
  return type(list) == "table" and #list or 0
end

---@param state Testing.HarnessProject.State
---@param kind string
---@param ok boolean
---@param msg? string
---@param file? string
---@param line? integer
local function record(state, kind, ok, msg, file, line)
  local case = state.a.current()
  if not case then
    return
  end
  case.assertions[#case.assertions + 1] =
    { ok = ok, kind = kind, msg = msg, file = file, line = line }
  state.recorded = state.recorded + 1
end

---Text of an error without its `file:line:` prefix, and that position.
---@param err any
---@return string text
---@return string|nil file
---@return integer|nil line
local function split_position(err)
  if type(err) ~= "string" then
    return ("non-string error value (%s)"):format(type(err)), nil, nil
  end
  local file, line, text = err:match("^(.-):(%d+): (.*)$")
  if text then
    return text, slashes(file), tonumber(line)
  end
  return err, nil, nil
end

---Wrap one function of the harness.
---@param state Testing.HarnessProject.State
---@param key string
---@param original function
---@return function
local function wrap(state, key, original)
  local resolved = state.resolved
  local is_collector = resolved.collectors[key] == true
  return function(...)
    local case = state.active and state.a.current() or nil
    if not case then
      return original(...)
    end
    local args = pack(...)

    -- a collector catches its callback's error itself: keep a copy of it for the message
    local captured, caught = nil, false
    if is_collector then
      for i = 1, args.n do
        if type(args[i]) == "function" then
          local callback = args[i]
          args[i] = function(...)
            local r = pack(pcall(callback, ...))
            if not r[1] then
              captured, caught = r[2], true
              error(r[2], 0)
            end
            return unpack_fn(r, 2, r.n)
          end
          break
        end
      end
    end

    local entered_in_assert = state.in_assert
    local known = state.assertions[key] == true and not is_collector
    if known then
      state.in_assert = state.in_assert + 1
    end
    local outermost = state.depth == 0
    state.depth = state.depth + 1
    local printed_from = state.capture and #state.capture.lines or 0
    local pass_before = pass_counter_sum(state)
    local recorded_before = state.recorded
    local fail_before = fail_counter_sum(state)
    local lists_before = {}
    for _, name in ipairs(resolved.lists) do
      lists_before[name] = list_len(state, name)
    end

    local res = pack(pcall(original, unpack_fn(args, 1, args.n)))

    state.depth = state.depth - 1
    if known then
      state.in_assert = state.in_assert - 1
    end
    if outermost and state.capture then
      local lines = state.capture.lines
      for i = printed_from + 1, #lines do
        if resolved.fail_line(lines[i]) then
          state.printed_fail = state.printed_fail + 1
          if #state.printed_lines < 3 then
            state.printed_lines[#state.printed_lines + 1] = lines[i]
          end
        end
      end
    end

    if res[1] then
      if is_collector then
        local grew = 0
        for _, name in ipairs(resolved.lists) do
          local delta = list_len(state, name) - lists_before[name]
          if delta > 0 then
            grew = grew + delta
            state.attributed[name] = (state.attributed[name] or 0) + delta
          end
        end
        local fail_delta = fail_counter_sum(state) - fail_before
        if fail_delta > 0 then
          state.attributed_fail = state.attributed_fail + fail_delta
        end
        if grew > 0 or fail_delta > 0 or caught then
          local text, efile, eline = split_position(captured)
          local name = type(args[1]) == "string" and args[1] or key
          local msg = caught and ("%s: %s"):format(name, text)
            or ("%s: the project harness recorded a failure"):format(name)
          -- the innermost wrapper that saw the error knows where the spec called the assertion
          local site = state.error_site
          if caught and site and site.err == captured then
            efile, eline = site.file, site.line
          end
          local file, line = site_of(state, efile, eline)
          record(state, key, false, msg, file, line)
        else
          local file, line = call_site(state)
          record(state, key, true, nil, file, line)
        end
      elseif entered_in_assert == 0 then
        -- the project's counter grew by more than the assertions recorded INSIDE this call: the helper is an
        -- assertion itself. A helper that only runs a callback (`H.notifications(fn)`, `H.notices(fn)`) raises
        -- the counter through the callback's own assertions, which are recorded one by one: counting the
        -- helper too would double them (and learning it as an assertion would collapse them next time)
        local counted = pass_counter_sum(state) - pass_before > state.recorded - recorded_before
        if counted then
          state.assertions[key] = true
        end
        if known or counted then
          local file, line = call_site(state)
          record(state, key, true, nil, file, line)
        end
      end
      return unpack_fn(res, 2, res.n)
    end

    local err = res[2]
    if not is_collector and entered_in_assert == 0 then
      local failure = resolved.classify(err)
      if failure then
        state.assertions[key] = true
        local file, line = site_of(state, failure.file, failure.line)
        record(state, key, false, failure.msg, file, line)
        return false
      end
    end
    -- not a failure of a check here (an outer collector may judge it): remember where the spec called
    -- the helper, once per error value, innermost first
    if type(err) == "string" and (not state.error_site or state.error_site.err ~= err) then
      local file, line = call_site(state)
      state.error_site = { err = err, file = file, line = line }
    end
    error(err, 0)
  end
end

---Wrap the project's harness in place and return the table the spec receives as `H`.
---@param a Testing.Assert.Context|table Context (needs `current()`).
---@param harness table The table the project's `harness.lua` returned (it is modified in place).
---@param assertions? table<string, boolean> Names known to be assertions (`M.assertion_names`).
---@param opts? { source?: string, file?: string, capture?: Testing.Policy.Capture }
---@return table H The same table, its functions wrapped.
---@return Testing.HarnessProject.State state
function M.new(a, harness, assertions, opts)
  opts = opts or {}
  local resolved = conventions.resolve(harness, opts.source)
  ---@type Testing.HarnessProject.State
  local state = {
    a = a,
    harness = harness,
    file = opts.file and slashes(opts.file) or nil,
    resolved = resolved,
    assertions = assertions or {},
    active = true,
    in_assert = 0,
    depth = 0,
    recorded = 0,
    base = {},
    attributed = {},
    base_fail = 0,
    generic_base = {},
    attributed_fail = 0,
    printed_fail = 0,
    printed_lines = {},
    capture = opts.capture,
  }
  for _, name in ipairs(resolved.lists) do
    state.base[name] = list_len(state, name)
  end
  state.base_fail = fail_counter_sum(state)
  for key in pairs(harness) do
    local size = conventions.looks_like_failure_field(key)
        and conventions.failure_field_size(harness, key)
      or nil
    if size then
      state.generic_base[key] = size
    end
  end
  local keys = {}
  for key, value in pairs(harness) do
    if type(value) == "function" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    harness[key] = wrap(state, key, harness[key])
  end
  return harness, state
end

---After the file ran: add what the project's harness recorded and the adapter did not see, and stop
---recording (late calls pass straight through).
---@param state Testing.HarnessProject.State
function M.reconcile(state)
  local case = state.a.current()
  state.active = false
  if not case then
    return
  end
  local resolved = state.resolved
  for _, name in ipairs(resolved.lists) do
    local list = rawget(state.harness, name)
    local unseen = list_len(state, name) - state.base[name] - (state.attributed[name] or 0)
    if unseen > 0 and type(list) == "table" then
      local first = {}
      for i = #list - unseen + 1, math.min(#list, #list - unseen + 3) do
        first[#first + 1] = tostring(list[i]):sub(1, 200)
      end
      record(
        state,
        "project_failures",
        false,
        ("the project's harness collected %d failure(s) in H.%s that the adapter did not see: %s"):format(
          unseen,
          name,
          table.concat(first, "; ")
        )
      )
    end
  end
  local unseen_counter = fail_counter_sum(state) - state.base_fail - state.attributed_fail
  if unseen_counter > 0 then
    record(
      state,
      "project_failures",
      false,
      ("the project's harness counted %d failure(s) the adapter did not see"):format(unseen_counter)
    )
  end
  local failed = 0
  for _, rec in ipairs(case.assertions) do
    if not rec.ok then
      failed = failed + 1
    end
  end
  if state.printed_fail > failed then
    record(
      state,
      "project_failures",
      false,
      ("the project's harness printed %d failure line(s) that the adapter did not record: %s"):format(
        state.printed_fail - failed,
        table.concat(state.printed_lines, " | ")
      )
    )
    failed = state.printed_fail -- accounted for: the generic net below judges only what is beyond that
  end
  -- the generic net: a field that looks like a failure record and grew by more than the failures that
  -- are already recorded (a field the conventions know is covered above; one they do not know, or one
  -- that came into existence while the file ran, is judged here)
  local known = {}
  for _, name in ipairs(resolved.lists) do
    known[name] = true
  end
  for _, name in ipairs(resolved.fail_counters) do
    known[name] = true
  end
  local widest, widest_name = 0, nil
  for key in pairs(state.harness) do
    if not known[key] and conventions.looks_like_failure_field(key) then
      local size = conventions.failure_field_size(state.harness, key)
      local grown = size and (size - (state.generic_base[key] or 0)) or 0
      if grown > widest then
        widest, widest_name = grown, key
      end
    end
  end
  if widest_name and widest > failed then
    record(
      state,
      "project_failures",
      false,
      ("the project's harness field H.%s grew by %d during the file (failure records the adapter did not see)"):format(
        widest_name,
        widest
      )
    )
  end
end

---Run one `return function(H)` spec file on the project's harness.
---@param a Testing.Assert.Context
---@param spec { path: string, rel: string, harness?: string, root?: string }
---@param opts? { on_case?: fun(case: Testing.Result.Case), assertions?: "error"|"warn" }
---@return Testing.Result.Case[] cases
function M.run_file(a, spec, opts)
  local case = policy.guard(opts, function(capture)
    return a.run_case({ file = spec.rel, name = vim.fs.basename(spec.rel) }, function()
      local path = spec.harness or (spec.root and M.find_harness(spec.path, spec.root))
      if not path then
        error(("dialect h: no harness.lua found above %s"):format(spec.rel), 0)
      end
      local f = assert(io.open(path, "rb"))
      local text = f:read("*a")
      f:close()
      local harness = dofile(path)
      if type(harness) ~= "table" then
        error(
          ("dialect h: %s must return the harness table, got %s"):format(path, type(harness)),
          0
        )
      end
      local H, state = M.new(a, harness, M.assertion_names(text), {
        source = text,
        file = path,
        capture = capture,
      })
      local ran, run_err = xpcall(function()
        local run = dofile(spec.path)
        if type(run) ~= "function" then
          error(
            ("%s must return `function(H)`, got %s"):format(
              spec.rel,
              run == nil and "nothing" or type(run)
            ),
            0
          )
        end
        run(H)
      end, function(e)
        -- keep the traceback of a raise of the spec itself; other error values travel untouched
        return type(e) == "string" and debug.traceback(e, 2) or e
      end)
      M.reconcile(state)
      if not ran then
        error(run_err, 0)
      end
    end)
  end)
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
