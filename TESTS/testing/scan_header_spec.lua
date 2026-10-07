-- TESTS/testing/scan_header_spec.lua -- the directives in the header of a file (`-- @cache off`, `-- @cache-inputs`,
-- `-- @cache-allow`, `-- @cache-env`) are read from the first 30 LINES, whatever the line ends are (`\n`, `\r\n`,
-- `\r`), and a byte order mark in front of the first line hides nothing. A directive that is dropped without a word is
-- a stale pass: the author wrote `-- @cache off` or `-- @cache-inputs fixtures/` and the cache keeps a result all the same.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-allow env
-- (the fixtures of this spec are spec files that read paths and names by a computed name)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")
  local scan = require("testing.affected.scan")

  ---Run `fn` as one section: a failure is collected, so one run names every section that is red.
  local failed = {}
  local function section(name, fn)
    local good, err = pcall(fn)
    if not good then
      failed[#failed + 1] = name .. ": " .. tostring(err)
    end
  end

  local BOM = "\239\187\191"
  local EOLS = { ["\n"] = "LF", ["\r\n"] = "CRLF", ["\r"] = "CR" }

  ---A file whose directive is on line `at` (the lines before it are comments), then one line of code.
  ---@param at integer
  ---@param directive string
  ---@param eol string
  ---@param prefix? string
  local function file_with(at, directive, eol, prefix)
    local lines = {}
    for i = 1, at - 1 do
      lines[#lines + 1] = "-- filler " .. i
    end
    lines[#lines + 1] = directive
    lines[#lines + 1] = "return 1"
    return (prefix or "") .. table.concat(lines, eol) .. eol
  end

  -- ---------------------------------------------------------------- the window is 30 lines, not 15 (or 10)
  for eol, label in pairs(EOLS) do
    section("window " .. label, function()
      eq(scan.HEADER_LINES, 30, "the window is 30 lines")
      for _, at in ipairs({ 1, 9, 10, 11, 15, 16, 21, 29, 30 }) do
        local d = scan.analyze(file_with(at, "-- @cache off", eol)).directives
        ok(d.off, label .. ": `-- @cache off` on line " .. at .. " counts")
        d = scan.analyze(file_with(at, "-- @cache-inputs fixtures/ docs/a.md", eol)).directives
        eq(d.inputs, { "fixtures/", "docs/a.md" }, label .. ": `-- @cache-inputs` on line " .. at)
        d = scan.analyze(file_with(at, "-- @cache-allow time random", eol)).directives
        eq(d.allow, { "time", "random" }, label .. ": `-- @cache-allow` on line " .. at)
        d = scan.analyze(file_with(at, "-- @cache-env FOO_* BAR", eol)).directives
        eq(d.env, { "FOO_*", "BAR" }, label .. ": `-- @cache-env` on line " .. at)
        d = scan.analyze(file_with(at, "-- @require-wrapper require lazy", eol)).directives
        eq(d.wrapper, { "require", "lazy" }, label .. ": `-- @require-wrapper` on line " .. at)
      end
      local d = scan.analyze(file_with(31, "-- @cache off", eol)).directives
      ok(not d.off, label .. ": line 31 is outside the window")
      d = scan.analyze(file_with(31, "-- @cache-inputs fixtures/", eol)).directives
      eq(d.inputs, {}, label .. ": and so is an input declared there")
      d = scan.analyze(file_with(40, "-- @cache-allow time", eol)).directives
      eq(d.allow, {}, label .. ": and a vouching")
    end)
  end

  section("blank lines count", function()
    -- thirty lines, 29 of them empty: the directive is the last line of the window
    local text = string.rep("\n", 29) .. "-- @cache off\nreturn 1\n"
    ok(scan.analyze(text).directives.off, "a directive after 29 empty lines is on line 30")
    ok(not scan.analyze("\n" .. text).directives.off, "and one more empty line puts it on line 31")
    ok(
      scan.analyze(string.rep("\r\n", 29) .. "-- @cache off\r\nreturn 1\r\n").directives.off,
      "the same with CRLF"
    )
    -- a file that is all one line, or has no line end at the end, is read
    ok(scan.analyze("-- @cache off").directives.off, "a file of one line without a line end")
    ok(scan.analyze("-- @cache off\r").directives.off, "and a lone carriage return at its end")
    ok(
      scan.analyze("\n\n-- @cache off").directives.off,
      "a directive on the last line without an end"
    )
    eq(scan.analyze("").directives.inputs, {}, "an empty file")
  end)

  section("the line end belongs to no line", function()
    -- a `\r` left at the end of a line would not match a pattern anchored with `%s*$` on some paths: pin the outcome
    local d =
      scan.analyze("-- @cache-env  A  B  \r\n-- @cache-inputs  x/  \r\nreturn 1\r\n").directives
    eq(d.env, { "A", "B" }, "env names without the carriage return")
    eq(d.inputs, { "x/" }, "inputs without the carriage return")
  end)

  -- ---------------------------------------------------------------- a byte order mark hides nothing
  section("byte order mark", function()
    local text = BOM
      .. "-- @cache off\n-- @cache-inputs fixtures/\n-- @cache-allow time\n-- @cache-env FOO_*\nreturn 1\n"
    local plain = scan.analyze((text:gsub("^" .. BOM, ""))).directives
    local with = scan.analyze(text).directives
    ok(plain.off, "fixture: the plain file has the directive")
    eq(with, plain, "a file with a byte order mark has the same directives")
    eq(with.inputs, { "fixtures/" }, "the first line is the directive of `-- @cache-inputs`")
    local second = scan.analyze(BOM .. "-- header\n-- @cache off\nreturn 1\n").directives
    ok(second.off, "a directive on line 2 counts with a byte order mark too")
    -- the code after the mark is analysed like any code: a `require` on the first line is seen
    local first = scan.analyze(BOM .. 'local a = require("x.y")\nreturn a\n')
    eq(first.requires, { "x.y" }, "a require on the first line")
    -- the mark alone, in the middle of the text, is no mark
    ok(
      not scan.analyze("-- header\n" .. BOM .. "-- @cache off\n").directives.off,
      "a mark in the middle of a file is text, not a mark"
    )
  end)

  section("the version of the analysis moved", function()
    ok(
      scan.VERSION >= 10,
      "analyses of the older scanner are read again: " .. tostring(scan.VERSION)
    )
  end)

  -- ---------------------------------------------------------------- the keys: the author's word is kept
  ---A project whose spec reads a file by a computed path (no literal anywhere) and declares it in the header.
  local function reads_project(header, eol, prefix)
    local body = {
      "local data = vim.fs.joinpath(vim.uv.cwd(), ('fix' .. 'tures'), 'x.txt')",
      "return function(H) local f = io.open(data, 'rb') H.ok(f, 'reads') end",
    }
    return S.project({
      ["fixtures/x.txt"] = "v1\n",
      ["TESTS/p_spec.lua"] = (prefix or "")
        .. table.concat(vim.list_extend(vim.deepcopy(header), body), eol)
        .. eol,
    })
  end
  local function ctx(root)
    return {
      root = root,
      cache_dir = vim.fs.normalize(vim.fn.tempname()),
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
      spec_roots = { "TESTS" },
      unresolved = "error",
    }
  end
  local SPEC = "TESTS/p_spec.lua"
  local function key_of(root)
    return cache.key({ file = SPEC }, ctx(root))
  end
  ---Header of `n` comment lines, then the directive.
  local function header(n, directive)
    local lines = {}
    for i = 1, n do
      lines[#lines + 1] = "-- filler " .. i
    end
    lines[#lines + 1] = directive
    return lines
  end

  for eol, label in pairs(EOLS) do
    section("key: `-- @cache-inputs` on line 21 (" .. label .. ")", function()
      local root = reads_project(header(20, "-- @cache-inputs fixtures/"), eol)
      local k0, why = key_of(root)
      ok(k0 ~= nil, "a spec with a declared input has a key: " .. tostring(why))
      S.edit(root, "fixtures/x.txt", "v2\n")
      ok(
        key_of(root) ~= k0,
        label .. ": the declared directory is an input, a fixture edit changes the key"
      )
      S.remove(root)
    end)
    section("key: the control without the directive (" .. label .. ")", function()
      -- the scenario is real: without the declaration the key does not see the computed path
      local root = reads_project(header(20, "-- not a directive"), eol)
      local k0 = key_of(root)
      ok(k0 ~= nil, "a key")
      S.edit(root, "fixtures/x.txt", "v2\n")
      eq(key_of(root), k0, label .. ": the computed path is not seen without a declaration")
      S.remove(root)
    end)
    section("key: `-- @cache off` on line 21 (" .. label .. ")", function()
      local root = S.project({
        [SPEC] = table.concat(header(20, "-- @cache off"), eol)
          .. eol
          .. "return function(H) end"
          .. eol,
      })
      local k, why = key_of(root)
      ok(k == nil, label .. ": a spec that opts out has no key")
      ok(
        type(why) == "string" and why:find("@cache off", 1, true) ~= nil,
        label .. ": and says why: " .. tostring(why)
      )
      S.remove(root)
    end)
  end

  section("key: a byte order mark in front of the directive on line 1", function()
    local root = S.project({
      [SPEC] = BOM .. "-- @cache off\nreturn function(H) end\n",
    })
    local k, why = key_of(root)
    ok(k == nil, "a spec with a mark and `-- @cache off` has no key")
    ok(
      type(why) == "string" and why:find("@cache off", 1, true) ~= nil,
      "and says why: " .. tostring(why)
    )
    S.remove(root)
    root = reads_project({ "-- @cache-inputs fixtures/" }, "\n", BOM)
    local k0 = key_of(root)
    ok(k0 ~= nil, "a spec with a mark and a declared input has a key")
    S.edit(root, "fixtures/x.txt", "v2\n")
    ok(key_of(root) ~= k0, "and the declared directory is an input")
    S.remove(root)
  end)

  ok(#failed == 0, "sections that are red:\n" .. table.concat(failed, "\n"))
end
