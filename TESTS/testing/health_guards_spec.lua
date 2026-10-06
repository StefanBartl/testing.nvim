-- TESTS/testing/health_guards_spec.lua -- the "guards and warm pool" section of `:checkhealth testing`: it reports
-- the guard modes and the pool the PROJECT configures (read from its `.testing.lua`), says so when every
-- guard is off, and a module of the isolation machinery that does not load is an error.
---@diagnostic disable: duplicate-set-field

return function(H)
  local ok = H.ok
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (got " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  ---@return string
  local function report()
    local ran, err = pcall(function()
      vim.cmd("checkhealth testing")
    end)
    ok(ran, "`:checkhealth testing` runs: " .. tostring(err))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    -- the report opens a tab with a buffer of its own: close both, the editor is left as found
    pcall(function()
      vim.cmd("silent! bwipeout!")
    end)
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(function()
        vim.cmd("silent! tabclose")
      end)
    end
    return text
  end

  local health = require("testing.health")
  local real_project_dir = health.project_dir
  local tmp = vim.fn.tempname() .. "-healthg"
  vim.fn.mkdir(tmp, "p")
  health.project_dir = function()
    return tmp
  end

  ---@param body string|nil
  local function with_config(body)
    local path = tmp .. "/.testing.lua"
    vim.fn.delete(path)
    if body then
      local fh = assert(io.open(path, "wb"))
      fh:write(body)
      fh:close()
    end
  end

  local finished, failure = pcall(function()
    -- 1. defaults: the guards are on, the pool is off, and the report says what that means
    with_config(nil)
    local text = report()
    has(text, "guards and warm pool", "the section exists")
    has(text, "the guard layer, the child drivers and the pool load", "the modules load")
    has(
      text,
      "guards: fs=warn state=warn scheduled_error=error prompt=error",
      "default guard modes are listed"
    )
    has(text, "clock=off", "the clock guard is opt-in")
    has(text, "warm pool: off", "the pool is off by default and the report says how to turn it on")
    has(text, "--pool-reuse", "...naming the flag")
    lacks(text, "every guard is off", "no warning while the guards are on")

    -- 2. the project's `.testing.lua` decides: pool on, a guard changed, an allowance counted
    with_config([[return {
  pool = { reuse = true, size = 3 },
  jobs = 6,
  guards = { fs = "error", process_net = "warn" },
  guard_allow = { fs = { "/tmp/x" }, spawn = { "git", "rg" }, network = {} },
}]])
    text = report()
    has(text, "warm pool: on (up to 3 editor(s) at a time", "the pool size of the project")
    has(text, "fs=error", "the project's guard mode")
    has(text, "process_net=warn", "the project's other guard mode")
    has(
      text,
      "1 path(s) for writes, 2 executable(s), 0 host(s)",
      "what is allowed on purpose is counted"
    )

    -- the default size is min(jobs, 4); one job keeps one editor and says so
    with_config("return { pool = { reuse = true }, jobs = 8 }")
    has(report(), "up to 4 editor(s) at a time", "default pool size: min(jobs, 4)")
    with_config("return { pool = { reuse = true } }")
    text = report()
    has(text, "up to 1 editor(s) at a time", "jobs = 1: one editor")
    has(text, "raise `jobs`", "...and the report names the way to more")

    -- 3. every guard off is a warning (the leaks of the fleet stay invisible)
    with_config([[return { guards = {
  fs = "off", state = "off", scheduled_error = "off", prompt = "off", deprecation = "off", process_net = "off", clock = false,
} }]])
    text = report()
    has(text, "every guard is off", "all guards off is called out")
    has(text, "WARNING", "...as a warning")

    -- 4. a module of the machinery that does not load is an error that names it
    with_config(nil)
    local mod = "testing.run.pool"
    local saved_loaded, saved_preload = package.loaded[mod], package.preload[mod]
    package.loaded[mod] = nil
    package.preload[mod] = function()
      error("simulated: broken")
    end
    local broken = report()
    package.loaded[mod], package.preload[mod] = saved_loaded, saved_preload
    has(broken, "testing.run.pool failed to load", "a module that does not load is named")
    has(broken, "ERROR", "...as an error")
  end)

  health.project_dir = real_project_dir
  vim.fn.delete(tmp, "rf")
  if not finished then
    error(failure, 0)
  end
end
