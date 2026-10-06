---@module 'testing.dialect.harness_conventions'
---@brief How a project's own harness reports a failed check: data and small functions, one entry per convention.
---@description
--- Dialect `h` runs a `return function(H)` spec on the project's OWN `TESTS/harness.lua` and still has
--- to see every failure, because the runner may never be greener than the project's own harness. The
--- fleet's harnesses report failures in a few ways; each one is a CONVENTION here, a table the adapter
--- (`testing.dialect.harness_project`) consults. A new convention is a new entry in `M.CONVENTIONS`
--- (or `M.register` from a spec), not a change of the adapter.
---
--- A convention is any subset of these parts:
---
---   detect(harness, source)  does this harness follow the convention? (decided per loaded harness
---                            from its table, `source` is its text); a convention without `detect`
---                            applies to every harness;
---   classify(err)            an error RAISED by an assertion helper: is it a failed check? Returns
---                            `{ msg, file?, line? }` (the adapter records it and returns `false`, the
---                            spec goes on) or nil (not an assertion failure: it propagates);
---   collectors(harness)      names of helpers that run a callback and CATCH its error themselves
---                            (`H.check(name, fn)`): the adapter learns the callback's error and tells
---                            pass from fail by what the helper collected;
---   lists(harness)           names of fields holding the failures the harness has collected
---                            (`H.failures`): growth of a list is failures, whether or not the adapter
---                            saw the call that caused it;
---   pass_counters(harness)   numeric fields counting executed assertions (`checks`, `assertions`,
---                            `passed`): a helper that raises them is an assertion;
---   fail_counters(harness)   numeric fields counting failures (`failed`);
---   fail_line(line)          is a printed line a failure notice (`[FAIL] name: ...`)?
---
--- Beyond the conventions there is a generic net (`looks_like_failure_field`): any number or list field
--- of the harness whose NAME says fail / err / bad / broken and that grew while a file ran is a
--- failure, whether or not a convention knows the harness (`H.n_bad`, `H.errors`, `H.fails`).
---
--- Conventions that exist in the fleet today:
---
---   fail_text         `error("FAIL <msg>: ...", 2)` raised by `H.eq` / `H.ok` / `H.match` (13 repos)
---   check_collector   `H.check(name, fn)` pcalls `fn`, prints `[ OK ]` / `[FAIL]` and appends the name
---                     to `H.failures`; the assertions inside raise plain errors (gopath.nvim)
---   failure_list      a harness with a `failures` list but no `check` (spotlight-style counters)
---   counters          `H.checks` / `H.assertions` / `H.passed` count assertions (fileops, emojis, gopath)
---   printed_failures  any helper that prints a failure line (`[FAIL] ...`, `FAIL ...`, `not ok ...`)
---
--- Pure Lua, no editor API.

local M = {}

---Does a field NAME of a harness look like a failure record (`failures`, `n_bad`, `errors`, `fail_count`)?
---The adapter's last line of defence: growth of such a number or list during a file is a failure the
---conventions did not name, so a harness with an unknown bookkeeping can never make a file greener
---than the project's own runner would.
---@param name any
---@return boolean
function M.looks_like_failure_field(name)
  if type(name) ~= "string" then
    return false
  end
  local lower = name:lower()
  return lower:find("fail", 1, true) ~= nil
    or lower:find("err", 1, true) ~= nil
    or lower:find("bad", 1, true) ~= nil
    or lower:find("broken", 1, true) ~= nil
end

---Current size of such a field: the number itself, or the length of a list; nil for anything else.
---@param harness table
---@param name string
---@return integer|nil
function M.failure_field_size(harness, name)
  local v = rawget(harness, name)
  if type(v) == "number" then
    return v
  elseif type(v) == "table" then
    return #v
  end
  return nil
end

---@class Testing.Harness.Failure
---@field msg string
---@field file? string
---@field line? integer

