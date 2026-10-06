-- Scenarios of the (opt-in) clock guard. Run by TESTS/testing/guard_clock_spec.lua in a real child
-- editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")
local uv = vim.uv

local raw = { time = os.time, now = uv.now, hrtime = uv.hrtime, date = os.date }

local function only_clock(extra)
  ---@type table<string, any>
  local g = { clock = extra or { mode = "error" } }
  for _, name in ipairs({ "fs", "state", "scheduled_error", "prompt", "deprecation", "process_net" }) do
    g[name] = "off"
  end
  return { guards = g }
end

B.case("off_by_default", {
  cfg = {
    guards = {
      fs = "off",
      state = "off",
      scheduled_error = "off",
      prompt = "off",
      deprecation = "off",
      process_net = "off",
    },
  },
  body = function()
    return {
      untouched = os.time == raw.time
        and uv.now == raw.now
        and uv.hrtime == raw.hrtime
        and os.date == raw.date,
    }
  end,
})

B.case("installed_but_not_started_is_transparent", {
  cfg = only_clock(),
  body = function(h)
    local a = uv.now()
    vim.wait(30)
    local b = uv.now()
    return {
      moved = b > a,
      patched = os.time ~= raw.time,
      advance_raises = not pcall(h:clock().advance, h:clock(), 10),
    }
  end,
})

B.case("tag_starts_a_frozen_clock", {
  cfg = only_clock({ mode = "error", seed = 42 }),
  ctx = { id = "fx::clock", file = "fx.lua", tags = { "clock" } },
  body = function(h)
    local clock = h:clock()
    local out = {}
    local t1, n1, h1 = os.time(), uv.now(), uv.hrtime()
    local d1 = os.date("%Y-%m-%d %H:%M:%S")
    local c1 = os.clock()
    vim.wait(60)
    out.frozen = os.time() == t1
      and uv.now() == n1
      and uv.hrtime() == h1
      and os.clock() == c1
      and os.date("%Y-%m-%d %H:%M:%S") == d1
    clock:advance(5000)
    out.time_delta = os.time() - t1
    out.now_delta = uv.now() - n1
    out.hr_delta_ms = math.floor((uv.hrtime() - h1) / 1e6)
    out.clock_delta = math.floor((os.clock() - c1) * 1000)
    out.localtime_delta = vim.fn.localtime() - t1
    out.strftime_ok = vim.fn.strftime("%S") == os.date("%S")
    local tbl = { year = 2020, month = 1, day = 1, hour = 12 }
    out.table_arg_passes = os.time(tbl) == raw.time(tbl)
    out.explicit_date_passes = os.date("!%Y", 0) == "1970"
    out.negative_raises = not pcall(clock.advance, clock, -1)
    -- the seed: the same sequence as an explicit seeding with 42
    local a = { math.random(), math.random() }
    math.randomseed(42)
    local b = { math.random(), math.random() }
    out.seeded = a[1] == b[1] and a[2] == b[2]
    return out
  end,
  after = function()
    -- window closed: the clock runs again
    local a = uv.now()
    vim.wait(30)
    return { running_again = uv.now() > a }
  end,
})

B.case("manual_start_without_tag", {
  cfg = only_clock(),
  body = function(h)
    local clock = h:clock()
    local before_start = not pcall(clock.advance, clock, 1)
    clock:start({ epoch = 1700000000 })
    clock:advance(60 * 1000)
    return { raises_before_start = before_start, time = os.time(), year = os.date("%Y") }
  end,
})

B.finish()
