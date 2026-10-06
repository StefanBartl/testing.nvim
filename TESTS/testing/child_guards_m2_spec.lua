-- TESTS/testing/child_guards_m2_spec.lua -- what the fleet runs of milestone M2 showed about the guards in a child
-- editor per file, with real children: the child's own sandbox is not "outside", a one-case child is
-- thrown away with its case (the state guard says it does not measure, instead of naming what dies with
-- the process), a busted child keeps the state guard between its cases, and a `script` file says that no
-- guard ran in it.

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

  ---@param root string
  ---@param files table<string, string>
  ---@param order string[]
  ---@param dialect? string
  ---@return Testing.Inproc.Report
  local function run(root, files, order, dialect)
    local o = options_mod.of({ project = { isolated = "file" }, args = {} })
    o.host_given = false
    return S.run(root, S.project(root, files, order, dialect), {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      guard_cfg = options_mod.guard_config(o, { root = root }),
    })
  end

  ---Findings of the case, as `id:severity` strings.
  ---@param case Testing.Result.Case
  ---@return string[]
  local function ids(case)
    local out = {}
    for _, g in ipairs(case.guards or {}) do
      out[#out + 1] = tostring(g.id or g.guard) .. ":" .. g.severity
    end
    return out
  end

  -- ===================================================================
  -- 1. a write below the child's own stdpath is a write into its sandbox, never "outside"
  do
    local root = S.new_root()
    local rep = run(root, {
      ["TESTS/a_spec.lua"] = [==[
return function(H)
  local dir = vim.fn.stdpath("data") .. "/someplugin"
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/usage.json", "w"))
  f:write("{}")
  f:close()
  vim.fn.mkdir(vim.fn.stdpath("cache"), "p")
  assert(io.open(vim.fn.stdpath("cache") .. "/x.tmp", "w")):close()
  H.ok(true, "wrote into the sandbox")
end
]==],
    }, { "TESTS/a_spec.lua" })
    local c = S.case_of(rep, "TESTS/a_spec.lua")
    eq(c.status, "pass", "the spec that writes into stdpath('data'|'cache') passes")
    eq(
      ids(c),
      {},
      "and no fs finding is made for the child's own sandbox: " .. vim.inspect(c.guards)
    )
  end

  -- 2. a one-case child is thrown away with its case: the state guard is off, and says so
  do
    local root = S.new_root()
    local rep = run(root, {
      ["TESTS/a_spec.lua"] = 'return function(H)\n  rawset(_G, "leaky_global", 1)\n  H.ok(true, "a")\nend\n',
    }, { "TESTS/a_spec.lua" })
    local c = S.case_of(rep, "TESTS/a_spec.lua")
    eq(c.status, "pass", "a leak that dies with the process does not fail a one-case file")
    eq(ids(c), {}, "and is not named either: " .. vim.inspect(c.guards))
    has(
      table.concat(c.notes, "\n"),
      "state: leaks (autocmds, buffers, globals, ...) are not measured",
      "the case says the leaks were not measured"
    )
  end

  -- 3. a busted child runs several cases in one editor: the state guard stays on between them
  do
    local root = S.new_root()
    local rep = run(root, {
      ["TESTS/b_spec.lua"] = [==[
describe("shared editor", function()
  it("leaves a global behind", function()
    rawset(_G, "leaky_between_cases", 1)
    assert.is_true(true)
  end)
  it("runs after it", function()
    assert.is_true(true)
  end)
end)
]==],
    }, { "TESTS/b_spec.lua" }, "busted")
    local named = false
    for _, c in ipairs(rep.result.cases) do
      for _, g in ipairs(c.guards or {}) do
        if g.id == "state.lua_global" and g.message:find("leaky_between_cases", 1, true) then
          named = true
        end
      end
    end
    ok(named, "busted in a child: the global that leaks into the next case is named")
  end

  -- 4. a script runs in its own process: no guard, and the case says so (an empty list is not a result)
  do
    local root = S.new_root()
    local rep = run(root, {
      ["TESTS/s_spec.lua"] = 'print("hello from a script")\n',
    }, { "TESTS/s_spec.lua" }, "script")
    local c = S.case_of(rep, "TESTS/s_spec.lua")
    eq(c.status, "pass", "the script ran")
    has(
      table.concat(c.notes, "\n"),
      "guards: not installed in a `script` file",
      "its case says that no guard was measuring it"
    )
  end

  S.cleanup()
end
