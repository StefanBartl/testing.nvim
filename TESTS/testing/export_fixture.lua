-- TESTS/testing/export_fixture.lua -- the synthetic fleet behind the contract `testing-export/1`: three mini
-- repositories (green, red with a flaky and a stale file, without any result), a vault that is left out, their
-- state files, and the fakes the documents need to be byte-stable (clock, engine, key, head, git and GitHub of the
-- CI adapter). Never a real repository: everything below one temporary base directory.
--
-- Used by the export_*_spec files and by TESTS/golden/regenerate_export.lua.

local M = {}

---The golden files of the export form (an export folder, byte for byte).
M.GOLDEN_DIR = vim.fs.normalize(
  vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))) .. "/golden/testing-export-1"
)

M.NOW_ISO = "2026-10-31T12:00:00Z"
M.ENGINE = { version = "0.1.0-dev", git = "fixture", nvim = "0.0.0" }
M.TS = 1793448000 -- 2026-10-31T12:00:00Z
M.MTIME = 1793440000 -- the mtime of every spec file of the fixture

local json = require("lib.nvim.json.canonical")

---@param path string
---@param text string
function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

---A spec file with a fixed mtime, and its `files` entry of last.json.
---@param dir string
---@param rel string
---@param run string
---@return table
local function spec_file(dir, rel, run)
  local path = dir .. "/" .. rel
  M.write(path, "return function(H) end\n")
  assert(vim.uv.fs_utime(path, M.MTIME, M.MTIME))
  local st = require("testing.state").stat(dir, rel)
  return { mtime_ns = st.mtime_ns, size = st.size, run = run, ts = M.TS }
end

