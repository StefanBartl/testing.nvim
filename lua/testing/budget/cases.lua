---@module 'testing.budget.cases'
---@brief The cases `testing budget` measures: the hot paths of a run, each a function that can be timed.
---@description
--- A case is `{ name, desc, kind, setup }`. `setup(ctx)` builds the fixture (not timed) and returns the
--- function that is timed plus an optional teardown. The sizes are the ones of the D.7 budget task and
--- can be shrunk through `ctx.sizes` (the specs run the real cases at toy size).
---
---   | case               | what is timed                                                              |
---   | doctor_startup     | `nvim -l scripts/testing.lua doctor` as a process: editor start to exit    |
---   | discover_100       | `testing.discover` over 100 spec files in 10 directories                   |
---   | ir_encode_10k      | `testing.core.result.encode` of an IR with 10 000 cases                    |
---   | history_append     | `testing.history.record` into a history that already holds 20 runs         |
---   | cache_hash_500     | read + `vim.fn.sha256` of 500 files of 2 KB (the work of a cache key)      |
---   | cache_key_100      | `testing.cache.key` of 100 spec files, each with a closure of 8 modules (warm index) |
---   | child_spawn_cold   | `testing.rpc.spawn`: a new editor to its first answer (the kill is not timed) |
---   | child_kill         | `child.kill()`: ending an editor with its whole process tree              |
---   | child_spawn_warm   | one call into an editor that is already running (what a pooled file saves) |
---
--- HONEST LABELS. `cache_hash_500` hashes a fixture with the plain primitive (`vim.fn.sha256`); it does
--- NOT go through the cache module's stat pre-check, which exists to avoid exactly this work, so it is
--- the cost of a cold, complete hash. `child_spawn_cold` cannot be OS-cold (the executable and the
--- libraries are in the file cache after the first start); it is the cost of a start with a warm file
--- cache, and with the antivirus scan the platform adds to every process start.

local M = {}

---@class Testing.Budget.Ctx
---@field self_dir string The testing.nvim checkout that is running.
---@field tmp fun(name: string): string A fresh scratch directory (removed after the case).
---@field sizes Testing.Budget.Sizes
---@field calls integer How many times the timed function is called (warm-up included).

---@class Testing.Budget.Sizes
---@field spec_files integer
---@field ir_cases integer
---@field history_cases integer
---@field hash_files integer
---@field key_specs integer

---@class Testing.Budget.Case
---@field name string
---@field desc string
---@field kind "inproc"|"process"
---@field setup fun(ctx: Testing.Budget.Ctx): fun(), (fun())?

---@type Testing.Budget.Sizes
M.SIZES =
  { spec_files = 100, ir_cases = 10000, history_cases = 1000, hash_files = 500, key_specs = 100 }

---@param path string
---@param text string
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---An IR with `n` passing cases, spread over files of 20 cases.
---@param n integer
---@return Testing.Result
local function build_result(n)
  local result = require("testing.core.result")
  local res =
    result.new({ root = "<REPO>", project_key = "budget@0000", nvim = "budget", os = "budget" })
  for i = 1, n do
    local c = result.new_case({
      file = ("TESTS/f%d_spec.lua"):format(math.floor((i - 1) / 20)),
      name = "case " .. i,
    })
    c.assertions[1] = { ok = true, kind = "eq" }
    c.duration_ms = 0.5
    result.add_case(res, result.finish_case(c))
  end
  result.finalize(res)
  return res
end
M.build_result = build_result

