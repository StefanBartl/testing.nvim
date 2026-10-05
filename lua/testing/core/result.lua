---@module 'testing.core.result'
---@brief The Result-IR (schema_version 1): builder, summary counting, JSON encoding, validation.
---@description
--- The IR is the one contract between the kernel and everything that reports on a run (guard rail
--- L1): runner, reporters, cache, UI and adapters know this table shape and nothing else. This
--- module is pure Lua apart from the (lazy) `lib.nvim.json` call in `encode`; it never touches the
--- editor, the file system or the clock unless a caller leaves out an id.
---
--- A case with no assertions is a failure, not a pass (`finish_case`, problem P4): a test that
--- asserts nothing proves nothing, and the message says so.
---
--- Path normalization (`normalize`, used by `encode`) replaces the repo root, the home directory,
--- the temp dir and the state dir with `<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`, so the serialized IR
--- is the same on every machine and carries no user name.

local M = {}

---@type integer
M.SCHEMA_VERSION = 1

---@type Testing.Status[]
M.STATUSES = { "pass", "fail", "error", "skip", "xfail", "xpass", "timeout", "crash" }

---@type table<string, boolean>
local STATUS_SET = {}
for _, s in ipairs(M.STATUSES) do
  STATUS_SET[s] = true
end

---@type table<string, string>
M.PLACEHOLDERS = { repo = "<REPO>", home = "<HOME>", tmp = "<TMP>", state = "<STATE>" }

---Message of the synthetic assertion a case without assertions receives.
---@type string
local NO_ASSERTIONS_MSG = "case made no assertions (a case without assertions proves nothing)"

-- =========================================================
-- Builders
-- =========================================================

---Build a run id: `<UTC ISO timestamp>-<4 hex>`. Both parts can be injected for tests.
---@param time? integer Unix time; default `os.time()`
---@param rnd? integer 0..65535; default `math.random`
---@return string
function M.make_run_id(time, rnd)
  local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ", time or os.time())
  return ("%s-%04x"):format(stamp, rnd or math.random(0, 0xffff))
end

