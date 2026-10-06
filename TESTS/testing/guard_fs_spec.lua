-- TESTS/testing/guard_fs_spec.lua -- the filesystem guard in a REAL child editor: writes outside the
-- allowed roots are found through every wrapped entry point (resolved paths: `..`, relative paths,
-- a symlinked directory), by the tree snapshot where the wrappers are bypassed, and allowed writes
-- (OS temp dir, allow list, patterns, suspended harness code, reads) stay quiet.

return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("fs")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
    if name ~= "red_block" then
      eq(c.body_error, nil, name .. ": the scenario body itself ran without an error")
    end
  end

  ---Does the effects list contain an entry that starts with `op` and ends with `file`?
  local function logged(case, op, file)
    for _, e in ipairs(case.effects.fs_outside_tmp) do
      if e:find("^" .. vim.pesc(op) .. " ") and e:find(file, 1, true) then
        return true
      end
    end
    return false
  end

  -- ---------------------------------------------------------------- RED: wrappers
  local c = r.red_io_open
  local f = S.find(
    c,
    "fs.write_outside",
    { "spec fx::red_io_open writes outside the allowed roots", "a.txt" }
  )
  ok(f ~= nil, "io.open(w) outside is a finding")
  eq(f.severity, "error", "default severity is error")
  ok(not f.message:find("%a:[\\/]Users"), "the path is redacted (no user directory)")
  ok(logged(c, "io.open(w)", "a.txt"), "the write is in the ledger kind fs_outside_tmp")
  eq(c.extra.created, true, "observing does not block: the file was written")
  eq(
    c.collect.effects.fs_outside_tmp[1],
    c.effects.fs_outside_tmp[1],
    "collect() carries the same effect"
  )

  c = r.red_io_open_append_and_update
  ok(
    logged(c, "io.open(a)", "b.txt") and logged(c, "io.open(r+)", "b.txt"),
    "append and update modes count as writes"
  )

  c = r.red_writefile_delete_mkdir_rename
  ok(logged(c, "writefile", "w.txt"), "vim.fn.writefile")
  ok(logged(c, "delete", "c.txt"), "vim.fn.delete")
  ok(logged(c, "mkdir", "newdir"), "vim.fn.mkdir of a new directory")
  ok(logged(c, "rename", "d.txt"), "vim.fn.rename: the SOURCE outside is a write too")

  c = r.red_uv_calls
  ok(logged(c, "uv.fs_open", "u3.txt"), "uv.fs_open with a string flag")
  ok(logged(c, "uv.fs_open", "u4.txt"), "uv.fs_open with numeric flags")
  ok(logged(c, "uv.fs_unlink", "u1.txt"), "uv.fs_unlink")
  ok(logged(c, "uv.fs_mkdir", "udir"), "uv.fs_mkdir")
  ok(logged(c, "uv.fs_rename", "u2.txt"), "uv.fs_rename")
  ok(logged(c, "os.remove", "u2b.txt"), "os.remove")

  c = r.red_relative_and_dotdot
  ok(logged(c, "io.open(w)", "dotdot.txt"), "`..` out of the allowed root is resolved")
  ok(logged(c, "io.open(w)", "relative.txt"), "a relative path is resolved against the cwd")

  c = r.red_relative_verdict_follows_the_cwd
  eq(#c.effects.fs_outside_tmp, 1, "the relative name is judged by the cwd it is used in: once")
  ok(
    logged(c, "io.open(w)", "same-name.txt"),
    "the write after the chdir out of the temp dir is the leak"
  )

  c = r.red_symlink_escape
  eq(c.extra.link_made, true, "the link (symlink / junction) could be created")
  ok(
    logged(c, "io.open(w)", "via-link.txt"),
    "a write through a link out of the root is outside (SEC-40)"
  )
  ok(
    not S.find(c, "fs.write_outside", { "link-to-outside" }),
    "the finding names the RESOLVED path, not the link"
  )

  c = r.red_buffer_write
  ok(logged(c, "BufWritePre", "buf.txt"), ":write of a buffer outside is seen")

  c = r.red_block
  ok(
    c.body_error and c.body_error:find("testing.guard", 1, true),
    "block = true raises in the spec"
  )
  ok(not c.body_error:find("Users", 1, true), "the raised message is redacted as well")
  eq(c.extra.created, false, "block = true: the file was never created")
  ok(S.find(c, "fs.write_outside", { "blocked.txt" }) ~= nil, "a blocked write is still a finding")

  -- ---------------------------------------------------------------- RED: snapshot
  -- the sandbox of a child editor is not "outside"; the same names without that layout still are
  eq(
    r.green_child_sandbox_dirs.findings,
    {},
    "a write below stdpath('data'|'state') of a child sandbox is allowed"
  )
  ok(
    r.green_child_sandbox_dirs.value.base ~= nil
      and r.green_child_sandbox_dirs.value.base:find("childbox", 1, true) ~= nil,
    "sandbox_base() recognises the layout: " .. vim.inspect(r.green_child_sandbox_dirs.value)
  )
  eq(r.red_not_a_sandbox_layout.value.base, nil, "no sandbox layout: sandbox_base() is nil")
  ok(
    S.find(r.red_not_a_sandbox_layout, "fs.write_outside", { "usage.json" }) ~= nil,
    "a data dir that is not below <base>/data is a write outside: "
      .. vim.inspect(r.red_not_a_sandbox_layout.findings)
  )
  -- the default snapshot does not walk the real stdpath trees (seconds per file on a developer machine)
  eq(
    S.of(r.green_default_watch_skips_stdpath, "fs.changed_outside"),
    {},
    "default snapshot: stdpath('data') is not watched"
  )
  ok(
    S.find(r.red_watch_stdpath_opt_in, "fs.changed_outside", { "looked-at.txt" }) ~= nil,
    "watch_stdpath = true: it is: " .. vim.inspect(r.red_watch_stdpath_opt_in.findings)
  )

  c = r.red_snapshot
  ok(
    S.find(c, "fs.changed_outside", { "created", "new.txt" }) ~= nil,
    "snapshot: created file found"
  )
  ok(
    S.find(c, "fs.changed_outside", { "modified", "old.txt" }) ~= nil,
    "snapshot: modified file found"
  )
  ok(S.find(c, "fs.write_outside", { "del.txt" }) ~= nil, "the wrapped delete is found live")
  eq(
    #S.of(c, "fs.changed_outside"),
    2,
    "snapshot: a path the wrappers already named is not reported twice"
  )

  -- ---------------------------------------------------------------- GREEN
  for _, name in ipairs({
    "green_tmp",
    "green_read_only",
    "green_allow_list",
    "green_suspended",
    "green_snapshot_nothing_changed",
    "green_snapshot_ignored",
    "green_light_snapshot_skips_tree",
  }) do
    eq(r[name].findings, {}, name .. ": no finding")
    eq(r[name].effects.fs_outside_tmp, {}, name .. ": nothing in the ledger")
  end
end
