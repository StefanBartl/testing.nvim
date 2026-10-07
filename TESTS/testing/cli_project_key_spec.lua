-- TESTS/testing/cli_project_key_spec.lua -- the results of a run are stored in the cache folder of THAT run's
-- `cache.project_key`, also when a spec of the run calls `cli.main` for another project (many specs of this suite do),
-- which leaves the key of that project in the global behind. Before, such a suite stored every result in a folder named
-- after the checkout path while its next run read the folder of the configured key: a whole suite without a single hit.

return function(H)
  local ok = H.ok
  local cli = require("testing.cli")
  local store = require("testing.cache.store")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-pkey"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  -- the project the spec of the host calls `main` for: it configures no key
  write(tmp .. "/p/TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  write(tmp .. "/p/.testing.lua", "return { plugin = 'proj', minit = false }\n")
  -- the host: its own key, and a spec that runs `main` for the other project
  write(
    tmp .. "/h/TESTS/nested_spec.lua",
    table.concat({
      "return function(H)",
      "  local rc = require('testing.cli').main({ 'list', " .. vim.inspect(tmp .. "/p") .. " }, {",
      "    out = function() end,",
      "    err = function() end,",
      "  })",
      "  H.ok(rc == 0, 'nested')",
      "end",
      "",
    }, "\n")
  )
  write(
    tmp .. "/h/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, cache = { project_key = 'host-key' } }\n"
  )

  local saved = store.project_key
  local code = cli.main({ tmp .. "/h", "--cached" }, {
    out = function() end,
    err = function() end,
    state_dir = tmp .. "/state",
    cache_dir = tmp .. "/cache",
    color = false,
    affected = { getenv = function() end, provider = false },
  })
  store.project_key = saved
  ok(code == 0, "the hosting run is green (exit " .. tostring(code) .. ")")
  local host = H.glob(tmp .. "/cache/testing/host-key-*/entries/*.json")
  local other = H.glob(tmp .. "/cache/testing/h-*/entries/*.json")
  ok(#host == 1, "its entry is in the folder of its own key (found " .. #host .. ")")
  ok(#other == 0, "and not in a folder named after the path (found " .. #other .. ")")

  -- where the cache lives never decides a key: the same project stored below another cache directory has the same
  -- entry name (else a cache restored to another path, or a stamp written on another machine, would never match)
  code = cli.main({ tmp .. "/h", "--cached" }, {
    out = function() end,
    err = function() end,
    state_dir = tmp .. "/state2",
    cache_dir = tmp .. "/other-place/cache",
    color = false,
    affected = { getenv = function() end, provider = false },
  })
  store.project_key = saved
  ok(code == 0, "the second run is green (exit " .. tostring(code) .. ")")
  local moved = H.glob(tmp .. "/other-place/cache/testing/host-key-*/entries/*.json")
  ok(#moved == 1, "the entry is below the other cache directory (found " .. #moved .. ")")
  ok(
    #host == 1 and #moved == 1 and vim.fs.basename(host[1]) == vim.fs.basename(moved[1]),
    "and has the same key: "
      .. tostring(host[1] and vim.fs.basename(host[1]))
      .. " vs "
      .. tostring(moved[1] and vim.fs.basename(moved[1]))
  )
  vim.fn.delete(tmp, "rf")
end
