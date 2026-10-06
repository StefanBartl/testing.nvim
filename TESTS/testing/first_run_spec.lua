-- TESTS/testing/first_run_spec.lua -- the test-environment default `disable_first_run`: every editor the
-- runner starts (a real child, and the editor of an in-process run) gets lib.nvim's
-- `vim.g.lib_nvim_deps_disable_first_run = true` BEFORE the project's minit, so the one-time
-- "missing tools" float of an empty stdpath('cache') cannot change windows or buffers inside a spec.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local GLOBAL = "lib_nvim_deps_disable_first_run"
  local options = require("testing.run.options")
  local project_cfg = require("testing.config.project")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")

  -- the outer run (this very repo) has already applied the default: look at it from a clean slate
  local outer = vim.g[GLOBAL]
  vim.g[GLOBAL] = nil

  -- ===================================================================
  -- 1. config contract: key, default, validation
  local defaults = require("testing.config.DEFAULTS").project
  eq(defaults.disable_first_run, true, "DEFAULTS: disable_first_run is on")
  local cfg, problems = project_cfg.validate({})
  eq(cfg.disable_first_run, true, "validate: default true")
  eq(problems, {}, "validate: no problem")
  cfg = project_cfg.validate({ disable_first_run = false })
  eq(cfg.disable_first_run, false, "validate: false is accepted")
  cfg, problems = project_cfg.validate({ disable_first_run = "no" })
  eq(cfg.disable_first_run, true, "validate: a non-boolean keeps the default")
  ok(
    #problems == 1 and problems[1]:find("disable_first_run", 1, true) ~= nil,
    "validate: the invalid value is named: " .. vim.inspect(problems)
  )
  eq(options.of({}).disable_first_run, true, "options.of: default on")
  eq(
    options.of({ project = { disable_first_run = false } }).disable_first_run,
    false,
    "options.of: the config switches it off"
  )

  -- ===================================================================
  -- 2. apply_first_run_default: sets when unset, restores, never overrides the user
  local restore = options.apply_first_run_default(true)
  eq(vim.g[GLOBAL], true, "apply: set when the user has not decided")
  restore()
  eq(vim.g[GLOBAL], nil, "restore: put back")
  restore = options.apply_first_run_default(false)
  eq(vim.g[GLOBAL], nil, "disabled: untouched")
  restore()
  vim.g[GLOBAL] = false
  restore = options.apply_first_run_default(true)
  eq(vim.g[GLOBAL], false, "an explicit user value wins")
  restore()
  eq(vim.g[GLOBAL], false, "and is not restored away")
  vim.g[GLOBAL] = nil

  -- ===================================================================
  -- 3. a real child: the variable is set before the minit and the spec, on an empty cache
  local MINIT = "vim.g.__seen_by_minit = vim.g.lib_nvim_deps_disable_first_run\n"
  local PROBE = [==[
return function(H)
  local cache = vim.fn.stdpath("cache")
  local files = vim.fn.glob(cache .. "/**", false, true)
  local f = assert(io.open("probe.json", "wb"))
  f:write(vim.json.encode({
    flag = vim.g.lib_nvim_deps_disable_first_run,
    minit_saw = vim.g.__seen_by_minit,
    cache_files = #files,
    wins = #vim.api.nvim_tabpage_list_wins(0),
  }))
  f:close()
  H.ok(true, "probe written")
end
]==]
  ---@param root string
  ---@return table
  local function probe(root)
    return vim.json.decode(S.slurp(root .. "/probe.json") or "{}", { luanil = { object = true } })
  end
  local root = S.new_root()
  S.write(root .. "/TESTS/minimal_init.lua", MINIT)
  local entries = S.project(root, { ["TESTS/probe_spec.lua"] = PROBE }, { "TESTS/probe_spec.lua" })
  local rep = S.run(root, entries, { minit = root .. "/TESTS/minimal_init.lua" })
  local c = S.case_of(rep, "TESTS/probe_spec.lua")
  eq(c and c.status, "pass", "the probe passes in a child: " .. vim.inspect(c))
  local info = probe(root)
  eq(info.flag, true, "child: lib.nvim's first-run popup is disabled for the spec")
  eq(info.minit_saw, true, "child: ... already when the project's minit runs")
  eq(info.cache_files, 0, "child: stdpath('cache') is empty (this is the first-run situation)")
  eq(info.wins, 1, "child: one window")

  vim.fn.delete(root .. "/probe.json")
  S.run(root, entries, {
    minit = root .. "/TESTS/minimal_init.lua",
    options = { disable_first_run = false },
  })
  info = probe(root)
  eq(info.flag, nil, "child: disable_first_run = false leaves the variable alone")
  eq(info.minit_saw, nil, "child: ... also for the minit")

  -- ===================================================================
  -- 4. in-process (`testing run` through cli.main): same default, restored afterwards
  local cli = require("testing.cli")
  local function go(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = vim.fs.normalize(vim.fn.tempname()),
      color = false,
    })
    return code, table.concat(out, "\n") .. "\n" .. table.concat(err, "\n")
  end
  local IN_SPEC = [==[
return function(H)
  H.eq(_G.__first_run_minit, true, "the minit saw the opt-out")
  H.eq(vim.g.lib_nvim_deps_disable_first_run, true, "the spec sees it")
end
]==]
  local iroot = S.new_root()
  S.write(iroot .. "/TESTS/minimal_init.lua", "_G.__first_run_minit = vim.g." .. GLOBAL .. "\n")
  S.write(iroot .. "/TESTS/a_spec.lua", IN_SPEC)
  local code, text = go({ iroot })
  _G.__first_run_minit = nil
  eq(code, 0, "in-process: the spec saw the opt-out in minit and in the spec\n" .. text)
  eq(vim.g[GLOBAL], nil, "in-process: the editor's global is restored after the run")

  S.write(iroot .. "/.testing.lua", "return { disable_first_run = false }\n")
  code, text = go({ iroot })
  _G.__first_run_minit = nil
  eq(code, 1, "in-process: disable_first_run = false -> the spec no longer sees it\n" .. text)
  eq(vim.g[GLOBAL], nil, "in-process: still nothing set")

  S.cleanup()
  vim.g[GLOBAL] = outer
end
