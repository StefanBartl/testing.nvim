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
---     it propagates untouched and ends the file as an `error`. The exception is the error of a failed check
---     that got out of a `pcall` of the spec (cleanup, then raised again): `record_escaped` books it as a failure
---     of that check;
---   * except inside a `pcall` / `xpcall` that the SPEC wrote (`testing.core.protected`): there the error of a
---     failed check propagates too, so a spec can ask "does this fail?". The helpers of the harness itself
---     are passed over (`harness_chunks`), the code under test is not.
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
local protected = require("testing.core.protected")

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

---Source text without Lua comments (line and long comments; string literals and long strings are kept). A doc
---comment above a function would otherwise be read as part of the PREVIOUS function's body by `assertion_names`,
---and the verdict would depend on the wording of a comment ("raises FAIL through error(...)").
M.strip_comments = require("testing.discover.lua_text").strip_comments

-- harness text -> names found in it: every spec file of a project reads the same harness again
---@type table<string, table<string, boolean>>
local NAMES_OF = {}
local names_cached = 0

---Names of the functions in the harness source whose body raises a message mentioning `FAIL` (static scan).
---A copy: the adapter learns names while it runs and adds them to what it was given.
---@param text string
---@return table<string, boolean>
function M.assertion_names(text)
  local cached = NAMES_OF[text]
  if cached then
    return vim.deepcopy(cached)
  end
  local found = M.scan_assertion_names(text)
  if names_cached >= 32 then
    NAMES_OF, names_cached = {}, 0
  end
  NAMES_OF[text], names_cached = found, names_cached + 1
  return vim.deepcopy(found)
end

