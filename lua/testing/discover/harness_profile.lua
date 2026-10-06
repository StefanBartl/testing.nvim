---@module 'testing.discover.harness_profile'
---@brief Static profile of a project's own `TESTS/harness.lua`: can a fixed shim stand in for it?
---@description
--- The fleet's `return function(H)` specs run on an `H` that each project builds itself
--- (`TESTS/harness.lua`). The shims `a`, `b`, `c` re-implement three families of those helpers. A shim
--- is only a faithful stand-in when the project's helpers behave like it; a helper of the same name
--- with another signature or another meaning (`H.eq` comparing tables deeply, `H.scratch(ft, lines)`
--- where the shim has `scratch(ft)`, `H.write_file(path, string)` where the shim has
--- `write_file(path, lines)`) makes a green run on the shim a different test than the project's own.
--- The measured fleet had 18 spec files that failed on a shim for exactly this reason.
---
--- This module reads the harness TEXT (never executes it) and answers, per file:
---
---   `equivalent`  every helper the spec uses exists in the project harness with the signature of the
---                 shim's reference, `eq` is a strict `==` comparison and `ok` a truthiness check:
---                 the shim may run the file;
---   `differs`     some helper has another signature, `eq`/`ok` another meaning, the harness' own
---                 failure convention cannot be read, or the spec hands `H` on (`escapes`): the file
---                 must run on the project's harness (dialect `h`);
---   `missing`     the spec uses a helper the project harness does not define: the shim knows it, so
---                 the file keeps its shim (the project's own runner may inject the helper).
---
--- "In doubt, `h`": an unreadable function, a body this scanner cannot classify and an `H` that
--- escapes all count as `differs`. The project's own harness is always the faithful choice; the shims
--- exist for repositories that have none.
---
--- Pure Lua, no editor API.

local lua_text = require("testing.discover.lua_text")

local M = {}

---Reference signatures of the fixed shims (`testing.dialect.harness_a|b|c`): parameter names in order.
---`eq` and `ok` are judged by meaning (see `M.profile`), not by their parameter names.
---@type table<string, table<string, string[]>>
M.REFERENCE = {
  a = {
    tmpfile = { "suffix" },
    read_lines = { "path" },
    with_patched = { "target", "key", "value", "fn" },
    with_stdpath_config = { "link", "fn" },
  },
  b = {
    scratch = { "ft" },
    tmproot = { "name" },
    tmpdir = {},
    canonical = { "path" },
    write_file = { "path", "lines" },
  },
  c = {
    falsy = { "v", "msg" },
    contains = { "haystack", "needle", "msg" },
    scratch = { "lines", "ft" },
    tmpdir = { "fn" },
    write = { "path", "content" },
  },
}

---@class Testing.HarnessProfile.Func
---@field params string[] Declared parameter names (`...` kept as `...`).
---@field body string Code of the function up to the next definition, comments and strings blanked.

---@class Testing.HarnessProfile
---@field funcs table<string, Testing.HarnessProfile.Func> Helpers defined as `function X.name(...)` / `X.name = function(...)`.
---@field eq "strict"|"deep"|"unknown" Meaning of `eq`, when the harness has one.
---@field ok "truthy"|"unknown" Meaning of `ok`, when the harness has one.
---@field collects boolean The harness collects failures itself (`check` plus a `failures` list).

---@param s string
---@return string[]
local function split_params(s)
  local out = {}
  for p in s:gmatch("[^,%s]+") do
    out[#out + 1] = p
  end
  return out
end

---Build the profile of a harness source.
---@param text string
---@return Testing.HarnessProfile
function M.profile(text)
  text = text:gsub("^\239\187\191", "")
  local code = lua_text.code_only(text)
  local starts = {}
  for pos, name, params in code:gmatch("()function%s+[%a_][%w_]*[%.:]([%a_][%w_]*)%s*%(([^)]*)%)") do
    starts[#starts + 1] = { pos = pos, name = name, params = params }
  end
  for pos, name, params in code:gmatch("()[%a_][%w_]*%.([%a_][%w_]*)%s*=%s*function%s*%(([^)]*)%)") do
    starts[#starts + 1] = { pos = pos, name = name, params = params }
  end
  table.sort(starts, function(x, y)
    return x.pos < y.pos
  end)
  ---@type table<string, Testing.HarnessProfile.Func>
  local funcs = {}
  for i, s in ipairs(starts) do
    local stop = starts[i + 1] and starts[i + 1].pos - 1 or #code
    if not funcs[s.name] then
      funcs[s.name] = { params = split_params(s.params), body = code:sub(s.pos, stop) }
    end
  end

  local eq, ok = "unknown", "unknown"
  if funcs.eq then
    local body = funcs.eq.body
    if body:find("deep", 1, true) then
      eq = "deep"
    elseif body:find("~=", 1, true) or body:find("==", 1, true) then
      eq = "strict"
    end
  end
  if funcs.ok and funcs.ok.body:find("not%s+[%a_][%w_]*") then
    ok = "truthy"
  end
  local collects = funcs.check ~= nil and code:find("failures", 1, true) ~= nil
  return { funcs = funcs, eq = eq, ok = ok, collects = collects }
end

---@param a string[]
---@param b string[]
---@return boolean
local function same_list(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---Can the fixed shim of `dialect` stand in for the project's harness, for a file using `keys`?
---@param profile Testing.HarnessProfile
---@param dialect string `a`, `b` or `c`.
---@param keys string[] The `H.<key>` names the file uses.
---@param escapes? boolean The file hands `H` on or indexes it dynamically (the key list is incomplete).
---@return "equivalent"|"differs"|"missing" verdict
---@return string reason
function M.verdict(profile, dialect, keys, escapes)
  local reference = M.REFERENCE[dialect]
  if not reference then
    return "differs", ("no reference shim for dialect %q"):format(tostring(dialect))
  end
  if escapes then
    return "differs",
      "the spec hands `H` on or indexes it dynamically: its helpers cannot be listed"
  end
  for _, key in ipairs(keys) do
    local fn = profile.funcs[key]
    if not fn then
      return "missing", ("the project harness defines no `%s` (the shim does)"):format(key)
    end
    if key == "eq" then
      if profile.eq ~= "strict" then
        return "differs",
          ("the project's `eq` is %s, the shim's is a strict `==`"):format(
            profile.eq == "deep" and "a deep comparison" or "not recognisably a strict `==`"
          )
      end
    elseif key == "ok" then
      if profile.ok ~= "truthy" then
        return "differs", "the project's `ok` is not recognisably a truthiness check"
      end
    elseif reference[key] and not same_list(fn.params, reference[key]) then
      return "differs",
        ("`%s(%s)` of the project differs from the shim's `%s(%s)`"):format(
          key,
          table.concat(fn.params, ", "),
          key,
          table.concat(reference[key], ", ")
        )
    end
  end
  return "equivalent", "every used helper has the shim's signature and meaning"
end

return M
