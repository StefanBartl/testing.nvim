-- TESTS/testing/surface_tags_spec.lua -- the second source of surface hits (tags: `binding:...` /
-- `command:...` in `cases[].tags`, `-- @covers` headers of a spec), the matrix entries x spec files
-- (text, markdown, tab separated, JSON), the "not covered" lines and `--write-ir`. The child editor is a seam
-- (see surface_main_spec); the specs with the real one are surface_e2e_spec / surface_track_spec.

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

  local _
  local surface = require("testing.surface")
  local tags = require("testing.surface.tags")
  local coverage = require("testing.surface.coverage")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local function write(name, content)
    local path = tmp .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
  end

  -- ------------------------------------------------------------------ pure: ids and header lines
  ok(tags.is_id("binding:<leader>ssa"), "is_id: a binding")
  ok(tags.is_id("command:Session save"), "is_id: a route with a space")
  ok(not tags.is_id("slow"), "is_id: a plain tag is no id")
  ok(not tags.is_id("bogus:thing"), "is_id: an unknown kind is no id")
  ok(not tags.is_id("binding:"), "is_id: an empty name is no id")
  ok(not tags.is_id(42), "is_id: a number is no id")
  eq(
    tags.ids_of_tags({ "slow", "binding:<leader>a", "binding:<leader>a", "command:Open", 7 }),
    { "binding:<leader>a", "command:Open" },
    "ids_of_tags: ids only, once"
  )
  eq(tags.ids_of_tags("garbage"), {}, "ids_of_tags: garbage")
  eq(
    tags.parse_covers(
      "-- @covers binding:<leader>a, command:Fx status ; autocmd:g:BufEnter\n"
        .. "local x = 1\n"
        .. "--@covers: command:Open\n"
        .. "-- @covers nonsense, binding:\n"
    ),
    { "binding:<leader>a", "command:Fx status", "autocmd:g:BufEnter", "command:Open" },
    "parse_covers: separators, the colon form, junk dropped"
  )
  eq(
    tags.parse_covers(string.rep("\n", 31) .. "-- @covers command:Late\n"),
    {},
    "parse_covers: only the first 30 lines"
  )
  eq(
    tags.file_covers(tmp .. "/does_not_exist.lua"),
    {},
    "file_covers: an unreadable file claims nothing"
  )

  -- ------------------------------------------------------------------ the project
  write(
    "c_spec.lua",
    "-- @covers autocmd:g:BufEnter, binding:a|b\n-- @covers command:Gone\nreturn function() end\n"
  )
  write("d_spec.lua", "-- @covers command:Open\n")
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
    notes = {},
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
  local function services_with(coverage_cfg)
    return {
      cwd = tmp,
      config = {
        plugin = "fx",
        coverage = coverage_cfg or { bindings = 0, commands = 0 },
        deps = {},
      },
      collect = function()
        return vim.deepcopy(fixed)
      end,
    }
  end
  local services = services_with()

  -- a tracked run: a_spec exercised <leader>a (tracked) and claims `command:Fx status` by a tag; b_spec
  -- FAILED and claims `command:Open` (a failed case covers nothing); c_spec has a header
  local function case(id, file, status, claim, hit)
    return { id = id, file = file, status = status, tags = claim, surface = { hit = hit } }
  end
  local ir = {
    cases = {
      case(
        "a_spec.lua::x",
        "a_spec.lua",
        "pass",
        { "slow", "command:Fx status" },
        { "binding:<leader>a" }
      ),
      case("b_spec.lua::y", "b_spec.lua", "fail", { "command:Open" }, {}),
      case("c_spec.lua::z", "c_spec.lua", "pass", {}, {}),
    },
  }
  local ir_path = write("run.json", vim.json.encode(ir))

  local code, text = surface.main({ "--from", ir_path }, services)
  eq(code, 0, "tags: a report")
  has(text, "overall  4/5  80.0%", "tags: tracked + tag + header make 4 of 5")
  has(text, "hit (tag)", "tags: an entry counted from a tag says so")
  has(text, "not covered (1):", "report: the not covered block")
  has(text, "  command:Open - no feature test", "report: the failed case's claim does not count")
  has(text, "counted from tags", "tags: a note says they are claims")
  has(
    text,
    "exercised but not in the surface (1): command:Gone",
    "tags: a claim on an id that is not in the surface"
  )

  -- Gegenprobe: without tags the same run covers one entry
  _, text = surface.main({ "--from", ir_path, "--no-tags" }, services)
  has(text, "overall  1/5  20.0%", "no-tags: only the tracked execution counts")
  lacks(text, "hit (tag)", "no-tags: nothing is marked")
  has(text, "not covered (4):", "no-tags: four entries are not covered")

  -- Gegenprobe: a failing case's claim counts when the case passed
  local passed = vim.deepcopy(ir)
  passed.cases[2].status = "pass"
  _, text = surface.main({ "--from", write("run2.json", vim.json.encode(passed)) }, services)
  has(text, "overall  5/5  100.0%", "tags: the same claim of a passing case counts")
  lacks(text, "not covered", "tags: nothing left to cover")

  -- the claims are `extra` when the id is not in the surface
  local report = surface.report(tmp, {
    config = services.config,
    surface = fixed,
    hits = { from = { ir_path } },
  })
  eq(
    report.coverage.extra,
    { "command:Gone" },
    "tags: a stale tag is reported as exercised but not in the surface"
  )

  -- the gate sees the tags: coverage.commands = 1.0 fails without the claim and passes with it
  local gated = services_with({ bindings = 0, commands = 1.0 })
  code = surface.main({ "--from", ir_path }, gated)
  eq(code, 1, "gate: command:Open is still missing")
  code = surface.main({ "--from", write("run2b.json", vim.json.encode(passed)) }, gated)
  eq(code, 0, "gate: both commands covered (one by tag)")
  code =
    surface.main({ "--from", write("run2c.json", vim.json.encode(passed)), "--no-tags" }, gated)
  eq(code, 1, "gate: without tags the commands are not covered")

  -- tag cases of an IR without tracking: the tags are still evidence, the rest stays untracked
  local untracked = {
    cases = {
      { id = "a::x", file = "a_spec.lua", status = "pass", tags = { "binding:<leader>a" } },
    },
  }
  report = surface.report(tmp, {
    config = services.config,
    surface = fixed,
    hits = { ir = { untracked } },
  })
  eq(report.coverage.hit, 1, "untracked IR: the tagged entry is a hit")
  eq(#report.coverage.untracked, 4, "untracked IR: the rest stays untracked, never missing")

  -- `surface = { tags = false }` in `.testing.lua` is the same as --no-tags
  report = surface.report(tmp, {
    config = { plugin = "fx", surface = { tags = false } },
    surface = fixed,
    hits = { from = { ir_path } },
  })
  eq(report.coverage.hit, 1, "config: surface.tags = false counts the tracked execution only")

  -- a file path that points out of the project is not read: its header claims nothing
  vim.fn.mkdir(tmp .. "/sub", "p")
  local escaped = coverage.new_hits()
  escaped.tag_cases = { { id = "x", file = "../c_spec.lua", status = "pass", tags = {} } }
  eq(tags.apply(escaped, tmp .. "/sub"), 0, "apply: a header outside the root claims nothing")
  eq(escaped.hit, {}, "apply: and nothing is hit")
  local inside = coverage.new_hits()
  inside.tag_cases = { { id = "x", file = "c_spec.lua", status = "pass", tags = {} } }
  eq(tags.apply(inside, tmp), 3, "apply: the same header inside the root claims its ids")

  -- ------------------------------------------------------------------ the matrix
  local header_cells = function(line)
    return vim.split(line, "\t", { plain = true })
  end
  code, text = surface.main({ "--from", ir_path, "--matrix", "--csv" }, services)
  eq(code, 0, "matrix csv: a report")
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  eq(
    header_cells(lines[1]),
    { "KIND", "STATUS", "ID", "a_spec.lua", "b_spec.lua", "c_spec.lua", "TOTAL" },
    "matrix csv: header (the file column of a case that hit nothing is there, the path outside the root too)"
  )
  local by_id = {}
  for i = 2, #lines do
    local c = header_cells(lines[i])
    by_id[c[3]] = c
  end
  eq(
    by_id["binding:<leader>a"],
    { "binding", "hit", "binding:<leader>a", "1", "", "", "1" },
    "matrix: tracked"
  )
  eq(
    by_id["command:Fx status"],
    { "command", "hit (tag)", "command:Fx status", "1", "", "", "1" },
    "matrix: a tag"
  )
  eq(
    by_id["autocmd:g:BufEnter"],
    { "autocmd", "hit (tag)", "autocmd:g:BufEnter", "", "", "1", "1" },
    "matrix: a header"
  )
  eq(
    by_id["command:Open"],
    { "command", "missing", "command:Open", "", "", "", "" },
    "matrix: an entry no case exercised"
  )
  eq(by_id["health:fx"], nil, "matrix: a kind that is not observable is no row")

  _, text = surface.main({ "--from", ir_path, "--matrix" }, services)
  has(text, "surface matrix: fx (5 entries x 3 spec files)", "matrix text: title")
  has(text, "binding:<leader>a", "matrix text: rows")
  has(text, "overall  4/5", "matrix text: the summary")
  _, text = surface.main({ "--from", ir_path, "--matrix", "--markdown" }, services)
  has(
    text,
    "| KIND | STATUS | ID | a_spec.lua | b_spec.lua | c_spec.lua | TOTAL |",
    "matrix markdown: header"
  )
  has(text, "| --- | --- | --- | ---: | ---: | ---: | ---: |", "matrix markdown: alignment")
  _, text = surface.main({ "--from", ir_path, "--matrix", "--json" }, services)
  local doc = vim.json.decode(text)
  eq(doc.matrix.files, { "a_spec.lua", "b_spec.lua", "c_spec.lua" }, "matrix json: files")
  eq(#doc.matrix.rows, 5, "matrix json: rows")
  _, text = surface.main({ "--matrix" }, services)
  has(text, "no matrix", "matrix without a tracked run says so instead of inventing one")
  _, text = surface.main({ "--csv" }, services)
  eq(
    vim.split(vim.trim(text), "\n", { plain = true })[1],
    "KIND\tSTATUS\tHITS\tID\tSRC",
    "csv: the list"
  )

  -- a cell cannot split a row
  eq(
    require("testing.surface.render").csv({
      surface = { entries = { entry("command:A\tB\nC", "command", "x:1") } },
      plugin = "fx",
    }, false),
    "KIND\tSTATUS\tHITS\tID\tSRC\ncommand\t-\t\tcommand:A?B?C\tx:1\n",
    "csv: tabs and line breaks never split a cell"
  )

  -- one case in both lists counts once
  local cov = coverage.compute(fixed, assert(surface.hits({ from = { ir_path } })))
  local hits = assert(surface.hits({ from = { ir_path } }))
  tags.apply(hits, tmp)
  local m = coverage.matrix(cov, hits)
  eq(m.rows[1].cells["a_spec.lua"], 1, "matrix: a case that is tracked AND tagged counts once")

  -- ------------------------------------------------------------------ --write-ir
  local out_ir = tmp .. "/annotated.json"
  code = surface.main({ "--from", ir_path, "--write-ir", out_ir }, services)
  eq(code, 0, "write-ir: done")
  local f = assert(io.open(out_ir, "rb"))
  local annotated = vim.json.decode(f:read("*a"))
  f:close()
  eq(annotated.surface.total, 5, "write-ir: the section has the totals")
  eq(annotated.surface.hit, 4, "write-ir: and the hits")
  eq(annotated.surface.missing, { "command:Open" }, "write-ir: and what is not covered")
  eq(
    annotated.surface.tagged,
    { "binding:a|b", "command:Fx status", "autocmd:g:BufEnter" },
    "write-ir: and what came from tags"
  )
  eq(#annotated.cases, 3, "write-ir: the cases stay")
  code, text = surface.main({ "--write-ir", out_ir }, services)
  eq(code, 2, "write-ir without a run is a usage error")
  has(text, "--write-ir needs the IR", "write-ir: says it needs --from")
  eq(surface.parse_args({ "--write-ir" }), nil, "args: --write-ir needs a value")

  vim.fn.delete(tmp, "rf")
end