---@param text string
---@return table<string, boolean>
function M.scan_assertion_names(text)
  local names = {}
  text = M.strip_comments(text)
  -- `function H.name(`, `function M.name(` and `H.name = function(`
  local starts = {}
  for pos, name in text:gmatch("()function%s+[%a_][%w_]*%.([%a_][%w_]*)%s*%(") do
    starts[#starts + 1] = { pos = pos, name = name }
  end
  -- (`%f[%w_]`: a match starts at the beginning of a word only, or a long run of word characters (a base64 blob in a
  -- string) would be tried from every position: quadratic)
  for pos, name in text:gmatch("()%f[%w_][%a_][%w_]*%.([%a_][%w_]*)%s*=%s*function") do
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
---@field transparent table<string, true> Chunks that define a function of the harness: their protected calls pass an error on (`testing.core.protected`).
---@field resolved Testing.Harness.Resolved
---@field assertions table<string, boolean> Helpers known to be assertions.
---@field active boolean False once the file ended: late calls pass straight through.
---@field in_assert integer Nesting of known assertion helpers (an assertion inside one is not recorded twice).
---@field depth integer Nesting of wrapped calls.
---@field recorded integer Assertions recorded so far (passed or failed): a helper that wraps a callback is told apart from an assertion by it.
---@field base_items table<string, any[]> The entries of every collected list when the file started.
---@field base_lists table<string, table|nil> The list tables themselves when the file started (a spec may replace one).
---@field base_fail integer Failure counters when the file started.
---@field generic_base table<string, integer> Size of every field that looks like a failure record when the file started.
---@field listed { entry: Testing.Result.Assertion, printed: integer, values: table<string, any[]> }[] Collector failures recorded from a failure list, oldest first (`values`: what the call appended, per list).
---@field attributed_fail integer Failure-counter growth the adapter recorded itself.
---@field printed_fail integer Failure lines printed inside wrapped calls.
---@field printed_lines string[] The first of them.
---@field capture? Testing.Policy.Capture
---@field error_sites table<string, { file?: string, line?: integer, call: integer }> Where the spec called the helper that raised an error text (innermost first), per text.
---@field error_site_count integer Entries of `error_sites`.
---@field calls integer Outermost wrapped calls started so far (one raise passes the wrappers of ONE such call).

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
---@return Testing.Result.Assertion|nil entry
local function record(state, kind, ok, msg, file, line)
  local case = state.a.current()
  if not case then
    return nil
  end
  local entry = { ok = ok, kind = kind, msg = msg, file = file, line = line }
  case.assertions[#case.assertions + 1] = entry
  state.recorded = state.recorded + 1
  return entry
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

---wrapper -> the function of the project it replaced: a harness table that outlives a run (`H` cached in `_G` or
---in `package.loaded`) is wrapped again by the next run, which must see the project's own function, not a layer
---of the earlier run (layers would pile up, one per file, and hide the chunk the function was defined in)
---@type table<function, function>
local ORIGINAL = setmetatable({}, { __mode = "k" })

---Wrap one function of the harness.
---@param state Testing.HarnessProject.State
---@param key string
---@param original function
---@return function
local function wrap(state, key, original)
  local resolved = state.resolved
  local is_collector = resolved.collectors[key] == true
  original = ORIGINAL[original] or original
  local wrapper
  wrapper = function(...)
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
    if outermost then
      state.calls = state.calls + 1
    end
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
    -- failure lines this call printed (a nested call counts its own, the outermost call adds them to the file's)
    local own_printed = 0
    if state.capture and (outermost or is_collector) then
      local lines = state.capture.lines
      for i = printed_from + 1, #lines do
        if resolved.fail_line(lines[i]) then
          own_printed = own_printed + 1
          if outermost then
            state.printed_fail = state.printed_fail + 1
            if #state.printed_lines < 3 then
              state.printed_lines[#state.printed_lines + 1] = lines[i]
            end
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
          local site = type(captured) == "string" and state.error_sites[captured] or nil
          if caught and site then
            efile, eline = site.file, site.line
          end
          local file, line = site_of(state, efile, eline)
          local entry = record(state, key, false, msg, file, line)
          if entry and grew > 0 then
            -- remembered so that a spec which takes the EXPECTED failure back out of the list can withdraw it
            local values = {}
            for _, list_name in ipairs(resolved.lists) do
              local list = rawget(state.harness, list_name)
              if list_len(state, list_name) > lists_before[list_name] then
                local added = {}
                for i = lists_before[list_name] + 1, #list do
                  added[#added + 1] = list[i]
                end
                values[list_name] = added
              end
            end
            state.listed[#state.listed + 1] =
              { entry = entry, printed = own_printed, values = values }
          end
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
    if
      not is_collector
      and entered_in_assert == 0
      and not protected.inside(state.a.entry, state.transparent)
    then
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
    if type(err) == "string" then
      local site = state.error_sites[err]
      -- the same raise passes the wrappers of one outermost call; the same TEXT raised by a later call is another
      -- raise (a loop, a helper called twice) and has its own place
      if not site or site.call ~= state.calls then
        if not site then
          if state.error_site_count >= 64 then
            state.error_sites, state.error_site_count = {}, 0
          end
          state.error_site_count = state.error_site_count + 1
        end
        local file, line = call_site(state)
        state.error_sites[err] = { file = file, line = line, call = state.calls }
      end
    end
    error(err, 0)
  end
  ORIGINAL[wrapper] = original
  return wrapper
end

---Absolute, normalized spelling of a chunk path (forward slashes, no `.` / `..` segments): it does not depend on
---how the file was found. A module found through a `./?.lua` entry of `package.path` (or `dofile("TESTS/x.lua")`)
---has a chunk name relative to the working directory, and `TESTS/../lib/x.lua` is not a file below `TESTS`.
---@param path string
---@return string
local function absolute(path)
  path = slashes(path)
  if not (path:find("^/") or path:find("^%a:/")) then
    path = slashes(vim.uv.cwd() or ".") .. "/" .. path
  end
  return (vim.fs.normalize(path, { expand_env = false }))
end

-- directories of a project that hold the code under test (what the runtime path loads), never a harness
local CODE_DIRS =
  { lua = true, plugin = true, after = true, ftplugin = true, autoload = true, src = true }

-- directories below a harness in the PROJECT ROOT that hold support code of the tests; anything else below a root
-- harness may be the plugin (`vendor/`, `core/`, a root-level module is no "below" at all and counts)
local TEST_DIRS = { tests = true, test = true, spec = true, specs = true }

---function -> absolute path of the chunk it was defined in, taken the first time it is seen: a relative chunk name
---is read against the working directory of THAT moment, so a harness table that outlives a run does not lose its
---relative helpers when the working directory changes in between
---@type table<function, string>
local CHUNK_PATH = setmetatable({}, { __mode = "k" })

---The chunks (`debug.getinfo(..., "S").source`) that define the harness: its file and the files below the
---directory of that file that define a function of `H` (one table level deep, raw fields only). A harness
---split over several files (`H.with_patched` from a helper module) is still the harness; its protected calls
---clean up and raise again, they never answer a question. A function from anywhere else is not the harness:
---`H.sut = require("plugin")` exports the code under test, and its `pcall` may swallow what the spec raises.
---Paths are compared in their absolute, normalized form, and a file below a directory of the runtime path
---(`lua/`, `plugin/`, `after/`, `ftplugin/`, `autoload/`, `src/`) of the harness directory is never part of the harness: a
---`harness.lua` in the project root has the plugin there (`src/` too). The files are not read: a support module below the
---harness directory that is exported through `H` counts although its `pcall` may keep the error.
---A relative chunk name is made absolute the first time the function is seen (`CHUNK_PATH`), so a harness table that
---outlives a run keeps its relative helpers when the working directory changes; only a function first seen after the
---change is read against the new directory.
---Call it before the functions are wrapped.
---@param harness table
---@param file? string Path of the harness file as it was loaded.
---@param root? string Project root. A harness that sits IN the root has the whole project below it: only files
---  directly in the root or below `tests/`, `test/`, `spec/` and `specs/` (any capitalisation) count then (the plugin
---  may live anywhere else).
---@return table<string, true>
local function harness_chunks(harness, file, root)
  ---@type table<string, true>
  local chunks = {}
  if not file then
    return chunks
  end
  chunks["@" .. file] = true
  local dir = absolute(file):match("^(.*)/[^/]*$")
  local at_root = false
  if dir ~= nil and root ~= nil then
    -- the same directory spelled differently (a symlinked project root, a case-insensitive file system) is still the
    -- root: a root that is missed would let the code under test below the harness count as the harness
    local uv = vim.uv or vim.loop
    at_root = absolute(root) == dir
      or (uv.fs_realpath(root) ~= nil and uv.fs_realpath(root) == uv.fs_realpath(dir))
  end
  ---@param value any
  local function add(value)
    if type(value) ~= "function" or not dir then
      return
    end
    -- a function of an earlier run's wrapper: the function of the project is what was defined in a chunk
    value = ORIGINAL[value] or value
    local info = debug.getinfo(value, "S")
    if info.what == "C" or info.source:sub(1, 1) ~= "@" then
      return
    end
    local path = CHUNK_PATH[value]
    if not path then
      path = absolute(info.source:sub(2))
      CHUNK_PATH[value] = path
    end
    local below = path:sub(1, #dir + 1) == dir .. "/"
    local top = below and path:sub(#dir + 2):match("^([^/]*)/") or nil
    if below and not CODE_DIRS[top] and not (at_root and top and not TEST_DIRS[top:lower()]) then
      -- the key stays the raw name: `protected.inside` looks the calling chunk up by its raw `source`
      chunks[info.source] = true
    end
  end
  for _, value in pairs(harness) do
    if type(value) == "table" then
      -- raw traversal: a table of the harness may carry metamethods that must not run here
      for _, inner in next, value do
        add(inner)
      end
    else
      add(value)
    end
  end
  return chunks
end

---Chunks (`@<path>`) of the spec files that ran in this process: a harness table that outlives a file carries what
---a spec put into it, and that is the spec's, not the harness's.
---@type table<string, true>
local spec_chunks = {}

---A failed check that reached the top of the file: the spec wrapped its body in a `pcall` of its own, cleaned up
---and raised the error again (`error(err, 0)`, `error(err)`, `assert(ok, err)`), so the file stopped at its first
---failed check. It is a failure of that check, not a broken spec: recorded like any failed assertion, with the
---position of the check (the innermost wrapper that saw the error knows where the spec called it).
---A text that is no failure of the project's convention (`nil` indexed, `error("boom")`) is not one: `false`, the
---caller raises it and the file ends as an `error`.
---@param state Testing.HarnessProject.State
---@param err any The error as it was raised, without the traceback.
---@return boolean recorded
function M.record_escaped(state, err)
  if type(err) ~= "string" then
    return false
  end
  -- `error(err)` and `assert` in front of a rethrow put `file:line: ` before the text, `xpcall(fn, debug.traceback)`
  -- hangs a traceback behind it: the text of the check is the first line without the position
  local bare = err:gsub("^[^\n]-:%d+: ", "", 1)
  local head = err:match("^[^\n]*")
  for _, text in ipairs({ err, bare, head, (head:gsub("^[^\n]-:%d+: ", "", 1)) }) do
    -- only an error that passed a helper of the harness is a failed check of the spec: a plugin that raises a
    -- message starting with `FAIL` (or a spec that does) is a broken file, not a failed check
    local site = state.error_sites[text]
    local failure = site and state.resolved.classify(text)
    if failure then
      record(state, "escaped", false, failure.msg, site.file, site.line)
      return true
    end
  end
  return false
end

---Wrap the project's harness in place and return the table the spec receives as `H`.
---@param a Testing.Assert.Context|table Context (needs `current()`).
---@param harness table The table the project's `harness.lua` returned (it is modified in place).
---@param assertions? table<string, boolean> Names known to be assertions (`M.assertion_names`).
---@param opts? { source?: string, file?: string, root?: string, capture?: Testing.Policy.Capture } `file` is the
---  path of the harness file as it was loaded; without it no helper of the harness is passed over by the pcall
---  rule. `root` is the project root (see `harness_chunks`).
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
    transparent = harness_chunks(harness, opts.file, opts.root),
    resolved = resolved,
    assertions = assertions or {},
    active = true,
    in_assert = 0,
    depth = 0,
    recorded = 0,
    base_items = {},
    base_lists = {},
    listed = {},
    base_fail = 0,
    generic_base = {},
    attributed_fail = 0,
    printed_fail = 0,
    printed_lines = {},
    error_sites = {},
    error_site_count = 0,
    calls = 0,
    capture = opts.capture,
  }
  for _, name in ipairs(resolved.lists) do
    local items, list = {}, rawget(harness, name)
    for i = 1, list_len(state, name) do
      items[i] = list[i]
    end
    state.base_items[name] = items
    state.base_lists[name] = list
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
  -- what is in every list now, with counts. A spec that tests the harness takes an expected failure back out of a
  -- list (`table.remove(H.failures)`, `H.failures = {}`): it is judged by WHAT is gone, not by how many entries there
  -- are (the oldest one may be gone, an entry of an earlier file, a new one may have taken its place)
  local present, lengths = {}, {}
  for _, name in ipairs(resolved.lists) do
    local list = rawget(state.harness, name)
    local counts = {}
    lengths[name] = type(list) == "table" and #list or 0
    for i = 1, lengths[name] do
      local v = list[i]
      if v == v then
        counts[v] = (counts[v] or 0) + 1
      end
    end
    -- the entries that were in the list when the file started and still are belong to the project, not to this file
    -- (a list the spec replaced (`H.failures = {}`) holds none of them)
    for _, v in ipairs(list == state.base_lists[name] and state.base_items[name] or {}) do
      if (counts[v] or 0) > 0 then
        counts[v] = counts[v] - 1
      end
    end
    present[name] = counts
  end
  -- a failure the adapter recorded whose entries are all gone from the lists was taken back: withdrawn
  local kept = {}
  for _, item in ipairs(state.listed) do
    local alive = 0
    for name, values in pairs(item.values) do
      local counts = present[name]
      for _, v in ipairs(values) do
        if counts and v == v and (counts[v] or 0) > 0 then
          counts[v] = counts[v] - 1
          alive = alive + 1
        end
      end
    end
    if alive > 0 then
      kept[#kept + 1] = item
    else
      for j = #case.assertions, 1, -1 do
        if case.assertions[j] == item.entry then
          table.remove(case.assertions, j)
          break
        end
      end
      -- the failure line it printed belongs to the failure that is gone
      state.printed_fail = math.max(0, state.printed_fail - item.printed)
    end
  end
  state.listed = kept
  for _, name in ipairs(resolved.lists) do
    -- what is left is in the list and nobody recorded it
    local counts, unseen = present[name], 0
    for _, count in pairs(counts) do
      unseen = unseen + count
    end
    if unseen > 0 then
      local list, first = rawget(state.harness, name), {}
      for i = 1, lengths[name] do
        local v = list[i]
        if v == v and (counts[v] or 0) > 0 then
          counts[v] = counts[v] - 1
          if #first < 3 then
            first[#first + 1] = tostring(v):sub(1, 200)
          end
        end
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
    return a.run_case(
      { file = spec.rel, name = vim.fs.basename(spec.rel), spec_path = spec.path },
      function()
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
          root = spec.root,
          capture = capture,
        })
        -- a harness table that outlives a file may carry helpers that a spec file put into it: no spec file that
        -- ran in this process (this one included) is part of the harness
        spec_chunks["@" .. spec.path] = true
        for chunk in pairs(state.transparent) do
          if spec_chunks[chunk] then
            state.transparent[chunk] = nil
          end
        end
        -- the error as it was raised: the handler below hangs a traceback on it, which would hide the text of a check
        local raw_err
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
          raw_err = e
          -- keep the traceback of a raise of the spec itself; other error values travel untouched
          return type(e) == "string" and debug.traceback(e, 2) or e
        end)
        M.reconcile(state)
        if not ran and not M.record_escaped(state, raw_err) then
          error(run_err, 0)
        end
      end
    )
  end)
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