---Build the fleet below `base`.
---@param base string
---@return { root: string, state: string, alpha: string, beta: string, gamma: string, vault: string, home_file: string }
function M.build(base)
  local root = base .. "/fleet"
  local state = base .. "/state"
  local home = vim.fs.normalize(vim.uv.os_homedir())
  local function repo(name, workflows)
    local dir = root .. "/" .. name
    M.write(dir .. "/.testing.lua", "return { plugin = 'proj', minit = false }\n")
    if workflows then
      M.write(dir .. "/.github/workflows/ci.yml", "name: CI\n")
    end
    return dir
  end
  local alpha = repo("alpha.nvim", true)
  local beta = repo("beta.nvim", true)
  local gamma = repo("gamma.nvim", false)
  local vault = repo("notes-vault", true)
  local sdir = function(dir)
    return require("testing.history").dir(dir, { state_dir = state })
  end

  -- alpha: green, the last green run is this run (its commit is known)
  local run_a = "2026-10-31T11:00:00Z-aaaa"
  M.write(
    sdir(alpha) .. "/last.json",
    json.encode({
      v = 1,
      run = run_a,
      ts = M.TS - 3600,
      partial = false,
      files = {
        ["TESTS/a_spec.lua"] = spec_file(alpha, "TESTS/a_spec.lua", run_a),
        ["TESTS/b_spec.lua"] = spec_file(alpha, "TESTS/b_spec.lua", run_a),
      },
      cases = {
        {
          id = "TESTS/a_spec.lua::one",
          file = "TESTS/a_spec.lua",
          line = 3,
          status = "pass",
          duration_ms = 1.5,
          name = "one",
        },
        {
          id = "TESTS/a_spec.lua::two",
          file = "TESTS/a_spec.lua",
          line = 7,
          status = "pass",
          duration_ms = 2,
          name = "two",
        },
        {
          id = "TESTS/b_spec.lua",
          file = "TESTS/b_spec.lua",
          status = "pass",
          duration_ms = 10,
        },
      },
    })
  )
  M.write(
    sdir(alpha) .. "/last_green.json",
    json.encode({
      v = 1,
      ts = M.TS - 3600,
      run = run_a,
      sha = "a1b2c3d",
      dirty = json.object({}),
    })
  )
  M.write(
    sdir(alpha) .. "/ci.json",
    json.encode({
      schema = "testing-ci/1",
      repo = "alpha.nvim",
      commit = string.rep("a", 40),
      tree = string.rep("b", 40),
      dirty = false,
      profile = "full",
      partial = false,
      verdict = "green",
      first_red = vim.NIL,
      time = "2026-10-31T10:00:00Z",
      steps = {},
    })
  )

  -- beta: red; the messages name the repository and a file below the home directory; a flaky pass; one file of
  -- the result is gone (stale)
  local run_b = "2026-10-31T11:30:00Z-bbbb"
  local home_file = home .. "/secret-notes/beta.txt"
  M.write(
    sdir(beta) .. "/last.json",
    json.encode({
      v = 1,
      run = run_b,
      ts = M.TS - 1800,
      partial = false,
      files = {
        ["TESTS/x_spec.lua"] = spec_file(beta, "TESTS/x_spec.lua", run_b),
        ["TESTS/gone_spec.lua"] = { mtime_ns = "1", size = 1, run = run_b, ts = M.TS },
      },
      cases = {
        {
          id = "TESTS/x_spec.lua::parser::reads a file",
          file = "TESTS/x_spec.lua",
          line = 12,
          status = "fail",
          duration_ms = 4,
          describe = { "parser" },
          name = "reads a file",
          message = beta .. "/lua/beta/parser.lua:40: cannot open " .. home_file,
          expected = "line one\nline two",
          actual = "line one\nline 2",
          fails = {
            { line = 14, msg = "expected 'b' got 'c' in " .. beta .. "/lua/beta/parser.lua" },
          },
        },
        {
          id = "TESTS/x_spec.lua::parser::times out",
          file = "TESTS/x_spec.lua",
          line = 30,
          status = "timeout",
          duration_ms = 5000,
          describe = { "parser" },
          name = "times out",
          message = "the case ran longer than 5000 ms",
        },
        {
          id = "TESTS/x_spec.lua::parser::flaky",
          file = "TESTS/x_spec.lua",
          line = 50,
          status = "pass",
          duration_ms = 3,
          flaky = true,
          describe = { "parser" },
          name = "flaky",
        },
        {
          id = "TESTS/gone_spec.lua",
          file = "TESTS/gone_spec.lua",
          status = "skip",
          duration_ms = 0,
          message = "skipped",
        },
      },
    })
  )
  M.write(
    sdir(beta) .. "/ci.json",
    json.encode({
      schema = "testing-ci/1",
      repo = "beta.nvim",
      commit = string.rep("c", 40),
      tree = string.rep("d", 40),
      dirty = true,
      profile = "fast",
      partial = true,
      verdict = "red",
      first_red = "suite",
      time = "2026-10-31T11:40:00Z",
      steps = {},
    })
  )
  -- the vault has a state too: it must not show up anywhere
  M.write(sdir(vault) .. "/ci.json", json.encode({ schema = "testing-ci/1", verdict = "red" }))
  return {
    root = root,
    state = state,
    alpha = alpha,
    beta = beta,
    gamma = gamma,
    vault = vault,
    home_file = home_file,
  }
end

---The GitHub answers of the CI adapter (`testing.ci.remote`), by API path.
local R = "/repos/fixture-owner/"
local function run_(id, status, conclusion)
  return {
    id = id,
    name = "CI",
    status = status,
    conclusion = conclusion,
    html_url = "https://github.com/fixture-owner/x/actions/runs/" .. id,
    created_at = "2026-10-31T11:00:00Z",
    updated_at = "2026-10-31T11:10:00Z",
    event = "push",
    run_attempt = 1,
    head_sha = string.rep("e", 40),
  }
end
local function job_(id, name, conclusion)
  return {
    id = id,
    name = name,
    status = "completed",
    conclusion = conclusion,
    html_url = "https://github.com/fixture-owner/x/actions/runs/1/job/" .. id,
    labels = {},
    created_at = "2026-10-31T11:00:00Z",
    started_at = "2026-10-31T11:01:00Z",
    completed_at = "2026-10-31T11:05:00Z",
  }
