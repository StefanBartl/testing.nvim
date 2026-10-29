-- TESTS/testing/hover_spec.lua -- testing.hover: the last result of a test where the test is written. The text of a
-- case and of a spec file, the wording of an outdated result (never a current green for an old one), hostile
-- titles and messages, a file without a result, and the registration with hover.nvim.

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

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local opts = { state_dir = sdir }
  local spec = "TESTS/a_spec.lua"
  local other = "TESTS/b_spec.lua"
  for _, f in ipairs({ spec, other }) do
    local fh = assert(io.open(root .. "/" .. f, "wb"))
    fh:write("return function() end\n")
    fh:close()
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
  local fh = assert(io.open(root .. "/" .. spec, "wb"))
  fh:write("return function() end -- edited and longer\n")
  fh:close()
  c = hover.content(st, spec, 3, now)
  has(text(c), "was pass", "stale: past tense")
  lacks(text(c), "is pass", "stale: never 'is pass'")
  has(text(c), "outdated: the file changed", "stale: the reason")
  has(c.title, "(outdated)", "stale: the title says so")
  ok(c.highlight == "HoverWarn", "stale: warning colour")
  c = hover.content(st, spec, 15, now)
  has(text(c), "was:", "stale file: past tense")
  has(c.title, "(outdated)", "stale file: the title says so")

  -- a spec file without a result ---------------------------------------------------------------------
  c = hover.content(st, other, 1, now)
  has(text(c), "not run yet", "no result: said, not silent")

  -- the buffer side -----------------------------------------------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, root .. "/" .. other)
  local content = hover.at(buf, 1, opts)
  ok(content and text(content):find("not run yet", 1, true), "at: a spec file of a project")
  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(src, root .. "/lua_thing.lua")
  ok(hover.at(src, 1, opts) == nil, "at: a file that is no test file declines")
  local nobuf = vim.api.nvim_create_buf(false, true)
  ok(hover.at(nobuf, 1, opts) == nil, "at: a buffer without a name declines")
  ok(hover.position(src, 1, 0) == nil, "position: declines and never raises")
  for _, b in ipairs({ buf, src, nobuf }) do
    vim.api.nvim_buf_delete(b, { force = true })
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
  local function write(rel, body)
    local f = assert(io.open(root .. "/" .. rel, "wb"))
    f:write(body)
    f:close()
  end
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
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(pbuf, root .. "/" .. nested)
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, vim.split(nested_text, "\n"))
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
  state.record(root, res3, {
    ran_files = { [whole] = true },
    known_files = { [spec] = true, [other] = true, [nested] = true, [whole] = true },
  }, opts)
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
  for _, bad in ipairs({
    "https://example.com/x_spec.lua",
    "\\\\server\\share\\x_spec.lua",
    "a\0b_spec.lua",
    ("x"):rep(600),
  }) do
    ok(
      hover.for_path(bad, opts) == nil,
      "path: refused without a look: " .. bad:sub(1, 20):gsub("%z", "NUL")
    )
  end
  ok(
    pcall(hover.file_preview, { path = root .. "/" .. nested }, {}, 0),
    "file_preview never raises"
  )
  ok(hover.file_preview("not a table", {}, 0) == nil, "file_preview: a malformed target declines")
  ok(
    hover.file_preview({ path = root .. "/notes.md" }, {}, 0) == nil,
    "file_preview: only .lua paths"
  )

  -- size limits from the configuration ------------------------------------------------------------------------------
  local format = require("testing.hover.format")
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
  local fwin = require("testing.hover.float").open({ lines = { "one", "two" }, title = "t" }, nil)
  ok(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), "float: opens through lib.nvim.window")
  ok(
    vim.api.nvim_win_get_config(fwin).relative ~= "editor",
    "float: anchored at the cursor (nvim reports it relative to the window)"
  )
  ok(vim.api.nvim_get_current_win() ~= fwin, "float: the cursor stays in the editing window")
  pcall(vim.api.nvim_win_close, fwin, true)

  -- registration with hover.nvim -------------------------------------------------------------------------
  local registered
  package.loaded["hover.registry"] = {
    register = function(name, contribution)
      registered = { name = name, contribution = contribution }
    end,
  }
  ok(hover.setup() == true, "setup: registers when hover.nvim is there")
  ok(registered and registered.name == "testing.nvim", "setup: under the plugin name")
  local pos = registered.contribution.positions[1]
  ok(pos.on_request == true, "setup: on request only, never on the automatic trigger")
  ok(type(pos.fn) == "function", "setup: a position function")
  ok(type(registered.contribution.previews.file) == "function", "setup: a preview for spec paths")
  package.loaded["hover.registry"].contributors = function()
    return {}
  end
  ok(
    hover.status().state == "not registered",
    "status: hover.nvim there, testing.nvim not in its list"
  )
  package.loaded["hover.registry"].contributors = function()
    return { { name = "testing.nvim", positions = 1, previews = 1 } }
  end
  ok(hover.status().state == "registered", "status: registered as read back from hover.nvim")
  ok(hover.available() == true, "available: hover.nvim loads")
  package.loaded["hover.registry"] = nil
  package.preload["hover.registry"] = function()
    error("no hover.nvim here")
  end
  ok(hover.setup() == false, "setup: silent without hover.nvim")
  ok(hover.available() == false, "available: false without hover.nvim")
  ok(hover.status().state == "absent", "status: absent without hover.nvim")
  -- no hover.nvim: the command still answers, in a float, and nothing raises
  vim.api.nvim_set_current_buf(vim.fn.bufadd(root .. "/" .. other))
  ok(pcall(hover.show), ":Testing hover without hover.nvim does not raise")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  package.preload["hover.registry"] = nil
  -- the module itself never requires hover.nvim at load time
  package.loaded["testing.hover"] = nil
  package.preload["hover"] = function()
    error("hover must not be required at module level")
  end
  ok(pcall(require, "testing.hover"), "no require of hover at module level")
  package.preload["hover"] = nil
end
