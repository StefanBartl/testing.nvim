-- TESTS/testing/config_spec.lua -- testing.config: validation, merge over the defaults, reset.

-- @cache-allow outside
-- (".." and "../x" are the BAD values of a path validator, no path is read)
return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local config = require("testing.config")
  local DEFAULTS = require("testing.config.DEFAULTS")

  config.reset()
  eq(config.get(), DEFAULTS, "a fresh config equals the defaults")
  ok(config.get() ~= DEFAULTS, "the active config is a copy, never the DEFAULTS table itself")

  -- validate: what passes, what is dropped and why
  local valid, problems = config.validate(nil)
  eq(valid, {}, "nil is no options")
  eq(problems, {}, "nil is no problem")

  valid, problems = config.validate("x")
  eq(valid, {}, "a non-table is ignored")
  eq(#problems, 1, "a non-table is reported once")

  valid, problems = config.validate({ notify_prefix = 3, keymaps = "no", nope = true })
  eq(valid, {}, "wrong types and unknown keys are dropped")
  eq(#problems, 3, "each dropped key is reported")
  has(table.concat(problems, "\n"), "unknown option 'nope'", "an unknown key is named")

  valid = config.validate({ notify_prefix = "" })
  eq(valid, {}, "an empty prefix is dropped")

  valid = config.validate({ notify_prefix = "[t]", keymaps = false })
  eq(valid, { notify_prefix = "[t]", keymaps = false }, "valid keys pass, false counts for keymaps")

  -- setup: defaults first, valid options on top, bad options never overwrite a good default
  problems = config.setup({ notify_prefix = "[mine]" })
  eq(problems, {}, "valid options raise no problem")
  eq(config.get().notify_prefix, "[mine]", "a valid option is applied")
  eq(config.get().keymaps, {}, "an untouched key keeps its default")

  ---@type any
  local not_a_string = 5
  problems = config.setup({ notify_prefix = not_a_string })
  eq(#problems, 1, "an invalid option is reported")
  eq(config.get().notify_prefix, DEFAULTS.notify_prefix, "setup rebuilds from the defaults")

  config.setup({ keymaps = { run = "<leader>x" } })
  eq(config.get().keymaps, { run = "<leader>x" }, "a keymap override is merged in")
  config.setup({ keymaps = false })
  eq(config.get().keymaps, false, "keymaps = false replaces the table")

  config.reset()
  eq(config.get(), DEFAULTS, "reset restores the defaults")

  -- `project` is data of the defaults, not an option of setup()
  valid, problems = config.validate({ project = {} })
  eq(valid, {}, "project is not settable through setup()")
  has(table.concat(problems, "\n"), "unknown option 'project'", "and says so")

  -- DEFAULTS is pure data (LUA-06): no function, no userdata anywhere
  local function pure(t, path)
    for k, v in pairs(t) do
      local kind = type(v)
      ok(
        kind ~= "function" and kind ~= "userdata" and kind ~= "thread",
        path .. "." .. tostring(k) .. " is " .. kind
      )
      if kind == "table" then
        pure(v, path .. "." .. tostring(k))
      end
    end
  end
  pure(DEFAULTS, "DEFAULTS")

  -- =====================================================================
  -- .testing.lua (testing.config.project)
  local project = require("testing.config.project")
  local PD = DEFAULTS.project

  local cfg, probs = project.validate(nil)
  eq(cfg, PD, "no file content: the defaults")
  eq(probs, {}, "and no problem")
  ok(cfg ~= PD and cfg.roots ~= PD.roots, "a deep copy, never the DEFAULTS tables")

  cfg, probs = project.validate("nope")
  eq(cfg, PD, "a non-table content is ignored")
  eq(#probs, 1, "and reported once")

  -- every valid key is taken
  cfg, probs = project.validate({
    plugin = "sessions",
    roots = { "TESTS", "spec/unit" },
    dialect = "busted",
    minit = false,
    deps = { "lib.nvim", "runtime-analysis.nvim" },
    setup = { keymaps = { save = "<leader>s" } },
    conformance = { load_budget_ms = 80 },
    coverage = { bindings = 1.0, commands = 0.5 },
    timeouts = { case_ms = 5000, file_ms = 20000 },
    snapshots = { dir = "TESTS/snap" },
    backends = { luals = true, pty = false, playwright = false, webdriver = false },
  })
  eq(probs, {}, "a fully valid file raises no problem")
  eq(cfg.plugin, "sessions", "plugin")
  eq(cfg.roots, { "TESTS", "spec/unit" }, "roots")
  eq(cfg.dialect, "busted", "dialect")
  eq(cfg.minit, false, "minit = false")
  eq(cfg.deps, { "lib.nvim", "runtime-analysis.nvim" }, "deps")
  eq(cfg.setup, { keymaps = { save = "<leader>s" } }, "setup")
  eq(cfg.timeouts, { case_ms = 5000, file_ms = 20000 }, "timeouts")
  eq(cfg.coverage, { bindings = 1.0, commands = 0.5, autocmds = 0 }, "coverage")
  eq(cfg.backends.luals, true, "backends.luals")

  -- partial groups keep the defaults of the other keys
  cfg = project.validate({ timeouts = { case_ms = 5 } })
  eq(cfg.timeouts, { case_ms = 5, file_ms = PD.timeouts.file_ms }, "a partial group merges")

  -- invalid values degrade to the default, and the warning names the key
  ---@type any
  local junk = {
    plugin = 5,
    roots = { "/abs" },
    dialect = "pascal",
    minit = "../out.lua",
    deps = { "a/b" },
    setup = "x",
    timeouts = { case_ms = "ten", file_ms = -1 },
    coverage = { bindings = 2 },
    snapshots = { dir = "C:\\x" },
    backends = { luals = "yes" },
    conformance = { load_budget_ms = -4 },
  }
  cfg, probs = project.validate(junk)
  eq(cfg, PD, "every invalid value degrades to its default")
  local all = table.concat(probs, "\n")
  eq(#probs, 12, "one warning per invalid key: " .. all)
  for _, key in ipairs({
    "'plugin'",
    "'roots'",
    "'dialect'",
    "'minit'",
    "'deps'",
    "'setup'",
    "'timeouts.case_ms'",
    "'timeouts.file_ms'",
    "'coverage.bindings'",
    "'snapshots.dir'",
    "'backends.luals'",
    "'conformance.load_budget_ms'",
  }) do
    has(all, "key " .. key .. " is invalid", "the warning names " .. key)
  end
  has(all, "using the default", "and says what happens")

  -- a path escape is never accepted, in every spelling
  for _, bad in ipairs({ "..", "../x", "a/../../x", "a\\..\\x", "/etc", "\\x", "C:/x", "", "a\0b" }) do
    cfg = project.validate({ roots = { bad } })
    eq(cfg.roots, PD.roots, "roots refuses " .. vim.inspect(bad))
  end
  cfg = project.validate({ roots = { "a/b..c", "..d" } })
  eq(cfg.roots, { "a/b..c", "..d" }, "dots inside a name are fine")
  cfg = project.validate({ roots = {} })
  eq(cfg.roots, PD.roots, "an empty roots list is refused")
  cfg = project.validate({ roots = { "TESTS", [3] = "x" } })
  eq(cfg.roots, PD.roots, "a list with a hole is refused")

  -- unknown keys and malformed groups
  cfg, probs = project.validate({ plugn = "typo", timeouts = "fast", coverage = { bindingz = 1 } })
  eq(cfg, PD, "typos change nothing")
  all = table.concat(probs, "\n")
  has(all, "unknown key 'plugn'", "unknown top-level key")
  has(all, "key 'timeouts' must be a table", "a group that is not a table")
  has(all, "unknown key 'coverage.bindingz'", "unknown nested key")

  -- load: from a real project root
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local tmp = vim.fs.normalize(vim.fn.tempname())
  local root = tmp .. "/my-plugin.nvim"
  vim.fn.mkdir(root, "p")

  local loaded = project.load(root)
  eq(loaded.path, nil, "no file: no path")
  eq(loaded.error, nil, "no file is no error")
  eq(loaded.problems, {}, "no file: no problem")
  eq(loaded.config.plugin, "my-plugin", "plugin is derived from the directory name")
  eq(loaded.config.roots, PD.roots, "no file: defaults")

  write(root .. "/.testing.lua", 'return { plugin = "mine", timeouts = { case_ms = 7 } }\n')
  loaded = project.load(root)
  eq(loaded.path, root .. "/.testing.lua", "the file in the root is the one loaded")
  eq(loaded.config.plugin, "mine", "plugin from the file")
  eq(loaded.config.timeouts.case_ms, 7, "a value from the file")
  eq(loaded.config.timeouts.file_ms, PD.timeouts.file_ms, "a default beside it")
  eq(loaded.error, nil, "no error")

  write(root .. "/.testing.lua", 'return { timeouts = { case_ms = "x" }, bogus = 1 }\n')
  loaded = project.load(root)
  eq(loaded.error, nil, "invalid values are warnings, not errors")
  eq(#loaded.problems, 2, "two warnings")
  eq(loaded.config.timeouts.case_ms, PD.timeouts.case_ms, "the default stayed")

  write(root .. "/.testing.lua", "return {\n")
  loaded = project.load(root)
  ok(loaded.error ~= nil, "a syntax error is an error")
  has(loaded.error, ".testing.lua", "naming the file")
  eq(loaded.path, nil, "no path for an unusable file")
  eq(loaded.config.roots, PD.roots, "the config is still usable (defaults)")

  write(root .. "/.testing.lua", 'error("boom")\n')
  loaded = project.load(root)
  has(loaded.error or "", "boom", "a raising file is an error that carries the message")

  write(root .. "/.testing.lua", "return 42\n")
  loaded = project.load(root)
  has(loaded.error or "", "must return a table", "a non-table return is an error")

  write(root .. "/.testing.lua", "return {}\n")
  loaded = project.load(root)
  eq(loaded.error, nil, "an empty table is fine")

  -- the bytecode of a chunk is not loaded (text mode only)
  local bc = string.dump(assert(load("return {}")))
  write(root .. "/.testing.lua", bc)
  loaded = project.load(root)
  ok(loaded.error ~= nil, "precompiled bytecode is refused")

  -- an oversized file is not executed
  write(root .. "/.testing.lua", "return {} -- " .. ("x"):rep(project.MAX_BYTES))
  loaded = project.load(root)
  has(loaded.error or "", "larger than", "an oversized file is refused")
  vim.fn.delete(root .. "/.testing.lua")

  -- --config: inside the root it works, outside it is refused
  write(root .. "/ci/alt.lua", 'return { plugin = "alt" }\n')
  loaded = project.load(root, { file = root .. "/ci/alt.lua" })
  eq(loaded.config.plugin, "alt", "an explicit file inside the root")
  write(tmp .. "/elsewhere.lua", 'return { plugin = "evil" }\n')
  loaded = project.load(root, { file = tmp .. "/elsewhere.lua" })
  has(
    loaded.error or "",
    "outside the project root",
    "an explicit file outside the root is refused"
  )
  eq(loaded.config.plugin, "my-plugin", "and was not executed")
  loaded = project.load(root, { file = root .. "/missing.lua" })
  has(
    loaded.error or "",
    "not found",
    "a missing explicit file is an error (an implicit one is not)"
  )
  loaded = project.load(root, { file = root .. "/ci" })
  ok(loaded.error ~= nil, "a directory is not a config file")

  -- ------------------------------------------------------------------ keys of the isolated/child driver
  local defaults = project.validate(nil)
  eq(defaults.spec_pattern, { "_spec%.lua$" }, "spec_pattern defaults to the _spec.lua suffix")
  eq(defaults.assertions, "error", "a case without assertions is an error by default")
  eq(defaults.isolated, "auto", "isolated defaults to auto")
  eq(defaults.jobs, 1, "jobs defaults to 1")
  eq(defaults.host, "c", "host defaults to c (started like plenary)")
  eq(defaults.filetype, true, "filetype defaults to true")
  eq(defaults.env_allow, {}, "env_allow defaults to nothing on top of the built-in allowlist")
  eq(project.isolated_for(defaults, "busted"), "file", "auto: busted specs get a process per file")
  for _, name in ipairs({ "a", "b", "c", "d", "h" }) do
    eq(
      project.isolated_for(defaults, name),
      "none",
      "auto: dialect " .. name .. " shares the process"
    )
  end
  eq(project.isolated_for(defaults, "script"), "file", "a script always has its own process")
  local explicit = project.validate({ isolated = "none" })
  eq(project.isolated_for(explicit, "busted"), "none", "an explicit none wins for busted")
  explicit = project.validate({ isolated = "file" })
  eq(project.isolated_for(explicit, "a"), "file", "an explicit file wins for dialect a")

  local good, good_problems = project.validate({
    spec_pattern = { "^TESTS/[%w_]+%.lua$", "_spec%.lua$" },
    assertions = "warn",
    isolated = "file",
    jobs = 8,
    host = "l",
    filetype = false,
    env_allow = { "REPOS_DIR", "MAGICK_*" },
  })
  eq(good_problems, {}, "valid values of the new keys raise no problem")
  eq(good.env_allow, { "REPOS_DIR", "MAGICK_*" }, "env_allow is taken (a name and a PREFIX*)")
  eq(good.spec_pattern, { "^TESTS/[%w_]+%.lua$", "_spec%.lua$" }, "spec_pattern is taken")
  eq(
    { good.assertions, good.isolated, good.jobs, good.host, good.filetype },
    { "warn", "file", 8, "l", false },
    "the other new keys are taken"
  )

  -- every invalid value degrades to the default with ONE typed warning that names the key
  local cases = {
    { "spec_pattern", {}, "spec_pattern" },
    { "spec_pattern", { "[" }, "spec_pattern" },
    { "spec_pattern", { 3 }, "spec_pattern" },
    { "spec_pattern", "_spec%.lua$", "spec_pattern" },
    { "assertions", "silent", "assertions" },
    { "isolated", "dir", "isolated" },
    { "isolated", true, "isolated" },
    { "jobs", 0, "jobs" },
    { "jobs", 1.5, "jobs" },
    { "jobs", 257, "jobs" },
    { "jobs", "4", "jobs" },
    { "host", "x", "host" },
    { "host", "L", "host" },
    { "filetype", "yes", "filetype" },
    { "env_allow", "REPOS_DIR", "env_allow" },
    { "env_allow", { "*" }, "env_allow" },
    { "env_allow", { "NVIM_LISTEN_ADDRESS" }, "env_allow" },
    { "env_allow", { "A B" }, "env_allow" },
    { "env_allow", { 3 }, "env_allow" },
  }
  for _, c in ipairs(cases) do
    local one, warnings = project.validate({ [c[1]] = c[2] })
    eq(#warnings, 1, ("%s = %s: one warning"):format(c[1], vim.inspect(c[2])))
    has(warnings[1], ("key '%s'"):format(c[3]), c[1] .. ": the warning names the key")
    has(warnings[1], "using the default", c[1] .. ": and says the default stays")
    eq(one[c[1]], defaults[c[1]], ("%s = %s: the default stays"):format(c[1], vim.inspect(c[2])))
  end

  -- dialect: the new names, and the table form with globs
  for _, name in ipairs({ "h", "script", "d", "busted", "auto" }) do
    local named, named_problems = project.validate({ dialect = name })
    eq(named_problems, {}, "dialect " .. name .. " is valid")
    eq(named.dialect, name, "dialect " .. name .. " is taken")
  end
  local table_form, table_problems = project.validate({
    dialect = { ["TESTS/x_spec.lua"] = "h", ["TESTS/hover/**"] = "busted", ["*"] = "script" },
  })
  eq(table_problems, {}, "the table form with a literal path, a glob and * is valid")
  eq(table_form.dialect["TESTS/hover/**"], "busted", "the glob key is kept")
  local _, bad_name = project.validate({ dialect = { ["*"] = "klingon" } })
  eq(#bad_name, 1, "a table entry with an unknown dialect name is invalid as a whole")
  local _, bad_key = project.validate({ dialect = { ["../x_spec.lua"] = "a" } })
  eq(#bad_key, 1, "a table key with .. is invalid")
  local _, empty_table = project.validate({ dialect = {} })
  eq(#empty_table, 1, "an empty table is invalid")

  -- DEFAULTS stays pure data (LUA-06): no function, no userdata anywhere
  local function plain_data(value, path)
    local t = type(value)
    if t == "table" then
      for k, v in pairs(value) do
        plain_data(v, path .. "." .. tostring(k))
      end
    else
      ok(t == "string" or t == "number" or t == "boolean", path .. " is plain data, not " .. t)
    end
  end
  plain_data(DEFAULTS, "DEFAULTS")

  vim.fn.delete(tmp, "rf")
end
