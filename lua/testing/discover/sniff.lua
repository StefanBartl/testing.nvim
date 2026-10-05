---@module 'testing.discover.sniff'
---@brief Dialect detection by signature sniffing of a spec file's text.
---@description
--- The fleet has five calling conventions (concept A.2). The file text decides which shim runs it:
---
---   a        `return function(H)`; `H` keys within eq, ok, tmpfile, read_lines, with_patched,
---            with_stdpath_config (lib.nvim, documentation, runtime-analysis)
---   b        `return function(H)` using scratch / tmproot / tmpdir() / canonical / write_file
---            (markdown.nvim, diff.nvim)
---   c        `return function(H)` using falsy / contains / write / tmpdir(fn) / scratch(lines, ft)
---            (images.nvim)
---   d        `local t = require("harness")` and `function M.run()`, `t.ok(name, cond, msg)`
---            (spotlight.nvim)
---   busted   top-level `describe(` / `it(` (plenary.busted of dap, sandbox, github_stats, ...)
---
--- Rules that keep the sniffer honest:
---   * an explicit override always wins and is reported as such;
---   * nothing matches -> `unknown`, with the reason. The caller reports it; nobody guesses silently;
---   * conflicting evidence (busted and `return function(H)`, helpers of b and c at once) -> `unknown`;
---   * a file that only uses `H.eq` / `H.ok` is `a`: those two behave the same in a, b and c.
---
--- The scan runs on `lua_text.code_only(text)` (no comments, no string contents), so a commented-out
--- `describe(` or a string mentioning `H.falsy` is not evidence.
---
--- Pure Lua, no editor API.

local lua_text = require("testing.discover.lua_text")

local M = {}

---Names of the dialects a spec file can be in (the values an override takes). The sniffer itself
---never answers `h` (a project harness is a fact about the project, not the file: see
---`testing.discover`); it reports the unknown keys in `foreign_keys` instead.
---@type string[]
M.DIALECTS = { "a", "b", "c", "d", "busted", "h" }

---@type table<string, boolean>
local DIALECT_SET = {}
for _, d in ipairs(M.DIALECTS) do
  DIALECT_SET[d] = true
end

---`H` keys per dialect (what the shims in `testing.dialect.harness_*` provide).
---@type table<string, string[]>
M.H_KEYS = {
  a = { "eq", "ok", "tmpfile", "read_lines", "with_patched", "with_stdpath_config" },
  b = { "eq", "ok", "scratch", "tmproot", "tmpdir", "canonical", "write_file" },
  c = { "eq", "ok", "falsy", "contains", "scratch", "tmpdir", "write" },
}

---@param list string[]
---@return table<string, boolean>
local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local A_SET, B_SET, C_SET = set_of(M.H_KEYS.a), set_of(M.H_KEYS.b), set_of(M.H_KEYS.c)

---Statement-start calls that make a file a busted file.
local BUSTED_HEADS = {
  describe = true,
  it = true,
  context = true,
  before_each = true,
  after_each = true,
  setup = true,
  teardown = true,
  pending = true,
  xit = true,
}

---@class Testing.Sniff
---@field dialect string One of `M.DIALECTS`, or `unknown`.
---@field source "sniff"|"override" Where the answer came from.
---@field evidence string[] What was seen (stable order), for the report.
---@field reason? string Set when `dialect == "unknown"`: why nothing was decided.
---@field keys string[] Sorted `H.<key>` names used (dialects a, b, c).
---@field param? string Name of the harness parameter of `return function(<param>)`.
---@field foreign_keys? string[] `H` keys no fixed shim provides (unknown result only): the project's own helpers.
---@field h_style? boolean Unknown result of a `return function(H)` spec (foreign or mixed helpers): a project harness may run it.

---Is `name` a dialect an override may name?
---@param name any
---@return boolean
function M.is_dialect(name)
  return type(name) == "string" and DIALECT_SET[name] == true
end

