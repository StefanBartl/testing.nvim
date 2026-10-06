---@module 'testing.guard.clock'
---@brief Opt-in fake clock and fixed random seed against time/random flakes.
---@description
--- Off by default (`guards.clock.mode = "off"`: nothing is patched). With a mode other than `off`
--- the wall-clock entry points are wrapped; they behave exactly like the originals until a fake
--- clock is STARTED, which happens per case: by the tag `@clock` (or `clock`) on the case, or by
--- `handle:clock():start()`.
---
--- While started the clock starts at the real time of `start()` and stands still until
--- `advance(ms)` moves it:
---   * `os.time()`, `os.clock()`, `os.date(fmt)` (without a time argument)
---   * `vim.uv.now()`, `vim.uv.hrtime()`, `vim.uv.gettimeofday()`
---   * `vim.fn.localtime()`, `vim.fn.strftime(fmt)` (without a time argument)
--- and the random generators are seeded (`math.randomseed(seed)`, `vim.fn.srand(seed)`) when a
--- `seed` is configured or passed to `start`.
---
--- HONEST LIMITS: real timers stay real (`vim.defer_fn`, `uv.new_timer`, `vim.wait` use the
--- editor's loop, not these functions), so `advance` does not fire them; a loop that waits for the
--- clock to move (`while uv.now() < deadline do end`) hangs under a frozen clock; the seeding of the
--- generators is not undone by `stop()` (there is no way to read it back).

local M = {}

---@class Testing.Guard.Clock.Fake
---@field orig table the unwrapped functions
---@field seed? integer
---@field offset_ms number
---@field base_epoch number
---@field base_now integer
---@field base_hr integer
---@field base_clock number
---@field started boolean
local Fake = {}
Fake.__index = Fake

---@param seed? integer
---@return Testing.Guard.Clock.Fake
local function new_fake(seed)
  return setmetatable({ started = false, seed = seed, offset_ms = 0 }, Fake)
end

---Start virtualizing time. `opts.epoch` (seconds) pins the starting wall-clock time.
---@param opts? { epoch?: number, seed?: integer }
function Fake:start(opts)
  opts = opts or {}
  local orig = self.orig
  self.base_epoch = opts.epoch or orig.time()
  self.base_now = orig.uv_now()
  self.base_hr = orig.uv_hrtime()
  self.base_clock = orig.clock()
  self.offset_ms = 0
  self.started = true
  local seed = opts.seed or self.seed
  if seed ~= nil then
    math.randomseed(seed)
    pcall(vim.fn.srand, seed)
  end
end

---Stop virtualizing: the wrappers pass through again.
function Fake:stop()
  self.started = false
end

---Move the fake clock forward.
---@param ms number >= 0
function Fake:advance(ms)
  if type(ms) ~= "number" or ms < 0 then
    error("clock.advance: ms must be a number >= 0", 2)
  end
  if not self.started then
    error("clock.advance: the fake clock is not started (tag the case @clock or call start())", 2)
  end
  self.offset_ms = self.offset_ms + ms
end

---Fake epoch seconds (float) while started.
---@return number
function Fake:epoch()
  return self.base_epoch + self.offset_ms / 1000
end

---@class Testing.Guard.Clock
---@field h Testing.Guard.Handle
---@field cfg table
---@field clock Testing.Guard.Clock.Fake
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.Clock
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg, clock = new_fake(cfg.seed) }, G)
end

function G:install()
  local fake, p = self.clock, self.h.patcher
  local uv = vim.uv or vim.loop
  fake.orig = {
    time = os.time,
    clock = os.clock,
    date = os.date,
    uv_now = uv.now,
    uv_hrtime = uv.hrtime,
  }
  p:wrap(os, "time", function(orig)
    return function(t)
      if t == nil and fake.started then
        return math.floor(fake:epoch())
      end
      return orig(t)
    end
  end, "os.time")
  p:wrap(os, "clock", function(orig)
    return function()
      if fake.started then
        return fake.base_clock + fake.offset_ms / 1000
      end
      return orig()
    end
  end, "os.clock")
  p:wrap(os, "date", function(orig)
    return function(fmt, t)
      if t == nil and fake.started then
        return orig(fmt, math.floor(fake:epoch()))
      end
      return orig(fmt, t)
    end
  end, "os.date")
  p:wrap(uv, "now", function(orig)
    return function()
      if fake.started then
        return fake.base_now + math.floor(fake.offset_ms)
      end
      return orig()
    end
  end, "uv.now")
  p:wrap(uv, "hrtime", function(orig)
    return function()
      if fake.started then
        return fake.base_hr + math.floor(fake.offset_ms * 1e6)
      end
      return orig()
    end
  end, "uv.hrtime")
  p:wrap(uv, "gettimeofday", function(orig)
    return function()
      if fake.started then
        local e = fake:epoch()
        local sec = math.floor(e)
        return sec, math.floor((e - sec) * 1e6)
      end
      return orig()
    end
  end, "uv.gettimeofday")
  p:wrap(vim.fn, "localtime", function(orig)
    return function()
      if fake.started then
        return math.floor(fake:epoch())
      end
      return orig()
    end
  end, "vim.fn.localtime")
  p:wrap(vim.fn, "strftime", function(orig)
    return function(fmt, t)
      if t == nil and fake.started then
        return orig(fmt, math.floor(fake:epoch()))
      end
      return orig(fmt, t)
    end
  end, "vim.fn.strftime")
end

---@param ctx Testing.Guard.CaseCtx
function G:begin(ctx)
  if self.h:has_tag("clock") then
    self.clock:start()
  end
end

function G:finish()
  self.clock:stop()
end

function G:uninstall()
  self.clock:stop()
end

return M