---@type Testing.Budget.Case[]
M.ALL = {
  {
    name = "doctor_startup",
    desc = "`testing doctor` as a process (editor start to exit)",
    kind = "process",
    setup = function(ctx)
      local script = ctx.self_dir .. "/scripts/testing.lua"
      return function()
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
            "doctor",
            ctx.self_dir,
          }, { text = true })
          :wait(60000)
        if res.code ~= 0 then
          error(
            ("testing doctor exited with %s: %s"):format(
              tostring(res.code),
              (res.stderr or ""):sub(1, 300)
            )
          )
        end
      end
    end,
  },
  {
    name = "discover_100",
    desc = "discovery of 100 spec files",
    kind = "inproc",
    setup = function(ctx)
      local root = ctx.tmp("discover")
      local n = ctx.sizes.spec_files
      for i = 1, n do
        write(
          ("%s/TESTS/d%d/s%d_spec.lua"):format(root, i % 10, i),
          "return function(H)\n  H.ok(true, 'x')\nend\n"
        )
      end
      local discover = require("testing.discover")
      return function()
        local disc = discover.discover(
          root,
          { roots = { "TESTS" }, dialect = "auto", spec_pattern = { "_spec%.lua$" } }
        )
        local ordered = discover.order(disc)
        if #ordered ~= n then
          error(("discovered %d of %d files"):format(#ordered, n))
        end
      end
    end,
  },
  {
    name = "ir_encode_10k",
    desc = "encoding the Result-IR of 10 000 cases",
    kind = "inproc",
    setup = function(ctx)
      local res = build_result(ctx.sizes.ir_cases)
      local result = require("testing.core.result")
      return function()
        local text, err = result.encode(res)
        if not text then
          error("encode failed: " .. tostring(err))
        end
      end
    end,
  },
  {
    name = "history_append",
    desc = "appending a run to a full history",
    kind = "inproc",
    setup = function(ctx)
      local state = ctx.tmp("history")
      local root = ctx.tmp("history-project")
      local history = require("testing.history")
      local res = build_result(ctx.sizes.history_cases)
      for _ = 1, history.MAX_RUNS do
        assert(history.record(root, res, {}, { state_dir = state }))
      end
      return function()
        local ok, err = history.record(root, res, {}, { state_dir = state })
        if not ok then
          error("history.record failed: " .. tostring(err))
        end
      end
    end,
  },
  {
    name = "cache_hash_500",
    desc = "reading and hashing 500 files of 2 KB (the work of a cache key)",
    kind = "inproc",
    setup = function(ctx)
      local root = ctx.tmp("hash")
      local paths = {}
      local body = string.rep("local x = 1 -- padding line of a spec file\n", 48)
      for i = 1, ctx.sizes.hash_files do
        local p = ("%s/f%d.lua"):format(root, i)
        write(p, body .. i)
        paths[#paths + 1] = p
      end
      return function()
        for _, p in ipairs(paths) do
          local f = assert(io.open(p, "rb"))
          local text = f:read("*a")
          f:close()
          vim.fn.sha256(text)
        end
      end
    end,
  },
  {
    name = "cache_key_100",
    desc = "the cache keys of 100 spec files with closures of 8 modules out of 40 shared ones (the index is warm)",
    kind = "inproc",
    setup = function(ctx)
      local root = vim.fs.normalize(ctx.tmp("keys"))
      -- 40 modules in a chain of five-module groups; every spec requires the head of one group
      for m = 1, 40 do
        local nxt = (m % 8 ~= 0) and ('require("bench.m%d")\n'):format(m + 1) or ""
        write(("%s/lua/bench/m%d.lua"):format(root, m), nxt .. "return { v = " .. m .. " }\n")
      end
      local specs = {}
      for i = 1, ctx.sizes.key_specs do
        local rel = ("TESTS/s%d_spec.lua"):format(i)
        write(
          root .. "/" .. rel,
          ('require("bench.m%d")\nreturn function(H) H.ok(true, "s%d") end\n'):format(
            (i % 5) * 8 + 1,
            i
          )
        )
        specs[#specs + 1] = rel
      end
      local cache = require("testing.cache")
      local hasher = require("testing.cache.hash").new()
      return function()
        -- a context per run: the memo of one run is not the next run's
        local c = {
          root = root,
          hasher = hasher,
          dep_roots = {},
          runner_version = "budget",
          nvim = "budget",
          config_digest = "budget",
          spec_roots = { "TESTS" },
          unresolved = "absent",
        }
        for _, rel in ipairs(specs) do
          assert(cache.key({ file = rel }, c))
        end
      end
    end,
  },
  {
    name = "child_spawn_cold",
    desc = "starting an embedded editor to its first answer (the kill is not timed)",
    kind = "process",
    setup = function(ctx)
      -- the child's `root` is where lib.nvim is looked up (a sibling checkout): this checkout, not a scratch dir
      local rpc = require("testing.rpc")
      local started = {}
      return function()
        local child, err = rpc.spawn({ root = ctx.self_dir })
        if not child then
          error("spawn failed: " .. tostring(err))
        end
        -- killing a process TREE on Windows asks the process table (a PowerShell start): that cost belongs
        -- to a different budget, so the editors are collected here and ended after the measurement
        started[#started + 1] = child
      end, function()
        for _, child in ipairs(started) do
          pcall(child.kill)
        end
      end
    end,
  },
  {
    name = "child_kill",
    desc = "ending an embedded editor with its process tree",
    kind = "process",
    setup = function(ctx)
      local rpc = require("testing.rpc")
      -- one editor per call of the timed function (warm-up included), started now
      local children = {}
      for i = 1, ctx.calls do
        local child, err = rpc.spawn({ root = ctx.self_dir })
        if not child then
          for _, c in ipairs(children) do
            pcall(c.kill)
          end
          error("spawn failed: " .. tostring(err))
        end
        children[i] = child
      end
      local n = 0
      return function()
        n = n + 1
        children[n].kill()
      end
    end,
  },
  {
    name = "child_spawn_warm",
    desc = "one call into an editor that is already running",
    kind = "process",
    setup = function(ctx)
      local child, err = require("testing.rpc").spawn({ root = ctx.self_dir })
      if not child then
        error("spawn failed: " .. tostring(err))
      end
      return function()
        if child.lua("return 1") ~= 1 then
          error("the warm editor answered something else")
        end
      end, function()
        child.kill()
      end
    end,
  },
}

---The case with this name.
---@param name string
---@return Testing.Budget.Case|nil
function M.find(name)
  for _, c in ipairs(M.ALL) do
    if c.name == name then
      return c
    end
  end
  return nil
end

return M
