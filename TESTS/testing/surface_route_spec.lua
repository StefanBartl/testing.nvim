-- TESTS/testing/surface_route_spec.lua -- `:Testing surface`: the flags of the route reach the child's argv
-- verbatim (`--matrix`, `--csv`, `--no-tags`, next to `--markdown`, `--from`, `--threshold`) and testing.surface
-- reads them back as the options they stand for. The child process itself is a seam (`bindings.child.start`).

---@diagnostic disable: duplicate-set-field, param-type-mismatch, missing-parameter, undefined-field, missing-fields
-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local usrcmds = require("testing.bindings.usrcmds")
  local child = require("testing.bindings.child")
  local surface = require("testing.surface")
  ok(usrcmds.register(), ":Testing registers")

  local real_start, real_notify = child.start, vim.notify
  local started
  child.start = function(sub, opts)
    started = { sub = sub, opts = opts }
    return true
  end
  vim.notify = function() end
  local passed, err = pcall(function()
    local function run(line)
      started = nil
      vim.cmd(line)
      return started
    end

    local got = run("Testing surface --matrix --csv --no-tags")
    ok(got ~= nil, ":Testing surface starts the child")
    eq(got.sub, "surface", "the subcommand")
    eq(
      got.opts.flags.raw,
      { "--matrix", "--csv", "--no-tags" },
      "matrix, csv and no-tags reach the argv, in the order of the route"
    )
    local args = surface.parse_args(got.opts.flags.raw)
    ok(args ~= nil, "testing.surface reads the flags back")
    eq(args.matrix, true, "--matrix is the matrix")
    eq(args.format, "csv", "--csv is the csv format")
    eq(args.no_tags, true, "--no-tags turns the claims off")

    local ir_file = vim.fs.normalize(vim.fn.tempname())
    vim.fn.writefile({ "{}" }, ir_file)
    got = run("Testing surface --markdown --from=" .. ir_file .. " --threshold=0.5")
    vim.fn.delete(ir_file)
    eq(
      got.opts.flags.raw,
      { "--markdown", "--from=" .. ir_file, "--threshold=0.5" },
      "the flags that were there before stay"
    )
    got = run("Testing surface")
    eq(got.opts.flags.raw, {}, "no flag, nothing in the argv")
    local complete = vim.fn.getcompletion("Testing surface --", "cmdline")
    table.sort(complete)
    eq(
      complete,
      { "--csv", "--from", "--markdown", "--matrix", "--no-tags", "--threshold" },
      "the route offers its flags"
    )
  end)
  child.start, vim.notify = real_start, real_notify
  if not passed then
    error(err, 0)
  end
end
