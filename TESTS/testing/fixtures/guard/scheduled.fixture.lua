---@diagnostic disable: param-type-mismatch
-- Scenarios of the scheduled-error guard (RED: an error nobody sees, GREEN: callbacks that work).
-- Run by TESTS/testing/guard_scheduled_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")
local uv = vim.uv

local function only_sched(extra)
  ---@type table<string, any>
  local g = { scheduled_error = vim.tbl_extend("force", { mode = "error" }, extra or {}) }
  for _, name in ipairs({ "fs", "state", "prompt", "deprecation", "process_net", "clock" }) do
    g[name] = "off"
  end
  return { guards = g }
end

B.case("red_schedule_callback", {
  cfg = only_sched(),
  body = function()
    -- no wait here: `check` settles the loop itself
    vim.schedule(function()
      error("boom-sched")
    end)
  end,
})

B.case("red_luv_timer", {
  cfg = only_sched(),
  body = function()
    local t = assert(uv.new_timer())
    t:start(1, 0, function()
      t:close()
      error("boom-timer")
    end)
    vim.wait(150)
  end,
})

B.case("red_schedule_made_before_the_window", {
  cfg = only_sched(),
  setup = function()
    vim.schedule(function()
      error("boom-early")
    end)
  end,
  body = function()
    vim.wait(50)
  end,
})

B.case("red_error_in_autocmd", {
  cfg = only_sched(),
  body = function()
    vim.cmd("autocmd User GuardFx lua error('boom-autocmd')")
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "GuardFx" })
    vim.cmd("autocmd! User GuardFx")
  end,
})

B.case("red_notify_error", {
  cfg = only_sched({ notify = "error" }),
  body = function()
    vim.notify("kaput-notify", vim.log.levels.ERROR)
  end,
})

B.case("info_notify_error_default", {
  cfg = only_sched(),
  body = function()
    vim.notify("expected user error", vim.log.levels.ERROR)
    vim.notify("just info", vim.log.levels.INFO)
  end,
})

B.case("green_callbacks_work", {
  cfg = only_sched(),
  body = function()
    local hits = 0
    vim.schedule(function()
      hits = hits + 1
    end)
    local t = assert(uv.new_timer())
    t:start(1, 0, function()
      t:close()
      hits = hits + 1
    end)
    vim.wait(100, function()
      return hits == 2
    end)
    assert(hits == 2, "callbacks did not run")
    pcall(error, "caught on purpose")
    local ok = pcall(vim.cmd, "lua error('caught too')")
    assert(not ok)
  end,
})

B.case("green_allow_pattern", {
  cfg = only_sched({ allow_patterns = { "expected%-boom" } }),
  body = function()
    vim.schedule(function()
      error("expected-boom on purpose")
    end)
  end,
})

B.finish()
