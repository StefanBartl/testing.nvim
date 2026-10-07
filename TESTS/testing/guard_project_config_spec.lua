-- TESTS/testing/guard_project_config_spec.lua -- the table form of `guards.<name>` in `.testing.lua`
-- (`mode`, `categories`, `ignore_*`, `keep`, `fs.allow`, ...): the schema takes it, the adapter
-- (`options.guard_config`) hands it to the guard layer, and the state guard honors it. A typo is one
-- warning that names the key; the project keeps the default for it.

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
  local function contains(list, value)
    return vim.tbl_contains(list or {}, value)
  end
  local project = require("testing.config.project")
  local options_mod = require("testing.run.options")
  local gconfig = require("testing.guard.config")
  local guard = require("testing.guard")

  local function build(guards, extra)
    local cfg, problems =
      project.validate(vim.tbl_extend("force", { guards = guards }, extra or {}))
    local o = options_mod.of({ project = cfg, args = {} })
    return options_mod.guard_config(o, { root = "/r" }), problems, o
  end

  -- ------------------------------------------------------------------ the schema takes the table form
  local gc, problems, o = build({
    state = {
      mode = "warn",
      categories = { autocmds = "off", usercmds = "info", keymaps = "error" },
      ignore_groups = { "MyPlugin" },
      ignore_vars = { "my_plugin_" },
      keep = { "MyPlug" },
      max_per_category = 5,
    },
    fs = { mode = "error", allow = { "TESTS/tmp" }, allow_patterns = { "%.cache$" } },
    process_net = { allow_exec = { "git" }, allow_hosts = { "localhost" } },
    scheduled_error = { allow_patterns = { "expected boom" }, notify = "warn" },
    prompt = { getchar_wait_ms = 50 },
    deprecation = "off",
  })
  eq(problems, {}, "a table section with every documented key is valid: " .. vim.inspect(problems))

  -- ------------------------------------------------------------------ the adapter hands it on
  eq(o.guards.state, "warn", "options.guards keeps the mode of a table section")
  eq(o.guards.fs, "error", "fs mode")
  eq(o.guards.deprecation, "off", "a bare mode still works")
  local st = gc.guards.state
  eq(st.mode, "warn", "state mode")
  eq(st.categories.autocmds, "off", "state.categories: the project's value")
  eq(st.categories.usercmds, "info", "state.categories: info stays below the mode")
  eq(st.categories.keymaps, "warn", "state.categories: capped at the mode of the guard (warn)")
  eq(st.categories.buffers, "warn", "state.categories: the defaults are capped as before")
  ok(contains(st.ignore_groups, "MyPlugin"), "ignore_groups has the project's entry")
  ok(contains(st.ignore_groups, "nvim."), "ignore_groups still has the editor's own default")
  ok(contains(st.ignore_vars, "my_plugin_"), "ignore_vars has the project's entry")
  ok(contains(st.ignore_vars, "loaded_node_provider"), "ignore_vars still has the defaults")
  ok(contains(st.ignore_groups, "MyPlug"), "keep reaches the autocmd groups")
  ok(contains(st.ignore_usercmds, "MyPlug"), "keep reaches the user commands")
  ok(contains(st.ignore_keymaps, "MyPlug"), "keep reaches the keymaps")
  eq(st.max_per_category, 5, "a plain value replaces the default")
  eq(gc.guards.fs.allow, { "TESTS/tmp" }, "fs.allow of the table form")
  eq(gc.guards.fs.allow_patterns, { "%.cache$" }, "fs.allow_patterns")
  eq(gc.guards.fs.ignore, nil, "what the project does not tune is left to the guard layer")
  local gc3 = build({ fs = { ignore = { "vendor" } } })
  ok(
    contains(gc3.guards.fs.ignore, ".git") and contains(gc3.guards.fs.ignore, "vendor"),
    "fs.ignore adds to the default ignore list"
  )
  eq(gc.guards.process_net.allow_exec, { "git" }, "process_net.allow_exec")
  eq(gc.guards.process_net.allow_hosts, { "localhost" }, "process_net.allow_hosts")
  eq(gc.guards.scheduled_error.notify, "warn", "scheduled_error.notify")
  eq(gc.guards.prompt.getchar_wait_ms, 50, "prompt.getchar_wait_ms")

  -- the allow lists of both spellings add up
  local gc2 = build({ fs = { allow = { "a" } } }, { guard_allow = { fs = { "b" } } })
  eq(gc2.guards.fs.allow, { "b", "a" }, "guard_allow.fs and guards.fs.allow add up")

  -- the layer's own validation is happy with the result
  local _, gproblems = gconfig.normalize(gc)
  eq(
    gproblems,
    {},
    "testing.guard.config accepts what the adapter builds: " .. vim.inspect(gproblems)
  )

  -- a table without `mode` keeps the default mode of the guard
  local _, _, o2 = build({ state = { ignore_groups = { "X" } } })
  eq(o2.guards.state, "warn", "no mode in a table: the default mode")

  -- ------------------------------------------------------------------ invalid input: one warning, default stays
  local cases = {
    { { state = { categories = { nonsense = "warn" } } }, "guards.state" },
    { { state = { categories = { autocmds = "loud" } } }, "guards.state" },
    { { state = { ignore_groups = "MyPlugin" } }, "guards.state" },
    { { fs = { mode = "loud" } }, "guards.fs" },
    { { fs = { allow = { 1 } } }, "guards.fs" },
    { { fs = { nonsense = true } }, "guards.fs" },
    { { process_net = { allow_exec = "git" } }, "guards.process_net" },
    { { scheduled_error = { allow_patterns = { "[" } } }, "guards.scheduled_error" },
    { { deprecation = { allow = {} } }, "guards.deprecation" },
  }
  for _, c in ipairs(cases) do
    local cfg, probs = project.validate({ guards = c[1] })
    eq(#probs, 1, "one warning for " .. vim.inspect(c[1]) .. ": " .. vim.inspect(probs))
    has(probs[1] or "", c[2], "the warning names the key")
    local name = next(c[1])
    eq(
      cfg.guards[name],
      require("testing.config.DEFAULTS").project.guards[name],
      "the default stays"
    )
  end

  -- ------------------------------------------------------------------ the state guard honors it
  local function leaks(state_section)
    local gcfg = { guards = {} }
    for _, n in ipairs(gconfig.ORDER) do
      gcfg.guards[n] = { mode = "off" }
    end
    gcfg.guards.state = state_section
    local h = guard.install(gcfg)
    h:begin_case({ id = "c", file = "f" })
    local group = vim.api.nvim_create_augroup("MyPlugGroup", { clear = true })
    vim.api.nvim_create_autocmd(
      "BufEnter",
      { group = group, pattern = "*.zzz", command = "echo 1" }
    )
    vim.api.nvim_create_user_command("MyPlugCmd", "echo 1", {})
    vim.keymap.set("n", "<Plug>MyPlugMap", "<Nop>")
    local res = h:end_case()
    h:uninstall()
    pcall(vim.api.nvim_del_augroup_by_name, "MyPlugGroup")
    pcall(vim.api.nvim_del_user_command, "MyPlugCmd")
    pcall(vim.keymap.del, "n", "<Plug>MyPlugMap")
    local ids = {}
    for _, f in ipairs(res.findings) do
      ids[f.id] = true
    end
    return ids
  end

  local loud = leaks({ mode = "error" })
  ok(loud["state.autocmd"], "without a keep list the autocmd is a finding")
  ok(loud["state.usercmd"], "without a keep list the user command is a finding")
  ok(loud["state.keymap"], "without a keep list the keymap is a finding")

  local quiet = leaks({
    mode = "error",
    ignore_groups = { "nvim.", "MyPlug" },
    ignore_usercmds = { "MyPlug" },
    ignore_keymaps = { "<Plug>MyPlug" },
  })
  ok(not quiet["state.autocmd"], "ignore_groups silences the group")
  ok(not quiet["state.usercmd"], "ignore_usercmds silences the command")
  ok(not quiet["state.keymap"], "ignore_keymaps silences the map")

  local cats =
    leaks({ mode = "error", categories = { autocmds = "off", usercmds = "off", keymaps = "off" } })
  ok(
    not cats["state.autocmd"] and not cats["state.usercmd"] and not cats["state.keymap"],
    "categories = off silences a category"
  )
end
