-- TESTS/testing/surface_e2e_spec.lua -- the whole chain on a real project and the REAL runner: the tracker is
-- connected to the runner's case windows from the project's minit (`track.hook_runner`), every spec file
-- runs in its own child editor, the hits land in a sink with the file of the case, and `testing surface`
-- reads the surface of the project in another child and joins both: ratio, thresholds, exit codes, the
-- per-file numbers and the baseline round trip.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 900) .. ")"
    )
  end

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/surface_support.lua")
  local surface = require("testing.surface")
  local entry = S.repo .. "/scripts/testing.lua"

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  S.run(function()
    local root = S.fixture()
    local sink = S.new_dir() .. "/sink.jsonl"

    -- the project's own harness and two specs: one drives a keymap and a command, the other a route
    write(
      root .. "/TESTS/harness.lua",
      [==[
local H = {}
function H.ok(v, msg)
  if not v then
    error("FAIL " .. msg, 2)
  end
end
return H
]==]
    )
    write(
      root .. "/TESTS/a_spec.lua",
      [==[
return function(H)
  require("fxsurf").setup()
  vim.api.nvim_feedkeys(vim.keycode("<Bslash>fo"), "mx", false)
  H.ok(require("fxsurf").calls.open == 1, "the keymap ran")
  vim.cmd("FxOpen")
  H.ok(require("fxsurf").calls.open == 2, "the command ran")
end
]==]
    )
    write(
      root .. "/TESTS/b_spec.lua",
      [==[
return function(H)
  require("fxsurf").setup()
  vim.cmd("Fx status")
  H.ok(require("fxsurf").calls.status == 1, "the route ran")
end
]==]
    )
    write(
      root .. "/TESTS/minimal_init.lua",
      ([==[
-- puts the plugin on the runtimepath and tracks the surface; the layer goes in BEFORE any setup()
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))
require("testing.surface.track").hook_runner({ sink = %q })
]==]):format(sink)
    )
    write(
      root .. "/.testing.lua",
      [==[
return {
  plugin = "fxsurf",
  dialect = "h",
  isolated = "file",
  minit = "TESTS/minimal_init.lua",
  setup = {},
}
]==]
    )

    -- ---------------------------------------------------------------- the run
    local ir_path = S.new_dir() .. "/ir.json"
    local res = vim
      .system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        entry,
        root,
        "--json",
        ir_path,
      }, { text = true, env = { TESTING_AGENT = "0" } })
      :wait(180000)
    ok(
      res.code == 0,
      "the project's suite is green: " .. tostring(res.stdout) .. tostring(res.stderr)
    )

    local lines = {}
    for line in io.lines(sink) do
      lines[#lines + 1] = vim.json.decode(line)
    end
    local by_file = {}
    for _, l in ipairs(lines) do
      if l.k == "case" then
        by_file[l.file] = l
      end
    end
    ok(
      by_file["TESTS/a_spec.lua"],
      "the sink has the case of a_spec.lua with its file: " .. vim.inspect(lines)
    )
    ok(by_file["TESTS/b_spec.lua"], "and the one of b_spec.lua")
    eq(
      by_file["TESTS/a_spec.lua"].hit,
      { "action:fxsurf.open", "binding:<leader>fo", "command:FxOpen" },
      "a_spec.lua exercised the keymap and the command (hit ids as the reader names them)"
    )
    eq(by_file["TESTS/b_spec.lua"].hit, { "command:Fx status" }, "b_spec.lua the route")

    -- ---------------------------------------------------------------- the report
    local services = { cwd = root }
    local code, text = surface.main({ root, "--hits", sink, "--threshold", "0.5" }, services)
    eq(code, 0, "3 of 6 entries is the 50 % the threshold asks for: " .. text)
    has(text, "overall  3/6  50.0%", "the ratio")
    has(text, "hit ", "statuses")
    has(text, "missing", "and what no spec exercised")
    code, text = surface.main({ root, "--hits", sink, "--threshold", "0.51" }, services)
    eq(code, 1, "just above: exit 1")
    has(text, "below threshold: overall 50.0% < 51.0%", "named")
    code, text = surface.main({ root, "--hits", sink, "--threshold", "binding=1" }, services)
    eq(code, 1, "bindings: 1 of 3 is no 100 %")
    has(text, "binding:<leader>fc@nx", "the missing ones are listed")

    local report = surface.report(root, { hits = { sinks = { sink } } })
    eq(
      report.coverage.missing,
      { "binding:<leader>fc@nx", "binding:<leader>ft", "autocmd:fxsurf:BufWritePost:*.fx" },
      "missing"
    )
    eq(report.files["TESTS/a_spec.lua"].hit, 2, "per file: a_spec.lua")
    eq(report.files["TESTS/b_spec.lua"].hit, 1, "per file: b_spec.lua")

    -- the aggregate goes into the IR of the run, which still validates
    local f = assert(io.open(ir_path, "rb"))
    local ir = vim.json.decode(f:read("*a"))
    f:close()
    surface.annotate_ir(ir, report)
    eq(ir.surface.total, 6, "IR: total")
    eq(ir.surface.hit, 3, "IR: hit")
    eq(ir.surface.files["TESTS/a_spec.lua"].hit, 2, "IR: per file")

    -- ---------------------------------------------------------------- baseline: a spec that stops driving something is caught
    local base = S.new_dir() .. "/baseline.json"
    code = surface.main({ root, "--hits", sink, "--write-baseline", base }, services)
    eq(code, 0, "baseline written")
    code = surface.main({ root, "--hits", sink, "--baseline", base }, services)
    eq(code, 0, "same run, no regression")
    -- b_spec.lua stops running the route
    write(
      root .. "/TESTS/b_spec.lua",
      [==[
return function(H)
  require("fxsurf").setup()
  H.ok(true, "does nothing now")
end
]==]
    )
    local sink2 = S.new_dir() .. "/sink2.jsonl"
    local minit = io.open(root .. "/TESTS/minimal_init.lua", "rb")
    local minit_text = minit:read("*a")
    minit:close()
    write(
      root .. "/TESTS/minimal_init.lua",
      (minit_text:gsub("sink = [^}]*", ("sink = %q "):format(sink2)))
    )
    res = vim
      .system(
        { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", entry, root },
        { text = true, env = { TESTING_AGENT = "0" } }
      )
      :wait(180000)
    ok(
      res.code == 0,
      "the changed suite is green: " .. tostring(res.stdout) .. tostring(res.stderr)
    )
    code, text = surface.main({ root, "--hits", sink2, "--baseline", base }, services)
    eq(code, 1, "the route is not exercised any more: the baseline catches it")
    has(text, "command:Fx status", "and names it")
  end)
end
