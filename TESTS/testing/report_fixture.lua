-- TESTS/testing/report_fixture.lua -- hand-built Result-IRs and a small XML checker shared by the
-- report_*_spec.lua files. Not a spec itself (run.lua only loads *_spec.lua).

local result = require("testing.core.result")

local F = {}

---@param r Testing.Result
---@return Testing.Result
local function checked(r)
  result.finalize(r)
  local ok, problems = result.validate(r, { allow_abs_paths = true })
  if not ok then
    error("fixture is not a valid IR: " .. table.concat(problems, "; "), 2)
  end
  return r
end

---@param r Testing.Result
---@param opts { file: string, describe?: string|string[], name: string, line?: integer, status?: string, ms?: number, assertions?: table[], error?: table, reason?: string }
---@return Testing.Result.Case
function F.add(r, opts)
  local c = result.new_case({
    file = opts.file,
    describe = opts.describe,
    name = opts.name,
    line = opts.line,
  })
  c.duration_ms = opts.ms or 1
  c.assertions = opts.assertions or { { ok = true, kind = "ok" } }
  c.error = opts.error
  c.reason = opts.reason
  if opts.status and opts.status ~= "pass" and opts.status ~= "fail" then
    c.status = opts.status
  else
    result.finish_case(c)
  end
  return result.add_case(r, c)
end

---A run with every status class: pass, fail (one-line values), fail (multi-line values), error,
---skip, xfail, xpass, timeout, crash; a seed and a duration.
---@return Testing.Result
function F.mixed()
  local r = result.new({
    id = "2026-10-05T10:00:00Z-0001",
    root = "<REPO>",
    project_key = "demo.nvim@a1b2",
    nvim = "0.12.0",
    os = "linux",
    seed = 4242,
    duration_ms = 1500,
  })
  F.add(r, { file = "TESTS/a_spec.lua", name = "adds", line = 3, ms = 5 })
  F.add(r, {
    file = "TESTS/b_spec.lua",
    name = "compares",
    line = 10,
    ms = 40,
    assertions = {
      { ok = true, kind = "ok" },
      {
        ok = false,
        kind = "eq",
        msg = "values differ",
        expected = "1",
        actual = "2",
        file = "TESTS/b_spec.lua",
        line = 12,
      },
    },
  })
  F.add(r, {
    file = "TESTS/c_spec.lua",
    name = "explodes",
    line = 1,
    ms = 7,
    status = "error",
    error = {
      message = "boom",
      traceback = "boom\nstack traceback:\n\tc_spec.lua:2: in main chunk",
    },
  })
  F.add(r, {
    file = "TESTS/d_spec.lua",
    name = "needs net",
    ms = 0,
    status = "skip",
    reason = "needs network",
  })
  F.add(r, { file = "TESTS/e_spec.lua", describe = "group", name = "green", line = 4, ms = 2 })
  F.add(r, {
    file = "TESTS/e_spec.lua",
    describe = "group",
    name = "multi",
    line = 8,
    ms = 300,
    assertions = {
      {
        ok = false,
        kind = "same",
        msg = "tables differ",
        expected = "one\ntwo\nthree\nfour\nfive\nsix\nseven",
        actual = "one\ntwo\nthree\nFOUR\nfive\nsix\nseven",
        file = "TESTS/e_spec.lua",
        line = 9,
      },
    },
  })
  F.add(r, { file = "TESTS/f_spec.lua", name = "known bug", ms = 1, status = "xfail" })
  F.add(r, { file = "TESTS/f_spec.lua", name = "fixed bug", ms = 1, status = "xpass" })
  F.add(r, {
    file = "TESTS/g_spec.lua",
    name = "hangs",
    ms = 5000,
    status = "timeout",
    error = { message = "case exceeded 5000 ms", traceback = "" },
  })
  F.add(r, {
    file = "TESTS/g_spec.lua",
    name = "dies",
    ms = 9,
    status = "crash",
    error = { message = "child exited with code 139", traceback = "" },
  })
  return checked(r)
