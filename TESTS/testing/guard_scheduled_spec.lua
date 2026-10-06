-- TESTS/testing/guard_scheduled_spec.lua -- the scheduled-error guard in a REAL child editor: errors in
-- vim.schedule / luv callbacks / autocmds that Neovim only prints become findings with the message
-- (and the stack where the wrapper saw it); working callbacks stay quiet.

return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("scheduled")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
  end

  local c = r.red_schedule_callback
  local f = S.find(c, "scheduled.schedule_callback", { "boom-sched" })
  ok(f ~= nil, "a throwing vim.schedule callback is a finding")
  eq(f.severity, "error", "severity error")
  eq(f.stack, true, "the finding carries the stack")
  eq(#c.findings, 1, "the message scan does not report the same error again")

  c = r.red_luv_timer
  ok(
    S.find(c, "scheduled.luv_callback", { "boom-timer" }) ~= nil,
    "an error in a luv timer callback"
  )

  c = r.red_schedule_made_before_the_window
  ok(
    S.find(c, "scheduled.schedule_callback", { "boom-early" }) ~= nil,
    "a callback scheduled before the window is found by the :messages scan"
  )

  c = r.red_error_in_autocmd
  ok(
    S.find(c, "scheduled.error_message", { "boom-autocmd" }) ~= nil,
    "E5108 of an autocmd nobody caught"
  )

  c = r.red_notify_error
  eq(
    S.find(c, "scheduled.notify_error", { "kaput-notify" }).severity,
    "error",
    "notify = error: ERROR notifications fail"
  )

  c = r.info_notify_error_default
  eq(#c.findings, 1, "only the ERROR notification is recorded")
  eq(c.findings[1].severity, "info", "by default an ERROR notification is info only")

  eq(r.green_callbacks_work.findings, {}, "working callbacks and caught errors: no finding")
  eq(r.green_callbacks_work.body_error, nil, "the green body itself ran")
  eq(r.green_allow_pattern.findings, {}, "allow_patterns lets a deliberate error through")
end