---@class Testing.Harness.Convention
---@field name string
---@field detect? fun(harness: table, source: string): boolean
---@field classify? fun(err: any): Testing.Harness.Failure|nil
---@field collectors? fun(harness: table): string[]
---@field lists? fun(harness: table): string[]
---@field pass_counters? fun(harness: table): string[]
---@field fail_counters? fun(harness: table): string[]
---@field fail_line? fun(line: string): boolean

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---Numeric fields of the harness among `names`.
---@param harness table
---@param names string[]
---@return string[]
local function numeric_fields(harness, names)
  local out = {}
  for _, name in ipairs(names) do
    if type(rawget(harness, name)) == "number" then
      out[#out + 1] = name
    end
  end
  return out
end

---@type Testing.Harness.Convention[]
M.CONVENTIONS = {
  {
    name = "fail_text",
    classify = function(err)
      if type(err) ~= "string" then
        return nil
      end
      -- `[<file>:<line>: ]FAIL ...`; the position prefix comes from `error(msg, 2)`
      local file, line, text = err:match("^(.-):(%d+): (FAIL.*)$")
      if not text then
        text = err:match("^(FAIL.*)$")
      end
      if not text then
        return nil
      end
      return { msg = text, file = file and slashes(file) or nil, line = tonumber(line) }
    end,
  },
  {
    name = "check_collector",
    detect = function(harness)
      return type(rawget(harness, "check")) == "function"
        and type(rawget(harness, "failures")) == "table"
    end,
    collectors = function()
      return { "check" }
    end,
    lists = function()
      return { "failures" }
    end,
  },
  {
    name = "failure_list",
    detect = function(harness)
      return type(rawget(harness, "failures")) == "table"
    end,
    lists = function()
      return { "failures" }
    end,
  },
  {
    name = "counters",
    detect = function(harness)
      return #numeric_fields(
          harness,
          { "checks", "assertions", "passed", "failed", "fail_count" }
        ) > 0
    end,
    pass_counters = function(harness)
      return numeric_fields(harness, { "checks", "assertions", "passed" })
    end,
    fail_counters = function(harness)
      return numeric_fields(harness, { "failed", "fail_count" })
    end,
  },
  {
    name = "printed_failures",
    fail_line = function(line)
      return line:find("^%s*%[FAIL%]") ~= nil
        or line:find("^%s*FAIL[%s:]") ~= nil
        or line:find("^%s*FAILED") ~= nil
        or line:find("^%s*not ok") ~= nil
    end,
  },
}

---Add a convention (checked after the built-in ones). A spec or a project can teach the adapter a
---harness that reports failures in a way no built-in convention knows.
---@param convention Testing.Harness.Convention
function M.register(convention)
  assert(
    type(convention) == "table" and type(convention.name) == "string",
    "convention needs a name"
  )
  M.CONVENTIONS[#M.CONVENTIONS + 1] = convention
end

---@class Testing.Harness.Resolved
---@field names string[] Conventions that apply to this harness.
---@field classify fun(err: any): Testing.Harness.Failure|nil
---@field collectors table<string, true>
---@field lists string[]
---@field pass_counters string[]
---@field fail_counters string[]
---@field fail_line fun(line: string): boolean

---@param into string[]
---@param from string[]|nil
local function add_unique(into, from)
  for _, name in ipairs(from or {}) do
    if not vim.tbl_contains(into, name) then
      into[#into + 1] = name
    end
  end
end

---The conventions that apply to a loaded harness, merged.
---@param harness table The table the project's `harness.lua` returned.
---@param source? string The text of `harness.lua`.
---@return Testing.Harness.Resolved
function M.resolve(harness, source)
  source = source or ""
  local active = {}
  for _, c in ipairs(M.CONVENTIONS) do
    local ok, applies = true, true
    if c.detect then
      ok, applies = pcall(c.detect, harness, source)
    end
    if ok and applies then
      active[#active + 1] = c
    end
  end
  local resolved = {
    names = {},
    collectors = {},
    lists = {},
    pass_counters = {},
    fail_counters = {},
  }
  for _, c in ipairs(active) do
    resolved.names[#resolved.names + 1] = c.name
    for _, name in ipairs(c.collectors and c.collectors(harness) or {}) do
      resolved.collectors[name] = true
    end
    add_unique(resolved.lists, c.lists and c.lists(harness))
    add_unique(resolved.pass_counters, c.pass_counters and c.pass_counters(harness))
    add_unique(resolved.fail_counters, c.fail_counters and c.fail_counters(harness))
  end
  resolved.classify = function(err)
    for _, c in ipairs(active) do
      if c.classify then
        local ok, failure = pcall(c.classify, err)
        if ok and failure then
          return failure
        end
      end
    end
    return nil
  end
  resolved.fail_line = function(line)
    for _, c in ipairs(active) do
      if c.fail_line then
        local ok, yes = pcall(c.fail_line, line)
        if ok and yes then
          return true
        end
      end
    end
    return false
  end
  return resolved
end

return M
