-- TESTS/testing/pool_run_support.lua -- helpers of the pool_run_*_spec files (real warm-pool members through
-- `testing.run.isolated`): run a project through the real driver, collect findings, files that litter the editor.
-- Loaded with dofile by the specs; it is not a spec itself (no `_spec` suffix).

---@param H table The harness the runner hands to the spec.
---@return table P
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local options_mod = require("testing.run.options")

  ---Run `files` (rel -> body, in `order`) through the real isolated driver.
  ---@param files table<string, string>
  ---@param order string[]
  ---@param cfg? { reuse?: boolean, size?: integer, jobs?: integer, guards?: table, extra?: table, dialect?: string }
  ---@return Testing.Inproc.Report report
  ---@return string root
  local function run(files, order, cfg)
    cfg = cfg or {}
    local root = S.new_root()
    local entries = S.project(root, files, order, cfg.dialect)
    local o = options_mod.of({
      project = {
        isolated = "file",
        pool = { reuse = cfg.reuse ~= false, size = cfg.size or 0 },
        guards = cfg.guards,
      },
      args = { jobs = cfg.jobs or 1 },
    })
    o.host_given = false
    local extra = vim.tbl_extend("force", {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      guard_cfg = options_mod.guard_config(o, { root = root }),
    }, cfg.extra or {})
    return S.run(root, entries, extra), root
  end

  ---Findings of the guard `name` over the whole report.
  ---@param report table
  ---@param name string
  ---@return Testing.Result.GuardFinding[]
  local function findings(report, name)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      for _, g in ipairs(c.guards or {}) do
        if g.guard == name then
          out[#out + 1] = g
        end
      end
    end
    return out
  end

  ---Files i = 1..n. File i leaves EVERYTHING it can behind (a global, a `vim.g` key, a loaded module,
  ---an autocmd group, a user command, a mapping, a buffer, an option, an environment variable, the
  ---working directory) and asserts that it sees nothing of the files before it.
  ---@param n integer
  ---@return table<string, string> files
  ---@return string[] order
  local function leaky_files(n)
    local files, order = {}, {}
    for i = 1, n do
      local rel = ("TESTS/leak%d_spec.lua"):format(i)
      order[#order + 1] = rel
      files[rel] = ([==[
return function(H)
  local me = %d
  for j = 1, me - 1 do
    H.ok(_G["LEAK_" .. j] == nil, "global of file " .. j .. " is gone")
    H.ok(vim.g["leak_g" .. j] == nil, "vim.g key of file " .. j .. " is gone")
    H.ok(package.loaded["leak_mod_" .. j] == nil, "module of file " .. j .. " is gone")
    H.ok(vim.fn.exists(":LeakCmd" .. j) == 0, "command of file " .. j .. " is gone")
    H.ok(vim.fn.mapcheck("<F" .. (j + 4) .. ">", "n") == "", "mapping of file " .. j .. " is gone")
    H.ok(vim.env["LEAK_ENV_" .. j] == nil, "environment variable of file " .. j .. " is gone")
    local found = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "BufEnter" })) do
      if a.group_name == "LeakGroup" .. j then
        found = found + 1
      end
    end
    H.ok(found == 0, "autocmd group of file " .. j .. " is gone")
  end
  H.ok(#vim.api.nvim_list_bufs() == 1, "one buffer at the start of file " .. me)
  H.ok(#vim.api.nvim_list_wins() == 1, "one window at the start of file " .. me)
  H.ok(vim.fn.getcwd() == vim.uv.cwd(), "cwd consistent")
  H.ok(vim.o.tabstop == 8, "options are back (file " .. me .. ")")

  _G["LEAK_" .. me] = true
  vim.g["leak_g" .. me] = me
  package.loaded["leak_mod_" .. me] = { me = me }
  vim.api.nvim_create_user_command("LeakCmd" .. me, function() end, {})
  vim.keymap.set("n", "<F" .. (me + 4) .. ">", "<Nop>")
  vim.env["LEAK_ENV_" .. me] = "x"
  local group = vim.api.nvim_create_augroup("LeakGroup" .. me, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, callback = function() end })
  vim.cmd("enew")
  vim.cmd("vsplit")
  vim.o.tabstop = 3 + me
  H.ok(true, "file " .. me .. " ran")
end
]==]):format(i)
    end
    return files, order
  end

  ---Statuses per file, in IR order.
  ---@param rep table
  ---@return string[]
  local function statuses(rep)
    return S.statuses(rep)
  end

  return {
    ok = ok,
    eq = eq,
    has = has,
    S = S,
    options_mod = options_mod,
    run = run,
    findings = findings,
    leaky_files = leaky_files,
    statuses = statuses,
  }
end
