-- TESTS/testing/scan_hostile_line_spec.lua -- a line made to keep a pattern busy must not stall the runner. The
-- directive patterns `(.-)%s*$` are quadratic in the blanks of a line such as `-- @cache x` + 40 000 spaces + `y`
-- (the lazy group grows one byte at a time and `%s*$` runs over the rest of the blanks each time): a spec in a pull
-- request could keep `testing explain`, `verify`, `--affected` and the key of every run busy for hours without
-- running anything. The directives read the rest of the line now, a header line is cut at a bound, and the same
-- shape is gone from the regex fallback of the spec discovery and from the CI migration.

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local scan = require("testing.affected.scan")
  local wrapped = require("testing.affected.wrapped")

  ---Run `fn` as one section: a failure is collected, so one run names every section that is red.
  local failed = {}
  local function section(name, fn)
    local good, err = pcall(fn)
    if not good then
      failed[#failed + 1] = name .. ": " .. tostring(err)
    end
  end

  -- a linear scan of this line takes about a millisecond, the quadratic one more than a second
  local BLANKS = 60000
  local LIMIT_MS = 250

  ---@param fn fun(): any
  ---@return any result
  ---@return number ms
  local function timed(fn)
    local t0 = vim.uv.hrtime()
    local result = fn()
    return result, (vim.uv.hrtime() - t0) / 1e6
  end

  local PAD = (" "):rep(BLANKS)

  -- ---------------------------------------------------------------- the directive patterns are linear
  -- (the bound of the line length is lifted: the patterns must be linear on their own)
  local DIRECTIVES = {
    {
      "@cache",
      "x",
      function(d)
        return d.off
      end,
      false,
    },
    {
      "@cache-allow",
      "time",
      function(d)
        return d.allow
      end,
      { "time" },
    },
    {
      "@cache-env",
      "A",
      function(d)
        return d.env
      end,
      { "A" },
    },
    {
      "@cache-inputs",
      "fixtures/",
      function(d)
        return d.inputs
      end,
      { "fixtures/" },
    },
    {
      "@require-wrapper",
      "lazy",
      function(d)
        return d.wrapper
      end,
      { "lazy" },
    },
  }
  for _, row in ipairs(DIRECTIVES) do
    local name, word, pick, expected = row[1], row[2], row[3], row[4]
    section("linear: -- " .. name, function()
      local bound = scan.MAX_HEADER_LINE
      scan.MAX_HEADER_LINE = math.huge
      local good, err = pcall(function()
        -- the blanks lie between the word and a character that is not blank: the pattern must find the end of the line
        local text = ("-- %s %s%sy\nreturn 1\n"):format(name, word, PAD)
        local info, ms = timed(function()
          return scan.analyze(text)
        end)
        ok(
          ms < LIMIT_MS,
          ("`-- %s` with %d blanks in the line took %.0f ms (limit %d)"):format(
            name,
            BLANKS,
            ms,
            LIMIT_MS
          )
        )
        if name == "@cache" then
          eq(pick(info.directives), false, name .. ": the words after the blanks are no `off`")
        elseif name == "@cache-env" then
          eq(pick(info.directives), { "A", "y" }, name .. ": and the words of the line are read")
        elseif name == "@cache-inputs" then
          eq(
            pick(info.directives),
            { "fixtures/", "y" },
            name .. ": and the words of the line are read"
          )
        elseif name == "@cache-allow" then
          eq(pick(info.directives), expected, name .. ": and the allowed word is read")
        else
          eq(
            pick(info.directives),
            { "lazy", "y" },
            name .. ": and the members of the line are read"
          )
        end
        -- blanks at the end of the line (what `(.-)%s*$` was for) change nothing
        local tail = scan.analyze(("-- %s %s%s\nreturn 1\n"):format(name, word, PAD)).directives
        if name == "@cache" then
          eq(pick(tail), false, name .. ": blanks at the end")
        else
          eq(pick(tail), expected, name .. ": blanks at the end are no word")
        end
      end)
      scan.MAX_HEADER_LINE = bound
      if not good then
        error(err, 0)
      end
    end)
  end

  section("linear: `-- @cache off` with blanks around it", function()
    local bound = scan.MAX_HEADER_LINE
    scan.MAX_HEADER_LINE = math.huge
    local good, err = pcall(function()
      local info, ms = timed(function()
        return scan.analyze("--" .. PAD .. "@cache" .. PAD .. "off" .. PAD .. "\nreturn 1\n")
      end)
      ok(ms < LIMIT_MS, ("a directive between blanks took %.0f ms (limit %d)"):format(ms, LIMIT_MS))
      ok(info.directives.off, "it is still `off`")
    end)
    scan.MAX_HEADER_LINE = bound
    if not good then
      error(err, 0)
    end
  end)

  section("linear: the wrapper directive on its own", function()
    local members, ms = timed(function()
      return wrapped.directive("-- @require-wrapper a" .. PAD .. "b")
    end)
    ok(
      ms < LIMIT_MS,
      ("`-- @require-wrapper` with %d blanks took %.0f ms (limit %d)"):format(BLANKS, ms, LIMIT_MS)
    )
    eq(members, { "a", "b" }, "the members of the line")
    eq(
      wrapped.directive("-- @require-wrapper a b   "),
      { "a", "b" },
      "blanks at the end of the line"
    )
    eq(wrapped.directive("-- not a directive"), nil, "a line that is none")
  end)

  -- ---------------------------------------------------------------- the line is cut at a bound
  section("a header line is cut after a whole word", function()
    local max = scan.MAX_HEADER_LINE
    ok(max >= 1024 and max <= 1024 * 1024, "the bound is a number of bytes: " .. tostring(max))
    local prefix = "-- @cache-allow "
    -- `env` ends exactly at the bound and a blank follows: the word is whole and counts
    local fits = prefix .. (" "):rep(max - #prefix - 3) .. "env random"
    eq(
      scan.analyze(fits .. "\nreturn 1\n").directives.allow,
      { "env" },
      "a word that ends at the bound counts"
    )
    -- `environment` is cut after `env`: the part that is left of a word is not another word
    local straddles = prefix .. (" "):rep(max - #prefix - 3) .. "environment"
    eq(
      scan.analyze(straddles .. "\nreturn 1\n").directives.allow,
      {},
      "a word the cut splits is dropped"
    )
    -- what lies beyond the bound is not read
    local beyond = prefix .. "time" .. (" "):rep(max) .. "random"
    eq(
      scan.analyze(beyond .. "\nreturn 1\n").directives.allow,
      { "time" },
      "words behind the bound are not read"
    )
    -- the directive itself survives a long line
    ok(
      scan.analyze("-- @cache off" .. (" "):rep(max * 4) .. "x\nreturn 1\n").directives.off,
      "`-- @cache off` in front of a very long run of blanks"
    )
    local env_line = "-- @cache-env " .. ("A "):rep(100000)
    local info, ms = timed(function()
      return scan.analyze(env_line .. "\nreturn 1\n")
    end)
    ok(ms < LIMIT_MS, ("a header line of 200 KB took %.0f ms (limit %d)"):format(ms, LIMIT_MS))
    eq(
      #info.directives.env,
      scan.MAX_ENV_DECLARED,
      "and its words are read, up to the number a file may declare"
    )
    -- lines of an ordinary length are read to the end
    eq(
      scan.analyze("-- @cache-env " .. ("N" .. ("x"):rep(40) .. " "):rep(300) .. "\nreturn 1\n").directives.env[64],
      "N" .. ("x"):rep(40),
      "a line of 12 KB is not cut"
    )
  end)

  -- ---------------------------------------------------------------- the regex fallback of the spec discovery
  section("positions: the regex fallback", function()
    local positions = require("testing.discover.positions")
    local text = 'it("a"x' .. PAD .. "y\nit('b'   , function() end)\n"
    local res, ms = timed(function()
      return positions.scan(text, { backend = "regex" })
    end)
    ok(
      ms < LIMIT_MS,
      ("a line with %d blanks took %.0f ms (limit %d)"):format(BLANKS, ms, LIMIT_MS)
    )
    eq(#res.positions, 2, "both calls are positions")
    ok(res.positions[1].dynamic, "a name that is followed by more than a `,` or `)` is dynamic")
    eq(res.positions[2].name, "b", "a name followed by blanks and a comma is plain")
    eq(res.positions[2].dynamic, false, "and not dynamic")
  end)

  -- ---------------------------------------------------------------- the CI migration
  section("migrate: the lines of a workflow", function()
    local ci = require("testing.migrate.ci")
    local ctx = {
      drop_plenary = false,
      fleet_deps = {},
      is_self = true,
      dep_step = function()
        return nil
      end,
      artifact_step = function()
        return nil
      end,
    }
    local function workflow(lib_line, name_line)
      return table.concat({
        "name: ci",
        "on: [push]",
        "jobs:",
        "  tests:",
        name_line,
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v5",
        "      - name: Run the specs",
        "        env:",
        lib_line,
        "          OTHER: 1",
        "        run: bash scripts/test.sh",
        "",
      }, "\n")
    end
    local function edit(src)
      return timed(function()
        return ci.edit(src, ctx)
      end)
    end
    local _, ms = edit(workflow("          LIB_NVIM_PATH: x" .. PAD .. "y", "    name: tests"))
    ok(
      ms < LIMIT_MS,
      ("a LIB_NVIM_PATH line with %d blanks took %.0f ms (limit %d)"):format(BLANKS, ms, LIMIT_MS)
    )
    _, ms = edit(workflow("          LIB_NVIM_PATH: x", "    name: plenary" .. PAD .. "y"))
    ok(
      ms < LIMIT_MS,
      ("a job name with %d blanks took %.0f ms (limit %d)"):format(BLANKS, ms, LIMIT_MS)
    )
    -- blanks at the end of a line are no part of its value
    local r = ci.edit(
      workflow(
        "          LIB_NVIM_PATH: ${{ github.workspace }}/lib.nvim   ",
        "    name: plenary tests   "
      ),
      ctx
    )
    ok(r.text ~= nil, "the workflow is edited")
    ok(
      r.text:find("LIB_NVIM_PATH", 1, true) == nil,
      "a LIB_NVIM_PATH line with blanks at its end still goes"
    )
    ok(
      r.text:find("    name: tests\n", 1, true) ~= nil,
      "a job name with blanks at its end is neutral again"
    )
  end)

  ok(#failed == 0, "sections that are red:\n" .. table.concat(failed, "\n"))
end
