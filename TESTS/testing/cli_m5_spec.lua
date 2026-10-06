-- TESTS/testing/cli_m5_spec.lua -- what `testing.cli` does with the M5 names: nothing is reserved any more
-- (a parsed option that nothing dispatches would be refused with exit 2), `--jobs auto` / `jobs = "auto"` become cores minus one, `doctor`
-- shows the new configuration, and `budget` without a root measures the current directory.

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local cli = require("testing.cli")

  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/x_spec.lua", "wb"))
  f:write("return function(H)\n  H.ok(true, 'x')\nend\n")
  f:close()

  local function captured(argv, seams)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = root .. "/state",
      color = false,
    }
    for k, v in pairs(seams or {}) do
      sv[k] = v
    end
    local code = cli.main(argv, sv)
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  -- nothing is reserved any more: every name is wired (docs: integration_cache_spec and integration_cli_spec
  -- run them); a name someone parses and does not dispatch would be refused here with exit 2
  eq(next(cli.RESERVED.options), nil, "no reserved option is left")
  eq(next(cli.RESERVED.commands), nil, "no reserved command is left")
  eq(next(cli.UNWIRED), nil, "UNWIRED stays empty")
  for _, argv in ipairs({
    { "--no-cache" },
    { "--cache-refresh" },
    { "--changed", "--list" },
    { "--since", "HEAD", "--list" },
  }) do
    local r = captured(vim.list_extend({ root }, argv))
    ok(
      r.code ~= 2 or not r.err:find("reserved", 1, true),
      table.concat(argv, " ") .. " is not refused as reserved"
    )
  end

  -- jobs: auto = cores minus one, at least 1
  eq(cli.auto_jobs(1), 1, "one core: one job")
  eq(cli.auto_jobs(2), 1, "two cores: one job")
  eq(cli.auto_jobs(8), 7, "eight cores: seven jobs")
  eq(cli.auto_jobs(), math.max(1, #vim.uv.cpu_info() - 1), "default: what libuv reports")
  local want = ("jobs=%d "):format(cli.auto_jobs())
  local r = captured({ "doctor", root, "--jobs", "auto" })
  eq(r.code, 0, "doctor --jobs auto\n" .. r.err)
  has(r.out, want, "--jobs auto is resolved to an integer")
  local conf = assert(io.open(root .. "/.testing.lua", "wb"))
  conf:write(
    'return { jobs = "auto", shard = { balance = "hash" }, watch = { debounce_ms = 321 }, budget = { factor = 3.5 } }\n'
  )
  conf:close()
  r = captured({ "doctor", root })
  eq(r.code, 0, "doctor with jobs = auto in .testing.lua\n" .. r.err)
  has(r.out, want, 'jobs = "auto" is resolved the same way')
  has(r.out, "shard: balance=hash", "doctor shows the shard balance")
  has(r.out, "debounce=321 ms", "doctor shows the watch debounce")
  has(r.out, "factor=3.5", "doctor shows the budget factor")
  r = captured({ "doctor", root, "--jobs", "2" })
  has(r.out, "jobs=2 ", "an explicit number wins")
  vim.fn.delete(root .. "/.testing.lua")

  -- budget without a root: the current directory; a fake runner keeps it fast
  local fake = {
    run = function()
      return {
        {
          name = "x",
          measure = { median_ms = 1, min_ms = 1, max_ms = 1, runs = 1, samples = { 1 } },
        },
      }
    end,
    machine = { os = "T", cpu = "c", arch = "a", cpus = 1, nvim = "0" },
  }
  local baseline = root .. "/b.json"
  r = captured({ "budget", "--update", "--baseline", baseline }, { budget = fake })
  eq(r.code, 0, "budget without a root runs on the current directory\n" .. r.err)
  ok(vim.uv.fs_stat(baseline) ~= nil, "and wrote the baseline where it was told")
  r = captured({ "budget", "--baseline", baseline }, { budget = fake })
  eq(r.code, 0, "and checks against it")
  has(r.out, "OK", "with a row per case")

  -- `testing --help` and the usage on an error mention the new subcommand
  r = captured({ "--help" })
  eq(r.code, 0, "--help")
  has(r.out, "budget", "usage names `budget`")
  vim.fn.delete(root, "rf")
end
