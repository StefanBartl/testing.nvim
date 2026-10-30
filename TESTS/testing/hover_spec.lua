-- TESTS/testing/hover_spec.lua -- testing.hover: the last result of a test where the test is written. The text of a
-- case and of a spec file, the wording of an outdated result (never a current green for an old one), hostile
-- titles and messages, a file without a result, the float without hover.nvim and the registration with hover.nvim.
---@diagnostic disable: assign-type-mismatch, need-check-nil, missing-fields, duplicate-set-field, undefined-field -- the case body is the guard: a nil raises and fails the case; partial limits and stand-ins for hover.nvim and the state module are handed in on purpose

return function(H)
  local ok = H.ok
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local state = require("testing.state")
  local result = require("testing.core.result")
  local hover = require("testing.hover")
  local format = require("testing.hover.format")
  local float = require("testing.hover.float")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local opts = { state_dir = sdir }
  local spec = "TESTS/a_spec.lua"
  local other = "TESTS/b_spec.lua"

  local function write(rel, body)
    local f = assert(io.open(root .. "/" .. rel, "wb"))
    f:write(body)
    f:close()
  end
  for _, f in ipairs({ spec, other }) do
    write(f, "return function() end\n")
  end

  ---A plain file buffer, as the user has it open (a scratch buffer is no file: the hover declines it).
  ---@param rel string
  ---@param body? string  Replaces the text; the buffer then counts as saved.
  ---@return integer
  local function filebuf(rel, body)
    local b = vim.fn.bufadd(root .. "/" .. rel)
    vim.fn.bufload(b)
    if body then
      vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(body, "\n", { plain = true }))
      vim.bo[b].modified = false
    end
    return b
  end
  local function floats()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        out[#out + 1] = w
      end
    end
    return out
  end
  local function close_floats()
    for _, w in ipairs(floats()) do
      pcall(vim.api.nvim_win_close, w, true)
    end
  end

  local res = result.new({ root = root, id = "run-1" })
  local function add(name, status, line, message, expected, actual)
    local case = result.new_case({ file = spec, name = name, line = line })
    case.status = status
    case.duration_ms = 12
    if message then
      case.assertions =
        { { ok = false, kind = "eq", msg = message, expected = expected, actual = actual } }
    end
    result.add_case(res, case)
  end
  add("fine", "pass", 3)
  add("broken", "fail", 9, "values differ", "one\ntwo\nthree", "one\n2\nthree")
  add("evil\27[31m name", "fail", 20, "boom\27]0;pwn\7 \226\128\174txt")
  add("later", "skip", 30)
  result.finalize(res)
  state.record(
    root,
    res,
    { ran_files = { [spec] = true }, known_files = { [spec] = true, [other] = true }, time = 1000 },
    opts
  )
  local st = state.load(root, opts)
  local now = 1000 + 5 * 60

  local function text(c)
    return table.concat(c.lines, "\n")
  end

  -- ago ---------------------------------------------------------------------------
  ok(hover.ago(1000, 1010) == "just now", "ago: seconds")
  ok(hover.ago(1000, 1000 + 300) == "5 min ago", "ago: minutes")
  ok(hover.ago(1000, 1000 + 7200) == "2 h ago", "ago: hours")
  ok(hover.ago(1000, 1000 + 3 * 86400) == "3 d ago", "ago: days")
  ok(hover.ago(nil, 5) == "at an unknown time", "ago: unknown")

  -- a green case ----------------------------------------------------------------------
  local c = hover.content(st, spec, 3, now)
  has(text(c), "is pass", "green: current wording")
  has(text(c), "12 ms", "green: the duration")
  has(text(c), "5 min ago", "green: the age")
  ok(c.highlight == nil, "green: no warning colour")
  ok(c.title == "fine", "green: the title is the case name")

  -- a red case with a diff ---------------------------------------------------------------
  c = hover.content(st, spec, 9, now)
  has(text(c), "is fail", "red: status")
  has(text(c), "values differ", "red: the message")
  has(text(c), "- two", "red: the diff shows the removed line")
  has(text(c), "+ 2", "red: the diff shows the added line")
  ok(c.highlight == "HoverError", "red: error colour")

  -- hostile text ---------------------------------------------------------------------------
  c = hover.content(st, spec, 20, now)
  lacks(text(c) .. c.title, "\27", "hostile: no escape character reaches the float")
  lacks(text(c) .. c.title, "\7", "hostile: no bell")
  lacks(text(c), "\226\128\174", "hostile: no bidi override")

  -- skip: shown, not green ------------------------------------------------------------------
  c = hover.content(st, spec, 30, now)
  has(text(c), "is skip", "skip: wording")

  -- a line without a case: the file ------------------------------------------------------------
  c = hover.content(st, spec, 15, now)
  has(text(c), "4 case(s) is", "file: the count")
  has(text(c), "red: " .. spec .. "::broken", "file: the red cases are listed")
  ok(c.title == spec, "file: the title is the path")

  -- outdated: never a current green --------------------------------------------------------------
  write(spec, "return function() end -- edited and longer\n")
  c = hover.content(st, spec, 3, now)
  has(text(c), "was pass", "stale: past tense")
  lacks(text(c), "is pass", "stale: never 'is pass'")
  has(text(c), "outdated: the file changed", "stale: the reason")
  has(c.title, "(outdated)", "stale: the title says so")
  ok(c.highlight == format.HL_WARN, "stale: warning colour")
  c = hover.content(st, spec, 15, now)
  has(text(c), "was:", "stale file: past tense")
  has(c.title, "(outdated)", "stale file: the title says so")

  -- a spec file without a result ---------------------------------------------------------------------
  c = hover.content(st, other, 1, now)
  has(text(c), "not run yet", "no result: said, not silent")

  -- the buffer side -----------------------------------------------------------------------------------
  local buf = filebuf(other)
  local content = hover.at(buf, 1, opts)
  ok(content and text(content):find("not run yet", 1, true), "at: a spec file of a project")
  local src = filebuf("lua_thing.lua")
  ok(hover.at(src, 1, opts) == nil, "at: a file that is no test file declines")
  local nobuf = vim.api.nvim_create_buf(true, false)
  ok(hover.at(nobuf, 1, opts) == nil, "at: a buffer without a name declines")
  ok(hover.position(src, 1, 0) == nil, "position: declines and never raises")
  -- a buffer that is not a plain file is no spec file, whatever it is named
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scratch, root .. "/" .. spec)
  ok(vim.bo[scratch].buftype == "nofile", "at: (precondition) a scratch buffer")
  ok(hover.at(scratch, 1, opts) == nil, "at: a scratch buffer named like a spec declines")
  local termish = filebuf(other)
  vim.bo[termish].buftype = "nowrite"
  ok(hover.at(termish, 1, opts) == nil, "at: any buftype but a file declines")
  vim.bo[termish].buftype = ""
  ok(hover.at(termish, 1, opts) ~= nil, "at: (control) the same buffer as a file answers")
  -- a URI buffer (fugitive://, oil://, diffview://, term://) is no project file
  for _, scheme in ipairs({ "fugitive", "oil", "diffview", "term" }) do
    local uri = vim.fn.bufadd(scheme .. "://" .. root .. "/" .. other)
    ok(
      vim.api.nvim_buf_get_name(uri):find("://", 1, true),
      "at: (precondition) the buffer keeps its " .. scheme .. " name"
    )
    ok(hover.at(uri, 1, opts) == nil, "at: a " .. scheme .. ":// buffer declines")
  end
  -- UNC: refused before anything is resolved (a stat on a dead share blocks the editor)
  local usrcmds = require("testing.bindings.usrcmds")
  local resolve_root = usrcmds.resolve_root
  local resolved = 0
  usrcmds.resolve_root = function(...)
    resolved = resolved + 1
    return resolve_root(...)
  end
  local unc = vim.fn.bufadd("//server/share/" .. other)
  ok(hover.at(unc, 1, opts) == nil, "at: a UNC name declines")
  usrcmds.resolve_root = resolve_root
  ok(resolved == 0, "at: a UNC name is refused before the project is looked up")
  for _, b in ipairs({ buf, src, nobuf, scratch, termish, unc }) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end

  -- positions: describe / it / a line that is neither ----------------------------------------------------------
  local nested = "TESTS/nested_spec.lua"
  local nested_text = table.concat({
    'describe("outer", function()',
    '  describe("inner", function()',
    '    it("works", function() end)',
    '    it("breaks", function() end)',
    "  end)",
    '  it("brand new", function() end)',
    "end)",
  }, "\n")
  write(nested, nested_text .. "\n")
  local res2 = result.new({ root = root, id = "run-2" })
  local function add2(name, status, line, message)
    local case = result.new_case({
      file = nested,
      describe = { "outer", "inner" },
      name = name,
      line = line,
    })
    case.status = status
    case.duration_ms = 40
    if message then
      case.assertions = { { ok = false, kind = "eq", msg = message, expected = "1", actual = "2" } }
    end
    result.add_case(res2, case)
  end
  add2("works", "pass", 3)
  add2("breaks", "fail", 4, "wrong value")
  result.finalize(res2)
  state.record(root, res2, {
    ran_files = { [nested] = true },
    known_files = { [spec] = true, [other] = true, [nested] = true },
  }, opts)
  local pbuf = filebuf(nested, nested_text)
  c = hover.at(pbuf, 3, opts)
  ok(c and c.title == "works", "it line: the case under the cursor")
  has(text(c), "is pass", "it line: current green")
  c = hover.at(pbuf, 4, opts)
  has(text(c), "wrong value", "it line: the red case says why")
  ok(c.highlight == "HoverError", "it line: red colour")
  c = hover.at(pbuf, 2, opts)
  has(c.title, "outer > inner", "describe line: the title is the describe path")
  has(text(c), "2 case(s) is", "describe line: the cases below it")
  has(text(c), "1 pass, 1 fail", "describe line: counted by status")
  has(text(c), "slowest:", "describe line: the slowest case")
  c = hover.at(pbuf, 6, opts)
  has(text(c), "not run yet", "an it that never ran says so")
  has(c.title, "brand new", "an it that never ran: its own title")
  lacks(text(c), "is pass", "an it that never ran is never a green")
  c = hover.at(pbuf, 5, opts)
  ok(c.title == nested, "a line that is no test: the file")
  has(text(c), "2 case(s)", "a line that is no test: the file summary")

  -- unsaved changes: the buffer is not the text that ran ----------------------------------------------------------
  vim.bo[pbuf].modified = true
  c = hover.at(pbuf, 3, opts)
  has(text(c), "was pass", "unsaved: a case is worded in the past tense")
  lacks(text(c), "is pass", "unsaved: never a current green")
  has(text(c), "outdated: the buffer has unsaved changes", "unsaved: says why")
  has(c.title, "(outdated)", "unsaved: the title says so")
  ok(c.highlight == format.HL_WARN, "unsaved: warning colour")
  c = hover.at(pbuf, 2, opts)
  has(c.title, "(outdated)", "unsaved: a describe block too")
  c = hover.at(pbuf, 5, opts)
  has(text(c), "was:", "unsaved: the file summary too")
  has(text(c), "unsaved changes", "unsaved: the file summary says why")
  vim.bo[pbuf].modified = false
  c = hover.at(pbuf, 3, opts)
  has(text(c), "is pass", "saved again: current")

  -- lines moved since the run: the case is found by name, not by its old line, and is worded as outdated
  vim.api.nvim_buf_set_lines(pbuf, 0, 0, false, { "-- a new first line", "-- and another" })
  write(nested, "-- a new first line\n-- and another\n" .. nested_text .. "\n")
  c = hover.at(pbuf, 6, opts)
  ok(c and c.title == "breaks (outdated)", "moved: found by describe path and name")
  has(text(c), "was fail", "moved: past tense")
  has(text(c), "outdated: the file changed", "moved: says why")

  -- a file that is one case (dialect A): the file result and every failing assertion ------------------------------
  local whole = "TESTS/whole_spec.lua"
  write(whole, "assert(1 == 2)\n")
  local res3 = result.new({ root = root, id = "run-3" })
  local wc = result.new_case({ file = whole, name = "whole_spec.lua" })
  wc.status = "fail"
  wc.duration_ms = 7
  wc.assertions = {
    { ok = false, kind = "eq", msg = "first bad", line = 4, expected = "a", actual = "b" },
    { ok = true, kind = "ok", line = 5 },
    { ok = false, kind = "ok", msg = "second\27[31m bad", line = 9 },
  }
  result.add_case(res3, wc)
  result.finalize(res3)
  local known = { [spec] = true, [other] = true, [nested] = true, [whole] = true }
  state.record(root, res3, { ran_files = { [whole] = true }, known_files = known }, opts)
  local wst = state.load(root, opts)
  ok(
    #wst.cases[#wst.cases].fails == 2,
    "dialect A: the store keeps the two failing assertions with their lines"
  )
  for _, line in ipairs({ 1, 40 }) do
    c = hover.content(wst, whole, line, now)
    ok(
      c.title == "whole_spec.lua",
      "dialect A: any line answers with the file result (line " .. line .. ")"
    )
    has(text(c), "2 failing assertion(s)", "dialect A: the list is announced")
    has(text(c), whole .. ":4 first bad", "dialect A: file:line of the first assertion")
    has(text(c), whole .. ":9 second", "dialect A: file:line of the second assertion")
    lacks(text(c), "\27", "dialect A: hostile assertion text is cleaned")
  end

  ---Record one spec file of the fixtures: `cases` is a list of { name, status?, line?, describe?, param?, message? }.
  ---@param run string
  ---@param file string
  ---@param body string
  ---@param cases table[]
  local function record(run, file, body, cases)
    write(file, body)
    known[file] = true
    local r = result.new({ root = root, id = run })
    for _, k in ipairs(cases) do
      local case = result.new_case({
        file = file,
        describe = k.describe,
        name = k.name,
        line = k.line,
        param = k.param,
      })
      case.status = k.status or "pass"
      case.duration_ms = k.ms or 5
      if k.message then
        case.assertions =
          { { ok = false, kind = "eq", msg = k.message, expected = "1", actual = "2" } }
      end
      result.add_case(r, case)
    end
    result.finalize(r)
    state.record(root, r, { ran_files = { [file] = true }, known_files = known }, opts)
  end

  -- a whole-file case with more failing assertions than the store keeps: the real count is shown ----------------------
  local many = "TESTS/many_spec.lua"
  write(many, "assert(false)\n")
  local function whole_case(file, n)
    local r = result.new({ root = root, id = "run-many" .. n })
    local k = result.new_case({ file = file, name = vim.fs.basename(file) })
    k.status = "fail"
    k.duration_ms = 3
    for i = 1, n do
      k.assertions[i] = { ok = false, kind = "ok", msg = "bad " .. i, line = i }
    end
    result.add_case(r, k)
    result.finalize(r)
    known[file] = true
    state.record(root, r, { ran_files = { [file] = true }, known_files = known }, opts)
    return state.load(root, opts)
  end
  local mst = whole_case(many, 32)
  local mc = mst.cases[#mst.cases]
  ok(#mc.fails == state.MAX_FAILS, "fails: the store keeps " .. state.MAX_FAILS)
  ok(mc.fails_total == 32, "fails: and the real count beside it")
  c = hover.content(mst, many, 1, now)
  has(text(c), "32 failing assertion(s)", "fails: the header carries the real count, not 20")
  has(text(c), "... and 24 more", "fails: the rest after the eight shown")
  lacks(text(c), "20 failing", "fails: never the capped count")
  mst = whole_case(many, 20)
  mc = mst.cases[#mst.cases]
  ok(mc.fails_total == nil, "fails: no separate count when nothing was cut")
  c = hover.content(mst, many, 1, now)
  has(text(c), "20 failing assertion(s)", "fails: exactly the cap")
  has(text(c), "... and 12 more", "fails: twelve after the eight shown")
  mst = whole_case(many, 8)
  c = hover.content(mst, many, 1, now)
  has(text(c), "8 failing assertion(s)", "fails: eight")
  lacks(text(c), "more", "fails: nothing hidden at eight")

  -- the body of an `it` answers with its case ----------------------------------------------------------------------------
  local body_spec = "TESTS/body_spec.lua"
  local body_text = table.concat({
    'describe("body", function()',
    '  it("has a body", function()',
    "    local x = 1",
    "",
    '    assert(x == 2, "boom")',
    "  end)",
    "",
    '  it("next", function()',
    "    assert(true)",
    "  end)",
    "end)",
  }, "\n")
  record("run-body", body_spec, body_text, {
    { name = "has a body", describe = { "body" }, line = 2, status = "fail", message = "boom" },
    { name = "next", describe = { "body" }, line = 8 },
  })
  local bbuf = filebuf(body_spec, body_text)
  for _, row in ipairs({ 2, 3, 4, 5 }) do
    c = hover.at(bbuf, row, opts)
    ok(c and c.title == "has a body", "body: row " .. row .. " answers with the case it is in")
  end
  has(text(hover.at(bbuf, 5, opts)), "boom", "body: the failing assertion line says why")
  for _, row in ipairs({ 6, 7 }) do
    c = hover.at(bbuf, row, opts)
    ok(
      c and c.title == body_spec,
      "body: row " .. row .. " (the end of the case or below) is the file"
    )
  end
  c = hover.at(bbuf, 9, opts)
  ok(c and c.title == "next", "body: the second case's own body")
  c = hover.at(bbuf, 11, opts)
  ok(c and c.title == body_spec, "body: the last line of the file is the file")
  c = hover.at(bbuf, 1, opts)
  has(c.title, "body", "body: the describe line is still the group")
  lacks(c.title, "has a body", "body: the describe line is not a case")

  -- a title that repeats: the case nearest to the line ---------------------------------------------------------------------
  local dup_spec = "TESTS/dup_spec.lua"
  local dup_text = table.concat({
    'describe("dup", function()',
    '  it("same", function() end)',
    '  it("other", function() end)',
    '  it("same", function() end)',
    "end)",
  }, "\n")
  record("run-dup", dup_spec, dup_text, {
    { name = "same", describe = { "dup" }, line = 2, param = 1 },
    { name = "other", describe = { "dup" }, line = 3 },
    {
      name = "same",
      describe = { "dup" },
      line = 4,
      param = 2,
      status = "fail",
      message = "second one",
    },
  })
  local dbuf = filebuf(dup_spec, dup_text)
  c = hover.at(dbuf, 2, opts)
  has(text(c), "is pass", "duplicate title: the first one is the green one")
  lacks(text(c), "second one", "duplicate title: not the red one below")
  c = hover.at(dbuf, 4, opts)
  has(text(c), "second one", "duplicate title: the second one is the red one")
  has(text(c), "is fail", "duplicate title: its own status")

  -- describe blocks that share a prefix --------------------------------------------------------------------------------------
  local groups_spec = "TESTS/groups_spec.lua"
  local groups_text = table.concat({
    'describe("outer", function()',
    '  describe("inner", function()',
    '    it("a", function() end)',
    "  end)",
    '  describe("inner2", function()',
    '    it("b", function() end)',
    '    it("b2", function() end)',
    "  end)",
    '  it("c", function() end)',
    "end)",
    'describe("outer2", function()',
    '  it("d", function() end)',
    "end)",
  }, "\n")
  record("run-groups", groups_spec, groups_text, {
    { name = "a", describe = { "outer", "inner" }, line = 3 },
    { name = "b", describe = { "outer", "inner2" }, line = 6 },
    { name = "b2", describe = { "outer", "inner2" }, line = 7 },
    { name = "c", describe = { "outer" }, line = 9 },
    { name = "d", describe = { "outer2" }, line = 12 },
  })
  local gbuf = filebuf(groups_spec, groups_text)
  c = hover.at(gbuf, 1, opts)
  has(text(c), "4 case(s) is", "describe prefix: outer holds a, b, b2 and c, not outer2's d")
  c = hover.at(gbuf, 2, opts)
  has(text(c), "1 case(s) is", "describe prefix: outer > inner holds only a, not inner2's")
  c = hover.at(gbuf, 5, opts)
  has(text(c), "2 case(s) is", "describe prefix: outer > inner2 holds b and b2")
  c = hover.at(gbuf, 11, opts)
  has(text(c), "1 case(s) is", "describe prefix: outer2 holds only d")

  -- titles that were cleaned when they were stored ---------------------------------------------------------------------------------
  local evil_spec = "TESTS/evil_spec.lua"
  local long_name = ("x"):rep(350)
  local evil_text = table.concat({
    'describe("grp\27[1m", function()',
    '  it("t\27[31m x", function() end)',
    '  it("' .. long_name .. '", function() end)',
    "end)",
  }, "\n")
  record("run-evil", evil_spec, evil_text, {
    {
      name = "t\27[31m x",
      describe = { "grp\27[1m" },
      line = 2,
      status = "fail",
      message = "found it",
    },
    { name = long_name, describe = { "grp\27[1m" }, line = 3 },
  })
  local ebuf = filebuf(evil_spec, evil_text)
  c = hover.at(ebuf, 2, opts)
  ok(
    c and not text(c):find("not run yet", 1, true),
    "cleaned title: a control character in the name still matches"
  )
  has(text(c), "found it", "cleaned title: it is the right case")
  c = hover.at(ebuf, 3, opts)
  ok(
    c and not text(c):find("not run yet", 1, true),
    "cleaned title: a name over 300 bytes still matches"
  )
  has(text(c), "is pass", "cleaned title: and is that case")
  c = hover.at(ebuf, 1, opts)
  has(
    text(c),
    "2 case(s) is",
    "cleaned title: a describe title with a control character still groups"
  )

  -- a spec path written somewhere else (a note, a task, a report) ------------------------------------------------
  c = hover.for_path(root .. "/" .. nested, opts)
  ok(c and c.title:find(nested, 1, true) ~= nil, "path: the summary of the spec file")
  c = hover.for_path(nested, { state_dir = sdir, base = root })
  ok(c ~= nil, "path: relative to the document's directory")
  ok(
    hover.for_path(root .. "/TESTS/not_there_spec.lua", opts) == nil,
    "path: a file that does not exist declines"
  )
  ok(hover.for_path(root .. "/lua_thing.lua", opts) == nil, "path: a file that is no spec declines")

  -- files that exist but are no spec: declined by their name, before the result file is read ----------------------
  write("TESTS/harness.lua", "return {}\n")
  write("TESTS/helper.lua", "return {}\n")
  write("notes.md", "# notes\n")
  write("lua_thing.lua", "return {}\n")
  local loads = 0
  local load = state.load
  state.load = function(...)
    loads = loads + 1
    return load(...)
  end
  local function loaded_by(fn)
    loads = 0
    local answer = fn()
    return answer, loads
  end
  for _, rel in ipairs({ "TESTS/harness.lua", "TESTS/helper.lua", "notes.md", "lua_thing.lua" }) do
    local answer, n = loaded_by(function()
      return hover.for_path(root .. "/" .. rel, opts)
    end)
    ok(answer == nil, "path: " .. rel .. " is no spec")
    ok(
      n == 0,
      "path: " .. rel .. " is declined by its name, the result file is not read (" .. n .. ")"
    )
    answer, n = loaded_by(function()
      return hover.file_preview({ path = root .. "/" .. rel }, {}, 0)
    end)
    ok(answer == nil, "file_preview: " .. rel .. " is left to hover.nvim's own preview")
    ok(n == 0, "file_preview: " .. rel .. " does not read the result file (" .. n .. ")")
  end
  local answer, n = loaded_by(function()
    return hover.file_preview({ path = root .. "/" .. nested }, {}, 0)
  end)
  ok(answer ~= nil and n == 1, "file_preview: a spec path reads the result file once (" .. n .. ")")
  state.load = load
  -- a file under a spec root that no discovery would run is no spec for a buffer either
  local hbuf = filebuf("TESTS/harness.lua")
  ok(hover.at(hbuf, 1, opts) == nil, "at: TESTS/harness.lua is no spec")
  local hhbuf = filebuf("TESTS/helper.lua")
  ok(hover.at(hhbuf, 1, opts) == nil, "at: a helper under TESTS/ is no spec")
  -- ...unless a run recorded it (a project with its own spec_pattern)
  record(
    "run-custom",
    "TESTS/custom_check.lua",
    "assert(true)\n",
    { { name = "custom_check.lua" } }
  )
  local cbuf = filebuf("TESTS/custom_check.lua")
  ok(
    hover.at(cbuf, 1, opts) ~= nil,
    "at: a file the store has a result for answers, whatever its name"
  )
  ok(
    hover.for_path(root .. "/TESTS/custom_check.lua", opts) == nil,
    "path: by name only (the default spec_pattern); no result file is read for a path in a note"
  )
  ok(
    require("testing.discover").DEFAULT_SPEC_PATTERN[1] == "_spec%.lua$",
    "the spec name check is the discovery's default pattern"
  )
  for _, b in ipairs({ hbuf, hhbuf, cbuf }) do
    vim.api.nvim_buf_delete(b, { force = true })
  end

  -- paths that are refused without a look: not one file-system call is made for them ---------------------------------
  local reads = 0
  local filereadable = vim.fn.filereadable
  vim.fn.filereadable = function(...)
    reads = reads + 1
    return filereadable(...)
  end
  local refused = {
    ["a URI"] = "https://example.com/x_spec.lua",
    ["a UNC path"] = "\\\\server\\share\\x_spec.lua",
    ["a UNC path with slashes"] = "//server/share/x_spec.lua",
    ["a NUL byte"] = "a\0b_spec.lua",
    ["a long name"] = ("x"):rep(600) .. "_spec.lua",
    ["a file URI"] = "file:///tmp/x_spec.lua",
  }
  for what, bad in pairs(refused) do
    reads = 0
    ok(hover.for_path(bad, opts) == nil, "path: " .. what .. " answers nothing")
    ok(reads == 0, "path: " .. what .. " is refused before any file is looked at (" .. reads .. ")")
  end
  reads = 0
  ok(hover.for_path(nested, { state_dir = sdir, base = root }) ~= nil, "path: (control) a good one")
  ok(reads > 0, "path: (control) a good one is looked at")
  vim.fn.filereadable = filereadable
  if vim.fn.has("win32") == 0 then
    -- a UNC spelling of a file that exists: `//tmp/...` is the same file on a POSIX system
    local same = "/" .. root .. "/" .. nested
    ok(vim.fn.filereadable(same) == 1, "path: (precondition) the UNC spelling exists")
    ok(hover.for_path(same, opts) == nil, "path: a UNC spelling of an existing spec is refused")
  end
  ok(
    pcall(hover.file_preview, { path = root .. "/" .. nested }, {}, 0),
    "file_preview never raises"
  )
  ok(hover.file_preview("not a table", {}, 0) == nil, "file_preview: a malformed target declines")
  ok(
    hover.file_preview({ path = root .. "/notes.md" }, {}, 0) == nil,
    "file_preview: only spec paths"
  )

  -- the colours of the first line exist ---------------------------------------------------------------------------------------
  local seen = {}
  for _, content_of in ipairs({
    function()
      return hover.content(st, spec, 9, now)
    end,
    function()
      return hover.content(st, spec, 3, now)
    end,
    function()
      return hover.content(st, other, 1, now)
    end,
    function()
      return hover.content(wst, whole, 1, now)
    end,
    function()
      return hover.at(pbuf, 2, opts)
    end,
    function()
      return hover.at(bbuf, 1, opts)
    end,
  }) do
    local hl = content_of().highlight
    if hl then
      seen[hl] = true
      ok(float.ensure_highlight(hl) == true, "highlight: " .. hl .. " is a group the hover defines")
    end
  end
  ok(
    seen[format.HL_ERROR] and seen[format.HL_WARN],
    "highlight: both the red and the warning colour occur"
  )
  ok(not seen.HoverWarn, "highlight: HoverWarn (defined nowhere) is not used")

  -- size limits from the configuration ------------------------------------------------------------------------------
  local long = { lines = {}, title = ("t"):rep(200) }
  for i = 1, 50 do
    long.lines[i] = ("line %d "):format(i) .. ("x"):rep(300)
  end
  local fitted = format.fit(long, { width = 40, height = 5 })
  ok(#fitted.lines == 5, "fit: the height is the configured one")
  ok(fitted.lines[5] == "...", "fit: a cut is marked")
  for _, l in ipairs(fitted.lines) do
    ok(vim.fn.strdisplaywidth(l) <= 40, "fit: no line wider than the configured width")
  end
  ok(vim.fn.strdisplaywidth(fitted.title) <= 40, "fit: the title fits too")
  local wide = format.fit(
    { lines = { ("\239\188\161"):rep(30) }, title = "w" },
    { width = 21, height = 3 }
  )
  ok(
    vim.fn.strdisplaywidth(wide.lines[1]) <= 21,
    "fit: double-width characters count as two columns"
  )
  local cfg = require("testing.config")
  cfg.setup({ hover = { max_height = 3 } })
  c = hover.at(pbuf, 2, opts)
  ok(c and #c.lines <= 3, "position: the configured height applies")
  local _, problems = cfg.validate({ hover = { max_width = 0 } })
  ok(#problems == 1, "config: a width of 0 is refused")
  _, problems = cfg.validate({ hover = { max_height = "tall" } })
  ok(#problems == 1, "config: a non-number is refused")
  cfg.reset()

  -- ... and the float that `:Testing hover` opens honours them as well (wider than the default 80 columns) --------------
  local wide_spec = "TESTS/wide_spec.lua"
  record("run-wide", wide_spec, 'it("wide", function() end)\n', {
    { name = "wide", line = 1, status = "fail", message = ("w"):rep(110) },
  })
  local wbuf = filebuf(wide_spec)
  local function longest_in_float()
    close_floats()
    vim.api.nvim_set_current_buf(wbuf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    hover.show(opts)
    local w = floats()[1]
    ok(w ~= nil, "float: `show` opens a float for a test line")
    local longest = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
      longest = math.max(longest, vim.fn.strdisplaywidth(l))
    end
    close_floats()
    return longest
  end
  ok(longest_in_float() <= 80, "float: (control) the default width cuts a 110 column line")
  cfg.setup({ hover = { max_width = 120 } })
  ok(longest_in_float() == 110, "float: max_width = 120 keeps a 110 column line whole")
  cfg.setup({ hover = { max_height = 2 } })
  vim.api.nvim_set_current_buf(wbuf)
  hover.show(opts)
  ok(
    #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats()[1]), 0, -1, false) <= 2,
    "float: max_height applies to the float too"
  )
  close_floats()
  cfg.reset()
  vim.api.nvim_buf_delete(wbuf, { force = true })

  -- hostile titles: markdown, control characters, huge ---------------------------------------------------------------
  local hostile = {
    id = "x::y",
    file = spec,
    status = "fail",
    duration_ms = 1,
    name = "# **bold** [link](http://x) `code`\n\27[2J\0",
    message = "<script>\27]0;t\7" .. ("m"):rep(5000),
  }
  c = format.fit(format.describe_case(hostile, 1000, false, nil, now), { width = 60, height = 10 })
  lacks(text(c) .. c.title, "\27", "hostile: no escape character after fit")
  lacks(text(c) .. c.title, "\0", "hostile: no NUL")
  ok(not text(c):find("\n\n\n"), "hostile: no runaway blank lines")
  for _, l in ipairs(c.lines) do
    ok(vim.fn.strdisplaywidth(l) <= 60, "hostile: every line is cut to the width")
  end

  -- the float without hover.nvim ------------------------------------------------------------------------------------------
  close_floats()
  local fwin = float.open({ lines = { "one", "two" }, title = "t" }, nil)
  ok(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), "float: opens through lib.nvim.window")
  ok(
    vim.api.nvim_win_get_config(fwin).relative ~= "editor",
    "float: anchored at the cursor (nvim reports it relative to the window)"
  )
  ok(vim.api.nvim_get_current_win() ~= fwin, "float: the cursor stays in the editing window")
  ok(
    #vim.api.nvim_get_autocmds({ group = "TestingHoverFloat" }) > 0,
    "float: its close autocmds live in the named group"
  )
  vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })
  ok(not vim.api.nvim_win_is_valid(fwin), "float: closes when the cursor moves")
  for _, event in ipairs({ "InsertEnter", "BufLeave" }) do
    fwin = float.open({ lines = { "one" }, title = "t" }, nil)
    ok(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), "float: opens again")
    vim.api.nvim_exec_autocmds(event, { modeline = false })
    ok(not vim.api.nvim_win_is_valid(fwin), "float: closes on " .. event)
  end
  -- ... and its first line carries the verdict colour, with a group that exists
  local function first_line_group(content_in)
    local w = float.open(content_in, nil)
    local b = vim.api.nvim_win_get_buf(w)
    local marks = vim.api.nvim_buf_get_extmarks(
      b,
      vim.api.nvim_create_namespace("testing_hover"),
      0,
      -1,
      { details = true }
    )
    close_floats()
    return marks[1] and marks[1][4].hl_group, marks[1] and marks[1][2]
  end
  vim.cmd("highlight clear " .. format.HL_WARN)
  local group, row =
    first_line_group({ lines = { "was pass", "x" }, title = "t", highlight = format.HL_WARN })
  ok(group == format.HL_WARN and row == 0, "float: the first line gets the warning group")
  local defined = vim.api.nvim_get_hl(0, { name = format.HL_WARN })
  ok(defined.link == "DiagnosticWarn", "float: and the group is defined (linked to DiagnosticWarn)")
  vim.cmd("highlight clear " .. format.HL_ERROR)
  group = first_line_group({ lines = { "is fail" }, title = "t", highlight = format.HL_ERROR })
  ok(group == format.HL_ERROR, "float: the first line gets the error group")
  defined = vim.api.nvim_get_hl(0, { name = format.HL_ERROR })
  ok(
    defined.link == "DiagnosticError",
    "float: and the group is defined (linked to DiagnosticError)"
  )
  group = first_line_group({ lines = { "x" }, title = "t", highlight = "HoverWarn" })
  ok(group == nil, "float: a group the hover does not define is not applied")
  group = first_line_group({ lines = { "x" }, title = "t" })
  ok(group == nil, "float: no verdict, no colour")
  -- a colorscheme that defined the group wins
  vim.api.nvim_set_hl(0, format.HL_WARN, { fg = "#ff8800" })
  first_line_group({ lines = { "x" }, title = "t", highlight = format.HL_WARN })
  ok(
    vim.api.nvim_get_hl(0, { name = format.HL_WARN }).fg == 0xff8800,
    "float: a group the user defined is not overwritten"
  )
  vim.cmd("highlight clear " .. format.HL_WARN)

  -- registration with hover.nvim -------------------------------------------------------------------------
  local saved_loaded = package.loaded["hover.registry"]
  local saved_preload = package.preload["hover.registry"]
  local function armed()
    local okg, found = pcall(vim.api.nvim_get_autocmds, { group = "TestingHoverRegister" })
    return okg and #found or 0
  end
  local registered
  local function fake_registry()
    return {
      register = function(name, contribution)
        registered = { name = name, contribution = contribution }
      end,
    }
  end
  local requires = 0
  package.loaded["hover.registry"] = nil
  package.preload["hover.registry"] = function()
    requires = requires + 1
    error("no hover.nvim here")
  end
  -- hover.nvim is not loaded: nothing is required (a lazy loader would load it), one retry is armed
  ok(hover.setup() == false, "setup: silent without hover.nvim")
  ok(requires == 0, "setup: never requires hover.nvim (" .. requires .. ")")
  ok(hover.available() == false, "available: false while it is not loaded")
  ok(requires == 0, "available: never requires hover.nvim")
  local first = armed()
  ok(first > 0, "setup: arms a retry in the named group TestingHoverRegister")
  hover.setup()
  ok(
    armed() == first,
    "setup: twice does not stack the retry (" .. armed() .. " vs " .. first .. ")"
  )
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  ok(
    registered == nil and armed() == first,
    "retry: nothing happens while hover.nvim is still absent"
  )
  -- hover.nvim gets loaded later (a lazy loader): the next event registers and the retry goes away
  package.preload["hover.registry"] = nil
  package.loaded["hover.registry"] = fake_registry()
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false })
  ok(registered and registered.name == "testing.nvim", "retry: registers once hover.nvim is loaded")
  ok(armed() == 0, "retry: the group is gone after the registration")
  -- ... or the first use does it, without waiting for an event
  registered = nil
  package.loaded["hover.registry"] = nil
  hover.setup()
  ok(registered == nil and armed() > 0, "setup: (again) not loaded, armed")
  package.loaded["hover.registry"] = fake_registry()
  vim.api.nvim_set_current_buf(filebuf(other))
  hover.show(opts)
  close_floats()
  ok(
    registered and registered.name == "testing.nvim",
    "show: registers on first use when hover.nvim came later"
  )
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false })
  -- hover.nvim is loaded when setup() runs
  registered = nil
  package.loaded["hover.registry"] = fake_registry()
  ok(hover.setup() == true, "setup: registers when hover.nvim is there")
  ok(registered and registered.name == "testing.nvim", "setup: under the plugin name")
  ok(armed() == 0, "setup: no retry when it registered")
  local pos = registered.contribution.positions[1]
  ok(pos.on_request == true, "setup: on request only, never on the automatic trigger")
  ok(type(pos.fn) == "function", "setup: a position function")
  ok(type(registered.contribution.previews.file) == "function", "setup: a preview for spec paths")
  ok(hover.available() == true, "available: hover.nvim is loaded")
  package.loaded["hover.registry"].contributors = function()
    return {}
  end
  ok(
    hover.status().state == "not registered",
    "status: hover.nvim there, testing.nvim not in its list"
  )
  ok(hover.registered() == false, "registered: not in its list")
  package.loaded["hover.registry"].contributors = function()
    return { { name = "testing.nvim", positions = 1, previews = 1 } }
  end
  ok(hover.status().state == "registered", "status: registered as read back from hover.nvim")
  ok(hover.registered() == true, "registered: in its list")
  -- the position function hands hover.nvim the text of the buffer under the cursor
  local rbuf = filebuf(body_spec, body_text)
  ok(pcall(hover.position, rbuf, 5, 0), "position: never raises")
  -- no hover.nvim at all
  package.loaded["hover.registry"] = nil
  package.preload["hover.registry"] = function()
    error("no hover.nvim here")
  end
  ok(hover.setup() == false, "setup: silent without hover.nvim (again)")
  ok(hover.available() == false, "available: false without hover.nvim")
  ok(hover.registered() == false, "registered: false without hover.nvim")
  ok(hover.status().state == "absent", "status: absent without hover.nvim")
  -- no hover.nvim: the command still answers, in a float, and nothing raises
  vim.api.nvim_set_current_buf(filebuf(other))
  ok(pcall(hover.show, opts), ":Testing hover without hover.nvim does not raise")
  ok(#floats() == 1, ":Testing hover without hover.nvim opens its float")
  close_floats()
  pcall(vim.api.nvim_del_augroup_by_name, "TestingHoverRegister")
  package.preload["hover.registry"] = saved_preload
  package.loaded["hover.registry"] = saved_loaded
  -- the module itself never requires hover.nvim at load time
  package.loaded["testing.hover"] = nil
  package.preload["hover"] = function()
    error("hover must not be required at module level")
  end
  ok(pcall(require, "testing.hover"), "no require of hover at module level")
  package.preload["hover"] = nil
end
