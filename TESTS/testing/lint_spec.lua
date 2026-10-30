-- TESTS/testing/lint_spec.lua -- `testing lint`: the lint checks of the pipeline (presets with a `lint` descriptor) on
-- the changed files, named files or everything; each preset (stylua, luacheck, luals) red on a real finding and green
-- without one, --file / --changed check only those files, --fix rewrites (stylua) and says what it changed, a missing
-- tool is a reported skip and exit 3 (never green, never hidden by a red check), usage errors exit 2, and the output
-- normalisation of the matcher (colours, carriage-return progress, Windows paths, blanks in a path).
--
-- The logic (scope, --fix, the filter of a workspace check, the options of a step's args, .styluaignore) is proven
-- with stub tools (`stylua`, `luacheck`, `lua-language-server` on PATH: a Lua script that prints findings in each
-- preset's format), so it runs on every machine, also on a CI runner without the linters. The real tools are tested
-- on top when they are installed; when one is not, its block says so in the output (never a silent skip).

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
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local lint = require("testing.lint")
  local report = require("testing.ci.report")
  local cli = require("testing.cli")

  -- --------------------------------------------------------- normalisation

  do
    local esc = "\27"
    -- LuaLS: progress text, carriage returns, colours and a Windows path on one physical line
    local raw = "Initializing ...\r          \r"
      .. esc
      .. "[34mlua\\a.lua:2:28"
      .. esc
      .. "[0m ["
      .. esc
      .. "[33mWarning"
      .. esc
      .. "[0m] Undefined global `x`. "
      .. esc
      .. "[35m(undefined-global)"
      .. esc
      .. "[0m\r"
    eq(
      report.normalize_line(raw),
      "lua\\a.lua:2:28 [Warning] Undefined global `x`. (undefined-global)",
      "normalize: colours and progress are gone"
    )
    eq(report.normalize_line("plain: line"), "plain: line", "normalize: a plain line is unchanged")
    eq(
      report.normalize_line("\r>>>>==== 1/2 [Found 1 problems]\r"),
      ">>>>==== 1/2 [Found 1 problems]",
      "normalize: a progress line keeps its text (no finding)"
    )
    local list, total = report.findings("%f:%l:%c %m", { raw })
    eq(total, 1, "normalize: the finding after the progress text is found")
    eq(list[1].file, "lua/a.lua", "normalize: the file with forward slashes")
    eq(list[1].line, 2, "normalize: line")
    eq(list[1].col, 28, "normalize: column")
    eq(list[1].text, "[Warning] Undefined global `x`. (undefined-global)", "normalize: message")
    local spaced = report.findings("%F:%l:%c %m", { "lua\\my dir\\sp.lua:1:8 [Warning] x" })
    eq(spaced[1] and spaced[1].file, "lua/my dir/sp.lua", "normalize: %F takes a path with blanks")
    eq(
      report.findings("%F:%l:%c %m", { " lead:1:2 x" }),
      {},
      "normalize: %F does not start with a blank"
    )
    local styl = report.findings("Diff in %f:", { "Diff in .\\lua\\b.lua:" })
    eq(styl[1].file, "lua/b.lua", "normalize: `.\\` is dropped from a file")
    local n = 0
    local m = report.matcher("%f:%l:%c: %m", function(f)
      n = n + 1
      return f.file == "lua/a.lua"
    end)
    m.feed("lua/a.lua:1:1: one")
    m.feed("lua/b.lua:1:1: two")
    eq(#m.list, 1, "matcher: keep drops the other files' findings")
    eq(m.total(), 1, "matcher: ... and does not count them")
    eq(n, 2, "matcher: keep was asked for each finding")
  end

  -- ------------------------------------------------------------------ args

  do
    local a = lint.parse({ "luacheck", "stylua", "--file", "a.lua,b.lua", "--fix", "--json" })
    eq(a.checks, { "luacheck", "stylua" }, "args: checks are the positionals")
    eq(a.scope, "file", "args: --file is the scope")
    eq(a.files, { "a.lua,b.lua" }, "args: --file values are kept as given (split later)")
    eq(
      lint.parse({ "--file=a.lua", "--file", "b.lua" }).files,
      { "a.lua", "b.lua" },
      "args: --file is repeatable"
    )
    eq(a.fix, true, "args: --fix")
    eq(a.json, true, "args: --json")
    eq(lint.parse({}).scope, "changed", "args: --changed is the default")
    local none, why = lint.parse({ "--file=a.lua", "--all" })
    eq(none, nil, "args: --file and --all exclude each other")
    has(why, "exclude each other", "args: ... said so")
    none = lint.parse({ "--changed", "--all" })
    eq(none, nil, "args: --changed and --all exclude each other")
    none = lint.parse({ "--frobnicate" })
    eq(none, nil, "args: an unknown option")
    none, why = lint.parse({ "--file" })
    eq(none, nil, "args: --file without a value")
    has(why, "--file needs a value", "args: ... said so")
  end

  -- ------------------------------------------------------------- projects

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-lint"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end

  -- formatted the way stylua formats with its defaults, and nothing luacheck or LuaLS reports
  local CLEAN = "local M = {}\nM.value = 1\nreturn M\n"
  local UNFORMATTED = "local  M = {}\nreturn M\n"
  local UNUSED = "local unused = 1\nreturn {}\n"
  local UNDEFINED = "local M = {}\nM.value = undefined_thing\nreturn M\n"

  ---A Lua project with stylua.toml and .luacheckrc (stylua and luacheck are derived), committed.
  ---@param name string
  ---@param files table<string, string>
  ---@param ci_lua? string The `ci` section (Lua text); nil: derived.
  ---@return string root
  local function project(name, files, ci_lua)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/mod.lua", CLEAN)
    write(root .. "/stylua.toml", "")
    write(root .. "/.luacheckrc", "")
    write(
      root .. "/.testing.lua",
      ('return { plugin = "proj", minit = false%s }\n'):format(
        ci_lua and (", ci = " .. ci_lua) or ""
      )
    )
    for rel, text in pairs(files) do
      write(root .. "/" .. rel, text)
    end
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  ---@return { code: integer, out: string, err: string, doc?: table }
  local function run(root, ...)
    local out, err = {}, {}
    local argv = { "lint", "--root=" .. root }
    vim.list_extend(argv, { ... })
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      env = {},
      color = false,
    })
    local text = table.concat(out, "\n")
    local doc
    if vim.tbl_contains({ ... }, "--json") then
      local okd, decoded = pcall(vim.json.decode, text)
      doc = okd and decoded or nil
    end
    return { code = code, out = text, err = table.concat(err, "\n"), doc = doc }
  end
  ---@param doc table
  ---@param name string
  ---@return table|nil
  local function check_of(doc, name)
    for _, c in ipairs(doc and doc.checks or {}) do
      if c.name == name then
        return c
      end
    end
    return nil
  end
  ---@param c table|nil
  ---@return string[]
  local function finding_files(c)
    local out = {}
    for _, f in ipairs(c and c.findings or {}) do
      if not vim.tbl_contains(out, f.file) then
        out[#out + 1] = f.file
      end
    end
    table.sort(out)
    return out
  end

  -- usage errors: exit 2
  do
    local root =
      project("usage", {}, '{ profiles = { full = { "s" } }, steps = { s = { run = { "x" } } } }')
    local res = run(root, "nope")
    eq(res.code, 2, "usage: an unknown check")
    has(res.err, "unknown check nope", "usage: ... named")
    has(res.err, "luals", "usage: ... with the lint checks there are")
    res = run(root, "s")
    eq(res.code, 2, "usage: a step that is no lint check")
    has(res.err, "no lint check", "usage: ... said so")
    res = run(root, "luacheck", "--file=../outside.lua")
    eq(res.code, 2, "usage: a file outside the root")
    has(res.err, "does not lie below the root", "usage: ... said so")
    res = run(root, "luacheck", "--file=lua/proj/none.lua")
    eq(res.code, 2, "usage: a file that does not exist")
    res = run(root, "--all", "--changed")
    eq(res.code, 2, "usage: two scopes")
    res = run(root, "--json", "--frobnicate")
    eq(res.code, 2, "usage: an unknown option")
    eq(run(tmp .. "/not-there", "--all").code, 2, "usage: a root that is no directory")
    -- the default set of a pipeline without a lint step: nothing to run, said so
    res = run(root, "--all")
    eq(res.code, 0, "no lint step: exit 0")
    has(res.out, "no lint check", "no lint step: said so")
  end

  -- a missing tool: a reported skip of that check, exit 3, the other checks still run; a red check does not hide it
  do
    local root = project(
      "missing",
      { ["lua/proj/bad.lua"] = UNFORMATTED },
      '{ profiles = { full = { "luacheck", "stylua" } }, steps = { luacheck = { preset = "luacheck", needs = { "does-not-exist-linter" } } } }'
    )
    local res = run(root, "--all", "--json")
    eq(res.code, 3, "missing: exit 3 (" .. res.err .. ")")
    local c = check_of(res.doc, "luacheck")
    eq(c and c.state, "skipped", "missing: the check is skipped")
    eq(c and c.missing, true, "missing: ... because a tool is missing")
    has(c and c.reason, "does-not-exist-linter", "missing: the reason names the tool")
    has(c and c.reason, "searched", "missing: ... and where it was searched")
    eq(res.doc.verdict, "infra", "missing: the verdict is infra, never green")
    local s = check_of(res.doc, "stylua")
    if vim.fn.executable("stylua") == 1 then
      eq(s and s.state, "red", "missing: the other check still ran (red)")
    end
    local agent = run(root, "--all", "--agent")
    eq(agent.code, 3, "missing: agent exit 3")
    has(vim.split(agent.out, "\n")[1], "lint INFRA luacheck", "missing: the agent's verdict line")
    has(agent.out, "does-not-exist-linter", "missing: the agent report says why")
  end

  -- --on-save: the default set leaves out what is too expensive on save (luals)
  do
    local root = project(
      "on-save",
      {},
      '{ profiles = { full = { "luals", "stylua" } }, steps = { stylua = { preset = "stylua", needs = { "does-not-exist-linter" } }, luals = { preset = "luals", needs = { "does-not-exist-linter" } } } }'
    )
    local all = run(root, "--all", "--json")
    eq(#all.doc.checks, 2, "on-save: without it, both checks")
    local saved = run(root, "--all", "--json", "--on-save")
    eq(#saved.doc.checks, 1, "on-save: one check")
    eq(saved.doc.checks[1].name, "stylua", "on-save: luals is left out")
    -- `testing ci list` names the lint steps (what `:Testing lint` completes)
    local list = require("testing.ci.list").load(root)
    eq(list and list.lint, { "luals", "stylua" }, "ci list: the lint steps of the pipeline")
  end

  -- ------------------------------------------------------------ stub tools

  -- what the three linters print, for the files they get: enough to prove what `testing lint` does with them
  local STUB = [==[
local tool = _G.arg[1]
local args = {}
for i = 2, #_G.arg do
  args[#args + 1] = _G.arg[i]
end
local function read(p)
  local f = io.open(p, "rb")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end
local log = os.getenv("LINT_STUB_LOG")
if log then
  local f = io.open(log, "ab")
  f:write(tool .. " " .. table.concat(args, " ") .. "\n")
  f:close()
end
local function lua_files(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return {}
  end
  if st.type == "file" then
    return { path }
  end
  local out = {}
  for name, kind in vim.fs.dir(path, { depth = 20 }) do
    if kind == "file" and name:match("%.lua$") then
      out[#out + 1] = (path == "." and "./" or (path .. "/")) .. name
    end
  end
  table.sort(out)
  return out
end
local code = 0
local function emit(s)
  io.stdout:write(s, "\n")
end
if tool == "luacheck" then
  local valued = { ["--formatter"] = true, ["--config"] = true, ["--std"] = true }
  local paths, i = {}, 1
  while i <= #args do
    local a = args[i]
    if valued[a] then
      i = i + 1
    elseif a:sub(1, 1) ~= "-" then
      paths[#paths + 1] = a
    end
    i = i + 1
  end
  for _, p in ipairs(paths) do
    for _, f in ipairs(lua_files(p)) do
      if (read(f) or ""):find("unused", 1, true) then
        emit(f .. ":1:7: (W211) unused variable 'unused'")
        code = 1
      end
    end
  end
elseif tool == "stylua" then
  local check, respect, paths, i = false, false, {}, 1
  while i <= #args do
    local a = args[i]
    if a == "--check" then
      check = true
    elseif a == "--respect-ignores" then
      respect = true
    elseif a == "--config-path" then
      i = i + 1
    elseif a:sub(1, 1) ~= "-" then
      paths[#paths + 1] = a
    end
    i = i + 1
  end
  local ignored = {}
  for line in (read(".styluaignore") or ""):gmatch("[^\r\n]+") do
    ignored[#ignored + 1] = line
  end
  for _, p in ipairs(paths) do
    local st = vim.uv.fs_stat(p)
    local named = st and st.type == "file"
    for _, f in ipairs(lua_files(p)) do
      local rel = f:gsub("^%./", "")
      local skip = false
      -- like stylua: a named file is formatted even when it is ignored, unless --respect-ignores
      if respect or not named then
        for _, ig in ipairs(ignored) do
          skip = skip or rel:sub(1, #ig) == ig
        end
      end
      local text = read(f) or ""
      if not skip and text:find("SYNTAX ERROR", 1, true) then
        -- a file stylua cannot parse: an error without a `Diff in` line, nothing is written
        emit("error: could not format " .. f)
        code = 1
      elseif not skip and text:find("  ", 1, true) then
        if check then
          emit("Diff in " .. f .. ":")
          code = 1
        else
          local fh = io.open(f, "wb")
          fh:write((text:gsub("  +", " ")))
          fh:close()
        end
      end
    end
  end
elseif tool == "lua-language-server" then
  local dir = "."
  for _, a in ipairs(args) do
    dir = a:match("^%-%-check=(.*)$") or dir
  end
  if read("CRASH") then
    emit("Failed to load the configuration")
    os.exit(1)
  end
  io.stdout:write("Initializing ...\r          \r")
  for _, f in ipairs(lua_files(dir)) do
    if (read(f) or ""):find("undefined_thing", 1, true) then
      local shown = f:gsub("^%./", ""):gsub("/", "\\")
      emit("\27[34m" .. shown .. ":1:8\27[0m [\27[33mWarning\27[0m] Undefined global `undefined_thing`.")
      code = 1
    end
  end
end
os.exit(code)
]==]

  local is_windows = require("testing.platform").is_windows()
  local stub_dir = tmp .. "/stub-bin"
  local stub_log = tmp .. "/stub.log"
  write(stub_dir .. "/stub.lua", STUB)
  for _, name in ipairs({ "stylua", "luacheck", "lua-language-server" }) do
    if is_windows then
      write(
        stub_dir .. "/" .. name .. ".cmd",
        ('@"%s" -n -i NONE --headless -u NONE -l "%s" %s %%*\r\n'):format(
          vim.v.progpath,
          stub_dir .. "/stub.lua",
          name
        )
      )
    else
      write(
        stub_dir .. "/" .. name,
        ('#!/bin/sh\nexec "%s" -n -i NONE --headless -u NONE -l "%s" %s "$@"\n'):format(
          vim.v.progpath,
          stub_dir .. "/stub.lua",
          name
        )
      )
      vim.uv.fs_chmod(stub_dir .. "/" .. name, 493)
    end
  end
  ---The last command line a stub tool got.
  local function last_call()
    local text = io.open(stub_log, "rb") and read(stub_log) or ""
    local lines = vim.split(text, "\n", { trimempty = true })
    return lines[#lines] or ""
  end

  ---Run `fn` with the stub tools first on PATH (and the executable cache of lib.nvim dropped before and after).
  local function with_stubs(fn)
    local executable = require("lib.nvim.cross.executable")
    local path_before, log_before = vim.env.PATH, vim.env.LINT_STUB_LOG
    vim.env.PATH = stub_dir .. (is_windows and ";" or ":") .. path_before
    vim.env.LINT_STUB_LOG = stub_log
    executable.clear()
    local fine, e = pcall(fn)
    vim.env.PATH, vim.env.LINT_STUB_LOG = path_before, log_before
    executable.clear()
    if not fine then
      error(e, 0)
    end
  end

  with_stubs(function()
    -- --changed (default) and --file: only those files. bad.lua is committed; new.lua is untracked, mod.lua is
    -- changed, ign.lua is ignored
    local scoped = project("scoped", {
      ["lua/proj/bad.lua"] = UNUSED,
      [".gitignore"] = "lua/proj/ign.lua\n",
    })
    local nothing = run(scoped, "luacheck", "--no-agent")
    eq(nothing.code, 0, "changed: a clean tree is green")
    has(nothing.out, "nothing changed", "changed: ... and says so")
    write(scoped .. "/lua/proj/new.lua", UNUSED)
    write(scoped .. "/lua/proj/ign.lua", UNUSED)
    write(scoped .. "/lua/proj/mod.lua", UNUSED)
    local changed = run(scoped, "luacheck", "--json")
    eq(changed.code, 1, "changed: red (" .. changed.err .. ")")
    eq(
      finding_files(check_of(changed.doc, "luacheck")),
      { "lua/proj/mod.lua", "lua/proj/new.lua" },
      "changed: the changed and the untracked file, not the committed or the ignored one"
    )
    eq(
      changed.doc.scope.files,
      { "lua/proj/mod.lua", "lua/proj/new.lua" },
      "changed: the scope of the document"
    )
    eq(
      last_call(),
      "luacheck --formatter plain --codes lua/proj/mod.lua lua/proj/new.lua",
      "changed: the files replace the paths of the args"
    )
    local named = run(scoped, "luacheck", "--json", "--file=" .. scoped .. "/lua/proj/bad.lua")
    eq(
      finding_files(check_of(named.doc, "luacheck")),
      { "lua/proj/bad.lua" },
      "file: only the named file (absolute below the root)"
    )
    eq(check_of(named.doc, "luacheck").files, { "lua/proj/bad.lua" }, "file: checked files")
    local other = run(scoped, "luacheck", "--file=.gitignore", "--no-agent")
    eq(other.code, 0, "file: a file no check reads is nothing to check")
    has(other.out, "nothing to check", "file: ... said so")
    -- a file with a comma in its name, and --file repeated
    write(scoped .. "/lua/proj/a,b.lua", UNUSED)
    local comma = run(scoped, "luacheck", "--json", "--file=lua/proj/a,b.lua")
    eq(
      finding_files(check_of(comma.doc, "luacheck")),
      { "lua/proj/a,b.lua" },
      "file: a file with a comma in its name is one file"
    )
    local twice =
      run(scoped, "luacheck", "--json", "--file=lua/proj/a,b.lua", "--file=lua/proj/bad.lua")
    eq(
      finding_files(check_of(twice.doc, "luacheck")),
      { "lua/proj/a,b.lua", "lua/proj/bad.lua" },
      "file: --file repeated"
    )
    local list = run(scoped, "luacheck", "--json", "--file=lua/proj/bad.lua,lua/proj/new.lua")
    eq(
      finding_files(check_of(list.doc, "luacheck")),
      { "lua/proj/bad.lua", "lua/proj/new.lua" },
      "file: a value that names no file is split on commas"
    )

    -- the step's args: its options stay, its paths limit the scope (never more than `testing ci` checks)
    local opts = project(
      "step-args",
      {},
      '{ profiles = { full = { "luacheck" } }, steps = { luacheck = { preset = "luacheck", args = { "--std", "luajit", "lua" } } } }'
    )
    write(opts .. "/scripts/tool.lua", UNUSED)
    write(opts .. "/lua/proj/new.lua", UNUSED)
    local limited = run(opts, "luacheck", "--json")
    eq(limited.code, 1, "step args: red (" .. limited.err .. ")")
    local lc = check_of(limited.doc, "luacheck")
    eq(finding_files(lc), { "lua/proj/new.lua" }, "step args: only the files below its paths")
    eq(lc.not_checked, { "scripts/tool.lua" }, "step args: the others are not checked")
    eq(
      last_call(),
      "luacheck --formatter plain --codes --std luajit lua/proj/new.lua",
      "step args: its options stay"
    )
    has(
      run(opts, "luacheck", "--no-agent").out,
      "not checked by luacheck (outside its args): scripts/tool.lua",
      "step args: the terminal report says so"
    )
    local outside = run(opts, "luacheck", "--file=scripts/tool.lua", "--json")
    eq(outside.code, 0, "step args: a file outside its paths is nothing to check")
    eq(lint.within({ "." }, "x/y.lua"), true, "within: . is everything")
    eq(lint.within({ "lua" }, "lua/y.lua"), true, "within: below a folder")
    eq(lint.within({ "lua" }, "luax/y.lua"), false, "within: not a folder of the same prefix")
    eq(lint.within({ "lua/a.lua" }, "lua/a.lua"), true, "within: a file matches itself")
    eq(lint.within({ "lua/a.lua" }, "lua/a.lua.bak"), false, "within: ... and nothing else")

    -- stylua: .styluaignore applies to named files (check and fix); --fix rewrites and names what it changed
    local ignore = project("stylua-ignore", { [".styluaignore"] = "vendor/\n" })
    write(ignore .. "/vendor/ext.lua", UNFORMATTED)
    write(ignore .. "/lua/proj/new.lua", UNFORMATTED)
    local st = run(ignore, "stylua", "--json")
    eq(st.code, 1, "stylua: red (" .. st.err .. ")")
    eq(
      finding_files(check_of(st.doc, "stylua")),
      { "lua/proj/new.lua" },
      "stylua: an ignored file is no finding"
    )
    has(last_call(), "--respect-ignores", "stylua: named files respect the ignore file")
    local fix = run(ignore, "stylua", "--fix", "--json")
    eq(fix.code, 0, "stylua --fix: green after the fix (" .. fix.err .. ")")
    eq(check_of(fix.doc, "stylua").fixed, { "lua/proj/new.lua" }, "stylua --fix: names the file")
    eq(read(ignore .. "/lua/proj/new.lua"), "local M = {}\nreturn M\n", "stylua --fix: rewrote it")
    eq(read(ignore .. "/vendor/ext.lua"), UNFORMATTED, "stylua --fix: an ignored file is untouched")
    -- a check that is red without a finding fixes the whole scope: the ignore file still applies to the fix
    write(ignore .. "/lua/proj/broken.lua", "SYNTAX ERROR\n")
    run(ignore, "stylua", "--fix", "--file=vendor/ext.lua", "--file=lua/proj/broken.lua")
    has(
      last_call(),
      "--respect-ignores",
      "stylua --fix: the fix of named files respects the ignore file"
    )
    eq(read(ignore .. "/vendor/ext.lua"), UNFORMATTED, "stylua --fix: ... and leaves it alone")
    os.remove(ignore .. "/lua/proj/broken.lua")
    write(ignore .. "/lua/proj/new.lua", UNFORMATTED)
    local fix_all = run(ignore, "stylua", "--fix", "--all", "--no-agent")
    eq(fix_all.code, 0, "stylua --fix --all: green")
    has(fix_all.out, "fixed: lua/proj/new.lua", "stylua --fix --all: the terminal report names it")
    local nofix = run(ignore, "luacheck", "--fix", "--all", "--no-agent")
    has(nofix.out, "luacheck: no --fix", "luacheck --fix: said so")

    -- luals: the whole workspace, only the findings in scope count; a path with blanks; a crash is never green
    local ls = project("luals-stub", {
      ["lua/proj/bad.lua"] = UNDEFINED,
      ["lua/my dir/sp.lua"] = UNDEFINED,
    })
    local all = run(ls, "luals", "--all", "--json")
    eq(all.code, 1, "luals: red (" .. all.err .. ")")
    eq(
      finding_files(check_of(all.doc, "luals")),
      { "lua/my dir/sp.lua", "lua/proj/bad.lua" },
      "luals: every finding, also in a path with blanks"
    )
    local in_scope = run(ls, "luals", "--file=lua/proj/mod.lua", "--json")
    eq(in_scope.code, 0, "luals: no finding in scope is green (the others are elsewhere)")
    local spaced = run(ls, "luals", "--file=lua/my dir/sp.lua", "--json")
    eq(spaced.code, 1, "luals: the file with blanks is red")
    eq(finding_files(check_of(spaced.doc, "luals")), { "lua/my dir/sp.lua" }, "luals: ... only it")
    write(ls .. "/CRASH", "")
    local crash = run(ls, "luals", "--file=lua/proj/mod.lua", "--json")
    eq(crash.code, 1, "luals: exit 1 without a single finding is red, not green")
    has(
      table.concat(check_of(crash.doc, "luals").errors, "\n"),
      "Failed to load",
      "luals: ... with its last lines"
    )

    -- a project without a pipeline: a named preset runs with its defaults
    local bare = tmp .. "/bare"
    write(bare .. "/x.lua", UNUSED)
    local b = run(bare, "luacheck", "--file=x.lua", "--json")
    eq(b.code, 1, "no pipeline: a named preset runs with its defaults (" .. b.err .. ")")
  end)

  -- a .testing.lua that cannot be used is an error, never a fallback to the preset's defaults
  do
    local broken = tmp .. "/broken"
    write(broken .. "/lua/proj/mod.lua", CLEAN)
    write(broken .. "/.testing.lua", "return {\n")
    local res = run(broken, "luacheck", "--all")
    eq(res.code, 2, "broken config: exit 2")
    has(res.err, ".testing.lua", "broken config: the loader's problem")
    local _, _, why = require("testing.ci.schema").load(broken)
    eq(why, nil, "broken config: not a project without a pipeline")
    local _, _, bare_why = require("testing.ci.schema").load(tmp .. "/bare")
    eq(bare_why, "absent", "no pipeline: absent")
  end

  ---Say that a block of a real tool did not run (a machine without it), instead of passing silently.
  local function skipped(tool)
    print(("lint_spec: %s is not installed: the specs of the real tool are skipped"):format(tool))
  end

  -- stylua: red on an unformatted file, green on a formatted one, --fix rewrites and says so
  if vim.fn.executable("stylua") ~= 1 then
    skipped("stylua")
  else
    local red = project("stylua-red", { ["lua/proj/bad.lua"] = UNFORMATTED })
    local res = run(red, "stylua", "--all", "--json")
    eq(res.code, 1, "stylua: red exit 1 (" .. res.err .. ")")
    eq(finding_files(check_of(res.doc, "stylua")), { "lua/proj/bad.lua" }, "stylua: the finding")
    local green = project("stylua-green", {})
    eq(run(green, "stylua", "--all").code, 0, "stylua: a formatted project is green")

    local fix = run(red, "stylua", "--fix", "--file=lua/proj/bad.lua", "--json")
    eq(fix.code, 0, "stylua --fix: green after the fix (" .. fix.err .. ")")
    eq(check_of(fix.doc, "stylua").fixed, { "lua/proj/bad.lua" }, "stylua --fix: names the file")
    eq(read(red .. "/lua/proj/bad.lua"), "local M = {}\nreturn M\n", "stylua --fix: rewrote it")
    local term = run(red, "stylua", "--fix", "--all", "--no-agent")
    eq(term.code, 0, "stylua --fix: nothing left")
    write(red .. "/lua/proj/bad.lua", UNFORMATTED)
    term = run(red, "stylua", "--fix", "--all", "--no-agent")
    has(term.out, "fixed: lua/proj/bad.lua", "stylua --fix --all: the terminal report names it")
    -- the real stylua formats an ignored file that is named on its command line, unless --respect-ignores
    local ignore = project("stylua-ignore-real", { [".styluaignore"] = "vendor/\n" })
    write(ignore .. "/vendor/ext.lua", UNFORMATTED)
    eq(run(ignore, "stylua").code, 0, "stylua: an ignored changed file is no finding")
    run(ignore, "stylua", "--fix", "--file=vendor/ext.lua")
    eq(read(ignore .. "/vendor/ext.lua"), UNFORMATTED, "stylua --fix: an ignored file is untouched")
  end

  -- the luacheck preset: red on a real warning, green without; --fix is not offered, the exit stays red
  if vim.fn.executable("luacheck") ~= 1 then
    skipped("luacheck")
  else
    local red = project("luacheck-red", { ["lua/proj/bad.lua"] = UNUSED })
    local res = run(red, "luacheck", "--all", "--json")
    eq(res.code, 1, "luacheck: red exit 1 (" .. res.err .. ")")
    local c = check_of(res.doc, "luacheck")
    eq(finding_files(c), { "lua/proj/bad.lua" }, "luacheck: the finding's file")
    eq(c.findings[1].line, 1, "luacheck: line")
    eq(c.findings[1].col, 7, "luacheck: column")
    has(c.findings[1].message, "unused variable", "luacheck: message")
    eq(c.findings[1].check, "luacheck", "luacheck: the finding names its check")
    eq(run(project("luacheck-green", {}), "luacheck", "--all").code, 0, "luacheck: green")
    local fix = run(red, "luacheck", "--fix", "--all", "--no-agent")
    eq(fix.code, 1, "luacheck --fix: still red")
    has(fix.out, "luacheck: no --fix", "luacheck --fix: said so")
    local agent = run(red, "luacheck", "--all", "--agent")
    eq(vim.split(agent.out, "\n")[1], "lint RED luacheck (1 finding)", "luacheck: agent verdict")
    has(
      agent.out,
      "lua/proj/bad.lua:1:7: (W211) unused variable 'unused'",
      "luacheck: agent finding"
    )
  end

  -- luals: the whole workspace, red on an undefined global, green without; findings outside the scope are dropped
  if vim.fn.executable("lua-language-server") ~= 1 then
    skipped("lua-language-server")
  else
    local red = project("luals-red", { ["lua/proj/bad.lua"] = UNDEFINED })
    local res = run(red, "luals", "--all", "--json")
    eq(res.code, 1, "luals: red exit 1 (" .. res.err .. ")")
    local c = check_of(res.doc, "luals")
    eq(finding_files(c), { "lua/proj/bad.lua" }, "luals: the finding's file")
    eq(c.findings[1].line, 2, "luals: line")
    has(c.findings[1].message, "undefined_thing", "luals: message")
    eq(run(project("luals-green", {}), "luals", "--all").code, 0, "luals: green")
    local scoped = run(red, "luals", "--file=lua/proj/mod.lua", "--json")
    eq(
      scoped.code,
      0,
      "luals: a file without findings is green, the workspace's other findings dropped"
    )
    eq(#check_of(scoped.doc, "luals").findings, 0, "luals: no finding in scope")
    local hit = run(red, "luals", "--file=lua/proj/bad.lua", "--json")
    eq(hit.code, 1, "luals: the file with the finding is red")
    lacks(hit.out, "mod.lua", "luals: nothing about the other file")
  end

  vim.fn.delete(tmp, "rf")
end