end
M.API = {
  [R .. "alpha.nvim/actions/runs"] = { workflow_runs = { run_(11, "completed", "success") } },
  [R .. "alpha.nvim/actions/runs/11/jobs"] = {
    jobs = {
      job_(111, "test (ubuntu-latest)", "success"),
      job_(112, "test (windows-latest)", "success"),
      job_(113, "test (macos-latest)", "success"),
    },
  },
  [R .. "beta.nvim/actions/runs"] = { workflow_runs = { run_(22, "completed", "failure") } },
  [R .. "beta.nvim/actions/runs/22/jobs"] = {
    jobs = {
      job_(221, "test (ubuntu-latest)", "success"),
      job_(222, "test (windows-latest)", "failure"),
    },
  },
}

---The fakes: a fixed clock and engine, a key that does not depend on where the fixture lives, a fixed head per
---repository, and the git and GitHub of the CI adapter. Returns the function that puts everything back.
---@param opts? { remote_fail?: string, no_clock?: boolean }
---@return fun() restore
function M.install(opts)
  opts = opts or {}
  local export = require("testing.export")
  local remote = require("testing.ci.remote")
  local saved = {
    clock = export.clock,
    engine_info = export.engine_info,
    key = export.deps.key,
    head = export.deps.head,
    remote_deps = remote.deps,
  }
  if not opts.no_clock then
    export.clock = function()
      return M.NOW_ISO
    end
  end
  export.engine_info = function()
    return vim.deepcopy(M.ENGINE)
  end
  export.deps.key = function(dir)
    local name = vim.fs.basename(dir)
    return name .. "-" .. vim.fn.sha256("fixture:" .. name):sub(1, 12)
  end
  local HEADS = {
    ["alpha.nvim"] = { sha = string.rep("1", 40), branch = "main", dirty = false },
    ["beta.nvim"] = { sha = string.rep("2", 40), branch = "feature/x", dirty = true },
  }
  export.deps.head = function(dir)
    return vim.deepcopy(HEADS[vim.fs.basename(dir)])
  end
  local function git(dir, args)
    local name = vim.fs.basename(dir)
    local res
    if args[1] == "remote" then
      if name == "gamma.nvim" then
        res = { code = 2, stdout = "", stderr = "no such remote" }
      else
        res = { code = 0, stdout = "https://github.com/fixture-owner/" .. name .. ".git\n" }
      end
    else
      res = { code = 0, stdout = string.rep("e", 40) .. "\nfixture commit\n" }
    end
    return {
      wait = function()
        return res
      end,
    }
  end
  local function transport(url, copts, done)
    if opts.remote_fail then
      return done(false, opts.remote_fail)
    end
    local path = url:gsub("^https://api%.github%.com", "")
    local body = M.API[path]
    if not body then
      return done(
        true,
        { status = 404, status_text = "Not Found", headers = {}, body = '{"message":"Not Found"}' }
      )
    end
    done(true, {
      status = 200,
      status_text = "OK",
      headers = { etag = '"' .. vim.fn.sha256(path):sub(1, 8) .. '"' },
      body = vim.json.encode(body),
    })
  end
  remote.deps = {
    git = git,
    transport = transport,
    now = function()
      return M.TS
    end,
    token = function()
      return "fixture-token", "env:" .. remote.TOKEN_ENV
    end,
  }
  return function()
    export.clock = saved.clock
    export.engine_info = saved.engine_info
    export.deps.key = saved.key
    export.deps.head = saved.head
    remote.deps = saved.remote_deps
  end
end

---The export options of the fixture fleet.
---@param fx table What `build` returned.
---@param extra? table
---@return Testing.Export.Opts
function M.opts(fx, extra)
  return vim.tbl_extend("force", {
    repos_roots = { fx.root },
    state_dir = fx.state,
    remote = true,
  }, extra or {})
end

---A fresh base directory.
---@param tag string
---@return string
function M.base(tag)
  local dir = vim.fs.normalize(vim.fn.tempname()) .. "-" .. tag
  vim.fn.mkdir(dir, "p")
  return dir
end

return M