---Stable case id `file::describe::...::name[#param]`. Backslashes in `file` become `/`.
---@param opts Testing.Result.CaseOpts
---@return string
function M.case_id(opts)
  local parts = { (opts.file:gsub("\\", "/")) }
  local describe = opts.describe
  if type(describe) == "string" then
    parts[#parts + 1] = describe
  elseif type(describe) == "table" then
    for _, d in ipairs(describe) do
      parts[#parts + 1] = d
    end
  end
  parts[#parts + 1] = opts.name
  local id = table.concat(parts, "::")
  if opts.param ~= nil then
    id = id .. "#" .. tostring(opts.param)
  end
  return id
end

---A run header with defaults for everything the caller does not know.
---@param opts? Testing.Result.RunOpts
---@return Testing.Result.Run
function M.new_run(opts)
  opts = opts or {}
  return {
    id = opts.id or M.make_run_id(),
    root = opts.root or M.PLACEHOLDERS.repo,
    project_key = opts.project_key or "unknown",
    nvim = opts.nvim or "unknown",
    os = opts.os or "unknown",
    arch = opts.arch,
    git = opts.git,
    seed = opts.seed,
    jobs = opts.jobs or 1,
    duration_ms = opts.duration_ms or 0,
    argv = opts.argv or {},
  }
end

---A fresh case: status `pass` is tentative until `finish_case` has looked at its assertions.
---@param opts Testing.Result.CaseOpts
---@return Testing.Result.Case
function M.new_case(opts)
  return {
    id = M.case_id(opts),
    file = (opts.file:gsub("\\", "/")),
    line = opts.line,
    tags = opts.tags or {},
    status = "pass",
    duration_ms = 0,
    retries = 0,
    assertions = {},
    effects = { spawned = {}, network = {}, fs_outside_tmp = {} },
    artifacts = {},
    notes = {},
  }
end

---An empty result: header, no cases, all counters zero.
---@param opts? Testing.Result.RunOpts
---@return Testing.Result
function M.new(opts)
  return {
    schema_version = M.SCHEMA_VERSION,
    run = M.new_run(opts),
    cases = {},
    summary = M.summarize({}),
  }
end

---Append a case. The summary is recomputed by `finalize`, not here.
---@param result Testing.Result
---@param case Testing.Result.Case
---@return Testing.Result.Case case the same table, for chaining
function M.add_case(result, case)
  result.cases[#result.cases + 1] = case
  return case
end

-- =========================================================
-- Verdict rules and summary
-- =========================================================

---Derive the final status of a case from what it recorded.
---
---  * statuses that are not computed (`error`, `skip`, `timeout`, `crash`, `xfail`, `xpass`) stay;
---  * any failed assertion -> `fail`;
---  * no assertion at all -> `fail`, with a synthetic `no_assertions` entry saying why (P4);
---  * otherwise `pass`;
---  * `opts.expect_fail` then maps `fail` -> `xfail` and `pass` -> `xpass` (but never the
---    `no_assertions` failure: a hole in the test is not an expected failure).
---@param case Testing.Result.Case
---@param opts? Testing.Result.FinishOpts
---@return Testing.Result.Case case the same table
function M.finish_case(case, opts)
  if case.status ~= "pass" and case.status ~= "fail" then
    return case
  end
  local failed, no_assertions = false, false
  for _, a in ipairs(case.assertions) do
    if not a.ok then
      failed = true
      break
    end
  end
  if not failed and #case.assertions == 0 then
    failed, no_assertions = true, true
    case.assertions[1] = { ok = false, kind = "no_assertions", msg = NO_ASSERTIONS_MSG }
  end
  case.status = failed and "fail" or "pass"
  if opts and opts.expect_fail and not no_assertions then
    case.status = failed and "xfail" or "xpass"
  end
  return case
end

---Count the cases per status; all eight keys are always present.
---@param cases Testing.Result.Case[]
---@return Testing.Result.Summary
function M.summarize(cases)
  ---@type Testing.Result.Summary
  local summary =
    { pass = 0, fail = 0, error = 0, skip = 0, xfail = 0, xpass = 0, timeout = 0, crash = 0 }
  for _, c in ipairs(cases) do
    if STATUS_SET[c.status] then
      summary[c.status] = summary[c.status] + 1
    end
  end
  return summary
end

---Recompute `result.summary` from `result.cases`.
---@param result Testing.Result
---@return Testing.Result result the same table
function M.finalize(result)
  result.summary = M.summarize(result.cases)
  return result
end

-- =========================================================
-- Normalization (path placeholders, valid UTF-8)
-- =========================================================

local MAX_DEPTH = 64

---Replace every byte sequence that is not valid UTF-8 by `?` (JSON must stay decodable).
---@param s string
---@return string
local function fix_utf8(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1)
      or (b >= 0xC2 and b <= 0xDF and 2)
      or (b >= 0xE0 and b <= 0xEF and 3)
      or (b >= 0xF0 and b <= 0xF4 and 4)
      or 0
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for k = i + 1, i + len - 1 do
        local c = s:byte(k)
        if c < 0x80 or c > 0xBF then
          ok = false
          break
        end
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
end

---@class Testing.Result.PathMatcher
---@field key string Root in forward slashes (lowercased when case-insensitive).
---@field ph string Placeholder.

---@param roots Testing.Result.PathRoots
---@param ci boolean
---@return Testing.Result.PathMatcher[] matchers longest root first
local function build_matchers(roots, ci)
  local list = {}
  for name, ph in pairs(M.PLACEHOLDERS) do
    local root = roots[name]
    if type(root) == "string" then
      root = root:gsub("\\", "/"):gsub("/+$", "")
      if root ~= "" then
        list[#list + 1] = { key = ci and root:lower() or root, ph = ph }
      end
    end
  end
  table.sort(list, function(a, b)
    if #a.key ~= #b.key then
      return #a.key > #b.key
    end
    return a.ph < b.ph
  end)
  return list
end

---Is the occurrence at `[i, j]` of `s` a whole path prefix (not the middle of a longer name)?
---@param s string
---@param i integer
---@param j integer
---@param absolute boolean Root starts with `/` (a POSIX path: must not sit inside a longer one)
---@return boolean
local function on_boundary(s, i, j, absolute)
  if s:sub(j + 1, j + 1):match("[%w_%-]") then
    return false
  end
  if absolute and i > 1 and s:sub(i - 1, i - 1):match("[%w_%.%-/~]") then
    return false
  end
  return true
end

---@param s string
---@param matchers Testing.Result.PathMatcher[]
---@param ci boolean
---@return string
local function scrub_paths(s, matchers, ci)
  if #matchers == 0 or not s:find("[/\\]") then
    return s
  end
  local flat = s:gsub("\\", "/")
  local low = ci and flat:lower() or flat
  local out, pos, changed = {}, 1, false
  while true do
    local best_i, best_j, best
    for _, m in ipairs(matchers) do
      local from = pos
      while true do
        local i, j = low:find(m.key, from, true)
        if not i or not j then
          break
        end
        if on_boundary(low, i, j, m.key:sub(1, 1) == "/") then
          if not best_i or i < best_i then
            best_i, best_j, best = i, j, m
          end
          break
        end
        from = i + 1
      end
    end
    if not best then
      break
    end
    out[#out + 1] = flat:sub(pos, best_i - 1)
    out[#out + 1] = best.ph
    pos = best_j + 1
    changed = true
  end
  if not changed then
    return s
  end
  out[#out + 1] = flat:sub(pos)
  return table.concat(out)
end

---Deep copy `value`, passing every string value through `fn`. Functions and userdata are dropped
---by the encoder later, not here.
---@param value any
---@param fn fun(s: string): string
---@param depth integer
---@return any
local function map_strings(value, fn, depth)
  local t = type(value)
  if t == "string" then
    return fn(value)
  end
  if t ~= "table" then
    return value
  end
  if depth > MAX_DEPTH then
    return "<max depth>"
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = map_strings(v, fn, depth + 1)
  end
  return copy
end

---Replace the roots in every string of `value` (a deep copy is returned, `value` is untouched).
---Backslashes of a string that contains a root are turned into `/` (one path style in the IR);
---strings without a root are returned as they are.
---@param value any
---@param roots Testing.Result.PathRoots
---@param opts? Testing.Result.NormalizeOpts
---@return any
function M.normalize(value, roots, opts)
  local ci = opts ~= nil and opts.case_insensitive == true
  local matchers = build_matchers(roots, ci)
  return map_strings(value, function(s)
    return scrub_paths(s, matchers, ci)
  end, 0)
end

-- =========================================================
-- Serialization
-- =========================================================

-- =========================================================
-- Redaction (free text only)
-- =========================================================

---Plain, optionally case-insensitive replacement of `word` where it stands alone: not touching a
---letter, digit or underscore on either side, so `bartl` is replaced in `by bartl.` but not in
---`StefanBartl/x` or in `compass`.
---@param s string
---@param word string
---@param repl string
---@param ci boolean
---@return string
local function replace_word(s, word, repl, ci)
  if word == "" then
    return s
  end
  local hay = ci and s:lower() or s
  local needle = ci and word:lower() or word
  local out, pos, from = {}, 1, 1
  while true do
    local i, j = hay:find(needle, from, true)
    if not i or not j then
      break
    end
    local before = i > 1 and s:sub(i - 1, i - 1) or ""
    local after = s:sub(j + 1, j + 1)
    if before:match("[%w_]") or after:match("[%w_]") then
      from = i + 1
    else
      out[#out + 1] = s:sub(pos, i - 1)
      out[#out + 1] = repl
      pos, from = j + 1, j + 1
    end
  end
  if pos == 1 then
    return s
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

---Redact one free-text string. Order matters: environment pairs first (their whole value goes),
---then user-home paths, e-mail shapes, then the named words. Works on the decoded string, never on
---JSON text, so a user called `pass` cannot break a key or a value of the IR.
---@param s string
---@param r Testing.Result.Redact
---@param ci boolean
---@return string
local function redact_string(s, r, ci)
  local has_pair = s:find("=", 1, true) ~= nil
  for _, name in ipairs(has_pair and r.env_names or {}) do
    if #name >= 2 then
      -- `NAME=value` up to the end of the quoted item or line (values may hold spaces and doubled
      -- backslashes: an inspected environment dump).
      local pat_name = name:gsub("%p", "%%%0")
      local out, pos = {}, 1
      while true do
        local i, j = s:find("%f[%w_]" .. pat_name .. "=", pos)
        if not i or not j then
          break
        end
        local e = s:find('["\n\r]', j + 1) or (#s + 1)
        out[#out + 1] = s:sub(pos, j)
        out[#out + 1] = "<ENV>"
        pos = e
      end
      if pos > 1 then
        out[#out + 1] = s:sub(pos)
        s = table.concat(out)
      end
    end
  end
  s = s:gsub("%a:[\\/]+[Uu]sers[\\/]+[^\\/%s\"']+", M.PLACEHOLDERS.home)
  s = s:gsub("([^%w])[\\/]+[Uu]sers[\\/]+[^\\/%s\"']+", "%1" .. M.PLACEHOLDERS.home)
  s = s:gsub("/home/[^/%s\"']+", M.PLACEHOLDERS.home)
  s = s:gsub("[%w%.%_%+%-]+@[%w%-]+[%w%.%-]*%.%a%a+", "<EMAIL>")
  for _, w in ipairs(r.words or {}) do
    if type(w.text) == "string" and #w.text >= 3 then
      s = replace_word(s, w.text, w.ph or "<REDACTED>", ci)
    end
  end
  return s
end

---Redact the free-text fields of every case (assertion text, error message and traceback, notes),
---on a copy. Structural strings (ids, status, kinds, paths) are never touched.
---@param value Testing.Result
---@param r Testing.Result.Redact
---@param ci boolean
---@return Testing.Result
local function redact_result(value, r, ci)
  local copy = vim.deepcopy(value)
  local function red(s)
    return type(s) == "string" and redact_string(s, r, ci) or s
  end
  for _, c in ipairs(copy.cases or {}) do
    for _, a in ipairs(c.assertions or {}) do
      a.msg, a.expected, a.actual = red(a.msg), red(a.expected), red(a.actual)
    end
    if type(c.error) == "table" then
      c.error.message, c.error.traceback = red(c.error.message), red(c.error.traceback)
    end
    for i, n in ipairs(c.notes or {}) do
      c.notes[i] = red(n)
    end
  end
  return copy
end

---Serialize to JSON through `lib.nvim.json` (keys sorted, so the same IR is the same bytes).
---Strings are made valid UTF-8; with `opts.roots` the paths are normalized first; with
---`opts.redact` the free text is redacted first (environment pairs, user-home paths, e-mail
---shapes, named words such as the user and host name).
---@param result Testing.Result
---@param opts? Testing.Result.EncodeOpts
---@return string|nil json
---@return string|nil err
function M.encode(result, opts)
  opts = opts or {}
  local matchers = opts.roots and build_matchers(opts.roots, opts.case_insensitive == true) or {}
  local ci = opts.case_insensitive == true
  if opts.redact then
    result = redact_result(result, opts.redact, ci)
  end
  local value = map_strings(result, function(s)
    return fix_utf8(scrub_paths(s, matchers, ci))
  end, 0)
  local json = require("lib.nvim.json")
  local encoded, err = json.encode(value, { indent = opts.indent })
  if not encoded then
    return nil, "cannot encode the result: " .. tostring(err)
  end
  return encoded, nil
end

-- =========================================================
-- Validation
-- =========================================================

local MAX_PROBLEMS = 100

---@param v any
---@return boolean
local function is_list(v)
  if type(v) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  return n == #v
end

---@param v any
---@return boolean
local function is_int(v)
  return type(v) == "number" and v == math.floor(v)
end

---@param list any
---@return boolean
local function is_string_list(list)
  if not is_list(list) then
    return false
  end
  for _, s in ipairs(list) do
    if type(s) ~= "string" then
      return false
    end
  end
  return true
end

---User-home path shapes that must not survive normalization (they carry the user name). Other
---absolute paths (a dependency checkout, the runtime) name no user and are not flagged.
---@param s string
---@return string|nil what
local function abs_path_leak(s)
  if s:find("[/\\]Users[/\\][^/\\%s]") or s:find("/home/[^/%s]") then
    return "a user home path"
  end
  return nil
end

---@param value any
---@param path string
---@param opts Testing.Result.ValidateOpts
---@param problems string[]
---@param depth integer
local function scan_leaks(value, path, opts, problems, depth)
  if depth > MAX_DEPTH or #problems >= MAX_PROBLEMS then
    return
  end
  local t = type(value)
  if t == "string" then
    for _, bad in ipairs(opts.forbid or {}) do
      -- Whole word, case-insensitive: the user name `bartl` is a leak in `by bartl` but not in the
      -- public handle `StefanBartl/lib.nvim`.
      if bad ~= "" and replace_word(value, bad, "", true) ~= value then
        problems[#problems + 1] = ("%s: contains forbidden text %q"):format(path, bad)
      end
    end
    if not opts.allow_emails and value:find("[%w%.%_%+%-]+@[%w%-]+[%w%.%-]*%.%a%a+") then
      problems[#problems + 1] = ("%s: contains an e-mail address"):format(path)
    end
    if not opts.allow_abs_paths then
      local what = abs_path_leak(value)
      if what then
        problems[#problems + 1] = ("%s: contains %s (not normalized to a placeholder)"):format(
          path,
          what
        )
      end
    end
  elseif t == "table" then
    for k, v in pairs(value) do
      if type(k) == "string" then
        scan_leaks(k, path .. "{key}", opts, problems, depth + 1)
      end
      scan_leaks(v, path .. "." .. tostring(k), opts, problems, depth + 1)
    end
  end
end

---@param run any
---@param problems string[]
local function validate_run(run, problems)
  local function bad(msg)
    problems[#problems + 1] = "run." .. msg
  end
  if type(run) ~= "table" then
    problems[#problems + 1] = "run: must be a table"
    return
  end
  for _, key in ipairs({ "id", "root", "project_key", "nvim", "os" }) do
    if type(run[key]) ~= "string" or run[key] == "" then
      bad(key .. ": must be a non-empty string")
    end
  end
  if run.arch ~= nil and type(run.arch) ~= "string" then
    bad("arch: must be a string")
  end
  if not is_int(run.jobs) or run.jobs < 1 then
    bad("jobs: must be an integer >= 1")
  end
  if type(run.duration_ms) ~= "number" or run.duration_ms < 0 then
    bad("duration_ms: must be a number >= 0")
  end
  if run.seed ~= nil and not is_int(run.seed) then
    bad("seed: must be an integer")
  end
  if not is_string_list(run.argv) then
    bad("argv: must be a list of strings")
  end
  if run.git ~= nil then
    if
      type(run.git) ~= "table"
      or type(run.git.sha) ~= "string"
      or type(run.git.dirty) ~= "boolean"
    then
      bad("git: must be { sha = string, dirty = boolean }")
    end
  end
end

---@param a any
---@param at string
---@param problems string[]
local function validate_assertion(a, at, problems)
  if type(a) ~= "table" then
    problems[#problems + 1] = at .. ": must be a table"
    return
  end
  if type(a.ok) ~= "boolean" then
    problems[#problems + 1] = at .. ".ok: must be a boolean"
  end
  if type(a.kind) ~= "string" or a.kind == "" then
    problems[#problems + 1] = at .. ".kind: must be a non-empty string"
  end
  for _, key in ipairs({ "msg", "expected", "actual", "file", "expected_ref", "diff" }) do
    if a[key] ~= nil and type(a[key]) ~= "string" then
      problems[#problems + 1] = ("%s.%s: must be a string"):format(at, key)
    end
  end
  if a.line ~= nil and (not is_int(a.line) or a.line < 1) then
    problems[#problems + 1] = at .. ".line: must be an integer >= 1"
  end
end

---Status-vs-assertions consistency, the verdict rules of `finish_case` seen from the outside.
---@param c Testing.Result.Case
---@param at string
---@param problems string[]
local function validate_verdict(c, at, problems)
  local n, failed = #c.assertions, 0
  for _, a in ipairs(c.assertions) do
    if type(a) == "table" and a.ok == false then
      failed = failed + 1
    end
  end
  if c.status == "pass" then
    if n == 0 then
      problems[#problems + 1] = at
        .. ".status: 'pass' without a single assertion (a case must assert)"
    elseif failed > 0 then
      problems[#problems + 1] = at .. ".status: 'pass' but an assertion failed"
    end
  elseif c.status == "fail" and failed == 0 then
    problems[#problems + 1] = at .. ".status: 'fail' without a failed assertion"
  elseif c.status == "error" then
    if type(c.error) ~= "table" or type(c.error.message) ~= "string" then
      problems[#problems + 1] = at .. ".error: status 'error' needs { message, traceback }"
    end
  end
end

---@param cases any
---@param problems string[]
local function validate_cases(cases, problems)
  if not is_list(cases) then
    problems[#problems + 1] = "cases: must be a list"
    return
  end
  local seen = {}
  for i, c in ipairs(cases) do
    local at = ("cases[%d]"):format(i)
    if type(c) ~= "table" then
      problems[#problems + 1] = at .. ": must be a table"
    else
      if type(c.id) ~= "string" or c.id == "" then
        problems[#problems + 1] = at .. ".id: must be a non-empty string"
      elseif seen[c.id] then
        problems[#problems + 1] = ("%s.id: duplicate id %q"):format(at, c.id)
      else
        seen[c.id] = true
      end
      if type(c.file) ~= "string" or c.file == "" then
        problems[#problems + 1] = at .. ".file: must be a non-empty string"
      elseif type(c.id) == "string" and c.id:sub(1, #c.file + 2) ~= c.file .. "::" then
        problems[#problems + 1] = at .. ".id: must start with '<file>::'"
      end
      if not STATUS_SET[c.status] then
        problems[#problems + 1] = ("%s.status: %q is not one of %s"):format(
          at,
          tostring(c.status),
          table.concat(M.STATUSES, "|")
        )
      end
      if type(c.duration_ms) ~= "number" or c.duration_ms < 0 then
        problems[#problems + 1] = at .. ".duration_ms: must be a number >= 0"
      end
      if not is_int(c.retries) or c.retries < 0 then
        problems[#problems + 1] = at .. ".retries: must be an integer >= 0"
      end
      if c.line ~= nil and (not is_int(c.line) or c.line < 1) then
        problems[#problems + 1] = at .. ".line: must be an integer >= 1"
      end
      for _, key in ipairs({ "tags", "notes" }) do
        if not is_string_list(c[key]) then
          problems[#problems + 1] = ("%s.%s: must be a list of strings"):format(at, key)
        end
      end
      if not is_list(c.artifacts) then
        problems[#problems + 1] = at .. ".artifacts: must be a list"
      end
      if type(c.effects) ~= "table" then
        problems[#problems + 1] = at .. ".effects: must be a table"
      else
        for _, key in ipairs({ "spawned", "network", "fs_outside_tmp" }) do
          if not is_string_list(c.effects[key]) then
            problems[#problems + 1] = ("%s.effects.%s: must be a list of strings"):format(at, key)
          end
        end
      end
      if not is_list(c.assertions) then
        problems[#problems + 1] = at .. ".assertions: must be a list"
      else
        for j, a in ipairs(c.assertions) do
          validate_assertion(a, ("%s.assertions[%d]"):format(at, j), problems)
        end
        if STATUS_SET[c.status] then
          validate_verdict(c, at, problems)
        end
      end
    end
    if #problems >= MAX_PROBLEMS then
      return
    end
  end
end

---Check a result (in memory or decoded from JSON) against the schema: shape, status enum, unique
---ids, summary == recount of the cases, status/assertion consistency, and no leaked paths.
---@param result any
---@param opts? Testing.Result.ValidateOpts
---@return boolean ok
---@return string[] problems empty when ok; capped at 100 entries
function M.validate(result, opts)
  opts = opts or {}
  local problems = {}
  if type(result) ~= "table" then
    return false, { "result: must be a table" }
  end
  if result.schema_version ~= M.SCHEMA_VERSION then
    problems[#problems + 1] = ("schema_version: must be %d"):format(M.SCHEMA_VERSION)
  end
  validate_run(result.run, problems)
  validate_cases(result.cases, problems)

  if type(result.summary) ~= "table" then
    problems[#problems + 1] = "summary: must be a table"
  else
    local expected = M.summarize(is_list(result.cases) and result.cases or {})
    for _, status in ipairs(M.STATUSES) do
      if result.summary[status] ~= expected[status] then
        problems[#problems + 1] = ("summary.%s: is %s but the cases count %d"):format(
          status,
          tostring(result.summary[status]),
          expected[status]
        )
      end
    end
    for key in pairs(result.summary) do
      if not STATUS_SET[key] then
        problems[#problems + 1] = ("summary.%s: unknown status key"):format(tostring(key))
      end
    end
  end

  scan_leaks(result, "result", opts, problems, 0)
  if #problems >= MAX_PROBLEMS then
    for i = #problems, MAX_PROBLEMS + 1, -1 do
      problems[i] = nil
    end
    problems[MAX_PROBLEMS] = "... more problems omitted"
  end
  return #problems == 0, problems
end

return M
