-- TESTS/testing/guard_state_spec.lua -- the state-leak guard in a REAL child editor: every RED scenario
-- must produce a precisely NAMED finding ("spec X leaves autocmd Y in group Z"), every GREEN control
-- must stay quiet, and the soft isolation must put the editor back.

return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("state")

  local function has_msg(case, id, needles, msg)
    local f = S.find(case, id, needles)
    ok(
      f ~= nil,
      msg
        .. ": no "
        .. id
        .. " with "
        .. vim.inspect(needles)
        .. " in "
        .. vim.inspect(case.findings)
    )
    return f
  end

  -- ------------------------------------------------------------ runtime noise is not a leak
  do
    local noise = r.green_runtime_noise
    eq(
      noise.findings,
      {},
      "runtime noise (markdown_*, lua_version, did_load_*, syntax, _G.re, default highlights): no finding"
    )
    local look = r.red_noise_lookalikes
    for _, want in ipairs({
      { "state.var", "vim.g.markdownish_plugin_flag" },
      { "state.var", "vim.g.my_plugin_state" },
      { "state.lua_global", "_G.reality" },
      { "state.highlight", "MyPluginGroup" },
    }) do
      ok(
        S.find(look, want[1], { want[2] }) ~= nil,
        "the look-alike " .. want[2] .. " is still a finding: " .. vim.inspect(look.findings)
      )
    end
    eq(
      r.green_clipboard_provider_job.findings,
      {},
      "the clipboard provider's job (win32yank) is not a leak"
    )
    ok(
      S.find(r.red_other_job_still_named, "state.channel", { "dev-server" }) ~= nil,
      "any other job is still named: " .. vim.inspect(r.red_other_job_still_named.findings)
    )
  end

  -- every scenario ran and the guard installed
  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
    eq(c.body_error, nil, name .. ": the scenario body itself ran without an error")
  end

  -- ---------------------------------------------------------------- RED
  local f = has_msg(
    r.red_autocmd,
    "state.autocmd",
    { "spec fx::red_autocmd leaves autocmd BufEnter in group LeakGrp", "*.lua" },
    "autocmd is named with event, group and pattern"
  )
  eq(f.severity, "error", "autocmd leak is an error by default")
  has_msg(
    r.red_autocmd_no_group,
    "state.autocmd",
    { "InsertLeave", "no group" },
    "autocmd without a group"
  )
  has_msg(r.red_usercmd, "state.usercmd", { "leaves user command :LeakedCmd" }, "user command")
  has_msg(r.red_keymap, "state.keymap", { "leaves keymap", "zq", "mode n" }, "global keymap")
  has_msg(r.red_keymap_replaced, "state.keymap", { "replaces keymap", "zr" }, "replaced keymap")
  has_msg(
    r.red_keymap_buffer_local,
    "state.keymap",
    { "buffer-local keymap zz", "of buffer" },
    "buffer-local keymap of a surviving buffer"
  )
  has_msg(
    r.red_buffer,
    "state.buffer",
    { "leaves buffer", "leaked-buffer.txt" },
    "buffer named by its file"
  )
  has_msg(r.red_window_tab, "state.window", { "leaves window" }, "window")
  has_msg(r.red_window_tab, "state.tab", { "leaves tab page" }, "tab page")
  local cwd = has_msg(r.red_cwd, "state.cwd", { "changes the working directory" }, "cwd")
  ok(cwd.message:find("-> <TMP>/", 1, true), "cwd message is redacted")
  local opt = has_msg(
    r.red_option,
    "state.option",
    { "option 'scrolloff'", "-> 7" },
    "option named with the values"
  )
  eq(opt.severity, "warn", "options are a warning by default")
  has_msg(r.red_var_env_global, "state.var", { "vim.g.leaked_flag" }, "vim.g")
  has_msg(r.red_var_env_global, "state.env", { "LEAKED_TESTING_VAR" }, "environment variable")
  has_msg(r.red_var_env_global, "state.lua_global", { "_G.leaked_global" }, "global")
  for _, fi in ipairs(r.red_var_env_global.findings) do
    ok(
      not fi.message:find("secret-value", 1, true),
      "an environment value never appears in a finding"
    )
  end
  has_msg(r.red_highlight, "state.highlight", { "highlight group LeakedHl" }, "highlight group")
  has_msg(r.red_rtp, "state.rtp", { "adds runtimepath entry" }, "runtimepath")
  has_msg(r.red_channel, "state.channel", { "leaves running job" }, "running job")
  local mod = has_msg(r.info_module, "state.module", { "leaky.module.x" }, "module is listed")
  eq(mod.severity, "info", "a loaded module is info only")
  eq(#S.loud(r.info_module), 0, "info findings are not loud")

  -- strict promotes warn to error
  eq(S.of(r.warn_strict, "state.option")[1].severity, "error", "strict: warn becomes error")

  -- ---------------------------------------------------------------- GREEN
  for _, name in ipairs({
    "green_nothing",
    "green_cleaned_up",
    "green_ignored_group",
    "green_category_off",
  }) do
    eq(S.loud(r[name]), {}, name .. ": no loud finding")
  end

  -- ---------------------------------------------------------------- soft isolation
  local rs = r.restore
  ok(#rs.findings >= 8, "restore: the leaks are still REPORTED (restoring is after the check)")
  eq(rs.extra.autocmds, 0, "restore: leaked autocmd group cleared")
  eq(rs.extra.usercmd, 0, "restore: user command deleted")
  eq(rs.extra.maps, 0, "restore: keymap deleted")
  eq(rs.extra.bufs, 0, "restore: leaked buffers deleted")
  eq(rs.extra.wins, 0, "restore: leaked windows closed")
  eq(rs.extra.tabs, 0, "restore: leaked tab closed")
  eq(rs.extra.cwd_ok, true, "restore: cwd back")
  eq(rs.extra.scrolloff_ok, true, "restore: option back")
  eq(rs.extra.g, nil, "restore: vim.g removed")
  eq(rs.extra.env, nil, "restore: environment variable removed")
  ok(
    rs.extra.restored.autocmds == 1 and rs.extra.restored.buffers == 2,
    "restore: counts per category"
  )
  eq(S.loud(r.green_nothing), {}, "restore does not hide a clean case")
end
