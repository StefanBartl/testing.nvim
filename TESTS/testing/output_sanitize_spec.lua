-- TESTS/testing/output_sanitize_spec.lua -- everything the run prints about the project passes the same
-- sanitizing: a case id, a file name, an environment name or the machine of a committed baseline can carry
-- an escape sequence or a line that starts a CI workflow command. The reporters were clean; the diagnostics
-- lines (`--profile`, the `cache (use):` line) were not.

return function(H)
  local ok = H.ok
  local cli = require("testing.cli")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-sanitize"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local root = tmp .. "/p"
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  -- a case whose name has a line break, a workflow command, and an OSC title change
  write(
    root .. "/TESTS/evil_spec.lua",
    "describe('suite\\n::error::INJECTED', function()\n  it('case "
      .. "\27]0;TITLE\7"
      .. "\\n::warning::TOO', function() assert.is_true(true) end)\nend)\n"
  )
  -- an environment variable with an escape sequence in its name
  write(
    root .. "/TESTS/env_spec.lua",
    'return function(H) H.ok(os.getenv("EV' .. "\27]0;X\7" .. 'IL") == nil, "env") end\n'
  )

  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ root }, argv), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      affected = {
        getenv = function() end,
      },
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  local function check(label, text)
    ok(not text:find("\27", 1, true), label .. ": no escape character reaches the output")
    ok(not text:find("\7", 1, true), label .. ": no bell")
    ok(not text:find("\n::error::", 1, true), label .. ": no line starts a workflow command")
    ok(not text:find("\n::warning::", 1, true), label .. ": nor a warning command")
  end

  local code, out, err = run({ "--profile" })
  ok(code == 0, "the run is green: " .. out .. err)
  check("--profile", err)
  check("stdout", out)
  ok(
    err:find("INJECTED", 1, true) ~= nil,
    "the profile does name the case (so the test looks at something)"
  )

  code, out, err = run({ "--cached" })
  ok(code == 0, "the cached run is green: " .. out .. err)
  ok(out:find("cache (use)", 1, true) ~= nil, "the cache line is printed")
  check("the cache line", out)
  check("the cache note", err)

  require("testing.cache").reset()
  vim.fn.delete(tmp, "rf")
end
