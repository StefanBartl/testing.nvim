-- TESTS/testing/report_init_spec.lua -- testing.report: the registry and `run_reporters` (lines,
-- files, errors that never raise and never stop the other reporters).

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local report = require("testing.report")

  -- registry ----------------------------------------------------------------------------------------------
  eq(report.names(), { "github", "junit", "term" }, "known reporters, sorted")
  for _, name in ipairs(report.names()) do
    local mod, err = report.resolve(name)
    ok(
      mod ~= nil and type(mod.render) == "function",
      name .. " resolves to a module with render: " .. tostring(err)
    )
  end
  local none, nerr = report.resolve("tap")
  ok(
    none == nil
      and (nerr or ""):find("unknown reporter", 1, true)
      and (nerr or ""):find("github, junit, term", 1, true),
    "unknown name lists the known ones"
  )
  local none2 = report.resolve(nil)
  ok(none2 == nil, "a missing name is an error, not a raise")
  ok(select(2, report.resolve({})) ~= nil, "a table is not a name")

  -- default: term lines ------------------------------------------------------------------------------------------
  local mixed = F.mixed()
  local outs, errs = report.run_reporters(mixed)
  eq(#errs, 0, "no errors")
  eq(#outs, 1, "default is one reporter")
  eq(outs[1].reporter, "term", "default reporter is term")
  eq(
    outs[1].lines,
    require("testing.report.term").render(mixed),
    "lines equal the reporter's own render"
  )
  ok(outs[1].path == nil and outs[1].written == nil, "no path: nothing written")
  eq(
    report.run_reporters(mixed, { reporters = {} })[1].reporter,
    "term",
    "an empty list falls back to term"
  )

  -- files ------------------------------------------------------------------------------------------------------------
  local base = vim.fn.tempname() .. "-report"
  local xml_path = base .. "/nested/dir/junit.xml"
  outs, errs = report.run_reporters(mixed, {
    reporters = {
      "term",
      { name = "junit", path = xml_path, opts = { suite_name = "from-spec" } },
    },
  })
  eq(#errs, 0, "no errors with a path")
  eq(#outs, 2, "request order and count")
  eq(
    { outs[2].reporter, outs[2].path, outs[2].written },
    { "junit", xml_path, true },
    "file written"
  )
  local raw = assert(io.open(xml_path, "rb"))
  local bytes = raw:read("*a")
  raw:close()
  eq(bytes, table.concat(outs[2].lines, "\n") .. "\n", "the file holds exactly the lines")
  ok(bytes:find('name="from-spec"', 1, true), "per-reporter opts reach the reporter")
  ok(bytes:sub(-1) == "\n" and not bytes:find("\r", 1, true), "file ends in LF, no CR")
  ok(F.parse_xml(bytes) ~= nil, "the written file is well-formed XML")
  local leftovers = vim.fn.glob(base .. "/nested/dir/*", false, true)
  eq(#leftovers, 1, "the atomic write leaves no temp file behind")

  -- defaults and spec opts: spec wins ----------------------------------------------------------------------------------
  outs = report.run_reporters(F.green(), {
    reporters = { "junit", { name = "junit", opts = { suite_name = "own" } } },
    defaults = { junit = { suite_name = "default" } },
  })
  ok(outs[1].lines[2]:find('name="default"', 1, true), "defaults apply")
  ok(outs[2].lines[2]:find('name="own"', 1, true), "spec opts win over defaults")

  -- errors: never raise, never stop the others -----------------------------------------------------------------------------
  ---@type any
  local requests = { "nope", "term", 42, { name = "term" } }
  outs, errs = report.run_reporters(mixed, { reporters = requests })
  eq(#outs, 4, "every request has an output entry")
  eq(#errs, 2, "unknown name and a non-name are errors")
  ok(outs[1].err:find("unknown reporter", 1, true), "error text on the entry")
  ok(#outs[2].lines > 0 and outs[2].err == nil, "the reporter after a failed one still runs")
  ok(#outs[4].lines > 0, "and the one after a number too")

  local bad_path_cases = { "", "a\0b", "a\nb" }
  for _, p in ipairs(bad_path_cases) do
    local o2, e2 = report.run_reporters(mixed, { reporters = { { name = "junit", path = p } } })
    ok(#e2 == 1 and o2[1].written == false, "bad path " .. vim.inspect(p) .. " is an error")
  end
  ---@diagnostic disable-next-line: assign-type-mismatch
  local o3, e3 = report.run_reporters(mixed, { reporters = { { name = "junit", path = 42 } } })
  ok(#e3 == 1 and o3[1].written == false, "a non-string path is an error")
  -- a directory where the file should go: the write fails and says so
  vim.fn.mkdir(base .. "/is_a_dir", "p")
  local o4, e4 =
    report.run_reporters(mixed, { reporters = { { name = "junit", path = base .. "/is_a_dir" } } })
  ok(
    #e4 == 1 and o4[1].written == false and e4[1]:find("cannot write", 1, true),
    "an unwritable path is an error: " .. tostring(e4[1])
  )

  -- a reporter that throws, returns junk or has a failing finish hook
  package.loaded["testing.report.__throwing"] = {
    render = function()
      error("kaboom")
    end,
  }
  package.loaded["testing.report.__junk"] = {
    render = function()
      return "not a table"
    end,
  }
  package.loaded["testing.report.__finish"] = {
    render = function()
      return { "line" }
    end,
    finish = function()
      return false, "side output failed"
    end,
  }
  report.REPORTERS.__throwing = "testing.report.__throwing"
  report.REPORTERS.__junk = "testing.report.__junk"
  report.REPORTERS.__finish = "testing.report.__finish"
  local o5, e5 =
    report.run_reporters(mixed, { reporters = { "__throwing", "__junk", "__finish", "term" } })
  report.REPORTERS.__throwing, report.REPORTERS.__junk, report.REPORTERS.__finish = nil, nil, nil
  package.loaded["testing.report.__throwing"] = nil
  package.loaded["testing.report.__junk"] = nil
  package.loaded["testing.report.__finish"] = nil
  eq(#e5, 3, "three failing reporters, three errors")
  ok(o5[1].err:find("kaboom", 1, true), "a throw becomes an error with its message")
  ok(o5[2].err:find("no lines", 1, true), "junk output is an error")
  ok(
    o5[3].err:find("side output failed", 1, true) and o5[3].lines[1] == "line",
    "a failing finish hook is an error, lines are kept"
  )
  ok(#o5[4].lines > 0 and o5[4].err == nil, "the last reporter still ran")

  -- github through the registry: annotations as lines, summary as a side file ----------------------------------------------------
  local summary = base .. "/summary.md"
  local o6, e6 = report.run_reporters(mixed, {
    reporters = { { name = "github", opts = { env = { GITHUB_STEP_SUMMARY = summary } } } },
  })
  eq(#e6, 0, "github reporter without errors")
  ok(o6[1].lines[1]:find("^::error "), "annotations come back as lines")
  eq(o6[1].extra, { ok = true }, "finish result is reported")
  ok(
    table.concat(vim.fn.readfile(summary, "b"), "\n"):find("## testing.nvim: FAILED", 1, true),
    "step summary was appended"
  )
  local o7 =
    report.run_reporters(mixed, { reporters = { { name = "github", opts = { env = {} } } } })
  eq(o7[1].extra, { ok = nil }, "no step summary variable: nothing written, not an error")

  vim.fn.delete(base, "rf")
end