end

---Only green cases.
---@return Testing.Result
function F.green()
  local r = result.new({ id = "2026-10-05T10:00:00Z-0002", nvim = "0.12.0", os = "linux" })
  F.add(r, { file = "TESTS/a_spec.lua", name = "one", ms = 3 })
  F.add(r, { file = "TESTS/b_spec.lua", name = "two", ms = 4 })
  return checked(r)
end

---Strings that attack every output format.
F.HOSTILE = {
  name = 'it "quotes" <b>&amp; ]]> %0A 日本語 😀',
  newline = "line1\n::error title=owned::pwned\nline3",
  escape = "red\27[31m\27]0;title\7 and \0 nul",
  commas = "a,b:c=d%e",
  bidi = "abc\226\128\174def",
  bad_utf8 = "bad \255\254 bytes \192\175 end",
}

---A run whose names and messages are hostile.
---@return Testing.Result
function F.hostile()
  local H = F.HOSTILE
  local r = result.new({ id = "2026-10-05T10:00:00Z-0003", nvim = "0.12.0", os = "linux" })
  F.add(r, {
    file = "TESTS/x,y:z_spec.lua",
    describe = { H.name },
    name = H.newline,
    line = 7,
    assertions = {
      {
        ok = false,
        kind = "eq",
        msg = H.newline,
        expected = H.escape,
        actual = H.bad_utf8,
        file = "TESTS/x,y:z_spec.lua",
        line = 8,
      },
      { ok = false, kind = "ok", msg = H.commas .. H.bidi },
    },
  })
  F.add(r, {
    file = "TESTS/x,y:z_spec.lua",
    name = H.escape,
    status = "error",
    error = { message = H.name .. H.newline, traceback = H.escape .. "\n" .. H.bad_utf8 },
  })
  F.add(r, { file = "TESTS/ok.lua", name = H.name .. " 2" })
  return checked(r)
end

-- =========================================================
-- Minimal XML 1.0 well-formedness checker (independent of the code under test)
-- =========================================================

---Strict UTF-8: no overlongs, no surrogates, nothing above U+10FFFF.
---@param s string
---@return boolean
local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len, lo, hi = 1, 0x80, 0xBF
    if b >= 0x80 then
      if b >= 0xC2 and b <= 0xDF then
        len = 2
      elseif b >= 0xE0 and b <= 0xEF then
        len = 3
        lo = b == 0xE0 and 0xA0 or 0x80
        hi = b == 0xED and 0x9F or 0xBF
      elseif b >= 0xF0 and b <= 0xF4 then
        len = 4
        lo = b == 0xF0 and 0x90 or 0x80
        hi = b == 0xF4 and 0x8F or 0xBF
      else
        return false
      end
      for k = 1, len - 1 do
        local c = s:byte(i + k)
        if not c then
          return false
        end
        local from, to = 0x80, 0xBF
        if k == 1 then
          from, to = lo, hi
        end
        if c < from or c > to then
          return false
        end
      end
    end
    i = i + len
  end
  return true
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

