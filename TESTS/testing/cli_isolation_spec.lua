-- TESTS/testing/cli_isolation_spec.lua -- the M2 isolation features end to end, as real `testing` processes on temp
-- projects: `--isolated=soft` (a polluted file sequence stays contained, the leaks are named), `--isolated=case`
-- (order-dependent cases, the degrade note), `--guard` / `.testing.lua` `guards` (a deprecation finding is a warning,
-- an error, or nothing), and the reporters that carry the findings. The fs guard is switched off where it is not the
-- subject: its snapshot of the user's real directories is the slow part of a run.

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
      msg .. " (got " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (got " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.dirname(vim.fs.dirname(dir))
  local entry = repo .. "/scripts/testing.lua"
  local S = dofile(dir .. "/child_support.lua")

  ---Run `testing` as a process. Returns exit code, stdout, stderr.
  local function run(argv)
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", entry }
    vim.list_extend(cmd, argv)
    local res = vim.system(cmd, { text = true, env = { TESTING_AGENT = "0" } }):wait(120000)
    return res.code, res.stdout or "", res.stderr or ""
  end
  local function project(files)
    local root = S.new_root()
    for rel, text in pairs(files) do
      S.write(root .. "/" .. rel, text)
    end
    return root
  end
  local QUIET = { "--guard", "fs=off", "--no-timings" }
  local function args(root, ...)
    local list = { root }
    vim.list_extend(list, QUIET)
    vim.list_extend(list, { ... })
    return list
  end

  -- ================================================================== --isolated=soft
  local soft_root = project({
    ["TESTS/a_spec.lua"] = [[
return function(H)
  local group = vim.api.nvim_create_augroup("LeakGroup", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, pattern = "*.leak", command = "echo 1" })
  rawset(_G, "leaked_global", 1)
  package.loaded["leaky.mod"] = { x = 1 }
  vim.g.leaked_var = "x"
  vim.api.nvim_set_current_dir(vim.uv.os_tmpdir())
  H.eq(1, 1, "a")
end
]],
    ["TESTS/b_spec.lua"] = [[
return function(H)
  H.eq(rawget(_G, "leaked_global"), nil, "the global of the previous file is gone")
  H.eq(package.loaded["leaky.mod"], nil, "the module is gone")
  H.eq(vim.g.leaked_var, nil, "the variable is gone")
  H.eq(pcall(vim.api.nvim_get_autocmds, { group = "LeakGroup" }), false, "the autocmd group is gone")
  H.eq(vim.uv.cwd() ~= vim.uv.os_tmpdir(), true, "the working directory is not the temp dir")
end
]],
  })
  local code, out = run(args(soft_root, "--isolated", "none", "--guard", "state=off"))
  local err
  eq(
    code,
    1,
    "control: in one shared editor the second file fails on the first one's leaks\n" .. out
  )
  has(out, "FAIL  TESTS/b_spec.lua", "and it is the victim that fails")

  code, out, err = run(args(soft_root, "--isolated", "soft", "--guard", "state=off"))
  eq(code, 0, "soft: the polluted sequence is green\n" .. out .. err)
  has(out, "ok    TESTS/b_spec.lua", "the victim passes")
  has(err, "soft isolation: 1 of 2 file(s) changed state", "stderr counts the leaky files")
  has(err, "not restorable", "and what could not be restored")

  -- the guard layer names the leaks per case (and soft isolation stays quiet about what it restored)
  code, out, err = run(args(soft_root, "--isolated", "soft"))
  eq(code, 0, "soft + state guard (warn): still green\n" .. out .. err)
  has(out, "guard findings:", "the findings are listed")
  has(
    out,
    "leaves autocmd BufEnter in group LeakGroup",
    "the leaked autocmd is named, with its group"
  )
  has(out, "TESTS/a_spec.lua", "and the file that leaked it")
  has(out, "ok    TESTS/b_spec.lua", "the victim still passes")

  -- state = error: the polluter fails, the victim is untouched
  code, out = run(args(soft_root, "--isolated", "soft", "--guard", "state=error"))
  eq(code, 1, "soft + state=error: the leaking file is red\n" .. out)
  has(out, "FAIL  TESTS/a_spec.lua", "the polluter")
  has(out, "ok    TESTS/b_spec.lua", "not the victim")

  -- ================================================================== --isolated=case
  local case_root = project({
    ["TESTS/order_spec.lua"] = [[
describe("order", function()
  local state = 0
  it("first sets the state", function()
    state = state + 1
    rawset(_G, "iso_order_flag", true)
    assert.is_true(state == 1)
  end)
  it("second sees nothing of the first", function()
    assert.is_nil(rawget(_G, "iso_order_flag"))
  end)
  it("third has a fresh upvalue", function()
    assert.is_true(state == 0)
  end)
end)
]],
    ["TESTS/plain_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "plain")\nend\n',
  })
  local json = case_root .. "/out/ir.json"
  code, out = run(args(case_root, "--isolated", "file", "--guard", "state=off"))
  eq(code, 1, "control: isolated=file shares the state between the cases of a file\n" .. out)
  code, out, err =
    run(args(case_root, "--isolated", "case", "--guard", "state=off", "--json", json))
  eq(code, 0, "isolated=case: every case in its own editor, green\n" .. out .. err)
  has(err, "--isolated=case: 1 spec file(s) are not busted", "stderr says which files degraded")
  local f = assert(io.open(json, "rb"))
  local ir = vim.json.decode(f:read("*a"))
  f:close()
  local ids = {}
  for _, c in ipairs(ir.cases) do
    ids[#ids + 1] = c.id
  end
  eq(ids, {
    "TESTS/order_spec.lua::order::first sets the state",
    "TESTS/order_spec.lua::order::second sees nothing of the first",
    "TESTS/order_spec.lua::order::third has a fresh upvalue",
    "TESTS/plain_spec.lua::plain_spec.lua",
  }, "the IR holds one case per `it`, in source order, and the plain file once")
  has(
    table.concat(ir.cases[4].notes, "\n"),
    "isolated=case degraded to file",
    "the degraded file carries the note in the IR"
  )
  -- the same through `.testing.lua`
  S.write(case_root .. "/.testing.lua", 'return { isolated = "case" }\n')
  code, out = run(args(case_root, "--guard", "state=off"))
  eq(code, 0, "isolated = case in .testing.lua\n" .. out)
  code, out = run(args(case_root, "--guard", "state=off", "--isolated", "file"))
  eq(code, 1, "and the flag wins over the file\n" .. out)

  -- ================================================================== guards: red and green
  local dep_root = project({
    ["TESTS/old_spec.lua"] = 'return function(H)\n  vim.deprecate("vim.old_function()", "vim.new_function()", "0.13", "Nvim", false)\n  H.eq(1, 1, "uses an old API")\nend\n',
    ["TESTS/new_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "uses nothing deprecated")\nend\n',
  })
  local base = { "--guard", "state=off" }
  local function dep(...)
    local list = vim.list_extend(vim.deepcopy(base), { ... })
    return run(args(dep_root, unpack(list)))
  end
  code, out = dep()
  eq(code, 0, "default (warn): green\n" .. out)
  has(out, "guard findings: 1 warning(s), 0 failure(s)", "one warning")
  has(out, "[deprecation]", "from the deprecation guard")
  has(out, "uses a deprecated API", "saying what it is")
  has(out, "TESTS/old_spec.lua", "and the spec")
  code, out = dep("--guard", "deprecation=error")
  eq(code, 1, "deprecation=error: the spec that used it is red\n" .. out)
  has(out, "FAIL  TESTS/old_spec.lua", "that spec")
  has(out, "ok    TESTS/new_spec.lua", "and only that one (the green control)")
  code, out = dep("--guard", "deprecation=off")
  eq(code, 0, "deprecation=off: green\n" .. out)
  lacks(out, "guard findings", "and nothing is reported")
  code, out = dep("--strict")
  eq(code, 1, "--strict: a warning is a failure\n" .. out)

  -- the same switches from .testing.lua; an invalid value degrades with a warning
  S.write(
    dep_root .. "/.testing.lua",
    'return { guards = { deprecation = "error", state = "off" } }\n'
  )
  code, out = run(args(dep_root))
  eq(code, 1, ".testing.lua guards.deprecation = error\n" .. out)
  code, out = run(args(dep_root, "--guard", "deprecation=warn"))
  eq(code, 0, "a flag wins over the file\n" .. out)
  S.write(
    dep_root .. "/.testing.lua",
    'return { guards = { deprecation = "loud", state = "off" } }\n'
  )
  code, out, err = run(args(dep_root))
  eq(code, 0, "an invalid mode degrades to the default (warn)\n" .. out)
  has(err, "key 'guards.deprecation' is invalid", "and is reported")
  vim.fn.delete(dep_root .. "/.testing.lua")

  -- ================================================================== the reporters carry the finding
  local xml = dep_root .. "/out/r.xml"
  code, out = dep("--junit", xml, "--github")
  eq(code, 0, "green with a warning\n" .. out)
  local jf = assert(io.open(xml, "rb"))
  local jtext = jf:read("*a")
  jf:close()
  has(jtext, "<system-out>", "JUnit: the warning is the system-out of a green testcase")
  has(jtext, "vim.old_function() is deprecated", "with the finding")
  has(out, "::warning file=TESTS/old_spec.lua", "GitHub: a warning annotation on the spec")

  -- ================================================================== doctor shows the configuration
  code, out = run({
    "doctor",
    dep_root,
    "--guard",
    "fs=error",
    "--guard",
    "process-net=warn",
    "--allow-spawn",
    "git",
    "--pool-size",
    "3",
    "--no-trace",
  })
  eq(code, 0, "doctor\n" .. out)
  has(
    out,
    "guards: fs=error state=warn scheduled_error=error prompt=error deprecation=warn process_net=warn clock=false",
    "the guards, with the flags applied"
  )
  has(
    out,
    "guard_allow: fs=0 spawn=1 network=0; pool: size=3 reuse=false; determinism=true trace=false",
    "allow lists, pool and switches"
  )

  S.cleanup()
end
