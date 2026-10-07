-- TESTS/testing/child_env_key_spec.lua -- the part of the cache key that stands for the environment of a child editor
-- (`testing.run.cached.child_env_lines`): exactly what a child can see of the parent stays in it (a variable it
-- can read is a hidden input), and what the driver replaces before the child starts (the locale and the time zone)
-- does not, so two machines with another `LANG` share their hits. Every rule has its mutation here.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-env TERM LANG TZ
-- (the variables the spec sets and restores itself: their outer values join the key; the whole environment is in the key anyway through
-- the modules that build the key)

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local cached = require("testing.run.cached")
  local child = require("testing.child")
  local explain = require("testing.cache.explain")
  local sha = vim.fn.sha256

  local function lines_of(environ, opts)
    return cached.child_env_lines(environ, opts or {})
  end
  local function find(lines, name)
    for _, l in ipairs(lines) do
      if l:match("^" .. vim.pesc(name) .. "=") then
        return l
      end
    end
  end
  local BASE = {
    PATH = "/usr/bin",
    TERM = "xterm",
    COLORTERM = "truecolor",
    DISPLAY = ":0",
    HOME = "/home/a",
    LANG = "de_AT.UTF-8",
    LANGUAGE = "de",
    LC_TIME = "de_AT.UTF-8",
    TZ = "Europe/Vienna",
    SECRET_TOKEN = "s3cret",
    NVIM = "/tmp/nvim.sock",
    MYVAR = "1",
  }
  local function with(over)
    return vim.tbl_extend("force", BASE, over)
  end

  -- ---------------------------------------------------------------- what the child cannot see is not there
  local base = lines_of(BASE)
  ok(find(base, "SECRET_TOKEN") == nil, "a variable outside the allowlist is not in the key")
  ok(find(base, "NVIM") == nil, "a variable of the parent editor is not")
  ok(find(base, "MYVAR") == nil, "a project variable that is not in `env_allow` is not")
  ok(
    find(lines_of(BASE, { env_allow = { "MYVAR" } }), "MYVAR") == "MYVAR=" .. sha("1"),
    "but one that is, with the hash of its value"
  )
  ok(not table.concat(base, "\n"):find("s3cret", 1, true), "no value is written out, only hashes")

  -- ---------------------------------------------------------------- what the child sees stays
  for _, name in ipairs({ "PATH", "TERM", "COLORTERM", "DISPLAY", "HOME" }) do
    ok(
      not vim.deep_equal(lines_of(with({ [name] = "changed" })), base),
      name .. " is read by a child, so its value is part of the key"
    )
  end
  ok(
    not vim.deep_equal(
      lines_of(with({ MYVAR = "2" }), { env_allow = { "MYVAR" } }),
      lines_of(BASE, { env_allow = { "MYVAR" } })
    ),
    "a variable of `env_allow` too"
  )
  ok(
    not vim.deep_equal(
      lines_of(with({ LUA_X = "2" }), { env_allow = { "LUA_*" } }),
      lines_of(with({ LUA_X = "1" }), { env_allow = { "LUA_*" } })
    ),
    "and one that a prefix of it names"
  )

  -- ---------------------------------------------------------------- what the driver replaces does not
  ok(
    find(base, "LANG") == "LANG=" .. sha("C.UTF-8"),
    "the child gets a fixed LANG: that is what the key holds"
  )
  ok(find(base, "TZ") == "TZ=" .. sha("UTC"), "and a fixed TZ")
  ok(find(base, "LANGUAGE") == nil and find(base, "LC_TIME") == nil, "and no other locale variable")
  eq(
    lines_of(
      with({ LANG = "en_US.UTF-8", LANGUAGE = "en", LC_TIME = "C", TZ = "America/New_York" })
    ),
    base,
    "another locale or time zone of the parent gives the same lines (the hits survive another machine)"
  )
  eq(
    lines_of(with({ LC_ALL = "fr_FR.UTF-8", LC_MESSAGES = "fr" })),
    base,
    "also LC_ALL and the other LC_*"
  )
  -- without determinism the child gets the parent's locale: it is part of the key again, and the two modes differ
  local free = lines_of(BASE, { determinism = false })
  ok(
    find(free, "LANG") == "LANG=" .. sha("de_AT.UTF-8"),
    "determinism = false: the parent's LANG reaches the child"
  )
  ok(
    not vim.deep_equal(lines_of(with({ LANG = "en_US.UTF-8" }), { determinism = false }), free),
    "so a changed LANG changes the lines"
  )
  ok(
    not vim.deep_equal(free, base) and vim.tbl_contains(free, "#determinism=false"),
    "and the mode is part of the lines"
  )

  -- ---------------------------------------------------------------- the lines are what `testing.child` builds
  -- (a variable the driver starts passing on must show up here, or a changed value of it would be a stale pass)
  for _, det in ipairs({ true, false }) do
    local environ = with({ LUA_X = "lx", Path = nil })
    local built = child.environment({
      parent_env = environ,
      env_allow = { "LUA_*" },
      deterministic = det,
      base = vim.fn.tempname(),
      name = "key-spec",
    })
    local env = {}
    for name, value in pairs(built.env) do
      -- the sandbox variables are the driver's own, not the parent's
      local up = name:upper()
      if not (up:match("^XDG_") or up == "TEMP" or up == "TMP" or up == "TMPDIR") then
        env[name] = value
      end
    end
    local expected = {}
    for name, value in pairs(env) do
      expected[#expected + 1] = name .. "=" .. sha(value)
    end
    table.sort(expected)
    local got = vim.tbl_filter(function(l)
      return l:sub(1, 1) ~= "#"
    end, lines_of(environ, { env_allow = { "LUA_*" }, determinism = det }))
    eq(
      got,
      expected,
      ("determinism = %s: the key lines are the environment the child is built with"):format(
        tostring(det)
      )
    )
  end

  -- ---------------------------------------------------------------- in the key, and named by `testing explain`
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-childenvkey"
  vim.fn.mkdir(tmp .. "/p/TESTS", "p")
  local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  write(tmp .. "/p/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n")
  write(tmp .. "/p/.testing.lua", "return { plugin = 'proj', minit = false, isolated = 'file' }\n")
  local cli = require("testing.cli")
  local function parts_of()
    local out = {}
    cli.main({ "explain", tmp .. "/p", "a_spec", "--json", "--parts" }, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function() end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      affected = { getenv = function() end, provider = false },
    })
    local doc = vim.json.decode(table.concat(out, "\n"))
    return doc.specs[1].key, doc.specs[1].parts
  end
  local function setenv(name, value)
    local old = vim.env[name]
    vim.env[name] = value
    return function()
      vim.env[name] = old
    end
  end
  local restore = setenv("TERM", "tn-term-one")
  local k1, p1 = parts_of()
  ok(k1 ~= nil, "a file that runs in a child has a key")
  ok(find(
    vim.tbl_map(function(l)
      return (l:gsub("^child%-env ", ""))
    end, p1 or {}),
    "TERM"
  ) ~= nil, "its parts hold the child's environment line by line")
  vim.env.TERM = "tn-term-two"
  local k2, p2 = parts_of()
  ok(k2 ~= k1, "a changed TERM (the child reads it) changes the key")
  local changes = explain.diff(p1, p2)
  eq(#changes, 1, "and it is the only change")
  eq(
    changes[1] and changes[1].kind .. " " .. changes[1].name,
    "child-env TERM",
    "which `explain` names by the variable"
  )
  local restore_lang = setenv("LANG", "xx_XX.UTF-8")
  local restore_tz = setenv("TZ", "Pacific/Fiji")
  local k3 = parts_of()
  restore_lang()
  restore_tz()
  eq(k3, k2, "another LANG and TZ (replaced in the child) keep the key")
  restore()
  vim.fn.delete(tmp, "rf")
end
