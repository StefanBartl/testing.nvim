-- TESTS/testing/export_contract_spec.lua -- the contract `testing-export/1` as a client meets it: the golden files of
-- the export folder byte for byte, the same digest for an unchanged state (whenever and wherever it was built), a new
-- digest for a changed source, the manifest's sums, every document valid against the JSON Schema (and documents
-- that break it refused), and the rules of a reader (a higher schema refused, unknown fields ignored).

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local export = require("testing.export")
  local schema = require("testing.export.schema")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local bases = {}
  local function build(tag)
    local base = fixture.base(tag)
    bases[#bases + 1] = base
    return fixture.build(base)
  end
  local function bundle_of(fx, extra, install)
    local restore = fixture.install(install)
    local okb, b, err = pcall(export.export, fixture.opts(fx, extra))
    restore()
    ok(okb, "export raised: " .. tostring(b))
    ok(b, "export failed: " .. tostring(err))
    return b
  end
  local function by_path(b)
    local out = {}
    for _, f in ipairs(b.files) do
      out[f.path] = f
    end
    out[b.manifest.path] = b.manifest
    return out
  end

  local fx = build("contract-a")
  local first = bundle_of(fx)

  -- ── golden files: the export folder byte for byte ──
  do
    local files = by_path(first)
    local golden = {}
    for name, kind in vim.fs.dir(fixture.GOLDEN_DIR, { depth = 3 }) do
      if kind == "file" then
        golden[#golden + 1] = name
      end
    end
    table.sort(golden)
    local produced = vim.tbl_keys(files)
    table.sort(produced)
    eq(produced, golden, "the export folder has exactly the files of the golden folder")
    for _, path in ipairs(golden) do
      local want = fixture.read(fixture.GOLDEN_DIR .. "/" .. path)
      ok(want and not want:find("\r", 1, true), path .. ": the golden file is LF only")
      local got = files[path] and files[path].text
      local first_diff = "?"
      if got and want and got ~= want then
        local gl, wl = vim.split(got, "\n"), vim.split(want, "\n")
        for i = 1, math.max(#gl, #wl) do
          -- the first line of content that differs: a digest, a rev or a sum only follows from it
          local derived = (gl[i] or ""):find('"[a-z0-9_]*digest"')
            or (gl[i] or ""):find('"rev"')
            or (gl[i] or ""):find('"sha256"')
            or (gl[i] or ""):find('"bytes"')
          if gl[i] ~= wl[i] and not derived then
            first_diff = ("line %d: got %s, golden %s"):format(
              i,
              vim.inspect(gl[i]),
              vim.inspect(wl[i])
            )
            break
          end
        end
      end
      ok(
        got == want,
        ("golden %s differs (%s; regenerate: TESTS/golden/regenerate_export.lua)"):format(
          path,
          first_diff
        )
      )
    end
    eq(
      #first.files,
      4,
      "fleet.json and one repos/<key>.json per repository (the vault is left out)"
    )
  end

  -- ── the same state built elsewhere, at another time: same bytes but generated_at, same digest ──
  do
    local fx2 = build("contract-b")
    local second = bundle_of(fx2)
    local a, b = by_path(first), by_path(second)
    for path, f in pairs(a) do
      eq(
        b[path] and b[path].text,
        f.text,
        path .. ": a second export of the same state is the same bytes"
      )
    end
    -- another clock: only generated_at moves, the digest does not
    local restore = fixture.install({ no_clock = true })
    local saved_clock = export.clock
    export.clock = function()
      return "2030-01-01T00:00:00Z"
    end
    -- the fleet of an export folder (`export`: with the data classes; `fleet` alone does not ask them)
    local later_bundle, err = export.export(fixture.opts(fx2))
    export.clock = saved_clock
    restore()
    local later = later_bundle and later_bundle.docs["fleet.json"]
    ok(later, "fleet at another time: " .. tostring(err))
    eq(later.generated_at, "2030-01-01T00:00:00Z", "the clock is the seam of generated_at")
    eq(later.digest, first.docs["fleet.json"].digest, "the digest leaves generated_at out")
    eq(later.rev, first.docs["fleet.json"].rev, "rev too")
  end

  -- ── the manifest at another time, by another engine: the same digest; with the folder as it is, the same bytes ──
  do
    local function at(clock, git, previous)
      local restore = fixture.install({ no_clock = true })
      local saved_clock, saved_engine = export.clock, export.engine_info
      export.clock = function()
        return clock
      end
      export.engine_info = function()
        return vim.tbl_extend("force", vim.deepcopy(fixture.ENGINE), { git = git })
      end
      local okb, b, err = pcall(export.export, fixture.opts(fx, { previous = previous }))
      export.clock, export.engine_info = saved_clock, saved_engine
      restore()
      ok(okb and b, "export at " .. clock .. ": " .. tostring(okb and err or b))
      return b
    end
    local later = at("2026-11-01T08:00:00Z", "other-engine")
    local m0, m1 = first.docs[export.MANIFEST], later.docs[export.MANIFEST]
    eq(m1.generated_at, "2026-11-01T08:00:00Z", "the manifest of the later export has its time")
    eq(
      m1.digest,
      m0.digest,
      "the manifest's digest follows the content, not the bytes of its files"
    )
    eq(m1.rev, m0.rev, "its rev too")
    ok(
      later.files[1].text ~= first.files[1].text,
      "without the folder the files differ (generated_at)"
    )
    -- the later export knows the folder of the first one: every file, the manifest too, keeps its bytes
    local texts = by_path(first)
    local function previous(path)
      return texts[path] and texts[path].text or nil
    end
    local again = at("2026-11-01T08:00:00Z", "other-engine", previous)
    for path, f in pairs(by_path(again)) do
      eq(f.text, texts[path] and texts[path].text, path .. ": an unchanged state is the same bytes")
    end
    -- a changed source: that document (and the fleet, and the manifest) get the new time, the others keep theirs
    local fx4 = build("contract-d")
    local sdir = require("testing.history").dir(fx4.alpha, { state_dir = fx4.state })
    local ci = vim.json.decode(fixture.read(sdir .. "/ci.json"))
    ci.verdict = "red"
    fixture.write(sdir .. "/ci.json", vim.json.encode(ci))
    local restore = fixture.install({ no_clock = true })
    local saved_clock = export.clock
    export.clock = function()
      return "2026-11-02T08:00:00Z"
    end
    local changed = export.export(fixture.opts(fx4, { previous = previous }))
    export.clock = saved_clock
    restore()
    ok(changed, "the changed export")
    for path, doc in pairs(changed.docs) do
      if path:match("^repos/alpha") or path == "fleet.json" or path == export.MANIFEST then
        eq(doc.generated_at, "2026-11-02T08:00:00Z", path .. ": changed, the new time")
      else
        eq(doc.generated_at, fixture.NOW_ISO, path .. ": unchanged, the time of the folder")
      end
    end
    -- a file that is no document of this contract changes nothing
    local junk = at("2026-11-01T08:00:00Z", "other-engine", function()
      return "not json"
    end)
    eq(junk.docs["fleet.json"].generated_at, "2026-11-01T08:00:00Z", "a broken file: the new time")
  end

  -- ── a changed source: a new rev and a new digest, and the manifest follows ──
  do
    local fx3 = build("contract-c")
    local sdir = require("testing.history").dir(fx3.alpha, { state_dir = fx3.state })
    local ci = vim.json.decode(fixture.read(sdir .. "/ci.json"))
    ci.verdict = "red"
    ci.first_red = "luacheck"
    fixture.write(sdir .. "/ci.json", vim.json.encode(ci))
    local changed = bundle_of(fx3)
    ok(
      changed.docs["fleet.json"].digest ~= first.docs["fleet.json"].digest,
      "a red ci.json changes the fleet's digest"
    )
    ok(changed.docs["fleet.json"].rev ~= first.docs["fleet.json"].rev, "and its rev")
    ok(
      changed.docs[export.MANIFEST].digest ~= first.docs[export.MANIFEST].digest,
      "and the manifest's digest"
    )
    local beta_key
    for path in pairs(changed.docs) do
      if path:match("^repos/beta") then
        beta_key = path
      end
    end
    eq(
      changed.docs[beta_key].digest,
      first.docs[beta_key].digest,
      "the document of a repository that did not change keeps its digest"
    )
  end

  -- ── the manifest: path, sha256 and bytes of every file, the manifest itself not among them ──
  do
    local m = first.docs[export.MANIFEST]
    eq(m.kind, "manifest", "kind")
    eq(m.form, "export", "a manifest is always the export form")
    eq(#m.files, #first.files, "one entry per document file")
    for i, f in ipairs(first.files) do
      eq(m.files[i].path, f.path, "sorted by path")
      eq(m.files[i].sha256, vim.fn.sha256(f.text), f.path .. ": sha256 of the bytes")
      eq(m.files[i].bytes, #f.text, f.path .. ": bytes")
      eq(f.text:sub(-1), "\n", f.path .. ": ends in a line feed")
    end
    eq(first.manifest.path, "testing-export.json", "the manifest's name")
  end

  -- ── every document against the JSON Schema; the local form too ──
  do
    for path, doc in pairs(first.docs) do
      local valid, problems = export.validate(doc)
      ok(valid, path .. " is valid: " .. table.concat(problems or {}, "; "))
    end
    for path, f in pairs(by_path(first)) do
      local valid, problems = export.validate(f.text)
      ok(valid, path .. " (the file text) is valid: " .. table.concat(problems or {}, "; "))
    end
    local restore = fixture.install()
    local lfleet = export.fleet(fixture.opts(fx, { form = "local" }))
    local lrepo = export.repo(fx.beta, fixture.opts(fx, { form = "local" }))
    local norem = export.fleet(fixture.opts(fx, { remote = false }))
    restore()
    for name, doc in pairs({
      ["fleet local"] = lfleet,
      ["repo local"] = lrepo,
      ["fleet without remote"] = norem,
    }) do
      local valid, problems = export.validate(doc)
      ok(valid, name .. " is valid: " .. table.concat(problems or {}, "; "))
    end
    eq(norem.remote, { asked = false, error = vim.NIL }, "not asked: said so")
    eq(norem.repos[1].ci_remote, vim.NIL, "not asked: ci_remote is null (unknown), not a state")
  end

  -- ── documents that break the contract are refused: the schema is not "accepts everything" ──
  do
    local fleet = vim.json.decode(by_path(first)["fleet.json"].text)
    local function refused(mutate, what)
      local doc = vim.deepcopy(fleet)
      mutate(doc)
      local valid, problems = export.validate(vim.json.encode(doc))
      ok(not valid, what .. " is refused")
      return table.concat(problems, "; ")
    end
    has(
      refused(function(d)
        d.surprise = 1
      end, "a field nobody listed"),
      "nobody listed",
      "the reason"
    )
    refused(function(d)
      d.root = "/srv/repos"
    end, "root in the head of the export form")
    refused(function(d)
      d.repos[1].root = "C:/repos/alpha.nvim"
    end, "root in a row of the export form")
    refused(function(d)
      d.repos[1].key = "alpha.nvim"
    end, "a key without its hash")
    refused(function(d)
      d.repos[2]["local"].verdict = "purple"
    end, "a verdict outside the enum")
    refused(function(d)
      d.repos[1]["local"].summary.pass = nil
    end, "a summary without a status")
    refused(function(d)
      d.digest = "sha256:xyz"
    end, "a digest that is no hash")
    refused(function(d)
      d.repos[1].ci_remote.run.url = "https://evil.example/x"
    end, "a link that is not to GitHub")
    refused(function(d)
      d.kind = "runs"
    end, "a kind this version does not write")
    refused(function(d)
      d.excluded = -1
    end, "a negative count")
    refused(function(d)
      d.repos[1].counts = nil
    end, "a row without counts")
    -- an export form whose data classes were not asked (an engine before 8e623df): a reader must not show it
    has(
      refused(function(d)
        d.classes.checked = false
      end, "an export-form fleet with classes.checked false"),
      "classes.checked",
      "the reason names the field"
    )
    refused(function(d)
      d.classes = nil
    end, "an export-form fleet without classes")
    -- the rule is the export form's: the local form, which stays on this machine, does not ask the data classes
    local localf = vim.deepcopy(fleet)
    localf.form = "local"
    localf.classes.checked = false
    local lvalid, lproblems = export.validate(vim.json.encode(localf))
    ok(
      lvalid,
      "a local-form fleet with classes.checked false is valid: " .. table.concat(lproblems, "; ")
    )
  end

  -- ── the validator itself: a keyword it does not know is an error of the schema, not a pass ──
  do
    local raised, msg = pcall(
      schema.validate,
      { type = "object", propertyNames = { pattern = "^a" } },
      {}
    )
    ok(not raised, "an unknown keyword raises")
    has(tostring(msg), "unknown keyword", "named")
    eq(schema.type_of(vim.json.decode("{}")), "object", "an empty decoded object is an object")
    eq(schema.type_of(vim.json.decode("[]")), "array", "an empty decoded array is an array")
    eq(schema.type_of(1.5), "number", "number")
    eq(schema.type_of(2), "integer", "integer")
    eq(select(1, schema.validate({ type = "integer" }, 1.5)), false, "1.5 is not an integer")
    eq(
      select(1, schema.validate({ type = "string", pattern = "^[0-9a-f]{4}$" }, "beef")),
      true,
      "a pattern"
    )
    eq(
      select(1, schema.validate({ type = "string", pattern = "^[0-9a-f]{4}$" }, "beefy")),
      false,
      "a pattern that fails"
    )
    eq(
      select(1, schema.validate({ oneOf = { { type = "string" }, { type = "string" } } }, "x")),
      false,
      "oneOf: two match"
    )
  end

  -- ── a reader's rules ──
  do
    local text = by_path(first)["fleet.json"].text
    local doc, err = export.read(text)
    ok(doc and not err, "a fleet document reads")
    local newer = vim.json.decode(text)
    newer.schema = "testing-export/2"
    local _, e2 = export.read(vim.json.encode(newer))
    eq(e2 and e2.code, "unsupported_schema", "a higher schema is refused")
    local older = vim.json.decode(text)
    older.schema = "testing-export/0"
    ok(export.read(vim.json.encode(older)), "a lower one is read")
    local extra = vim.json.decode(text)
    extra.added_later = { "x" }
    extra.repos[1].added_later = true
    local read = export.read(vim.json.encode(extra))
    ok(read, "unknown fields are ignored, not an error")
    eq(read.repos[1].name, "alpha.nvim", "and the known ones are read")
    local _, e3 = export.read('{"schema":"tasks-export/1","kind":"fleet"}')
    eq(e3 and e3.code, "invalid", "another contract")
    local _, e4 = export.read('{"schema":"testing-export/1","kind":"runs"}')
    eq(e4 and e4.code, "unknown_kind", "an unknown kind")
    local _, e5 = export.read("[1,2]")
    eq(e5 and e5.code, "invalid", "not an object")
    local _, e6 = export.read(string.rep(" ", export.MAX_DOC_BYTES + 1))
    eq(e6 and e6.code, "payload_too_large", "more than 8 MiB")
  end

  for _, base in ipairs(bases) do
    vim.fn.delete(base, "rf")
  end
end
