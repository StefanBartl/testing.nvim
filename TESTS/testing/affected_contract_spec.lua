-- TESTS/testing/affected_contract_spec.lua -- the consumer side of the documentation.nvim contract against ANSWERS
-- THE REAL PROVIDER GAVE (recorded from `documentation.testing.affected_specs` of documentation.nvim e427659 on its
-- own repository, shortened; fixtures/affected/*.json). The earlier version of this consumer was written against
-- an imagined shape (lists of names) and silently never used the graph: every real answer was "an unknown shape".
--
-- To record again: call `require("documentation.testing").affected_specs({ root = ..., changed = ... })` in a
-- checkout of documentation.nvim and write the table with `vim.json.encode`.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local affected = require("testing.affected")

  local function recorded(name)
    return vim.json.decode(S.read(dir .. "/fixtures/affected/" .. name .. ".json"))
  end
  local complete = recorded("documentation_answer_complete")
  local incomplete = recorded("documentation_answer_incomplete")

  -- the shape is accepted as it is
  ok(affected.check_answer(complete) ~= nil, "a real, complete answer is a valid answer")
  ok(affected.check_answer(incomplete) ~= nil, "a real, incomplete answer is a valid answer")
  eq(complete.complete, true, "the recording is complete")
  eq(incomplete.complete, false, "the other one is not")
  -- and the shape checks can fail: each of these breaks one thing the real provider promises
  for _, broken in ipairs({
    function(a)
      a.specs = { { "x" } }
    end,
    function(a)
      a.modules = { "documentation" }
    end,
    function(a)
      a.complete = nil
    end,
    function(a)
      a.graph.stale = nil
    end,
    function(a)
      a.graph.gaps = { "documentation" }
    end,
    function(a)
      a.unplaced_specs = "TESTS/x_spec.lua"
    end,
  }) do
    local copy = vim.deepcopy(complete)
    broken(copy)
    ok(affected.check_answer(copy) == nil, "a broken answer is refused")
  end

  -- a project that has the specs and the module of the recording
  local names = {}
  for _, s in ipairs(complete.specs) do
    names[s] = true
  end
  for _, s in ipairs(complete.unplaced_specs or {}) do
    names[s] = true
  end
  local files = {
    ["lua/documentation/core/annotate.lua"] = "return {}\n",
    ["lua/documentation/other.lua"] = "return {}\n",
    ["TESTS/own_spec.lua"] = "return function(H) H.ok(true, 'own') end\n",
  }
  local specs = { "TESTS/own_spec.lua" }
  for name in pairs(names) do
    files[name] = "return function(H) H.ok(true, 'x') end\n"
    specs[#specs + 1] = name
  end
  table.sort(specs)
  local root = S.project(files)
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local function select_with(answer, changed)
    return affected.select({
      root = root,
      specs = specs,
      changed = changed,
      getenv = function() end,
      cache_dir = cdir,
      roots = { "TESTS" },
      provider = function()
        return (vim.deepcopy(answer))
      end,
    })
  end

  local r = select_with(complete, { "lua/documentation/core/annotate.lua" })
  eq(r.source, "graph", "the graph is used (the real answer is not 'an unknown shape')")
  eq(r.all, false, "a complete answer narrows")
  for _, s in ipairs(complete.specs) do
    ok(vim.tbl_contains(r.files, s), s .. " is selected: the graph named it")
  end
  for _, s in ipairs(complete.unplaced_specs or {}) do
    ok(vim.tbl_contains(r.files, s), s .. " is selected: the graph cannot place it, run it too")
  end
  eq(#r.warnings, 0, "no warning that the graph was not used")

  -- the same change with a graph that is not complete runs everything
  r = select_with(incomplete, { "lua/documentation/core/annotate.lua" })
  eq(r.all, true, "an incomplete answer selects everything")
  ok(
    r.all_reason:find("test_support_changed", 1, true) ~= nil,
    "and names why: " .. tostring(r.all_reason)
  )

  -- a changed module the answer does not mention is not trusted
  r = select_with(complete, { "lua/documentation/other.lua" })
  eq(r.all, true, "a module file the graph does not know selects everything")

  require("testing.cache").reset()
  S.remove(root)
  S.remove(cdir)
end
