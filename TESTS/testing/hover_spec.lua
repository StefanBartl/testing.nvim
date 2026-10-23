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
  has(text(c), "no result yet", "no result: said, not silent")

  -- the buffer side -----------------------------------------------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, root .. "/" .. other)
  local content = hover.at(buf, 1, opts)
  ok(content and text(content):find("no result yet", 1, true), "at: a spec file of a project")
  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(src, root .. "/lua_thing.lua")
  ok(hover.at(src, 1, opts) == nil, "at: a file that is no test file declines")
  local nobuf = vim.api.nvim_create_buf(false, true)
  ok(hover.at(nobuf, 1, opts) == nil, "at: a buffer without a name declines")
  ok(hover.position(src, 1, 0) == nil, "position: declines and never raises")
  for _, b in ipairs({ buf, src, nobuf }) do
    vim.api.nvim_buf_delete(b, { force = true })
  end

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
  package.loaded["hover.registry"] = nil
  package.preload["hover.registry"] = function()
    error("no hover.nvim here")
  end
  ok(hover.setup() == false, "setup: silent without hover.nvim")
  package.preload["hover.registry"] = nil
end
