-- TESTS/testing/watch_source_spec.lua -- the real file-system side of `--watch`: the scanner, the fs_event source
-- (`lib.nvim.fs.watch` handles) on a temp tree, a path that cannot be watched (nil + error, the cue for the
-- polling fallback), a directory that appears after the start, and a clean stop.

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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local watch = require("testing.run.watch")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local root = vim.fs.normalize(vim.fn.tempname())
  write(root .. "/TESTS/a_spec.lua", "return 1\n")
  write(root .. "/TESTS/sub/b_spec.lua", "return 2\n")
  write(root .. "/TESTS/notes.md", "# not lua\n")
  write(root .. "/TESTS/.git/hook.lua", "return 3\n")
  write(root .. "/lua/m.lua", "return {}\n")

  -- scan: .lua files only, below the given directories, never below .git; the signature changes with
  -- the content (size) and is stable without a change
  local snap = watch.scan_dirs({ root .. "/TESTS", root .. "/lua" })
  eq(snap[root .. "/TESTS/a_spec.lua"] ~= nil, true, "a spec is in the snapshot")
  eq(snap[root .. "/TESTS/sub/b_spec.lua"] ~= nil, true, "a nested spec is in the snapshot")
  eq(snap[root .. "/lua/m.lua"] ~= nil, true, "a module is in the snapshot")
  eq(snap[root .. "/TESTS/notes.md"], nil, "a markdown file is not")
  eq(snap[root .. "/TESTS/.git/hook.lua"], nil, "nothing below .git is")
  eq(
    watch.diff(snap, watch.scan_dirs({ root .. "/TESTS", root .. "/lua" })),
    {},
    "an unchanged tree has no diff"
  )
  write(root .. "/TESTS/a_spec.lua", "return 1 -- longer now\n")
  eq(
    watch.diff(snap, watch.scan_dirs({ root .. "/TESTS", root .. "/lua" })),
    { root .. "/TESTS/a_spec.lua" },
    "a rewritten file is the one difference"
  )
  eq(watch.scan_dirs({ root .. "/does-not-exist" }), {}, "a missing directory scans as empty")

  -- a fixture that a spec reads, and the project's own `.testing.lua`, are watched too (`opts.all`, `opts.files`):
  -- a green "waiting for changes" must not be wrong for a change that `--changed` would select
  write(root .. "/TESTS/fixture.json", "{}\n")
  write(root .. "/.testing.lua", "return {}\n")
  local all = watch.scan_dirs(
    { root .. "/TESTS", root .. "/lua" },
    { all = true, files = { root .. "/.testing.lua" } }
  )
  eq(all[root .. "/TESTS/fixture.json"] ~= nil, true, "a data file is in the full snapshot")
  eq(all[root .. "/TESTS/notes.md"] ~= nil, true, "so is a markdown file")
  eq(all[root .. "/.testing.lua"] ~= nil, true, "and the project configuration")
  eq(all[root .. "/TESTS/.git/hook.lua"], nil, "but nothing below .git")
  write(root .. "/TESTS/fixture.json", '{"changed":true}\n')
  eq(
    watch.diff(
      all,
      watch.scan_dirs(
        { root .. "/TESTS", root .. "/lua" },
        { all = true, files = { root .. "/.testing.lua" } }
      )
    ),
    { root .. "/TESTS/fixture.json" },
    "a rewritten fixture is a change"
  )
  eq(
    watch.diff(snap, watch.scan_dirs({ root .. "/TESTS", root .. "/lua" })),
    { root .. "/TESTS/a_spec.lua" },
    "the default snapshot stays Lua-only"
  )

  -- directories below a root for the non-recursive platforms: the root and everything below, no VCS dirs
  local dirs = watch.dirs_below(root .. "/TESTS")
  table.sort(dirs)
  eq(dirs, { root .. "/TESTS", root .. "/TESTS/sub" }, "dirs_below: the tree without .git")

  -- the real source: a change under a watched root reaches the callback
  local events = 0
  local src, err = watch.fs_source(function()
    events = events + 1
  end, { dirs = { root .. "/TESTS", root .. "/lua" } })
  src = assert(src, "the source starts on existing directories: " .. tostring(err))
  eq(src.mode, "events", "and says it uses events")
  -- some backends need a moment before they deliver (macOS registers its stream from another thread):
  -- keep touching the file until the first event, with a generous limit
  local n = 0
  local got = vim.wait(8000, function()
    n = n + 1
    if n % 20 == 1 then
      write(root .. "/lua/m.lua", ("return { n = %d }\n"):format(n))
    end
    return events > 0
  end, 10)
  ok(got, "a change below a watched directory produces an event")

  -- a directory that appears later is picked up by resync (a no-op where one handle watches the tree)
  vim.fn.mkdir(root .. "/TESTS/fresh", "p")
  assert(src.resync)()
  local before = events
  n = 0
  got = vim.wait(8000, function()
    n = n + 1
    if n % 20 == 1 then
      write(root .. "/TESTS/fresh/c_spec.lua", ("return %d\n"):format(n))
    end
    return events > before
  end, 10)
  ok(got, "a file in a directory created after the start is seen after resync")

  -- stop: no more events, idempotent, and the handles are really closed
  src.stop()
  src.stop()
  vim.wait(60) -- libuv closes handles on the next loop turn (ERR-40: Windows keeps the directory until then)
  local after = events
  write(root .. "/lua/m.lua", "return { after = true }\n")
  vim.wait(300)
  eq(events, after, "no event arrives after stop()")
  -- the directory can be removed right after the stop: no open handle holds it on Windows
  local rm = vim.fn.delete(root .. "/TESTS/fresh", "rf")
  eq(rm, 0, "a watched directory can be deleted once the watcher is stopped")

  -- a path that cannot be watched is nil + a message (the signal to poll), and leaves nothing behind
  local missing, merr = watch.fs_source(
    function() end,
    { dirs = { root .. "/lua", root .. "/missing-dir" } }
  )
  eq(missing, nil, "a missing directory: no source")
  has(tostring(merr), "missing-dir", "the error names the path")

  -- one handle per directory where the platform is not recursive: forced both ways with a fake watcher
  local started = {}
  local fake = {
    start = function(path, _, wopts)
      started[#started + 1] = { path = path, recursive = wopts.recursive }
      return { stop = function() end }, nil
    end,
  }
  local s1 = watch.fs_source(function() end, {
    dirs = { "/r/TESTS" },
    watch = fake,
    recursive = true,
  })
  eq(
    started,
    { { path = "/r/TESTS", recursive = true } },
    "recursive platforms: one recursive handle per root"
  )
  assert(s1).stop()
  started = {}
  local s2 = watch.fs_source(function() end, {
    dirs = { "/r/TESTS" },
    watch = fake,
    recursive = false,
    resolve_dirs = function(dir)
      return { dir, dir .. "/x", dir .. "/y" }
    end,
  })
  eq(#started, 3, "inotify-style platforms: one handle per directory")
  eq(started[2].recursive, false, "and they are not recursive")
  assert(s2).stop()
  -- a start failure of any handle closes the ones already started
  local stops = 0
  local failing = {
    start = function(path)
      if path:find("bad", 1, true) then
        return nil, "ENOSPC"
      end
      return {
        stop = function()
          stops = stops + 1
        end,
      }, nil
    end,
  }
  local s3, e3 = watch.fs_source(function() end, {
    dirs = { "/r/good", "/r/bad" },
    watch = failing,
    recursive = true,
  })
  eq(s3, nil, "one failing handle fails the source")
  eq(e3, "ENOSPC", "with the reason")
  eq(stops, 1, "and the handle that had started is closed")

  -- SIGINT handle: installable and removable without side effects
  local w = watch.new({
    root = root,
    say = function() end,
    scan = function()
      return {}
    end,
    source = function() end,
    is_spec = function()
      return false
    end,
    run = function()
      return { exit_code = 0 }
    end,
  })
  local remove = watch.install_sigint(w)
  ok(
    remove == nil or type(remove) == "function",
    "install_sigint returns a remover (or nil when libuv has no signal handle)"
  )
  if remove then
    remove()
    remove()
  end
  eq(w.stopped, false, "installing and removing the handler interrupts nothing")

  vim.fn.delete(root, "rf")
end
