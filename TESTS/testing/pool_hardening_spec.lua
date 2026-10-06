-- TESTS/testing/pool_hardening_spec.lua -- the warm pool does not lie about "clean": what the review of
-- milestone M2 found that a reused member kept without anybody noticing (replaced functions of the editor
-- API and the standard library, registers, abbreviations, tab and window variables, diagnostics, a guard
-- layer that stays installed) is now undone or makes the member be thrown away, and a red case in a reused
-- member says where it ran. Real editors (`testing.rpc`), the real isolated driver.

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
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local options_mod = require("testing.run.options")

  ---Run `files` (rel -> body) in `order` through ONE warm-pool member.
  ---@param files table<string, string>
  ---@param order string[]
  ---@return table report
  local function run(files, order)
    local root = S.new_root()
    local entries = S.project(root, files, order)
    local o = options_mod.of({
      project = { isolated = "file", pool = { reuse = true, size = 1 } },
      args = { jobs = 1 },
    })
    o.host_given = false
    return S.run(root, entries, {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      guard_cfg = options_mod.guard_config(o, { root = root }),
    })
  end

  ---Findings of the guard `name` over the whole report.
  ---@param report table
  ---@param name string
  ---@return Testing.Result.GuardFinding[]
  local function findings(report, name)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      for _, g in ipairs(c.guards or {}) do
        if g.guard == name then
          out[#out + 1] = g
        end
      end
    end
    return out
  end

  local A, B = "TESTS/a_spec.lua", "TESTS/b_spec.lua"

  -- ===================================================================
  -- 1. a function of the editor API or the standard library that a file replaced for good
  do
    local rep = run({
      [A] = [==[
return function(H)
  vim.fn.expand = function() return "stub" end
  vim.json.decode = function() return 1 end
  getmetatable("").__index.poison = function() end
  H.ok(true, "a leaves stubs behind")
end
]==],
      [B] = [==[
return function(H)
  H.ok(vim.fn.expand("%") ~= "stub", "b sees the real vim.fn.expand")
  H.ok(vim.json.decode("1") == 1, "b sees the real vim.json.decode")
  H.ok(("x").poison == nil, "b sees no extra string method")
end
]==],
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":pass" }, "both files pass: b ran in a fresh member")
    eq(rep.pool.spawned, 2, "the member that kept the stubs was not reused")
    eq(rep.pool.discarded, 1, "it was discarded")
    local found = findings(rep, "pool")
    eq(#found, 1, "one finding names the file that left the stubs")
    has(found[1].message, A, "the finding names the culprit file")
    has(found[1].message, "vim.fn.expand was replaced", "and the replaced function")
    has(found[1].message, "vim.json.decode was replaced", "and the second one")
    has(found[1].message, "poison was added", "and the string method")
  end

  -- 2. registers and abbreviations are put back, the member is reused
  do
    local rep = run({
      [A] = [==[
return function(H)
  vim.fn.setreg("a", "leaked text")
  vim.fn.setreg("/", "leaked pattern")
  vim.cmd("iabbrev teh the")
  H.ok(true, "a fills registers and defines an abbreviation")
end
]==],
      [B] = [==[
return function(H)
  H.ok(vim.fn.getreg("a") == "", "register a is empty")
  H.ok(vim.fn.getreg("/") ~= "leaked pattern", "the search register is back")
  H.ok(not vim.fn.execute("iabbrev"):find("teh", 1, true), "the abbreviation is gone")
end
]==],
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":pass" }, "registers and abbreviations: both pass")
    eq(
      rep.pool.spawned,
      1,
      "the member was reused: they were put back, not a reason to throw it away"
    )
    eq(rep.pool.discarded, 0, "nothing discarded")
  end

  -- 3. tab and window variables and diagnostics (ui.nvim: `vim.t.bufs` kept numbers of wiped buffers, every
  -- later case died with "E86: Buffer N does not exist")
  do
    local rep = run({
      [A] = [==[
return function(H)
  vim.t.bufs = { 1, 2, 99 }
  vim.w.some_state = "x"
  local ns = vim.api.nvim_create_namespace("leak_ns")
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = "left over" } })
  H.ok(#vim.diagnostic.get(0) == 1, "a sets a tab variable, a window variable and a diagnostic")
end
]==],
      [B] = [==[
return function(H)
  H.ok(vim.t.bufs == nil, "the tab variable is gone")
  H.ok(vim.w.some_state == nil, "the window variable is gone")
  H.ok(#vim.diagnostic.get() == 0, "no diagnostic is left")
end
]==],
    }, { A, B })
    eq(
      S.statuses(rep),
      { A .. ":pass", B .. ":pass" },
      "scoped variables and diagnostics: both pass"
    )
    eq(rep.pool.spawned, 1, "and the member was reused")
  end

  -- 4. a red case in a reused member says where it ran
  do
    local rep = run({
      [A] = 'return function(H) H.ok(true, "clean") end\n',
      [B] = 'return function(H) H.eq(1, 2, "red") end\n',
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":fail" }, "a clean file, then a red one")
    local red = S.case_of(rep, B)
    has(
      table.concat(red.notes, "\n"),
      "ran in a reused warm-pool member after " .. A,
      "the red case names the file before it"
    )
    has(
      table.concat(red.notes, "\n"),
      "--no-pool-reuse",
      "and how to tell a leak from a bug of its own"
    )
    local first = S.case_of(rep, A)
    eq(#vim.tbl_filter(function(n)
      return n:find("reused warm-pool member", 1, true) ~= nil
    end, first.notes), 0, "the first file of a member carries no such note")
  end

  -- 5. a guard layer that stays installed is a leak: the next file would wrap its wrappers
  do
    local rep = run({
      [A] = [==[
return function(H)
  _G.__keep_handle = require("testing.guard").install({ guards = { fs = "off", state = "off", process_net = "off" } })
  H.ok(true, "a installs a guard layer and never uninstalls it")
end
]==],
      [B] = 'return function(H) H.ok(true, "b") end\n',
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":pass" }, "both pass")
    eq(rep.pool.discarded, 1, "the member with the leftover guard layer was discarded")
    local found = findings(rep, "pool")
    eq(#found, 1, "and a finding says why")
    has(found[1].message, "guard layer is still installed", "it names the guard layer")
  end

  -- 6. a function the runtime creates by itself on first use (`vim.uri_from_fname`, `vim.fn.x`) is not a stub
  do
    local rep = run({
      [A] = [==[
return function(H)
  H.ok(vim.uri_from_fname("/tmp/x") ~= nil, "a touches lazily created functions")
  H.ok(vim.fn.fnamemodify("x", ":p") ~= nil, "and vim.fn ones")
end
]==],
      [B] = 'return function(H) H.ok(true, "b") end\n',
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":pass" }, "lazy functions: both pass")
    eq(rep.pool.discarded, 0, "and the member is not discarded for what the runtime made")
    eq(rep.pool.spawned, 1, "one member for both files")
  end

  -- 7. a stub layered on top of a function the guard layer wrapped (`io.open`, `vim.system`) and never
  -- put back: the guard cannot undo its wrapper, the member is not clean, and the finding names the
  -- slot and the file
  do
    local rep = run({
      [A] = [==[
return function(H)
  local wrapped = io.open
  rawset(io, "open", function(...) return wrapped(...) end)
  H.ok(true, "a stubs io.open on top of the guard's wrapper")
end
]==],
      [B] = "return function(H) H.ok(io.open ~= nil, 'b') end",
    }, { A, B })
    eq(S.statuses(rep), { A .. ":pass", B .. ":pass" }, "both pass")
    eq(
      rep.pool.discarded,
      1,
      "the member whose io.open is a stub on top of the wrapper is discarded"
    )
    local found = findings(rep, "pool")
    ok(#found >= 1, "a finding says why")
    has(
      found[1].message,
      "guard patch not restored: io.open",
      "it names the slot the guard could not undo"
    )
    has(found[1].message, A, "and the file")
  end

  S.cleanup()
end
