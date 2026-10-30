-- TESTS/testing/ci_luarc_spec.lua -- the configuration the `luals` preset runs `lua-language-server --check` with
-- (`testing.ci.luarc`): the repository's `.luarc.json` (flat, nested, with comments) plus the library the editor
-- gives LuaLS ($VIMRUNTIME/lua, the ${3rd} meta libraries, lib.nvim and the project's deps, never the project), the
-- ignoreDir union, an own `workspace.library` kept as it is, forward slashes and valid JSON; and that a `luals` step
-- carries `--configpath=<file>` (a missing runtime or dependency is exit 3, never a smaller library).

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil

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

  local luarc = require("testing.ci.luarc")
  local deps = require("testing.deps")
  local presets = require("testing.ci.presets")
  local internal = require("testing.ci").internal

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-luarc"
  vim.fn.mkdir(tmp, "p")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- a runtime folder of its own, named with backslashes the way $VIMRUNTIME is on Windows
  local runtime = tmp .. "/runtime"
  vim.fn.mkdir(runtime .. "/lua", "p")
  local runtime_bs = runtime:gsub("/", "\\")

  ---A dependency resolver over fixed folders (name -> dir), as testing.deps.resolve answers.
  ---@param dirs table<string, string>
  local function resolver(dirs)
    return function(name)
      if dirs[name] then
        return { name = name, dir = dirs[name], source = "spec", locations = {} }
      end
      return nil, ("dependency %s was not found (spec)"):format(name)
    end
  end

  local lib_dir = tmp .. "/lib.nvim"
  local dep_dir = tmp .. "/mydep"

  -- without a library of its own: runtime, ${3rd}, lib.nvim and the deps; the repository's keys kept; ignoreDir union
  do
    local root = tmp .. "/plain"
    write(
      root .. "/.luarc.json",
      '{ "runtime.version": "LuaJIT", "workspace.ignoreDir": ["build", ".claude"], "diagnostics.globals": ["x"] }'
    )
    local built, problems, infra = luarc.build(root, {
      deps = { "mydep" },
      vimruntime = runtime_bs,
      resolve = resolver({ ["lib.nvim"] = lib_dir, mydep = dep_dir }),
      self_dir = tmp .. "/runner",
    })
    eq(problems, {}, "plain: no problem")
    eq(infra, false, "plain: not infra")
    eq(built.own_library, false, "plain: the library is built")
    eq(built.config["workspace.library"], {
      runtime .. "/lua",
      "${3rd}/luv/library",
      "${3rd}/busted/library",
      "${3rd}/luassert/library",
      lib_dir .. "/lua",
      dep_dir .. "/lua",
    }, "plain: runtime, ${3rd}, lib.nvim, the deps (forward slashes)")
    eq(
      built.config["workspace.ignoreDir"],
      { "build", ".claude", ".deps", ".git" },
      "plain: ignoreDir is the union, the repository's entries first"
    )
    eq(built.config["runtime.version"], "LuaJIT", "plain: the repository's keys stay")
    eq(built.config["diagnostics.globals"], { "x" }, "plain: ... all of them")
    eq(built.source, ".luarc.json", "plain: the file it read")
    local text = luarc.encode(built.config)
    eq(text:find("\\", 1, true), nil, "plain: no backslash in the file")
    local okd, back = pcall(vim.json.decode, text)
    ok(okd, "plain: the file is valid JSON (" .. tostring(back) .. ")")
    eq(back, built.config, "plain: ... and decodes to the configuration")
    has(built.note, "mydep", "plain: the note names the dependencies")
  end

  -- the project itself is never part of the library (LLS-02), also when a dependency resolves to it
  do
    local root = tmp .. "/self"
    vim.fn.mkdir(root, "p")
    local built = luarc.build(root, {
      deps = { "selfdep" },
      vimruntime = runtime,
      resolve = resolver({ ["lib.nvim"] = root, selfdep = root }),
      self_dir = tmp .. "/runner",
    })
    eq(built.config["workspace.library"], {
      runtime .. "/lua",
      "${3rd}/luv/library",
      "${3rd}/busted/library",
      "${3rd}/luassert/library",
    }, "self: the project's own lua/ is not in the library")
  end

  -- another checkout of the project (a worktree of lib.nvim checked with $LIB_NVIM_DIR on the main one): it declares
  -- the project's namespace, so it is the project, left out and said so; a dependency of its own namespace stays
  do
    local root = tmp .. "/wt"
    write(root .. "/lua/proj/init.lua", "return {}\n")
    local main = tmp .. "/main-checkout"
    write(main .. "/lua/proj/init.lua", "return {}\n")
    local other = tmp .. "/otherdep"
    write(other .. "/lua/otherdep/init.lua", "return {}\n")
    local built = luarc.build(root, {
      deps = { "proj", "otherdep" },
      vimruntime = runtime,
      resolve = resolver({ ["lib.nvim"] = lib_dir, proj = main, otherdep = other }),
      self_dir = tmp .. "/runner",
    })
    eq(built.config["workspace.library"], {
      runtime .. "/lua",
      "${3rd}/luv/library",
      "${3rd}/busted/library",
      "${3rd}/luassert/library",
      lib_dir .. "/lua",
      other .. "/lua",
    }, "another checkout: not in the library, a different project is")
    has(
      built.note,
      "proj is this project (another checkout: lua/proj), left out",
      "another checkout: the note says so"
    )
  end

  -- a library of its own (nested, with comments and a trailing comma: .luarc.jsonc): kept as it is, and said so
  do
    local root = tmp .. "/own"
    write(
      root .. "/.luarc.jsonc",
      table.concat({
        "{",
        "  // the repository's own library",
        '  "workspace": { "library": ["/x/lua"], "ignoreDir": [".deps"], },',
        '  /* a block comment with a "string" */',
        '  "runtime": { "version": "LuaJIT" },',
        '  "hint": "a // in a string stays",',
        "}",
      }, "\n")
    )
    local built, problems = luarc.build(root, {
      vimruntime = runtime,
      resolve = resolver({ ["lib.nvim"] = lib_dir }),
      self_dir = tmp .. "/runner",
    })
    eq(problems, {}, "own: no problem")
    eq(built.own_library, true, "own: the repository's library")
    eq(built.config.workspace.library, { "/x/lua" }, "own: kept where it is, unchanged")
    eq(built.config["workspace.library"], nil, "own: no second library")
    eq(built.library, { "/x/lua" }, "own: the library the check sees")
    eq(built.config.workspace.ignoreDir, nil, "own: the nested ignoreDir is moved ...")
    eq(
      built.config["workspace.ignoreDir"],
      { ".deps", ".claude", ".git" },
      "own: ... into the union"
    )
    eq(built.config.runtime, { version = "LuaJIT" }, "own: the other nested keys stay")
    eq(built.config.hint, "a // in a string stays", "own: a comment marker in a string stays")
    has(built.note, "LLS-01", "own: the note says the measurement is the repository's")
    has(built.note, ".luarc.jsonc", "own: ... and names the file")
    -- the flat form, with the `Lua.` prefix
    write(root .. "/.luarc.json", '{ "Lua.workspace.library": ["/y/lua"] }')
    local flat = luarc.build(root, { vimruntime = runtime, resolve = resolver({}) })
    eq(flat.own_library, true, "own: the flat Lua.-prefixed key counts")
    eq(flat.library, { "/y/lua" }, "own: ... and is kept")
  end

  -- no .luarc.json at all: the library alone
  do
    local root = tmp .. "/none"
    vim.fn.mkdir(root, "p")
    local built = luarc.build(root, {
      vimruntime = runtime,
      resolve = resolver({ ["lib.nvim"] = lib_dir }),
      self_dir = tmp .. "/runner",
    })
    eq(built.source, nil, "none: no file")
    eq(built.config["workspace.ignoreDir"], { ".claude", ".deps", ".git" }, "none: ignoreDir")
    eq(#built.config["workspace.library"], 5, "none: runtime, ${3rd}, lib.nvim")
  end

  -- what cannot be had is reported, never a smaller library
  do
    local root = tmp .. "/none"
    local built, problems, infra = luarc.build(root, {
      vimruntime = "",
      resolve = resolver({ ["lib.nvim"] = lib_dir }),
      self_dir = tmp .. "/runner",
    })
    eq(built, nil, "no runtime: nothing is built")
    has(problems[1], "$VIMRUNTIME", "no runtime: said so")
    eq(infra, true, "no runtime: a problem of the machine")
    built, problems, infra = luarc.build(root, {
      deps = { "gone" },
      vimruntime = runtime,
      resolve = resolver({ ["lib.nvim"] = lib_dir }),
      self_dir = tmp .. "/runner",
    })
    eq(built, nil, "missing dependency: nothing is built")
    has(problems[1], "gone", "missing dependency: named")
    eq(infra, true, "missing dependency: a problem of the machine")
    write(tmp .. "/broken/.luarc.json", "{ not json")
    built, problems, infra = luarc.build(tmp .. "/broken", { vimruntime = runtime })
    eq(built, nil, "broken .luarc.json: nothing is built")
    has(problems[1], ".luarc.json is not valid JSON", "broken .luarc.json: said so")
    eq(infra, false, "broken .luarc.json: a configuration error")
  end

  -- a `luals` step carries --configpath=<the merged file>, written when it starts; deps of the pipeline, a sibling
  do
    local root = tmp .. "/proj"
    write(root .. "/lua/proj/init.lua", "return {}\n")
    write(root .. "/.luarc.json", '{ "workspace.ignoreDir": ["vendor"] }')
    -- a checkout beside the project (place 3 of testing.deps)
    write(tmp .. "/sibdep/lua/sibdep/init.lua", "return {}\n")
    local step = presets.step("luals", presets.get("luals"), { timeout_ms = 60000 })
    -- an executable that exists everywhere stands in for the tool (only the plan is looked at)
    step.argv[1] = vim.v.progpath
    local state_dir = tmp .. "/state"
    local pipeline = { steps = { luals = step }, deps = { "sibdep" } }
    local planned, code, problems = internal.plan(
      pipeline,
      { "luals" },
      root,
      { state_dir = state_dir }
    )
    eq(problems, {}, "plan: no problem")
    eq(code, nil, "plan: no exit code")
    local p = planned[1]
    local path = luarc.path(root, state_dir)
    eq(p.argv[#p.argv], "--configpath=" .. path, "plan: the argv carries --configpath")
    eq(path:find("\\", 1, true), nil, "plan: the path has forward slashes")
    has(table.concat(p.notes or {}, "\n"), "sibdep", "plan: the step output names the library")
    local config = vim.json.decode(p.write.text)
    local lib = deps.resolve("lib.nvim", deps.self_dir())
    local library = config["workspace.library"]
    eq(
      library[1],
      vim.fs.normalize(vim.env.VIMRUNTIME) .. "/lua",
      "plan: the runtime of this Neovim"
    )
    eq(library[5], vim.fs.normalize(lib.dir) .. "/lua", "plan: lib.nvim as the runner finds it")
    eq(library[6], tmp .. "/sibdep/lua", "plan: the project's dependency")
    eq(#library, 6, "plan: nothing else (not the project)")
    eq(config["workspace.ignoreDir"], { "vendor", ".claude", ".deps", ".git" }, "plan: ignoreDir")
    eq(vim.uv.fs_stat(path), nil, "plan: nothing is written before the step starts")

    -- the file is written when the step starts
    p.argv = { vim.v.progpath, "--headless", "--clean", "-l", tmp .. "/noop.lua" }
    write(tmp .. "/noop.lua", "")
    local r = internal.run_process(p, root, { out = function() end, err = function() end })
    eq(r.state, "green", "run: the stand-in ran (" .. table.concat(r.errors, "\n") .. ")")
    local f = io.open(path, "rb")
    ok(f ~= nil, "run: the configuration was written")
    if f then
      eq(vim.json.decode(f:read("*a")), config, "run: ... with the planned content")
      f:close()
    end

    -- a step that names its own --configpath keeps it
    local own = presets.step("luals", presets.get("luals"), {
      timeout_ms = 60000,
      args = { "--check=.", "--configpath=mine.json" },
    })
    own.argv[1] = vim.v.progpath
    local planned_own = internal.plan({ steps = { luals = own }, deps = {} }, { "luals" }, root)
    local own_argv = planned_own[1].argv
    eq(own_argv[#own_argv], "--configpath=mine.json", "own configpath: kept, nothing appended")
    eq(planned_own[1].write, nil, "own configpath: nothing written")

    -- a dependency that cannot be found is exit 3
    local missing, missing_code, missing_problems = internal.plan(
      { steps = { luals = step }, deps = { "no-such-dep-xyz" } },
      { "luals" },
      root,
      { state_dir = state_dir }
    )
    eq(missing, nil, "missing dep: not planned")
    eq(missing_code, 3, "missing dep: exit 3")
    has(table.concat(missing_problems, "\n"), "no-such-dep-xyz", "missing dep: named")

    -- a batch shim (Mason's lua-language-server.cmd) runs through cmd.exe: the --configpath argument is checked for
    -- the characters cmd.exe interprets like every other argument
    write(root .. "/bin/lua-language-server.cmd", "@echo off\n")
    local shim = presets.step("luals", presets.get("luals"), { timeout_ms = 60000 })
    shim.argv[1] = root .. "/bin/lua-language-server.cmd"
    local bad_state = tmp .. "/state 100%"
    local refused, refused_code, refused_problems = internal.plan(
      { steps = { luals = shim }, deps = {} },
      { "luals" },
      root,
      { state_dir = bad_state }
    )
    eq(refused, nil, "batch shim: a --configpath with % is refused")
    eq(refused_code, 2, "batch shim: exit 2")
    has(
      table.concat(refused_problems or {}, "\n"),
      "--configpath=",
      "batch shim: the argument named"
    )
  end

  vim.fn.delete(tmp, "rf")
end
