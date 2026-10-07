-- TESTS/testing/conformance_waiver_utc_spec.lua -- a waiver expires by the UTC calendar day, never by the
-- time zone of the machine: the same instant gives the same answer under every `TZ`. The time zone is read by
-- the C runtime when the process starts, so each zone is checked in a fresh `nvim -l` process.

return function(H)
  local ok = H.ok
  local settings = require("testing.conformance.settings")
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))

  -- 2026-06-30T23:30:00Z and an hour later (2026-07-01T00:30:00Z)
  local utc_2330 = 1782862200
  local utc_0030 = utc_2330 + 3600
  ok(
    os.date("!%Y-%m-%dT%H:%M", utc_2330) == "2026-06-30T23:30",
    "the fixture instant is what it says"
  )

  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    ("package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path"):format(
      root,
      root
    ),
    "local runner = require('testing.conformance.runner')",
    "local out = {}",
    "for _, now in ipairs({ tonumber(arg[1]), tonumber(arg[2]) }) do",
    "  local results = { { findings = { { check = 'K1', level = 'warn', rule = 'R1', message = 'm' } } } }",
    "  local waivers = { { check = 'K1', rule = 'R1', reason = 'accepted for the spec', expires = '2026-06-30' } }",
    "  runner.apply_waivers(results, waivers, now)",
    "  out[#out + 1] = results[1].findings[1].waived == true and 'applies' or 'expired'",
    "end",
    "io.stdout:write(table.concat(out, ','))",
    "vim.cmd('qa!')",
  }, script)

  for _, tz in ipairs({ "UTC0", "NZST-12", "PST8", "JST-9", "IST-5:30" }) do
    local res = vim
      .system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        script,
        tostring(utc_2330),
        tostring(utc_0030),
      }, { env = { TZ = tz }, text = true })
      :wait(20000)
    ok(res.code == 0, tz .. ": the probe process ran: " .. tostring(res.stderr))
    ok(
      res.stdout == "applies,expired",
      tz
        .. ": 23:30 UTC on the day still applies, 00:30 UTC the next day has expired (got "
        .. tostring(res.stdout)
        .. ")"
    )
  end
  vim.fn.delete(script)

  -- the date check itself has no time zone either
  ok(settings.valid_date("2026-02-28"), "a normal day")
  ok(not settings.valid_date("2026-02-29"), "no leap day in 2026")
  ok(settings.valid_date("2000-02-29"), "2000 is a leap year")
  ok(not settings.valid_date("1900-02-29"), "1900 is not")
  ok(not settings.valid_date("2026-13-01"), "month 13")
  ok(not settings.valid_date("2026-00-10"), "month 0")
  ok(not settings.valid_date("2026-04-31"), "April has 30 days")
  ok(settings.valid_date("9999-12-31"), "far years are fine (no platform time_t limit)")
end
