-- TESTS/testing/config_pattern_spec.lua -- `testing.config.pattern`: the syntax check of a Lua pattern that the
-- configuration (`spec_pattern`, `guards.*.ignore_patterns` / `allow_patterns`, `surface.ignore`) relies on.
-- `pcall(string.find, "", p)` only reads the first pattern item, so `a[` or `%.log%` passed the old check and raised
-- on the first file name that reached the broken item. Here: the broken patterns are refused (each one raises in the
-- real matcher for the subject given), the good ones pass, the check never accepts a pattern the matcher rejects
-- (a generated set compared with the real matcher), `project.validate` names the key, and the fs guard does not lose
-- its tree snapshot to a pattern that slipped in by another way.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields, undefined-field

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end

  local pattern = require("testing.config.pattern")
  local project = require("testing.config.project")

  -- ---------------------------------------------------------------- broken patterns: each raises for SOME subject
  local broken = {
    { "a[", "ab", "missing ']'" },
    { "a(", "ab", "unfinished capture" },
    { "a.)", "ab", "invalid pattern capture" },
    { "a%", "ab", "ends with '%'" },
    { "%.log%", "x.log", "ends with '%'" },
    { "_spec%.lua%", "a_spec.lua", "ends with '%'" },
    { "x%b", "xy", "'%b'" },
    { "x%f", "xy", "'%f'" },
    { "x%f%a", "xy", "'%f'" },
    { "[a%]", "a", "missing ']'" },
    { "(a%1)", "aa", "invalid capture index" },
    { "x%1", "xx", "invalid capture index" },
    { "x%0", "x0", "invalid capture index" },
    { "x[%", "x", "missing ']'" },
    { "x[^", "x", "missing ']'" },
    { "((a)", "a", "unfinished capture" },
    { "(a))", "a", "invalid pattern capture" },
  }
  for _, c in ipairs(broken) do
    local p, subject, why = c[1], c[2], c[3]
    ok(
      not pcall(string.find, subject, p),
      ("the matcher itself raises for %s on %s"):format(vim.inspect(p), vim.inspect(subject))
    )
    local good, err = pattern.check(p)
    eq(good, false, ("check refuses %s"):format(vim.inspect(p)))
    has(err, why, ("the reason for %s"):format(vim.inspect(p)))
  end

  -- the ones the old probe let through: pcall on "" says fine, the matcher disagrees on a real subject
  for _, p in ipairs({ "a[", "a(", "a.)", "a%", "%.log%", "_spec%.lua%", "x%b", "x%f" }) do
    ok(pcall(string.find, "", p), ("the old probe accepted %s"):format(vim.inspect(p)))
  end

  -- ---------------------------------------------------------------- good patterns
  for _, p in ipairs({
    "_spec%.lua$",
    "^%.git$",
    "%.log$",
    "%.swp$",
    "^TESTS/",
    "[]]",
    "[^]]",
    "[%]]",
    "[a-z%d_]+",
    "%f[%w]%w+%f[%W]",
    "%b()",
    "(a)%1",
    "()",
    "(a)(b)(c)%3%2%1",
    "a-",
    "a*b+c?",
    "%%",
    "%(",
    "%)",
    "[(]",
    "[)]",
    ".",
    "^",
    "$",
    "a^b$c",
  }) do
    local good, err = pattern.check(p)
    ok(good, ("check accepts %s (%s)"):format(vim.inspect(p), tostring(err)))
    ok(pcall(string.find, "ab(c)[d]", p), ("and the matcher agrees on %s"):format(vim.inspect(p)))
  end
  eq(pattern.checked("a%"), nil, "checked: nil for a broken pattern")
  eq(pattern.checked("a%d"), "a%d", "checked: the pattern itself for a good one")
  eq(pattern.check(42), false, "a number is not a pattern")
  eq(pattern.check(nil), false, "nil is not a pattern")
  eq(pattern.check(("(a)"):rep(33)), false, "33 captures are too many")
  eq(pattern.check(("(a)"):rep(32)), true, "32 captures are the limit")

  -- ---------------------------------------------------------------- never accepts what the matcher rejects
  -- A generated set (fixed seed): every pattern the check accepts must run on every probe subject without raising.
  local alphabet = {
    "a",
    "b",
    "%",
    "[",
    "]",
    "(",
    ")",
    "^",
    "$",
    ".",
    "-",
    "*",
    "+",
    "?",
    "1",
    "2",
    "0",
    "f",
    "%",
    "[",
    "(",
    ")",
    "b",
  }
  local subjects = {
    "",
    "a",
    "b",
    "ab",
    "aab",
    "a(b)",
    "[a]",
    "%a",
    "a.b",
    "1",
    "12",
    "a1b2",
    "()",
    "((",
    "f",
    "ba",
    "^a$",
    "-",
    "ab-ab",
    "a%b",
    "]",
    "aa1aa",
    "b1b",
    "abab",
    "a b",
  }
  math.randomseed(20261007)
  local accepted, seen = 0, {}
  local escaped = {}
  for _ = 1, 20000 do
    local t = {}
    for i = 1, math.random(1, 9) do
      t[i] = alphabet[math.random(#alphabet)]
    end
    local p = table.concat(t)
    if not seen[p] then
      seen[p] = true
      if pattern.check(p) then
        accepted = accepted + 1
        for _, s in ipairs(subjects) do
          if not pcall(string.find, s, p) then
            escaped[#escaped + 1] = ("%s on %s"):format(vim.inspect(p), vim.inspect(s))
            break
          end
        end
      end
    end
  end
  ok(accepted > 1000, "the generated set has enough good patterns to mean something: " .. accepted)
  eq(escaped, {}, "no accepted pattern raises in the real matcher")

  -- ---------------------------------------------------------------- the configuration names the key
  ---@param raw table
  ---@return table config
  ---@return string[] problems
  local function validate(raw)
    return project.validate(raw)
  end
  local defaults = require("testing.config.DEFAULTS").project

  local cfg, problems = validate({ spec_pattern = { "_spec%.lua%" } })
  eq(#problems, 1, "spec_pattern: one problem: " .. vim.inspect(problems))
  has(problems[1], "'spec_pattern'", "it names the key")
  eq(cfg.spec_pattern, defaults.spec_pattern, "and the default stays")
  cfg, problems = validate({ spec_pattern = { "_spec%.lua$", "x(" } })
  eq(
    #problems,
    1,
    "one broken entry refuses the list (it is checked entry by entry): " .. vim.inspect(problems)
  )
  eq(cfg.spec_pattern, defaults.spec_pattern, "the default stays")
  cfg, problems = validate({ spec_pattern = { "_spec%.lua$", "_test%.lua$" } })
  eq(problems, {}, "good patterns: no problem")
  eq(cfg.spec_pattern, { "_spec%.lua$", "_test%.lua$" }, "and they are kept")

  cfg, problems = validate({ guards = { fs = { mode = "error", ignore_patterns = { "a[" } } } })
  eq(#problems, 1, "guards.fs.ignore_patterns: one problem: " .. vim.inspect(problems))
  has(problems[1], "guards.fs.ignore_patterns", "it names the key")
  eq(cfg.guards.fs.mode, "error", "a wrong key does not take the mode with it")
  eq(cfg.guards.fs.ignore_patterns, nil, "and the broken list is not kept")
  local _, allow_problems = validate({ guards = { fs = { allow_patterns = { "%.log%" } } } })
  eq(#allow_problems, 1, "guards.fs.allow_patterns: one problem")
  _, allow_problems = validate({ guards = { scheduled_error = { allow_patterns = { "x%b" } } } })
  eq(#allow_problems, 1, "guards.scheduled_error.allow_patterns: one problem")
  cfg, problems = validate({ surface = { ignore = { "x(" } } })
  eq(#problems, 1, "surface.ignore: one problem")
  eq(cfg.surface.ignore, defaults.surface.ignore, "the default stays")
  cfg, problems = validate({ guards = { fs = { ignore_patterns = { "%.log$", "^tmp/" } } } })
  eq(problems, {}, "good guard patterns: no problem")
  eq(cfg.guards.fs.ignore_patterns, { "%.log$", "^tmp/" }, "and they are kept")

  -- ---------------------------------------------------------------- the fs guard keeps its tree snapshot
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-fspat"
  vim.fn.mkdir(tmp, "p")
  local function touch(rel)
    local f = assert(io.open(tmp .. "/" .. rel, "wb"))
    f:write("x")
    f:close()
  end
  touch("alpha.txt")
  touch("old.log")

  local notes, findings = {}, {}
  ---@type table
  local handle = {
    cfg = { repo = tmp, tmp = {}, run_dir = nil },
    notes = notes,
    redact = function(s)
      return s
    end,
    label = function()
      return "case"
    end,
    log = function() end,
    finding = function(_, guard, id, message)
      findings[#findings + 1] = { guard = guard, id = id, message = message }
    end,
  }
  local fs_guard = require("testing.guard.fs").new(handle, {
    mode = "error",
    snapshot = true,
    allow = {},
    allow_patterns = {},
    ignore = {},
    -- the first entry is what a typo looks like; the second is a valid one that must still hide `*.log`
    ignore_patterns = { "a[", "%.log$" },
    max_files = 1000,
    max_depth = 8,
    watch = { tmp },
  })
  -- the temp directory is an allowed root of the guard; for this check the walk is all that matters
  fs_guard.refresh_roots = function(self)
    self.allowed = {}
    self.cache = {}
  end

  local snap = fs_guard:snapshot({ heavy = true })
  ok(snap.trees ~= nil, "the snapshot is taken (the broken entry did not end it)")
  touch("abc.txt")
  touch("new.log")
  fs_guard:check(snap, {})
  local created = {}
  for _, f in ipairs(findings) do
    created[#created + 1] = f.message
  end
  local joined = table.concat(created, "\n")
  has(joined, "abc.txt", "a file made after the snapshot is found although a pattern is broken")
  ok(not joined:find("new.log", 1, true), "a valid ignore pattern still hides `*.log`")
  eq(findings[1] and findings[1].id, "fs.changed_outside", "as the finding of the tree snapshot")
  local note_text = table.concat(notes, "\n")
  has(note_text, "ignore_patterns entry", "the broken entry is named in a note")
  has(note_text, '"a["', "with its text")
  eq(#notes, 1, "once, not once per walk")

  vim.fn.delete(tmp, "rf")
end
