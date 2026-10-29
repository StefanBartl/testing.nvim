-- TESTS/testing/ci_derive_spec.lua -- the pipeline of a Lua project without `ci` profiles: derived from what the
-- repository has (stylua.toml, .luacheckrc, spec files, the conformance gate), adjusted by `skip` and own `steps`,
-- and said where it came from (`ci list`, the document, the message of a missing tool).

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local derive = require("testing.ci.derive")
  local schema = require("testing.ci.schema")
  local cli = require("testing.cli")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-derive"
  vim.fn.mkdir(tmp, "p")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---A Lua project with the files named (`true` for an empty one) and a .testing.lua.
  ---@param name string
  ---@param files table<string, string|true>
  ---@param testing_lua? string The Lua text after `return`.
  ---@return string root
  local function project(name, files, testing_lua)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/init.lua", "return {}\n")
    for rel, text in pairs(files) do
      write(root .. "/" .. rel, text == true and "" or text)
    end
    write(root .. "/.testing.lua", "return " .. (testing_lua or "{ plugin = 'proj' }") .. "\n")
    return root
  end

  local FULL = {
    ["stylua.toml"] = 'indent_type = "Spaces"\n',
    [".luacheckrc"] = 'std = "luajit"\n',
    ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end\n",
  }

  -- what is derived, and why
  do
    local root = project("full", FULL, "{ plugin = 'proj', conformance = { gate = true } }")
    local section, why = derive.section(root, { conformance = { gate = true } })
    eq(section.profiles.fast, { "stylua", "luacheck" }, "derive: fast is stylua and luacheck")
    eq(
      section.profiles.full,
      { "fast", "suite", "conformance" },
      "derive: full adds suite and conformance"
    )
    eq(section.default, "full", "derive: full is the default")
    eq(why.stylua, "stylua.toml", "derive: stylua because of stylua.toml")
    eq(why.luacheck, ".luacheckrc", "derive: luacheck because of .luacheckrc")
    has(why.suite, "TESTS/", "derive: the suite because of its spec files")
    eq(why.conformance, "conformance.gate = true", "derive: conformance because it is a gate")

    local no_gate = derive.section(root, {})
    eq(no_gate.profiles.full, { "fast", "suite" }, "derive: no conformance step without the gate")

    local dot = project("dot-stylua", { [".stylua.toml"] = "" })
    local _, dot_why = derive.section(dot, {})
    eq(dot_why.stylua, ".stylua.toml", "derive: .stylua.toml counts too")

    local roots = project("roots", { ["spec/x_spec.lua"] = "return 1\n" })
    eq(
      derive.section(roots, {}),
      nil,
      "derive: spec files outside the spec roots are not the suite"
    )
    local custom = derive.section(roots, { roots = { "spec" } })
    eq(custom.profiles.full, { "suite" }, "derive: ... unless `roots` names their folder")

    local not_lua = tmp .. "/not-lua"
    write(not_lua .. "/stylua.toml", "")
    local none, reason = derive.section(not_lua, {})
    eq(none, nil, "derive: nothing without a lua/ folder")
    has(reason, "not a Lua project", "derive: ... and says why")
    local empty = project("empty", {})
    local nothing, empty_reason = derive.section(empty, {})
    eq(nothing, nil, "derive: nothing to derive in a bare Lua project")
    has(empty_reason, "nothing to derive", "derive: ... and says so")
  end

  -- schema.load: no section derives; `skip` leaves out; own `steps` define anew or join `full`
  do
    local root = project("load", FULL)
    local p = schema.load(root)
    eq(p.profiles.full, { "stylua", "luacheck", "suite" }, "load: the derived pipeline, expanded")
    eq(p.derived.stylua, "stylua.toml", "load: what was derived is part of the pipeline")

    local skipped = project("skip", FULL, "{ plugin = 'proj', ci = { skip = { 'luacheck' } } }")
    p = schema.load(skipped)
    eq(p.profiles.fast, { "stylua" }, "skip: luacheck is out of fast")
    eq(p.profiles.full, { "stylua", "suite" }, "skip: ... and of full")
    eq(p.derived.luacheck, nil, "skip: ... and not called derived")

    local both =
      project("skip-both", FULL, "{ plugin = 'proj', ci = { skip = { 'stylua', 'luacheck' } } }")
    p = schema.load(both)
    eq(p.profiles.fast, nil, "skip: an empty fast profile is gone")
    eq(p.profiles.full, { "suite" }, "skip: full keeps the rest")

    local bad = project("skip-bad", FULL, "{ plugin = 'proj', ci = { skip = { 'docs' } } }")
    local none, problems = schema.load(bad)
    eq(none, nil, "skip: a name that is not derived is an error")
    has(table.concat(problems, "\n"), '"docs" is not a derived step', "skip: ... naming it")

    local all = project(
      "skip-all",
      { ["stylua.toml"] = "" },
      "{ plugin = 'proj', ci = { skip = { 'stylua' } } }"
    )
    none, problems = schema.load(all)
    eq(none, nil, "skip: leaving nothing is an error")
    has(table.concat(problems, "\n"), "leaves nothing to run", "skip: ... saying so")

    local own = project(
      "own-steps",
      FULL,
      "{ plugin = 'proj', ci = { steps = { docs = { run = { 'x' } }, luacheck = { preset = 'luacheck', args = { 'lua' } } } } }"
    )
    p = schema.load(own)
    eq(p.profiles.full, { "stylua", "luacheck", "suite", "docs" }, "steps: an own step joins full")
    eq(p.steps.luacheck.argv[#p.steps.luacheck.argv], "lua", "steps: a derived step defined anew")
    eq(p.derived.docs, nil, "steps: an own step is not derived")

    local written =
      project("written", FULL, "{ plugin = 'proj', ci = { profiles = { full = { 'stylua' } } } }")
    p = schema.load(written)
    eq(p.profiles.full, { "stylua" }, "written: a section with profiles is used as written")
    eq(p.derived, nil, "written: ... and nothing is derived")
    local mixed = project(
      "written-skip",
      FULL,
      "{ plugin = 'proj', ci = { profiles = { full = { 'stylua' } }, skip = { 'luacheck' } } }"
    )
    none, problems = schema.load(mixed)
    eq(none, nil, "written: skip with profiles is an error")
    has(
      table.concat(problems, "\n"),
      "only a section without `profiles`",
      "written: ... saying when skip applies"
    )

    local not_lua = tmp .. "/load-not-lua"
    write(not_lua .. "/.testing.lua", "return {}\n")
    none, problems = schema.load(not_lua)
    eq(none, nil, "load: not a Lua project and no section")
    has(
      table.concat(problems, "\n"),
      "no `ci` section",
      "load: ... the old message, with the reason"
    )
  end

  ---@param root string
  ---@param ... string
  local function run(root, ...)
    local out, err = {}, {}
    -- a subcommand (`list`) comes first, the root after it
    local rest = { ... }
    local argv = { "ci" }
    if rest[1] == "list" then
      argv[2] = table.remove(rest, 1)
    end
    argv[#argv + 1] = "--root=" .. root
    vim.list_extend(argv, rest)
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      affected = { provider = false },
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  -- what the user sees: `ci list` names where each step came from; a missing tool of a derived step says how to
  -- leave it out
  do
    local root = project("list", FULL)
    local res = run(root, "list")
    eq(res.code, 0, "list: a derived pipeline lists")
    has(res.out, "derived: stylua (stylua.toml)", "list: says where a step came from")
    has(res.out, "fast: stylua, luacheck", "list: the profiles")

    local missing = project(
      "missing-tool",
      { ["stylua.toml"] = "" },
      "{ plugin = 'proj', ci = { steps = { stylua = { run = { 'does-not-exist-tool-xyz' } } } } }"
    )
    res = run(missing)
    eq(res.code, 3, "missing tool: exit 3")
    has(res.err, "The step is derived (stylua.toml)", "missing tool: the step is called derived")
    has(res.err, 'skip = { "stylua" }', "missing tool: ... and how to leave it out")
  end
end
