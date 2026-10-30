-- TESTS/testing/surface_collect_deps_spec.lua -- `testing surface` starts its child editor with the
-- environment the project's minit needs: `$<NAME>_DIR` of every dependency of `.testing.lua` (`deps`),
-- `REPOS_DIR` and the project's `env_allow`; and a minit that fails names its reason in the error.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/surface_support.lua")
  local surface = require("testing.surface")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- a minit that finds its dependency ONLY through `$FXDEP_NVIM_DIR` (no `.deps/`, not beside the
  -- project) and reads `REPOS_DIR` and `FX_EXTRA`; it fails loudly when one is missing
  local MINIT = [==[
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))
local lib = vim.env.LIB_NVIM_DIR
if lib and lib ~= "" then
  vim.opt.rtp:append(lib)
end
local dep = os.getenv("FXDEP_NVIM_DIR")
if not dep or dep == "" then
  error("FXDEP_NVIM_DIR is not set in the child")
end
vim.opt.rtp:append(dep)
vim.g.fx_repos_dir = os.getenv("REPOS_DIR") or ""
vim.g.fx_extra = os.getenv("FX_EXTRA") or ""
]==]

  local saved = {
    FXDEP_NVIM_DIR = vim.env.FXDEP_NVIM_DIR,
    REPOS_DIR = vim.env.REPOS_DIR,
    FX_EXTRA = vim.env.FX_EXTRA,
  }
  local function restore()
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
  end

  S.run(function()
    local root = S.fixture()
    write(root .. "/TESTS/minimal_init.lua", MINIT)
    -- the dependency lives in a directory of its own, reachable only through its variable
    local depdir = S.new_dir() .. "/elsewhere/fxdep.nvim"
    write(depdir .. "/lua/fxdep/init.lua", "return { marker = 'fxdep' }\n")
    local repos = S.new_dir() .. "/repos"
    vim.fn.mkdir(repos, "p")

    local okr, err = pcall(function()
      vim.env.FXDEP_NVIM_DIR = depdir
      vim.env.REPOS_DIR = repos
      vim.env.FX_EXTRA = "extra-value"
      local got, cerr = surface.collect(root, {
        plugin = "fxsurf",
        minit = root .. "/TESTS/minimal_init.lua",
        deps = { "fxdep.nvim" },
        env_allow = { "FX_EXTRA" },
      })
      ok(
        got ~= nil,
        "the surface is read with a dependency reachable only via $FXDEP_NVIM_DIR: "
          .. tostring(cerr)
      )
      ok(type(got.entries) == "table" and #got.entries > 0, "the surface has entries")

      -- read back what the child saw: the spawn seam wraps the real spawn
      local seen
      local spawn = require("testing.rpc").spawn
      got, cerr = surface.collect(root, {
        plugin = "fxsurf",
        minit = root .. "/TESTS/minimal_init.lua",
        deps = { "fxdep.nvim" },
        env_allow = { "FX_EXTRA" },
        spawn = function(o)
          local child, serr = spawn(o)
          if child then
            seen = child.lua(
              "return { repos = vim.g.fx_repos_dir, extra = vim.g.fx_extra, dep = os.getenv('FXDEP_NVIM_DIR') }"
            )
          end
          return child, serr
        end,
      })
      ok(got ~= nil, "second read: " .. tostring(cerr))
      ok(type(seen) == "table", "the child answered")
      ok(
        vim.fs.normalize(seen.dep or ""):lower() == vim.fs.normalize(depdir):lower(),
        "$FXDEP_NVIM_DIR reaches the child: " .. vim.inspect(seen)
      )
      ok(
        vim.fs.normalize(seen.repos or ""):lower() == vim.fs.normalize(repos):lower(),
        "REPOS_DIR reaches the child: " .. vim.inspect(seen)
      )
      ok(seen.extra == "extra-value", "an env_allow name reaches the child: " .. vim.inspect(seen))

      -- the minit fails: the error names the reason, not only that the child did not start
      vim.env.FXDEP_NVIM_DIR = nil
      got, cerr = surface.collect(root, {
        plugin = "fxsurf",
        minit = root .. "/TESTS/minimal_init.lua",
        deps = {},
      })
      ok(got == nil, "a failing minit fails the read")
      has(cerr, "FXDEP_NVIM_DIR is not set in the child", "the error names the reason of the child")
    end)
    restore()
    if not okr then
      error(err, 0)
    end
  end)

  -- the report passes `env_allow` of `.testing.lua` on to the collector
  local passed
  surface.report(S.repo, {
    config = { plugin = "fxsurf", deps = { "fxdep.nvim" }, env_allow = { "FX_EXTRA" } },
    collect = function(_, o)
      passed = o
      return nil, "stop"
    end,
  })
  ok(
    passed and vim.deep_equal(passed.env_allow, { "FX_EXTRA" }),
    "report hands env_allow to collect"
  )
end