---The parameter of the file's top-level `return function(<param>)`. Only a `return` at column 0
---counts: a nested `return function(msg)` of a helper is not the spec's entry point.
---@param code string
---@return string|nil param
local function harness_param(code)
  return code:match("^return%s+function%s*%(%s*([%a_][%w_]*)")
    or code:match("\nreturn%s+function%s*%(%s*([%a_][%w_]*)")
end

---Sorted set of `<param>.<key>` names used in the code.
---@param code string
---@param param string
---@return string[]
local function used_keys(code, param)
  local seen = {}
  for key in code:gmatch("%f[%w_]" .. param .. "%.([%a_][%w_]*)") do
    seen[key] = true
  end
  local keys = {}
  for key in pairs(seen) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---Does any statement in the code start with a busted call (`describe(`, `it(`, ...)?
---@param code string
---@return table<string, integer> heads How often each head was seen.
local function busted_heads(code)
  local heads = {}
  for head in code:gmatch("\n%s*([%a_][%w_]*)%s*%(") do
    if BUSTED_HEADS[head] then
      heads[head] = (heads[head] or 0) + 1
    end
  end
  -- the first line has no leading newline
  local first = code:match("^%s*([%a_][%w_]*)%s*%(")
  if first and BUSTED_HEADS[first] then
    heads[first] = (heads[first] or 0) + 1
  end
  return heads
end

