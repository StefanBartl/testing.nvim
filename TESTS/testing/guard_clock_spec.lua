-- TESTS/testing/guard_clock_spec.lua -- the opt-in fake clock and seed in a REAL child editor: off by
-- default (nothing patched), transparent until started, frozen and advanced by `advance(ms)` while a
-- `@clock` case runs, running again afterwards.

return function(H)
  local eq = H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("clock")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
    eq(c.body_error, nil, name .. ": the scenario body itself ran without an error")
  end

  eq(r.off_by_default.value.untouched, true, "default: no time function is replaced")

  local c = r.installed_but_not_started_is_transparent
  eq(c.value.patched, true, "mode on: the entry points are wrapped")
  eq(c.value.moved, true, "but they behave like the originals until the clock is started")
  eq(c.value.advance_raises, true, "advance() before start() is an error")

  c = r.tag_starts_a_frozen_clock
  local v = c.value
  eq(v.frozen, true, "the @clock tag freezes os.time / os.clock / os.date / uv.now / uv.hrtime")
  eq(v.time_delta, 5, "advance(5000): os.time +5 s")
  eq(v.now_delta, 5000, "advance(5000): uv.now +5000 ms")
  eq(v.hr_delta_ms, 5000, "advance(5000): uv.hrtime +5000 ms")
  eq(v.clock_delta, 5000, "advance(5000): os.clock +5 s")
  eq(v.localtime_delta, 5, "vim.fn.localtime follows the fake clock")
  eq(v.strftime_ok, true, "vim.fn.strftime without a time follows the fake clock")
  eq(v.table_arg_passes, true, "os.time(table) is still the real conversion")
  eq(v.explicit_date_passes, true, "os.date with an explicit time is untouched")
  eq(v.negative_raises, true, "advance(-1) is refused")
  eq(v.seeded, true, "the configured seed seeds math.random")
  eq(c.extra.running_again, true, "after the case the real clock runs again")
  eq(c.findings, {}, "the clock guard never produces findings")

  c = r.manual_start_without_tag
  eq(c.value.raises_before_start, true, "not started: advance raises")
  eq(c.value.time, 1700000060, "start{ epoch } pins the time, advance moves it")
  eq(c.value.year, "2023", "os.date uses the fake time")
end
