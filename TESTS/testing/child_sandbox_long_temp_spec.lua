-- TESTS/testing/child_sandbox_long_temp_spec.lua -- a child's sandbox never inherits the 8.3 short form of the parent's
-- temp directory (Windows: `C:\Users\STEFAN~1\...`). `vim.fn.glob()` finds nothing below a path with a short-name
-- component, so a spec that globs below `tempname()` was red locally and green on CI (no short form there). The base of
-- the sandbox is brought into its long form before `TEMP`/`TMP`/`TMPDIR`/XDG are built from it, and the IR scrubber
-- still turns such a long-form path into `<TMP>` when the parent's temp dir is the short form. Windows only (a short
-- form exists nowhere else); skipped where the volume does not generate 8.3 names.

return function(H)
  local ok = H.ok
  if vim.fn.has("win32") ~= 1 then
    ok(true, "skipped: 8.3 short names exist on Windows only")
    return
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local child_mod = require("testing.child")

  ---@param p string
  ---@return boolean
  local function has_short(p)
    return p:find("~%d") ~= nil
  end

  S.run(function()
    local long = S.new_dir() .. "/a_rather_long_sandbox_parent_directory"
    vim.fn.mkdir(long, "p")
    if long:find('[%s"&|<>^()]') then
      ok(true, "skipped: the temp path needs quoting for cmd (" .. long .. ")")
      return
    end
    -- no quotes: libuv would escape them for cmd (`\"`), and a temp path without blanks needs none
    local res = vim
      .system(
        { "cmd", "/d", "/c", ("for %%I in (%s) do @echo %%~sI"):format((long:gsub("/", "\\"))) },
        { text = true }
      )
      :wait()
    local short = vim.trim(res.stdout or ""):gsub("\\", "/")
    if res.code ~= 0 or not has_short(short) then
      ok(true, "skipped: this volume does not generate 8.3 names (" .. short .. ")")
      return
    end

    -- the positive control: below the short form, glob really finds nothing
    local probe = short .. "/probe"
    vim.fn.mkdir(probe, "p")
    vim.fn.writefile({ "x" }, probe .. "/f.txt")
    ok(vim.fn.filereadable(probe .. "/f.txt") == 1, "the probe file exists below the short form")
    if #vim.fn.glob(probe .. "/*", false, true) ~= 0 then
      ok(true, "skipped: glob finds files below a short-form path on this editor, nothing to guard")
      return
    end

    -- the plan: no sandbox directory and no sandbox variable carries the short form
    local e = child_mod.environment({ base = short, parent_env = {} })
    ok(not has_short(e.sandbox), "the sandbox is below the long form: " .. e.sandbox)
    for name, path in pairs(e.dirs) do
      ok(not has_short(path), ("dirs.%s has no short-name component: %s"):format(name, path))
    end
    for _, name in ipairs({
      "TEMP",
      "TMP",
      "TMPDIR",
      "XDG_DATA_HOME",
      "XDG_STATE_HOME",
      "XDG_CACHE_HOME",
    }) do
      ok(
        not has_short(e.env[name] or ""),
        ("%s has no short-name component: %s"):format(name, tostring(e.env[name]))
      )
    end

    -- a real child below the short form: its TEMP is the long form and glob below tempname() works
    local c = S.spawn({ base = short })
    local seen = c.lua([[
      local d = vim.fn.tempname()
      vim.fn.mkdir(d, "p")
      vim.fn.writefile({ "x" }, d .. "/written.txt")
      return { temp = vim.env.TEMP or "", dir = d, found = #vim.fn.glob(d .. "/*", false, true) }
    ]])
    ok(not has_short(seen.temp), "the child's TEMP has no short-name component: " .. seen.temp)
    ok(
      seen.found == 1,
      ("glob(tempname() .. '/*') finds the written file in the child (%s): %d"):format(
        seen.dir,
        seen.found
      )
    )

    -- the IR of a parent whose TEMP is the short form: a `vim.inspect`ed path below the child's (long-form)
    -- sandbox still becomes `<TMP>` in the spec's own text (`scrub_texts`), not `<HOME>\\AppData\\...`
    local p = S.spawn({ extra_env = { TEMP = short, TMP = short, TMPDIR = short } })
    local scrubbed = p.lua([[
      local tmp = vim.fs.dirname(vim.fn.tempname())
      local long = vim.uv.fs_realpath(tmp) or tmp
      local msg = vim.inspect(long:gsub("/", "\\") .. "\\testing-child-1-1\\tmp\\x.txt")
      local res = { cases = { { assertions = { { msg = msg } }, notes = {} } } }
      require("testing.run.inproc").scrub_texts(res, vim.fn.getcwd())
      return { tmp = tmp, msg = res.cases[1].assertions[1].msg }
    ]])
    ok(has_short(scrubbed.tmp), "that parent's temp dir is the short form: " .. scrubbed.tmp)
    ok(
      vim.startswith(scrubbed.msg, '"<TMP>\\\\testing-child-1-1'),
      "the inspected long-form sandbox path is <TMP>-relative: " .. scrubbed.msg
    )
  end)
end