---Sniff the dialect of a spec file's text.
---@param text string File content.
---@return Testing.Sniff
function M.sniff(text)
  -- a UTF-8 byte order mark is legal for the loader but would hide `return function(H)` at column 0
  text = text:gsub("^\239\187\191", "")
  local code = lua_text.code_only(text)
  local evidence = {}
  ---@param s string
  local function see(s)
    evidence[#evidence + 1] = s
  end

  local heads = busted_heads(code)
  local has_describe_it = (heads.describe or 0) + (heads.it or 0) + (heads.context or 0) > 0
  local param = harness_param(code)
  -- the string contents are blanked in `code`: look for the require in the text minus comments
  local requires_harness = lua_text
    .strip_comments(text)
    :find("require%s*%(?%s*[\"'][%w_%.]*harness[\"']") ~= nil
  local has_run = code:find("function%s+[%a_][%w_]*%.run%s*%(") ~= nil
    or code:find("%.run%s*=%s*function") ~= nil

  local keys = {}
  if param then
    keys = used_keys(code, param)
  end

  if has_describe_it then
    see(
      ("describe/it at statement start (describe x%d, it x%d)"):format(
        heads.describe or 0,
        heads.it or 0
      )
    )
  end
  if param then
    see(("return function(%s)"):format(param))
  end
  if requires_harness and has_run then
    see('require("harness") and a `run` function')
  end

  ---@param dialect string
  ---@return Testing.Sniff
  local function decided(dialect)
    return { dialect = dialect, source = "sniff", evidence = evidence, keys = keys, param = param }
  end
  ---@param reason string
  ---@return Testing.Sniff
  local function unknown(reason)
    return {
      dialect = "unknown",
      source = "sniff",
      evidence = evidence,
      reason = reason,
      keys = keys,
      param = param,
    }
  end

  -- 1. busted
  if has_describe_it then
    if param then
      return unknown(
        ("both describe/it and `return function(%s)` are present: cannot tell busted from a harness spec"):format(
          param
        )
      )
    end
    return decided("busted")
  end

  -- 2. dialect D
  if not param and requires_harness and has_run then
    return decided("d")
  end

  -- 3. dialects a, b, c share `return function(H)`
  if param then
    local a_only, b_only, c_only, foreign = {}, {}, {}, {}
    for _, key in ipairs(keys) do
      local in_a, in_b, in_c = A_SET[key], B_SET[key], C_SET[key]
      if not (in_a or in_b or in_c) then
        foreign[#foreign + 1] = key
      elseif in_a and not in_b and not in_c then
        a_only[#a_only + 1] = key
      elseif in_b and not in_c and not in_a then
        b_only[#b_only + 1] = key
      elseif in_c and not in_b and not in_a then
        c_only[#c_only + 1] = key
      end
    end
    if #foreign > 0 then
      see("keys of no known harness: " .. table.concat(foreign, ", "))
      local verdict = unknown(
        ("uses %s.%s, which no fixed harness shim provides (a project harness, or an override, can run it)"):format(
          param,
          foreign[1]
        )
      )
      verdict.foreign_keys = foreign
      verdict.h_style = true
      return verdict
    end

    -- helpers whose signature differs between b and c decide by their call form; a call form that
    -- tells nothing (`scratch()`, `scratch(buf_lines)`) is `shared`: both shims accept both forms
    local uses = set_of(keys)
    local shared = {}
    if uses.tmpdir then
      if code:find("%f[%w_]" .. param .. "%.tmpdir%s*%(%s*function") then
        c_only[#c_only + 1] = "tmpdir(fn)"
      elseif code:find("%f[%w_]" .. param .. "%.tmpdir%s*%(%s*%)") then
        b_only[#b_only + 1] = "tmpdir()"
      else
        shared[#shared + 1] = "tmpdir(?)"
      end
    end
    if uses.scratch then
      if code:find("%f[%w_]" .. param .. "%.scratch%s*%(%s*[{]") then
        c_only[#c_only + 1] = "scratch(lines)"
      elseif code:find("%f[%w_]" .. param .. "%.scratch%s*%(%s*[\"']") then
        b_only[#b_only + 1] = "scratch(ft)"
      else
        shared[#shared + 1] = "scratch(?)"
      end
    end
    if #shared > 0 and #b_only == 0 and #c_only == 0 then
      if #a_only > 0 then
        -- dialect a has no scratch/tmpdir
        see("a: " .. table.concat(a_only, ", "))
        see("b or c: " .. table.concat(shared, ", "))
        local verdict = unknown("helpers of dialect a are mixed with helpers of dialect b or c")
        verdict.h_style = true
        return verdict
      end
      b_only[#b_only + 1] = shared[1]
    elseif #shared > 0 then
      see("shared: " .. table.concat(shared, ", "))
    end

    if #a_only > 0 and (#b_only > 0 or #c_only > 0) then
      -- dialect a's helpers (tmpfile, read_lines, with_patched, ...) exist in no other harness
      see("a: " .. table.concat(a_only, ", "))
      see(
        (#b_only > 0 and "b: " .. table.concat(b_only, ", "))
          or ("c: " .. table.concat(c_only, ", "))
      )
      local verdict = unknown("helpers of dialect a are mixed with helpers of dialect b or c")
      verdict.h_style = true
      return verdict
    end
    if #b_only > 0 and #c_only > 0 then
      see("b: " .. table.concat(b_only, ", "))
      see("c: " .. table.concat(c_only, ", "))
      local verdict = unknown("helpers of dialect b are mixed with helpers of dialect c")
      verdict.h_style = true
      return verdict
    end
    if #c_only > 0 then
      see("c: " .. table.concat(c_only, ", "))
      return decided("c")
    end
    if #b_only > 0 then
      see("b: " .. table.concat(b_only, ", "))
      return decided("b")
    end
    if #a_only > 0 then
      see("a: " .. table.concat(a_only, ", "))
    else
      see("only eq/ok (identical in a, b and c): a")
    end
    return decided("a")
  end

  -- 4. nothing matched
  if requires_harness then
    return unknown('requires "harness" but defines no `run` function (dialect d needs `M.run`)')
  end
  return unknown(
    "no known signature: no describe/it, no `return function(H)`, no require of a harness with `run`"
  )
end

---Resolve the dialect of one file: an override wins, else sniff.
---@param text string
---@param override? string A dialect name (`a`, `b`, `c`, `d`, `busted`); anything else is ignored here.
---@return Testing.Sniff
function M.resolve(text, override)
  if M.is_dialect(override) then
    local sniffed = M.sniff(text)
    return {
      dialect = override --[[@as string]],
      source = "override",
      evidence = { ("override: %s (sniffed: %s)"):format(override, sniffed.dialect) },
      keys = sniffed.keys,
      param = sniffed.param,
    }
  end
  return M.sniff(text)
end

return M