---Decode the references of an attribute value or text; nil on a malformed one.
---@param s string
---@return string|nil
local function decode_refs(s)
  local bad = false
  local res, pos = {}, 1
  while true do
    local i = s:find("&", pos, true)
    if not i then
      res[#res + 1] = s:sub(pos)
      break
    end
    res[#res + 1] = s:sub(pos, i - 1)
    local j = s:find(";", i, true)
    if not j then
      return nil
    end
    local ref = s:sub(i + 1, j - 1)
    if ENTITIES[ref] then
      res[#res + 1] = ENTITIES[ref]
    elseif ref:match("^#%d+$") then
      res[#res + 1] = ("<#%s>"):format(ref:sub(2))
    elseif ref:match("^#x%x+$") then
      res[#res + 1] = ("<#x%s>"):format(ref:sub(3))
    else
      bad = true
    end
    pos = j + 1
  end
  if bad then
    return nil
  end
  return table.concat(res)
end

---@class Testing.Fixture.XmlNode
---@field name string
---@field attrs table<string, string>
---@field kids Testing.Fixture.XmlNode[]
---@field text string Concatenated character data and CDATA of the node itself.

---Parse a document. Returns the root element or `nil, reason`.
---@param s string
---@return Testing.Fixture.XmlNode|nil root
---@return string|nil err
function F.parse_xml(s)
  if not valid_utf8(s) then
    return nil, "invalid UTF-8"
  end
  local bad_ctl = s:find("[%z\1-\8\11\12\14-\31]")
  if bad_ctl then
    return nil, "forbidden control character at byte " .. bad_ctl
  end
  if s:find("\239\191[\190\191]") then
    return nil, "U+FFFE or U+FFFF"
  end
  local pos = 1
  local decl = s:match("^<%?xml[^>]*%?>")
  if decl then
    pos = #decl + 1
  end
  local root, stack = nil, {}
  local name_pat = "[%a_][%w_%.%-]*"
  while pos <= #s do
    local top = stack[#stack]
    if s:sub(pos, pos + 8) == "<![CDATA[" then
      local e = s:find("]]>", pos + 9, true)
      if not e or not top then
        return nil, "bad CDATA at " .. pos
      end
      top.text = top.text .. s:sub(pos + 9, e - 1)
      pos = e + 3
    elseif s:sub(pos, pos + 1) == "</" then
      local name, e = s:match("^</(" .. name_pat .. ")%s*>()", pos)
      if not name or not top or top.name ~= name then
        return nil, "mismatched end tag at " .. pos
      end
      stack[#stack] = nil
      pos = e
      if #stack == 0 and pos <= #s and s:sub(pos):find("%S") then
        return nil, "content after the root element"
      end
    elseif s:sub(pos, pos) == "<" then
      local name, e = s:match("^<(" .. name_pat .. ")()", pos)
      if not name then
        return nil, "bad start tag at " .. pos
      end
      pos = e
      local node = { name = name, attrs = {}, kids = {}, text = "" }
      while true do
        local an, q, val, e2 = s:match("^%s+(" .. name_pat .. ")%s*=%s*([\"'])(.-)%2()", pos)
        if not an then
          break
        end
        if val:find("[<\t\r\n]") or val:find(q, 1, true) then
          return nil, "raw character in attribute " .. an
        end
        local decoded = decode_refs(val)
        if not decoded then
          return nil, "bad reference in attribute " .. an
        end
        if node.attrs[an] ~= nil then
          return nil, "duplicate attribute " .. an
        end
        node.attrs[an] = decoded
        pos = e2
      end
      local slash, e3 = s:match("^%s*(/?)>()", pos)
      if not e3 then
        return nil, "unterminated start tag at " .. pos
      end
      pos = e3
      if top then
        top.kids[#top.kids + 1] = node
      elseif root then
        return nil, "second root element"
      else
        root = node
      end
      if slash ~= "/" then
        stack[#stack + 1] = node
      end
    else
      local e = s:find("<", pos, true) or (#s + 1)
      local chunk = s:sub(pos, e - 1)
      if chunk:find("]]>", 1, true) then
        return nil, "]]> in text"
      end
      local decoded = decode_refs(chunk)
      if not decoded then
        return nil, "bad reference in text at " .. pos
      end
      if top then
        top.text = top.text .. decoded
      elseif chunk:find("%S") then
        return nil, "text outside the root element"
      end
      pos = e
    end
  end
  if #stack > 0 then
    return nil, "unclosed element " .. stack[#stack].name
  end
  if not root then
    return nil, "no root element"
  end
  return root, nil
end

return F
