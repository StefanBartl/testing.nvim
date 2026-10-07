-- TESTS/testing/scan_env_spelling_spec.lua -- every spelling of a read of the environment is a read: a literal name
-- joins the key, a computed one blocks it. Covers `expand("$VAR")` and its kin (`exists`, `eval`, `nvim_eval`, an ex
-- command with a path), `call("getenv")`, `vim.fn["getenv"]`, white space inside the call, and a string that only
-- MENTIONS `os.getenv("X")` and must not hide a computed read next to it. The scan of a long run of
-- identifier characters is linear.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-allow env
-- @cache-allow time
-- @cache-env A B HOME MYAPP_HOME
-- (the fixtures of this spec spell out every way to read the environment; the scan of a long run is timed)
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

  ---@param text string
  ---@return { names: string[], computed: boolean, whole: boolean }
  local function read_of(text)
    local m = scan.analyze(text).markers
    return { names = m.env, computed = m.env_computed, whole = m.env_whole }
  end

  -- ---------------------------------------------------------------- a literal name is named
  section("literal names", function()
    local named = {
      { "expand('$MYAPP_HOME/x')", "vim.fn.expand('$MYAPP_HOME/x')" },
      { 'expand("${MYAPP_HOME}/x")', 'return vim.fn.expand("${MYAPP_HOME}/x")' },
      { "expandcmd", "return vim.fn.expandcmd('$MYAPP_HOME')" },
      { "exists", "return vim.fn.exists('$MYAPP_HOME') == 1" },
      { "eval", "return vim.fn.eval('$MYAPP_HOME')" },
      { "nvim_eval", "return vim.api.nvim_eval('$MYAPP_HOME')" },
      { "glob", "return vim.fn.glob('$MYAPP_HOME/*')" },
      { "a concatenation", "return vim.fn.expand('$MYAPP_HOME/' .. name)" },
      { "a second piece", "return vim.fn.expand(root .. '/$MYAPP_HOME')" },
      { "a grouping parenthesis", "return vim.fn.expand(('$MYAPP_HOME/%s'):format(name))" },
      { "a call in between", "return vim.fn.expand(vim.fs.normalize('$MYAPP_HOME'))" },
      { "vim.cmd", "vim.cmd('let g:v = $MYAPP_HOME')" },
      { "vim.cmd edit", "vim.cmd('edit $MYAPP_HOME/x')" },
      { "vim.cmd braces", "vim.cmd('edit ${MYAPP_HOME}/x')" },
      { "vim.cmd.edit", "vim.cmd.edit('$MYAPP_HOME/x')" },
      { "vim.cmd long string", "vim.cmd([[\n  let g:v = $MYAPP_HOME\n]])" },
      { "vim.cmd without parentheses", "vim.cmd 'let g:v = $MYAPP_HOME'" },
      { "nvim_command", "vim.api.nvim_command('let g:v = $MYAPP_HOME')" },
      { "nvim_exec2", "vim.api.nvim_exec2('echo $MYAPP_HOME', {})" },
      { "execute", "vim.fn.execute('echo $MYAPP_HOME')" },
      { "call getenv", "return vim.fn.call('getenv', { 'MYAPP_HOME' })" },
      { "vim.call getenv", "return vim.call('getenv', 'MYAPP_HOME')" },
      { "nvim_call_function", "return vim.api.nvim_call_function('getenv', { 'MYAPP_HOME' })" },
      { "fn bracket", "return vim.fn['getenv']('MYAPP_HOME')" },
      { "fn bracket double quotes", 'return vim.fn["getenv"]("MYAPP_HOME")' },
      { "os bracket", "return os['getenv']('MYAPP_HOME')" },
      -- (built in pieces: the scanner of THIS file must not read the fixture as a call without parentheses)
      { "uv bracket", "return vim.uv[" .. "'os_getenv'" .. "]('MYAPP_HOME')" },
      { "tab before the parenthesis", "return os.getenv\t('MYAPP_HOME')" },
      { "two spaces", "return os.getenv  ('MYAPP_HOME')" },
      { "a line end", "return os.getenv\n('MYAPP_HOME')" },
      { "vim.fn.getenv tab", "return vim.fn.getenv\t('MYAPP_HOME')" },
      { "vim.env space", "return vim.env ['MYAPP_HOME']" },
      { "vim.env dot", "return vim.env.MYAPP_HOME" },
    }
    for _, c in ipairs(named) do
      local r = read_of(c[2])
      ok(vim.tbl_contains(r.names, "MYAPP_HOME"), c[1] .. ": names the variable " .. vim.inspect(r))
      ok(not r.computed, c[1] .. ": and is no computed read " .. vim.inspect(r))
    end
    -- `~` is the home directory: the variable it comes from
    local r = read_of("return vim.fn.expand('~/x')")
    ok(
      vim.tbl_contains(r.names, "HOME") and vim.tbl_contains(r.names, "USERPROFILE"),
      "expand('~/x') reads HOME or USERPROFILE: " .. vim.inspect(r)
    )
    ok(vim.tbl_contains(read_of("return vim.fn.expand('~')").names, "HOME"), "expand('~')")
  end)

  -- ---------------------------------------------------------------- a computed name blocks
  section("computed names", function()
    local computed = {
      { "call getenv", "return vim.fn.call('getenv', { name })" },
      { "vim.call", "return vim.call('getenv', name)" },
      { "nvim_call_function", "return vim.api.nvim_call_function('getenv', { name })" },
      { "fn bracket", "return vim.fn['getenv'](name)" },
      { "os bracket", "return os['getenv'](name)" },
      { "tab", "return os.getenv\t(name)" },
      { "two spaces", "return os.getenv  (name)" },
      { "a line end", "return os.getenv\n(name)" },
      { "vim.fn.getenv tab", "return vim.fn.getenv\t(name)" },
      { "vim.env space", "return vim.env [name]" },
      { "expand", "return vim.fn.expand('$' .. name)" },
      { "expand a prefix", "return vim.fn.expand('$MYAPP_' .. name .. '/x')" },
      { "expand braces", "return vim.fn.expand('${' .. name .. '}')" },
      { "exists", "return vim.fn.exists('$' .. name)" },
      { "nvim_eval", "return vim.api.nvim_eval('$' .. name)" },
      { "vim.cmd", "vim.cmd('edit $' .. name)" },
    }
    for _, c in ipairs(computed) do
      local r = read_of(c[2])
      ok(r.computed, c[1] .. ": a computed name " .. vim.inspect(r))
    end
  end)

  -- ---------------------------------------------------------------- what is no read stays no read
  section("no read", function()
    local none = {
      "return vim.fn.expand('%:p')",
      "return vim.fn.expand('<cword>')",
      "return vim.fn.expand('<sfile>:p:h')",
      "return vim.fn.exists('g:x')",
      "return vim.fn.exists(':Foo')",
      "return vim.fn.eval('1 + 1')",
      "return vim.fn.glob('*.lua')",
      -- `$` is the end of a line or a range, no variable
      "vim.cmd('normal! $a')",
      "vim.cmd('normal! $' .. keys)",
      "vim.cmd('1,$d')",
      "vim.cmd('$put')",
      "vim.cmd('s/x$/y/')",
      "vim.cmd('echo \"cost: $5\"')",
      -- a `$` in a string that nothing expands: a shell description, a Lua pattern
      "return quote('$HOME is mine')",
      "return ('a$b'):find('$')",
      "return s:match('^%s*$')",
      "return describe('echoes $PATH')",
      -- an injected reader, no environment read
      "return seam.getenv",
      "local t = { getenv = fake }",
      -- a string that is a file name with a tilde, no expansion
      "return name == '~'",
    }
    for _, text in ipairs(none) do
      local r = read_of(text)
      ok(
        #r.names == 0 and not r.computed and not r.whole,
        text .. ": no environment read " .. vim.inspect(r)
      )
    end
  end)

  -- ---------------------------------------------------------------- the key follows the variable
  local env = {}
  local function ctx(root, over)
    return vim.tbl_extend("force", {
      root = root,
      cache_dir = vim.fs.normalize(vim.fn.tempname()),
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return env
      end,
      hasher = hash.new(),
      spec_roots = { "TESTS" },
      unresolved = "error",
    }, over or {})
  end
  local SPEC = "TESTS/p_spec.lua"
  local function key_of(root, over)
    local k, why, parts = cache.key({ file = SPEC }, ctx(root, over))
    return k, why, parts
  end
  ---A project whose module reads the variable `MYAPP_HOME` the way `read` says, and a spec that loads the module.
  local function module_project(read)
    return S.project({
      ["lua/envmod.lua"] = "local M = {}\nfunction M.get(name)\n  " .. read .. "\nend\nreturn M\n",
      [SPEC] = 'local m = require("envmod")\nreturn function(H) H.ok(m.get("x"), "read") end\n',
    })
  end

  local reads = {
    { "expand", "return vim.fn.expand('$MYAPP_HOME/x')" },
    { "nvim_eval", "return vim.api.nvim_eval('$MYAPP_HOME')" },
    { "exists", "return vim.fn.exists('$MYAPP_HOME')" },
    { "vim.cmd", "vim.cmd('let g:v = $MYAPP_HOME') return 1" },
    { "call getenv", "return vim.fn.call('getenv', { 'MYAPP_HOME' })" },
    { "nvim_call_function", "return vim.api.nvim_call_function('getenv', { 'MYAPP_HOME' })" },
    { "fn bracket", "return vim.fn['getenv']('MYAPP_HOME')" },
    { "os.getenv with a tab", "return os.getenv\t('MYAPP_HOME')" },
  }
  for _, r in ipairs(reads) do
    section("key of a module that reads " .. r[1], function()
      env = { MYAPP_HOME = "/one" }
      local root = module_project(r[2])
      local k1, why, parts = key_of(root)
      ok(k1 ~= nil, "a module that reads a variable by a literal name has a key: " .. tostring(why))
      ok(
        table.concat(parts, "\n"):find("env MYAPP_HOME=" .. vim.fn.sha256("/one"), 1, true) ~= nil,
        "the value of the variable is part of the key"
      )
      env.MYAPP_HOME = "/two"
      ok(key_of(root) ~= k1, "a changed value changes the key")
      S.remove(root)
    end)
  end

  local computed_reads = {
    { "expand", "return vim.fn.expand('$' .. name)" },
    { "call getenv", "return vim.fn.call('getenv', { name })" },
    { "fn bracket", "return vim.fn['getenv'](name)" },
    { "os.getenv with a line end", "return os.getenv\n(name)" },
  }
  for _, r in ipairs(computed_reads) do
    section("no key for a module that computes " .. r[1], function()
      env = { MYAPP_HOME = "/one" }
      local root = module_project(r[2])
      local k, why = key_of(root)
      ok(k == nil, "a module that computes the name has no key")
      ok(
        type(why) == "string" and why:find("computed name", 1, true) ~= nil,
        "and says why: " .. tostring(why)
      )
      S.remove(root)
    end)
  end

  section("key of a spec that reads by a spelling", function()
    env = { MYAPP_HOME = "/one" }
    local root = S.project({
      [SPEC] = "return function(H) H.ok(vim.fn.expand('$MYAPP_HOME/x') ~= '', 'x') end\n",
    })
    local k, why = key_of(root)
    ok(k == nil, "a spec that expands a variable nobody lists has no key")
    ok(
      type(why) == "string" and why:find("MYAPP_HOME", 1, true) ~= nil,
      "and names the variable: " .. tostring(why)
    )
    local k1 = key_of(root, { env_names = { "MYAPP_HOME" } })
    ok(k1 ~= nil, "a listed variable has a key")
    env.MYAPP_HOME = "/two"
    ok(key_of(root, { env_names = { "MYAPP_HOME" } }) ~= k1, "which follows its value")
    S.remove(root)
  end)

  section("key of a spec that is no reader", function()
    env = { MYAPP_HOME = "/one" }
    local root = S.project({
      [SPEC] = "return function(H) H.ok(vim.fn.expand('%:p') ~= nil and vim.fn.exists('g:x') == 0, 'x') end\n",
    })
    ok(key_of(root) ~= nil, "expand('%:p') and exists('g:x') read no variable")
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- a string that mentions a read hides nothing
  section("a mention in a string", function()
    local bait = {
      { "os.getenv", [[local doc = 'use os.getenv("HOME") here']], "return os.getenv(name)" },
      { "double quotes", [[local doc = "call os.getenv('HOME')"]], "return os.getenv(name)" },
      { "long string", "local doc = [[os.getenv('HOME')]]", "return os.getenv(name)" },
      { "uv", [[local doc = 'vim.uv.os_getenv("HOME")']], "return vim.uv.os_getenv(name)" },
      { "vim.fn.getenv", [[local doc = "vim.fn.getenv('HOME')"]], "return vim.fn.getenv(name)" },
      { "vim.env", "local doc = 'see vim.env.HOME'", "return vim.env[name]" },
      { "vim.env bracket", [[local doc = "vim.env['HOME']"]], "return vim.env[name]" },
      { "pcall", [[local doc = 'pcall(os.getenv, "HOME")']], "return pcall(os.getenv, name)" },
      { "no parentheses", [[local doc = 'os.getenv"HOME"']], "return os.getenv(name)" },
      { "fn bracket", [[local doc = "vim.fn['getenv']('HOME')"]], "return vim.fn['getenv'](name)" },
      {
        "call getenv",
        [[local doc = "call('getenv', { 'HOME' })"]],
        "return vim.fn.call('getenv', { name })",
      },
    }
    for _, b in ipairs(bait) do
      local text = b[2] .. "\nlocal M = {}\nfunction M.get(name)\n  " .. b[3] .. "\nend\nreturn M\n"
      local r = read_of(text)
      ok(
        r.computed,
        b[1] .. ": the computed read next to the mention is still computed " .. vim.inspect(r)
      )
      ok(vim.tbl_contains(r.names, "HOME"), b[1] .. ": the mentioned name is still collected")
      -- a comment in front moves every offset of the text: the same answer
      local with_comment = read_of("-- a comment\n--[[ and a\nblock comment ]]\n" .. text)
      ok(with_comment.computed, b[1] .. ": with comments in front " .. vim.inspect(with_comment))
      -- the mention alone is no computed read
      local alone = read_of(b[2] .. "\n")
      ok(not alone.computed, b[1] .. ": a mention alone is no computed read " .. vim.inspect(alone))
    end
    -- a real call with a literal name next to a mention: no computed read
    local r = read_of([[local doc = 'os.getenv("A")']] .. "\nreturn os.getenv('B')\n")
    ok(not r.computed, "a literal call next to a mention is no computed read")
    eq(r.names, { "A", "B" }, "both names are collected")
  end)

  section("key of a module that mentions a read in a string", function()
    env = { MYAPP_HOME = "/one" }
    local root = S.project({
      ["lua/pad.lua"] = "local doc = 'use os.getenv(\"HOME\") here'\n"
        .. "return { get = function(n) return os.getenv(n) end }\n",
      [SPEC] = 'local m = require("pad")\nreturn function(H) H.ok(m.get("MYAPP_HOME"), "read") end\n',
    })
    local k, why = key_of(root, { env_names = { "HOME" } })
    ok(k == nil, "a module that reads by a computed name has no key, a mention does not hide it")
    ok(
      type(why) == "string" and why:find("computed name", 1, true) ~= nil,
      "and says why: " .. tostring(why)
    )
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- the scan is linear
  section("long runs of identifier characters", function()
    local function ms(text)
      local t0 = vim.uv.hrtime()
      local info = scan.analyze(text)
      return (vim.uv.hrtime() - t0) / 1e6, info
    end
    -- 40 KB of `a.a.a. ...`: the scan of a run that starts at every position took seconds
    local dotted, info = ms("local x = " .. string.rep("a.", 20000) .. "b\n")
    ok(dotted < 1500, ("a dotted run of 40 KB is scanned in %.0f ms"):format(dotted))
    ok(not info.markers.env_computed, "and it reads no environment")
    local word = ms("local x = " .. string.rep("a", 50000) .. "\n")
    ok(word < 1500, ("a word of 50000 characters is scanned in %.0f ms"):format(word))
    local many, many_info = ms(string.rep("local g = os.getenv\n", 3000))
    ok(many < 1500, ("3000 references are scanned in %.0f ms"):format(many))
    ok(many_info.markers.env_computed, "and every one of them is a read: a computed name")
    -- the answer is the same at the end of a long run
    local tail = scan.analyze("local x = " .. string.rep("a.", 5000) .. "os.getenv\n")
    ok(tail.markers.env_computed, "a reference that ends a long run is a read")
    local called = scan.analyze("local x = " .. string.rep("a.", 5000) .. "os.getenv('A')\n")
    ok(not called.markers.env_computed, "a call that ends a long run names its variable")
    eq(called.markers.env, { "A" }, "which is A")
  end)

  ok(#failed == 0, "sections that are red:\n" .. table.concat(failed, "\n"))
end
