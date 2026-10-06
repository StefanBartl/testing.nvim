-- TESTS/testing/health_spec.lua -- `:checkhealth testing` resolves, reports without errors, and its
-- levels agree with its text for every failure it can detect.
---@diagnostic disable: duplicate-set-field

return function(H)
  local ok = H.ok
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end

  ---Run `:checkhealth testing` and return the report text.
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
  local tmp = vim.fn.tempname() .. "-health"
  vim.fn.mkdir(tmp, "p")
  health.project_dir = function()
    return tmp
  end

  ---@param body string|nil Content of `.testing.lua` in the fixture directory (nil: no file).
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
    -- 1. The normal report ------------------------------------------------------------------
    with_config(nil)
    local text = report()
    has(text, "testing.nvim", "the report has the plugin's section")
    has(text, "lib.nvim.notify", "the report lists the lib.nvim modules")
    has(text, "testing.core.result", "the report lists the kernel modules")
    has(text, "lib.nvim.json", "the report lists the primitives the kernel needs")
    has(text, "dialects: a, b, c, d, h, busted", "the report lists every dialect")
    has(text, "reporters: github, junit, term", "the report lists every reporter")
    has(text, "safe_call keeps non-string errors", "the report probes safe_call")
    has(text, "no .testing.lua in", "no .testing.lua is an info, not a problem")
    lacks(text, "ERROR", "a healthy setup holds no error:\n" .. text)

    -- 2. An old lib.nvim (module missing): name the module and the commit that is needed -------
    local mod = "lib.nvim.fs.write.atomic"
    local saved_loaded, saved_preload = package.loaded[mod], package.preload[mod]
    package.loaded[mod] = nil
    package.preload[mod] = function()
      error("simulated: module not found")
    end
    local old_text = report()
    package.loaded[mod], package.preload[mod] = saved_loaded, saved_preload
    has(old_text, mod .. " missing", "an old lib.nvim: the report names the missing module")
    has(old_text, "6304829", "an old lib.nvim: the report names the lib.nvim commit that is needed")
    has(old_text, "ERROR", "an old lib.nvim is an error, not a warning")

    -- 3. A safe_call that loses non-string errors: an error, with the commit ---------------------
    local emod = "lib.lua.error"
    local saved_e = package.loaded[emod]
    package.loaded[emod] = {
      safe_call = function()
        return false, "flattened to a string"
      end,
    }
    local lossy_text = report()
    package.loaded[emod] = saved_e
    has(lossy_text, "loses non-string errors", "a lossy safe_call is named")
    has(lossy_text, "89cb912", "a lossy safe_call names the lib.nvim commit that fixes it")
    has(lossy_text, "ERROR", "a lossy safe_call is an error")

    -- 4. .testing.lua: valid, invalid values, syntax error, needs more than a table ---------------
    with_config('return { dialect = "auto", roots = { "TESTS" } }\n')
    local valid_text = report()
    has(valid_text, ".testing.lua is valid", "a valid .testing.lua is reported valid")
    lacks(valid_text, "ERROR", "a valid .testing.lua holds no error")
    lacks(valid_text, "WARNING", "a valid .testing.lua holds no warning")

    with_config('return { dialect = "nope", frobnicate = 1 }\n')
    local bad_text = report()
    has(bad_text, "2 problem(s)", "the number of problems is reported")
    has(bad_text, "dialect", "the invalid key is named")
    has(bad_text, "frobnicate", "the unknown key is named")
    has(bad_text, "WARNING", "invalid keys are a warning (the defaults stay in place)")
    lacks(bad_text, "ERROR", "invalid keys are not an error")

    with_config("return { dialect = \n")
    local syntax_text = report()
    has(syntax_text, ".testing.lua cannot be loaded", "a syntax error is reported")
    has(syntax_text, "ERROR", "a syntax error is an error")

    -- 5. A file that is more than a table is NOT executed by :checkhealth -------------------------
    local marker = tmp .. "/executed.marker"
    vim.fn.delete(marker)
    local marker_lua = marker:gsub("\\", "/")
    with_config(
      ('local f = io.open("%s", "wb"); f:write("x"); f:close(); return { dialect = "auto" }\n'):format(
        marker_lua
      )
    )
    local code_text = report()
    ok(vim.uv.fs_stat(marker) == nil, "the sandbox must not let .testing.lua write a file")
    has(code_text, "was not evaluated here", "a file that needs io is not evaluated")
    has(code_text, "testing doctor", "the report names the command that does evaluate it")
    lacks(code_text, "ERROR", "an unevaluated file is not an error")
    lacks(code_text, ".testing.lua is valid", "an unevaluated file is never reported valid")

    with_config("while true do end\n")
    local t0 = vim.uv.hrtime()
    local loop_text = report()
    local took_ms = (vim.uv.hrtime() - t0) / 1e6
    has(loop_text, "instruction budget", "an endless loop stops at the budget")
    ok(took_ms < 20000, ("an endless loop must end quickly (took %d ms)"):format(took_ms))

    -- 6. Dependency resolution: an override that points nowhere is a warning, never silent --------
    with_config(nil)
    local saved_env = vim.env.LIB_NVIM_DIR
    vim.env.LIB_NVIM_DIR = tmp .. "/does-not-exist"
    local dep_text = report()
    vim.env.LIB_NVIM_DIR = saved_env
    has(dep_text, "not in any of the places", "a missing lib.nvim checkout is reported")
    has(dep_text, "LIB_NVIM_DIR", "the report names the override variable")
    has(dep_text, "WARNING", "an unresolvable command-line dependency is a warning")
    lacks(dep_text, "ERROR", "the plugin itself still works, so it is not an error")
  end)

  health.project_dir = real_project_dir
  vim.fn.delete(tmp, "rf")
  if not finished then
    error(failure, 0)
  end
end
