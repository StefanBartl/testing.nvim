-- TESTS/testing/deps_spec.lua -- testing.deps: the four places in order, the override that decides
-- alone, and a failure message that names all four.
---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local deps = require("testing.deps")

  eq(deps.env_name("lib.nvim"), "LIB_NVIM_DIR", "env name of lib.nvim")
  eq(deps.env_name("testing.nvim"), "TESTING_NVIM_DIR", "env name of testing.nvim")
  eq(deps.env_name("runtime-analysis"), "RUNTIME_ANALYSIS_DIR", "dashes become underscores")
  for _, bad in ipairs({ "", "a/b", "a\\b", "..", "a..b", ".hidden", "a b", "a;b" }) do
    eq(deps.is_valid_name(bad), false, "invalid name " .. vim.inspect(bad))
  end
  eq(deps.is_valid_name("lib.nvim"), true, "valid name")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  local base = tmp .. "/proj" -- the project root
  local data = tmp .. "/data" -- a fake stdpath('data')
  local env = {}
  local opts = {
    getenv = function(name)
      return env[name]
    end,
    data_dir = data,
  }
  -- each place can hold a checkout of "foo.nvim" (marker: a lua/ directory)
  local places = {
    env = tmp .. "/override/foo.nvim",
    deps = base .. "/.deps/foo.nvim",
    sibling = tmp .. "/foo.nvim",
    lazy = data .. "/lazy/foo.nvim",
  }
  vim.fn.mkdir(base, "p")
  local function make(place)
    vim.fn.mkdir(places[place] .. "/lua", "p")
  end

  local r, msg = deps.resolve("foo.nvim", base, opts)
  eq(r, nil, "nothing anywhere: not resolved")
  -- the failure names ALL FOUR places, with the paths that were looked at
  has(msg, "$FOO_NVIM_DIR", "place 1 named")
  has(msg, ".deps/foo.nvim", "place 2 named")
  has(msg, "../foo.nvim", "place 3 named")
  has(msg, "stdpath('data')/lazy/foo.nvim", "place 4 named")
  has(msg, places.deps, "the real path of place 2")
  has(msg, places.sibling, "the real path of place 3")
  has(msg, places.lazy, "the real path of place 4")
  has(msg, "1.", "numbered in order")
  has(msg, "4.", "four of them")
  has(msg, "dependency 'foo.nvim' not found", "names the dependency")

  -- order: the last place wins when it is the only one, then each earlier place beats it
  make("lazy")
  r = deps.resolve("foo.nvim", base, opts)
  ok(r ~= nil and r.dir == places.lazy, "stdpath('data')/lazy is the last resort")
  eq(r.source, "stdpath('data')/lazy/foo.nvim", "its label")
  make("sibling")
  r = deps.resolve("foo.nvim", base, opts)
  eq(r and r.dir, places.sibling, "the sibling beats lazy")
  make("deps")
  r = deps.resolve("foo.nvim", base, opts)
  eq(r and r.dir, places.deps, ".deps beats the sibling")
  make("env")
  env.FOO_NVIM_DIR = places.env
  r = deps.resolve("foo.nvim", base, opts)
  eq(r and r.dir, places.env, "the environment variable beats everything")
  eq(r and r.source, "$FOO_NVIM_DIR", "its label")
  eq(#(r and r.locations or {}), 4, "a result carries all four places")

  -- an override that is set but wrong decides alone: no fall-through to .deps (which is valid)
  env.FOO_NVIM_DIR = tmp .. "/does-not-exist"
  r, msg = deps.resolve("foo.nvim", base, opts)
  eq(r, nil, "a wrong override is a failure, not a fall-through")
  has(msg, "is set but does not point to a valid checkout", "says why")
  has(msg, tmp .. "/does-not-exist", "names the bad path")
  has(msg, "stdpath('data')/lazy/foo.nvim", "still names all four")
  env.FOO_NVIM_DIR = ""
  r = deps.resolve("foo.nvim", base, opts)
  eq(r and r.dir, places.deps, "an empty override counts as unset")
  env.FOO_NVIM_DIR = nil

  -- the marker: a directory without lua/ is not a checkout
  vim.fn.delete(places.deps .. "/lua", "rf")
  r = deps.resolve("foo.nvim", base, opts)
  eq(r and r.dir, places.sibling, "an invalid .deps/foo.nvim is skipped")
  local locs = deps.locations("foo.nvim", base, opts)
  eq(locs[2].status, "invalid", "and reported as invalid")
  eq(locs[3].status, "ok", "the sibling is ok")
  eq(locs[1].status, "unset", "no override")

  -- lib.nvim needs lua/lib/nvim, not just lua/
  vim.fn.mkdir(base .. "/.deps/lib.nvim/lua", "p")
  r, msg = deps.resolve("lib.nvim", base, opts)
  eq(r, nil, "lib.nvim without lua/lib/nvim is not lib.nvim")
  has(msg, "not a lib.nvim checkout", "says so")
  vim.fn.mkdir(base .. "/.deps/lib.nvim/lua/lib/nvim", "p")
  r = deps.resolve("lib.nvim", base, opts)
  eq(r and r.dir, base .. "/.deps/lib.nvim", "lib.nvim with the marker")

  -- an invalid name is refused before any path is built
  r, msg = deps.resolve("../evil", base, opts)
  eq(r, nil, "path traversal in the name")
  has(msg, "invalid dependency name", "says so")

  -- resolve_all reports every failure, not the first
  local resolved, failures = deps.resolve_all({ "foo.nvim", "bar.nvim", "baz.nvim" }, base, opts)
  eq(#resolved, 1, "foo.nvim resolved")
  eq(#failures, 2, "two failures, both reported")
  has(failures[1], "'bar.nvim'", "first failure")
  has(failures[2], "'baz.nvim'", "second failure")

  -- a project checked out where its siblings are not (a worktree, a temp copy): a dependency that the
  -- project's own base lacks is found beside the runner's checkout, with no $<NAME>_DIR set
  do
    local runner_base = tmp .. "/runner/testing.nvim"
    vim.fn.mkdir(runner_base, "p")
    vim.fn.mkdir(tmp .. "/runner/qux.nvim/lua", "p")
    local with = vim.tbl_extend("force", opts, { fallback = runner_base })
    local got, fails = deps.resolve_all({ "qux.nvim" }, base, with)
    eq(#fails, 0, "found beside the runner: " .. vim.inspect(fails))
    eq(got[1] and got[1].dir, tmp .. "/runner/qux.nvim", "the checkout beside the runner")
    has(got[1] and got[1].source, "beside the runner", "and the source says so")
    local none =
      deps.resolve_all({ "qux.nvim" }, base, vim.tbl_extend("force", opts, { fallback = false }))
    eq(#none, 0, "fallback = false: only the project's own places")
    -- an override that is set but invalid is never skipped for the fallback
    env.QUX_NVIM_DIR = tmp .. "/nowhere"
    local _, bad = deps.resolve_all({ "qux.nvim" }, base, with)
    eq(#bad, 1, "an invalid override still fails")
    env.QUX_NVIM_DIR = nil
  end

  -- a stale lib.nvim (without fs.write.atomic) that comes first is named, with the commit that fixes it
  do
    local stale = tmp .. "/stale/lib.nvim"
    vim.fn.mkdir(stale .. "/lua/lib/nvim", "p")
    local res = { name = "lib.nvim", dir = stale, source = ".deps/lib.nvim", locations = {} }
    local problem = deps.lib_problem(res)
    has(problem, "too old", "a lib.nvim without fs.write.atomic is too old")
    has(problem, "6304829", "and the message names the commit that has it")
    has(problem, stale, "and the checkout")
    vim.fn.mkdir(stale .. "/lua/lib/nvim/fs/write", "p")
    vim.fn.writefile({ "return function() end" }, stale .. "/lua/lib/nvim/fs/write/atomic.lua")
    eq(deps.lib_problem(res), nil, "with the module present there is no problem")
    -- the real lib.nvim this suite runs on must pass its own check
    local real_lib = deps.resolve("lib.nvim", deps.self_dir())
    eq(real_lib and deps.lib_problem(real_lib), nil, "the lib.nvim of this run is recent enough")
  end

  -- report rows
  local rows = deps.report({ "foo.nvim", "bar.nvim" }, base, opts)
  eq(rows[1].ok, true, "report: found")
  eq(rows[2].ok, false, "report: missing")
  has(rows[2].message, "$BAR_NVIM_DIR", "report: missing carries the message")

  -- without injection the real environment and data dir are used (nothing raises)
  local real = deps.locations("surely-not-installed.nvim", base)
  eq(#real, 4, "four places with the real environment")
  has(real[4].path, "/lazy/surely-not-installed.nvim", "the real stdpath('data') is used")

  -- self_dir is this checkout
  ok(
    vim.fn.isdirectory(deps.self_dir() .. "/lua/testing") == 1,
    "self_dir is the testing.nvim checkout"
  )

  vim.fn.delete(tmp, "rf")
end
