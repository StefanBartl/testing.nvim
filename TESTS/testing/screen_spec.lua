-- TESTS/testing/screen_spec.lua -- screen snapshots (testing.screen): masks by pattern, text and
-- screen cell (wide characters as a whole), placeholders, attribute letters given again after
-- masking, the file format, the snapshot path, and the outcomes of compare (match, written,
-- updated, missing on CI, differ, error) with CRLF files. Pure: hand-made screens, no child.

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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local screen = require("testing.screen")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-screen"
  vim.fn.mkdir(root .. "/TESTS/sub", "p")
  local spec = root .. "/TESTS/sub/dialog_spec.lua"

  ---A screen from rows of cells and attribute letters (one letter per cell).
  local function shot(rows, attrs, extra)
    local cells, lines = {}, {}
    for r, row in ipairs(rows) do
      cells[r] = row
      lines[r] = table.concat(row)
    end
    local s = {
      size = { rows = #rows, cols = #rows[1] },
      cursor = { row = 1, col = 1 },
      mode = "n",
      lines = lines,
      attrs = attrs,
      cells = cells,
      cell_attrs = attrs,
    }
    return vim.tbl_extend("force", s, extra or {})
  end
  local function chars(s)
    local t = {}
    for ch in s:gmatch(".") do
      t[#t + 1] = ch
    end
    return t
  end

  local function slurp(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end

  local body_ok, body_err = xpcall(function()
    -- ===================================================================
    -- 1. masks
    do
      local s = shot(
        { chars("time 12:34 ok"), chars("status line ") },
        { "aaaaabbbbbaaa", "cccccccccccc" }
      )
      local n = screen.normalize(s, { masks = { "%d%d:%d%d" } })
      eq(n.text[1], "time ##### ok", "a pattern mask keeps the width")
      eq(n.attrs[1], "aaaaa#####aaa", "masked cells get the attribute #")
      eq(
        n.attrs[2],
        "bbbbbbbbbbbb",
        "letters are given again after masking: b was masked away, c becomes b"
      )

      local r = screen.normalize(s, { masks = { { row = 2 } } })
      eq(r.text[2], "############", "a rectangle with only a row masks the whole row")
      eq(r.text[1], "time 12:34 ok", "and nothing else")

      local c = screen.normalize(s, { masks = { { row = 1, col = 6, cols = 2 } } })
      eq(c.text[1], "time ##:34 ok", "col and cols are 1-based screen cells")

      local t = screen.normalize(s, { masks = { { text = "12:" } } })
      eq(t.text[1], "time ###34 ok", "a text mask is a literal, not a pattern")

      local p = screen.normalize(s, { masks = { { pattern = "o." } } })
      eq(p.text[1], "time 12:34 ##", "{ pattern = p } is a Lua pattern")

      local okm, errm = pcall(screen.normalize, s, { masks = { { row = 0 } } })
      ok(
        not okm and tostring(errm):find("positive integer", 1, true) ~= nil,
        "row 0 is refused: " .. tostring(errm)
      )
      local oke = pcall(screen.normalize, s, { masks = { 42 } } --[[@as any]])
      ok(not oke, "a mask of another type is refused")
    end

    -- wide characters: the second cell is "", masking either half masks both
    do
      local s = shot({ { "a", "日", "", "b" } }, { "xyyz" })
      local n = screen.normalize(s, { masks = { { row = 1, col = 3, cols = 1 } } })
      eq(
        n.text[1],
        "a##b",
        "masking the second half of a wide character masks it whole, width kept"
      )
      eq(n.attrs[1], "a##b", "its two cells get the attribute #")
      local plain = screen.normalize(s)
      eq(plain.text[1], "a日b", "unmasked: the wide character once")
      eq(plain.attrs[1], "abc", "and one attribute letter for it")
    end

    -- placeholders: both slash styles, longest root first; the attribute row keeps its width
    do
      local s = shot({ chars("C:\\tmp\\x\\f.lua  ") }, { "aaaaaaaaaaaaaaaa" })
      local n = screen.normalize(s, { roots = { tmp = "C:/tmp", repo = "C:/tmp/x" } })
      eq(n.text[1], "<REPO>\\f.lua", "the longer root wins, backslash spelling replaced")
      eq(n.attrs[1], "aaaaaaaaaaaaaaaa", "attributes untouched by placeholders")
      local rep = screen.normalize(s, { replace = { { from = "f.lua", to = "<F>" } } })
      has(rep.text[1], "<F>", "a plain replacement")
    end

    -- a shot without cells (older child, hand-made): one cell per character from lines/attrs
    do
      local n = screen.normalize({
        size = { rows = 1, cols = 4 },
        lines = { "ab日c" },
        attrs = { "  ab" },
      })
      eq(n.text[1], "ab日c", "characters from lines")
      eq(n.attrs[1], "  ab", "attributes from attrs")
    end

    -- cursor and mode are part of the snapshot unless switched off
    do
      local s = shot({ chars("x") }, { " " }, { cursor = { row = 1, col = 2 }, mode = "i" })
      eq(
        screen.render(screen.normalize(s)),
        "testing.nvim screen v1\nsize: 1x1\ncursor: 1,2\nmode: i\n--- text\n1|x\n--- attrs\n1|\n",
        "the file format"
      )
      local off = screen.render(screen.normalize(s, { cursor = false, mode = false }))
      ok(
        not off:find("cursor:", 1, true) and not off:find("mode:", 1, true),
        "cursor = false, mode = false leave them out"
      )
    end

    -- row numbers are as wide as the largest
    do
      local rows, attrs = {}, {}
      for i = 1, 12 do
        rows[i] = chars("r")
        attrs[i] = " "
      end
      local out = screen.render(screen.normalize(shot(rows, attrs)))
      has(out, "\n01|r\n", "two digits for twelve rows")
      has(out, "\n12|r\n", "the last row")
    end

    -- ===================================================================
    -- 2. path
    do
      local p, rel = screen.path("confirm.80x24", { root = root, file = spec })
      eq(
        rel,
        "TESTS/__snapshots__/sub/dialog_spec/confirm.80x24.snap",
        "TESTS/ and .lua leave the spec part"
      )
      eq(p, root .. "/" .. rel, "absolute below the root")
      local _, rel2 =
        screen.path("x", { root = root, file = root .. "/other/thing_spec.lua", dir = "snaps" })
      eq(
        rel2,
        "snaps/other/thing_spec/x.snap",
        "dir is configurable; a spec outside TESTS keeps its folder"
      )
      local _, rel3 = screen.path("x", { root = root .. "/nope", file = spec })
      eq(rel3, "TESTS/__snapshots__/dialog_spec/x.snap", "a spec outside the root: its base name")
      for _, bad in ipairs({ "", "../x", "a/b", "a..b", ".x", ("n"):rep(101) }) do
        local np, why = screen.path(bad, { root = root, file = spec })
        ok(np == nil and why:find("snapshot name", 1, true) ~= nil, "name refused: " .. bad)
      end
      local this = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
      local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))
      local fp = screen.path("found", { root = repo })
      ok(
        fp ~= nil and fp:find("/TESTS/__snapshots__/testing/screen_spec/found.snap", 1, true) ~= nil,
        "without file: the spec on the call stack (" .. tostring(fp) .. ")"
      )
    end

    -- ===================================================================
    -- 3. compare
    local base = { root = root, file = spec, ci = false, update = false }
    local function o(extra)
      return vim.tbl_extend("force", base, extra or {})
    end
    local s1 = shot({ chars("hello  "), chars("world  ") }, { "aaaaa  ", "bbbbb  " })
    local s2 = shot({ chars("hello  "), chars("WORLD  ") }, { "aaaaa  ", "bbbbb  " })

    do
      local miss = screen.compare("ci", s1, o({ ci = true }))
      eq({ miss.ok, miss.status }, { false, "missing" }, "no file on CI: a failure")
      eq(slurp(miss.path), nil, "and nothing written on CI")
      has(miss.message, "is missing", "the message says why")

      local w = screen.compare("one", s1, o())
      eq({ w.ok, w.status }, { true, "written" }, "no file locally: written, passes")
      has(w.message, "written (new)", "the message says it was written")
      eq(slurp(w.path), w.actual, "the file holds the rendering")

      local m = screen.compare("one", s1, o())
      eq({ m.ok, m.status }, { true, "match" }, "the same screen matches")

      local d = screen.compare("one", s2, o())
      eq({ d.ok, d.status }, { false, "differ" }, "another screen differs")
      has(d.message, "  - 2|world", "the message shows the snapshot row")
      has(d.message, "  + 2|WORLD", "and the screen row")
      has(d.message, "--update-snapshots", "and how to accept it")
      eq(slurp(d.path), w.actual, "a difference leaves the file alone")

      local u = screen.compare("one", s2, o({ update = true }))
      eq({ u.ok, u.status }, { true, "updated" }, "updating rewrites a difference")
      eq(slurp(u.path), u.actual, "the file holds the new rendering")
      eq(
        screen.compare("one", s2, o({ ci = true })).status,
        "match",
        "and matches afterwards, also on CI"
      )

      local crlf = u.path:gsub("one%.snap$", "crlf.snap")
      local f = assert(io.open(crlf, "wb"))
      f:write((u.actual:gsub("\n", "\r\n")))
      f:close()
      eq(screen.compare("crlf", s2, o()).status, "match", "a file checked out with CRLF matches")

      local bad = screen.compare("a/b", s1, o())
      eq({ bad.ok, bad.status }, { false, "error" }, "a bad name is an error, not a crash")
    end

    -- expect hands the verdict to the harness; check raises
    do
      local got
      local r_ok = screen.expect(function(v, msg)
        got = { v, msg }
      end, "one", s2, o())
      ok(
        r_ok == true and got[1] == true and got[2]:find("matches", 1, true) ~= nil,
        "expect calls ok_fn(true, msg)"
      )
      screen.expect(function(v)
        got = v
      end, "one", s1, o())
      eq(got, false, "expect calls ok_fn(false, ...) on a difference")
      local raised, err = pcall(screen.check, "one", s1, o())
      ok(
        not raised and tostring(err):find("differs", 1, true) ~= nil,
        "check raises on a difference"
      )
      ok(pcall(screen.check, "one", s2, o()), "check passes on a match")
    end
  end, debug.traceback)

  vim.fn.delete(root, "rf")
  ok(body_ok, "screen spec body: " .. tostring(body_err))
end
