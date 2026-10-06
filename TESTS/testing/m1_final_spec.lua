-- TESTS/testing/m1_final_spec.lua -- regressions of the M1 review: every one of these used to turn a
-- red or incomplete run green, or a green run red, or let hostile text reach a log. Each block
-- states the failure it guards against.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local cli = require("testing.cli")
  local sniff = require("testing.discover.sniff")
  local history = require("testing.history")
  local result = require("testing.core.result")
  local assert_mod = require("testing.core.assert")
  local json = require("lib.nvim.json")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local state_dir = vim.fs.normalize(vim.fn.tempname())
  local made = {}
  ---@return string
  local function new_root()
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-m1"
    vim.fn.mkdir(root .. "/TESTS", "p")
    made[#made + 1] = root
    return root
  end
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function go(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  ---@param path string
  ---@return string
  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end
  local function both(r)
    return "\n--- out\n" .. r.out .. "\n--- err\n" .. r.err
  end

  -- =====================================================================
  -- a busted file that registers no `it` is red in a REAL run (the driver always passes a selector)
  local root = new_root()
  write(
    root .. "/TESTS/never_spec.lua",
    "describe('x', function()\n  if false then\n    it('never', function() end)\n  end\nend)\n"
  )
  write(
    root .. "/TESTS/ok_spec.lua",
    "describe('y', function()\n  it('works', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  local r = go({ root })
  eq(r.code, 1, "a file without any it() is red, not silently absent" .. both(r))
  has(r.out, "FAIL  TESTS/never_spec.lua", "and names the file")
  ok(r.out:find("TESTING_OK", 1, true) == nil, "no sentinel")

  -- ... but a file whose cases are all filtered out is no failure (it did register cases)
  local froot = new_root()
  write(
    froot .. "/TESTS/a_spec.lua",
    "describe('a', function()\n  it('alpha', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  write(
    froot .. "/TESTS/b_spec.lua",
    "describe('b', function()\n  it('beta', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  r = go({ froot, "--filter", "alpha" })
  eq(r.code, 0, "a filter that skips every case of a file is not a failure" .. both(r))

  -- =====================================================================
  -- a file that was not classified is an error (exit 1), also behind a UTF-8 BOM
  eq(
    sniff.sniff("\239\187\191return function(H)\n  H.eq(1, 1, 'x')\nend\n").dialect,
    "a",
    "a BOM does not hide `return function(H)`"
  )
  local broot = new_root()
  write(
    broot .. "/TESTS/bom_spec.lua",
    "\239\187\191return function(H)\n  H.eq(1, 2, 'bom spec fails')\nend\n"
  )
  r = go({ broot })
  eq(r.code, 1, "a failing spec behind a BOM is red" .. both(r))
  has(r.out, "bom spec fails", "its failure is reported")
  local uroot = new_root()
  write(uroot .. "/TESTS/ok_spec.lua", "return function(H)\n  H.eq(1, 1, 'ok')\nend\n")
  write(uroot .. "/TESTS/mystery_spec.lua", "local x = 1\nreturn x\n")
  r = go({ uroot })
  eq(r.code, 1, "an unclassifiable file makes the exit code red" .. both(r))
  r = go({ uroot, "--json", uroot .. "/out.json" })
  eq(r.code, 1, "also with a written IR" .. both(r))
  eq(json.decode(slurp(uroot .. "/out.json")).summary.error, 1, "an error in the IR")

  -- =====================================================================
  -- scratch()/tmpdir() are shared by dialect b and c: such a spec never falls back to `a`
  eq(
    sniff.sniff("return function(H)\n  local b = H.scratch()\n  H.eq(b, b, 'x')\nend\n").dialect,
    "b",
    "scratch()"
  )
  eq(
    sniff.sniff("return function(H)\n  local b = H.scratch(lines)\n  H.eq(b, b, 'x')\nend\n").dialect,
    "b",
    "scratch(var) without other evidence"
  )
  eq(
    sniff.sniff("return function(H)\n  H.scratch(lines)\n  H.falsy(nil, 'x')\nend\n").dialect,
    "c",
    "scratch(var) next to a c helper"
  )
  eq(
    sniff.sniff("return function(H)\n  H.scratch()\n  H.tmpfile()\n  H.eq(1, 1, 'x')\nend\n").dialect,
    "unknown",
    "a helpers mix is not guessed"
  )
  eq(
    sniff.sniff("return function(H)\n  H.tmpdir(run)\n  H.eq(1, 1, 'x')\nend\n").dialect,
    "b",
    "tmpdir(var)"
  )
  local a = assert_mod.new()
  local hb = require("testing.dialect.harness_b").new(a)
  local hc = require("testing.dialect.harness_c").new(a)
  local buf = hb.scratch({ "one", "two" }, "lua")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two" }, "b: scratch(lines, ft)")
  eq(vim.bo[buf].filetype, "lua", "b: scratch(lines, ft) sets the filetype")
  vim.api.nvim_buf_delete(buf, { force = true })
  buf = hc.scratch("markdown")
  eq(vim.bo[buf].filetype, "markdown", "c: scratch(ft)")
  vim.api.nvim_buf_delete(buf, { force = true })
  local seen
  eq(
    hb.tmpdir(function(dir)
      seen = dir
      return 7
    end),
    7,
    "b: tmpdir(fn) returns fn's result"
  )
  ok(seen and vim.uv.fs_stat(seen) == nil, "b: tmpdir(fn) removes the directory")
  local dir = hc.tmpdir()
  ok(
    vim.uv.fs_stat(dir) ~= nil and (dir:sub(-1) == "/" or dir:sub(-1) == "\\"),
    "c: tmpdir() gives a fresh directory"
  )
  vim.fn.delete(dir, "rf")

  -- =====================================================================
  -- redaction: a word of the user name in a case id is no leak and no exit 3
  local saved_user, saved_username = vim.env.USER, vim.env.USERNAME
  vim.env.USER, vim.env.USERNAME = "runner", "runner"
  local rroot = new_root()
  write(
    rroot .. "/TESTS/r_spec.lua",
    "describe('the runner', function()\n  it('runs', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  local irpath = rroot .. "/out.json"
  r = go({ rroot, "--json", irpath })
  eq(r.code, 0, "a title with the user's name keeps a green run green" .. both(r))
  local ir = json.decode(slurp(irpath))
  ok(ir and ir.cases[1].id:find("the runner", 1, true) ~= nil, "the id is the project's own text")
  write(
    rroot .. "/TESTS/r_spec.lua",
    "describe('the runner', function()\n  it('runs', function() assert.are.equal(1, 2, 'Runner RUNNER failed') end)\nend)\n"
  )
  r = go({ rroot, "--json", irpath })
  eq(
    r.code,
    1,
    "a failing spec whose text names the user is red (1), not infrastructure (3)" .. both(r)
  )
  ir = json.decode(slurp(irpath))
  local texts = {}
  for _, c in ipairs(ir.cases) do
    for _, as in ipairs(c.assertions) do
      texts[#texts + 1] = tostring(as.msg)
    end
  end
  local joined = table.concat(texts, "\n")
  ok(
    joined:lower():find("runner", 1, true) == nil,
    "free text is redacted whatever its case: " .. joined
  )
  has(joined, "<USER>", "by the placeholder")
  vim.env.USER, vim.env.USERNAME = saved_user, saved_username
  -- the validator itself: `forbid` only for free text when asked
  local res = result.new({ root = "<repo>", id = "2026-01-01T00:00:00Z-0001" })
  local case = result.new_case({ file = "TESTS/x_spec.lua", name = "the runner" })
  case.status, case.reason = "skip", "no assertion needed"
  result.add_case(res, case)
  result.finalize(res)
  local decoded = json.decode(assert(result.encode(res)))
  local valid = result.validate(decoded, { forbid = { "runner" }, allow_abs_paths = true })
  eq(valid, false, "default: forbid is checked everywhere")
  valid = result.validate(
    decoded,
    { forbid = { "runner" }, forbid_free_text_only = true, allow_abs_paths = true }
  )
  eq(valid, true, "free-text-only: ids are exempt")

  -- a case NAMED after an address-shaped string (ai.nvim: "https://a:b@gw.example.com:8443/p") is the
  -- project's own word; a full sanitize must not end in exit 3 because of it, yet the same shape in
  -- free text is still redacted
  local mail = result.new({ root = "<repo>", id = "2026-01-01T00:00:00Z-0003" })
  local mcase =
    result.new_case({ file = "TESTS/x_spec.lua", name = "keeps https://a:b@gw.example.com:8443/p" })
  mcase.status = "skip"
  mcase.reason = "ask admin@example.com"
  result.add_case(mail, mcase)
  result.finalize(mail)
  local inproc = require("testing.run.inproc")
  local mir, mjson, merr = inproc.sanitize(mail, "<repo>")
  ok(mir ~= nil, "an address-shaped case name does not fail the IR validation: " .. tostring(merr))
  has(mjson or "", "gw.example.com", "the case name is kept as it is")
  ok(
    (mjson or ""):find("admin@example.com", 1, true) == nil,
    "while an address in free text (the skip reason) is redacted"
  )
  eq(
    result.validate(
      json.decode(assert(result.encode(mail))),
      { forbid_free_text_only = true, allow_abs_paths = true }
    ),
    false,
    "and the validator still flags an address in free text"
  )

  -- =====================================================================
  -- history: a control character in an id, or one bad id, never discards a run
  local rec = history.validate({
    v = history.VERSION,
    run = "r",
    ts = 1,
    failed = { "TESTS/a_spec.lua::a\tb", "TESTS/a_spec.lua::line\nbreak" },
  })
  ok(rec ~= nil, "a control character in an id does not discard the run")
  eq(
    rec and rec.failed,
    { "TESTS/a_spec.lua::a\tb", "TESTS/a_spec.lua::line\nbreak" },
    "and the ids are kept as they are"
  )
  local junk = history.validate({ v = history.VERSION, run = "r", ts = 1, failed = { "" } })
  eq(junk, nil, "an unusable id is a corrupt line, never 'no failures'")
  local long = "TESTS/a_spec.lua::" .. string.rep("x", history.MAX_ID_BYTES + 10)
  local hres = result.new({ root = root, id = "2026-01-01T00:00:00Z-0002" })
  for _, id in ipairs({ long, "TESTS/a_spec.lua::short" }) do
    local c = result.new_case({ file = "TESTS/a_spec.lua", name = "n" })
    c.id, c.status = id, "fail"
    result.add_case(hres, c)
  end
  result.finalize(hres)
  local failed, too_long = history.merge_failed({}, hres, {})
  eq(failed, { "TESTS/a_spec.lua::short" }, "the short id is remembered")
  eq(too_long, 1, "the long one is counted, not silently lost")
  local hok, herr, note = history.record(root, hres, {}, { state_dir = state_dir })
  ok(hok and herr == nil, "recorded")
  has(note, "cannot be remembered", "and the loss is a note")

  -- =====================================================================
  -- hostile ids never reach a log raw (workflow-command and terminal-escape injection)
  local hroot = new_root()
  write(
    hroot .. "/TESTS/h_spec.lua",
    [=[describe("grp\n::error::pwn\27[31m\0 \226\128\174x", function()
  it("works", function() assert.are.equal(1, 1) end)
end)
]=]
  )
  r = go({ hroot, "--list" })
  eq(r.code, 0, "--list works" .. both(r))
  ok(r.out:find("[%z\1-\9\11-\31]") == nil, "no control byte besides line breaks in the listing")
  for line in (r.out .. "\n"):gmatch("(.-)\n") do
    ok(line:sub(1, 9) ~= "::error::", "no listing line starts a workflow command: " .. line)
  end
  ok(r.out:find("\226\128\174", 1, true) == nil, "no bidi override in the listing")

  -- =====================================================================
  -- a spec that fires VimLeavePre itself is not the editor quitting
  local project = require("testing.run.project")
  local release = project.guard_exit()
  vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })
  release()
  ok(true, "a synthetic VimLeavePre does not end the run")

  -- =====================================================================
  -- per-file dialect overrides in .testing.lua
  local config = require("testing.config.project")
  local cfg, probs = config.validate({ dialect = { ["TESTS/x_spec.lua"] = "c", ["*"] = "a" } })
  eq(probs, {}, "a table is a valid dialect setting")
  eq(cfg.dialect, { ["TESTS/x_spec.lua"] = "c", ["*"] = "a" }, "and is kept")
  local _, bad_path = config.validate({ dialect = { ["../x_spec.lua"] = "c" } })
  ok(#bad_path > 0, "an unsafe path in the table is refused")
  local _, bad_name = config.validate({ dialect = { ["TESTS/x_spec.lua"] = "pascal" } })
  ok(#bad_name > 0, "an unknown dialect in the table is refused")
  local droot = new_root()
  write(droot .. "/TESTS/x_spec.lua", "return function(H)\n  H.eq(1, 1, 'x')\nend\n")
  write(droot .. "/.testing.lua", 'return { dialect = { ["TESTS/x_spec.lua"] = "c" } }\n')
  local found = require("testing.discover").discover(droot, {
    scan_lua_dir = false,
    dialect = { ["TESTS/x_spec.lua"] = "c" },
  })
  eq(found.files[1].dialect, "c", "discovery applies the per-file override")
  r = go({ droot })
  eq(r.code, 0, "and the run uses it" .. both(r))

  for _, p in ipairs(made) do
    vim.fn.delete(p, "rf")
  end
  vim.fn.delete(state_dir, "rf")
end
