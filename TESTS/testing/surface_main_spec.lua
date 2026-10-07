-- TESTS/testing/surface_main_spec.lua -- `testing surface` / `:Testing surface`: the arguments, the exit codes
-- (0 report, 1 threshold or baseline failed, 2 usage, 3 the surface could not be read), the three output
-- formats, the baseline round trip. The child editor is replaced by a seam here; specs with the real one
-- are surface_read_spec / surface_track_spec / surface_e2e_spec.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 900) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local surface = require("testing.surface")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local function write(name, content)
    local path = tmp .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
  end
  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end

  local function entry(id, kind, src, extra)
    return vim.tbl_extend("force", {
      id = id,
      kind = kind,
      name = (id:gsub("^%a+:", "")),
      src = src,
    }, extra or {})
  end
  local fixed = {
    version = 1,
    plugin = "fx",
    root = tmp,
    notes = { "from the seam" },
    counts = { binding = 2, command = 2, autocmd = 1, health = 1 },
    entries = {
      entry("binding:<leader>a", "binding", "lua/fx/init.lua:10", {
        detail = { lhs = "<leader>a", modes = { "n" } },
      }),
      entry("binding:a|b", "binding", "lua/fx/init.lua:20", {
        detail = { lhs = "a|b", modes = { "n" } },
      }),
      entry("command:Open", "command", "lua/fx/init.lua:30"),
      entry("command:Fx status", "command", "lua/fx/init.lua:40"),
      entry("autocmd:g:BufEnter", "autocmd", "lua/fx/init.lua:50"),
      entry("health:fx", "health", "lua/fx/health.lua:1"),
    },
  }
  local calls = {}
  local services = {
    cwd = tmp,
    config = { plugin = "fx", coverage = { bindings = 0, commands = 0 }, deps = {} },
    collect = function(root, opts)
      calls[#calls + 1] = { root = root, plugin = opts.plugin }
      return vim.deepcopy(fixed)
    end,
  }
  local function sink_line(hit, extra)
    return vim.json.encode(
      vim.tbl_extend(
        "force",
        { k = "case", id = "a::x", file = "a_spec.lua", hit = hit },
        extra or {}
      )
    )
  end
  -- 2 of the 5 observable entries are exercised: 40 %
  local sink = write("hits.jsonl", sink_line({ "binding:<leader>a", "command:Open" }) .. "\n")
  local function main(argv)
    return surface.main(argv, services)
  end

  -- ------------------------------------------------------------------ arguments
  local a = assert(surface.parse_args({
    "proj",
    "--from",
    "x.json",
    "--from=y.json",
    "--hits",
    "s",
    "--kind",
    "binding,command",
    "--threshold",
    "0.8",
    "--threshold",
    "command=0.5",
    "--ignore",
    "^api:",
    "--baseline",
    "b.json",
    "--write-baseline",
    "w.json",
    "--fail-on-new",
    "--markdown",
    "--out",
    "o.md",
  }))
  eq(a.root, "proj", "args: root")
  eq(a.from, { "x.json", "y.json" }, "args: --from is repeatable and takes = too")
  eq(a.sinks, { "s" }, "args: --hits")
  eq(a.kinds, { "binding", "command" }, "args: --kind")
  eq(a.thresholds, { overall = 0.8, kinds = { command = 0.5 } }, "args: thresholds")
  eq(a.ignore, { "^api:" }, "args: --ignore")
  eq(
    { a.baseline, a.write_baseline, a.fail_on_new, a.format, a.out },
    { "b.json", "w.json", true, "markdown", "o.md" },
    "args: the rest"
  )
  eq(
    assert(surface.parse_args({ "list", "--json" })).format,
    "json",
    "args: `list` is the one view and --json a format"
  )
  for _, bad in ipairs({
    { "--bogus" },
    { "--threshold", "1.5" },
    { "--threshold", "abc" },
    { "--threshold", "nokind=0.5" },
    { "--threshold", "binding=2" },
    { "--threshold" },
    { "--kind", "nonsense" },
    { "a", "b" },
    { "--from" },
  }) do
    local parsed, err = surface.parse_args(bad)
    eq(parsed, nil, "args refused: " .. table.concat(bad, " "))
    ok(type(err) == "string" and err ~= "", "with a reason: " .. table.concat(bad, " "))
  end

  local code, text = main({ "--bogus" })
  eq(code, 2, "an unknown option is exit 2")
  has(text, "unknown option --bogus", "and says so")
  has(text, "usage: testing surface", "with the usage")
  code, text = main({ "--help" })
  eq(code, 0, "--help is exit 0")
  has(text, "--baseline", "and documents the baseline")

  -- ------------------------------------------------------------------ report only
  code, text = main({})
  eq(code, 0, "no tracked run, no gate: exit 0")
  eq(calls[1].plugin, "fx", "the plugin of the project is read")
  has(text, "surface: fx (6 entries)", "the header")
  has(text, "binding:<leader>a", "an entry")
  has(text, "lua/fx/init.lua:10", "its source")
  has(text, "nothing is measured", "and it says that nothing was measured")
  lacks(text, "missing", "no entry is called missing without a measurement")
  has(text, "note: from the seam", "notes of the surface are shown")

  code, text = main({ "--hits", sink })
  eq(code, 0, "a tracked run without a threshold only reports")
  has(text, "hit ", "statuses")
  has(text, "overall  2/5  40.0%", "the ratio")
  has(text, "binding  1/2  50.0%", "per kind")

  -- ------------------------------------------------------------------ thresholds
  code = main({ "--hits", sink, "--threshold", "0.4" })
  eq(code, 0, "at the threshold")
  code, text = main({ "--hits", sink, "--threshold", "0.5" })
  eq(code, 1, "below the overall threshold is exit 1")
  has(text, "below threshold: overall 40.0% < 50.0%", "and says by how much")
  code = main({ "--hits", sink, "--threshold", "0" })
  eq(code, 0, "0 is report only")
  code = main({ "--hits", sink, "--threshold", "binding=0.5" })
  eq(code, 0, "per kind: 1/2 binding is enough for 0.5")
  code, text = main({ "--hits", sink, "--threshold", "binding=0.6" })
  eq(code, 1, "per kind: not enough for 0.6")
  has(text, "below threshold: binding", "named")
  code = main({ "--hits", sink, "--threshold", "command=1" })
  eq(code, 1, "the other kind (1 of 2 commands)")
  code = main({ "--hits", sink, "--threshold", "autocmd=0", "--ignore", "^command:" })
  eq(code, 0, "ignored entries are out of the ratio")
  code, text = main({ "--threshold", "0.5" })
  eq(code, 2, "a threshold without a tracked run is a usage error, not a pass")
  has(text, "needs a tracked run", "with the reason")

  -- the thresholds of .testing.lua (`coverage.bindings`) gate without any flag
  local gated = vim.deepcopy(services)
  gated.config.coverage = { bindings = 1.0, commands = 0 }
  code, text = surface.main({ "--hits", sink }, gated)
  eq(code, 1, "coverage.bindings = 1.0 of the project is a gate")
  has(text, "below threshold: binding 50.0% < 100.0%", "named")
  gated.config.surface = { threshold = 0.9 }
  code = surface.main({ "--hits", sink, "--threshold", "0.1", "--threshold", "binding=0.1" }, gated)
  eq(code, 0, "the command line overrides the file")

  -- ------------------------------------------------------------------ from a Result-IR
  local ir = write(
    "ir.json",
    vim.json.encode({
      schema_version = 1,
      cases = {
        {
          id = "a::x",
          file = "a_spec.lua",
          surface = { hit = { "binding:<leader>a", "command:Open", "autocmd:g:BufEnter" } },
        },
      },
    })
  )
  code, text = main({ "--from", ir, "--threshold", "0.6" })
  eq(code, 0, "hits from a Result-IR: 3 of 5 is 60 %")
  has(text, "overall  3/5  60.0%", "the ratio")
  code, text = main({ "--from", tmp .. "/nope.json" })
  eq(code, 2, "an unreadable IR is a usage error")
  has(text, "cannot read", "with the reason")
  code, text = main({ "--from", write("garbage.json", "not json") })
  eq(code, 2, "an IR that is no JSON")
  has(text, "not a Result-IR", "with the reason")

  -- ------------------------------------------------------------------ baseline
  local base_path = tmp .. "/baseline.json"
  code, text = main({ "--hits", sink, "--write-baseline", base_path })
  eq(code, 0, "writing a baseline")
  has(text, "baseline written", "says so")
  local base = vim.json.decode(slurp(base_path))
  eq(base.entries["binding:<leader>a"], "hit", "the baseline: hit")
  eq(base.entries["command:Fx status"], "missing", "the baseline: missing")
  eq(base.entries["health:fx"], nil, "the baseline: only entries that count")

  code, text = main({ "--hits", sink, "--baseline", base_path })
  eq(code, 0, "the same run against its own baseline")
  has(text, "no regressions", "says so")

  local fewer = write("fewer.jsonl", sink_line({ "command:Open" }) .. "\n")
  code, text = main({ "--hits", fewer, "--baseline", base_path })
  eq(code, 1, "an entry that was exercised and is not now fails")
  has(text, "regressions: hit before, not hit now (1):", "named")
  has(text, "binding:<leader>a", "which one")
  code =
    main({ "--hits", fewer, "--baseline", base_path, "--write-baseline", tmp .. "/never.json" })
  eq(code, 1, "failing and writing")
  eq(vim.uv.fs_stat(tmp .. "/never.json"), nil, "a failed run does not write a baseline")

  local grown = vim.deepcopy(fixed)
  grown.entries[#grown.entries + 1] = entry("command:Brand new", "command", "lua/fx/init.lua:60")
  local grown_services = vim.tbl_extend("force", services, {
    collect = function()
      return vim.deepcopy(grown)
    end,
  })
  code, text = surface.main({ "--hits", sink, "--baseline", base_path }, grown_services)
  eq(code, 0, "new surface that nobody exercises does not fail by default")
  has(text, "new and not exercised (1):", "but is listed")
  code = surface.main({ "--hits", sink, "--baseline", base_path, "--fail-on-new" }, grown_services)
  eq(code, 1, "--fail-on-new makes it a failure")

  -- an entry that was exercised and is gone from the surface: listed, a failure only with --fail-on-removed
  local shrunk = vim.deepcopy(fixed)
  shrunk.entries = vim.tbl_filter(function(e)
    return e.id ~= "binding:<leader>a"
  end, shrunk.entries)
  local shrunk_services = vim.tbl_extend("force", services, {
    collect = function()
      return vim.deepcopy(shrunk)
    end,
  })
  code, text = surface.main({ "--hits", sink, "--baseline", base_path }, shrunk_services)
  eq(code, 0, "a vanished entry does not fail by default")
  has(text, "binding:<leader>a", "but is listed")
  code, text =
    surface.main({ "--hits", sink, "--baseline", base_path, "--fail-on-removed" }, shrunk_services)
  eq(code, 1, "--fail-on-removed makes it a failure")
  has(text, "gone from the surface", "and says why")

  -- a baseline that was edited after a run wrote it says so (the bar is whatever the file holds now)
  local signed = vim.json.decode(slurp(base_path))
  eq(type(signed.digest), "string", "a written baseline carries a digest")
  text = select(2, main({ "--hits", sink, "--baseline", base_path }))
  eq(text:find("digest", 1, true), nil, "an untouched baseline raises no note")
  signed.entries["binding:<leader>a"] = "missing"
  local edited_path = write("edited.json", vim.json.encode(signed))
  text = select(2, main({ "--hits", sink, "--baseline", edited_path }))
  has(text, "do not match its digest", "an edited baseline is named")
  signed.digest = nil
  text = select(
    2,
    main({ "--hits", sink, "--baseline", write("unsigned.json", vim.json.encode(signed)) })
  )
  has(text, "no digest", "a baseline without a digest says that it cannot be checked")

  -- --out and --write-baseline go through the atomic writer: no temp file stays behind
  local leftovers = 0
  for name in vim.fs.dir(tmp) do
    if name:find("atomic-tmp", 1, true) then
      leftovers = leftovers + 1
    end
  end
  eq(leftovers, 0, "no temp file of an atomic write is left in the directory")

  code, text = main({ "--hits", sink, "--baseline", write("nobase.json", "{}") })
  eq(code, 2, "a baseline that is none")
  has(text, "not a surface baseline", "says so")
  code = main({ "--baseline", base_path })
  eq(code, 2, "a baseline without a tracked run")

  -- ------------------------------------------------------------------ formats
  code, text = main({ "--hits", sink, "--json" })
  eq(code, 0, "json: exit")
  local doc = vim.json.decode(text)
  eq(doc.plugin, "fx", "json: plugin")
  eq(doc.coverage.total, 5, "json: total")
  eq(doc.coverage.hit, 2, "json: hit")
  eq(doc.coverage.kinds.binding.total, 2, "json: per kind")
  eq(#doc.entries, 6, "json: the entries")
  eq(doc.entries[1].status, "hit", "json: with their status")
  eq(doc.exit_code, 0, "json: the exit code is in it")

  code, text = main({ "--hits", sink, "--markdown", "--threshold", "0.9" })
  eq(code, 1, "markdown: exit")
  has(text, "# Surface of `fx`", "markdown: title")
  has(text, "| binding | 1 | 2 | 50.0% | 0 |", "markdown: summary table")
  has(text, "| hit | binding | `binding:<leader>a` |", "markdown: entry rows")
  has(text, "`binding:a\\|b`", "markdown: a pipe in an id is escaped")
  has(text, "below threshold: overall", "markdown: the failure")

  local out_path = tmp .. "/out.md"
  main({ "--hits", sink, "--markdown", "--out", out_path })
  has(slurp(out_path), "# Surface of `fx`", "--out writes the output too")

  -- hostile text from a plugin never reaches the terminal
  local hostile = vim.deepcopy(fixed)
  hostile.entries[1].id = "binding:\27[31mred\0"
  hostile.entries[1].src = "x\ry"
  local hostile_services = vim.tbl_extend("force", services, {
    collect = function()
      return vim.deepcopy(hostile)
    end,
  })
  local _, htext = surface.main({}, hostile_services)
  lacks(htext, "\27", "no escape sequence")
  lacks(htext, "\0", "no NUL")
  lacks(htext, "\r", "no carriage return")

  -- ------------------------------------------------------------------ the surface cannot be read
  local broken = vim.tbl_extend("force", services, {
    collect = function()
      return nil, "cannot start the child editor: boom"
    end,
  })
  code, text = surface.main({}, broken)
  eq(code, 3, "no surface is exit 3")
  has(text, "boom", "with the reason")

  vim.fn.delete(tmp, "rf")
end
