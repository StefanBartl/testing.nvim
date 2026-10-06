---@diagnostic disable: discard-returns
-- Scenarios of the filesystem guard (RED: a write outside the allowed roots, GREEN: allowed writes).
-- Run by TESTS/testing/guard_fs_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")
local uv = vim.uv
local sb = B.sandbox()

-- references taken BEFORE any guard is installed: they bypass the wrappers on purpose
local raw_open = io.open
local raw_mkdir = vim.fn.mkdir

local function only_fs(extra)
  ---@type table<string, any>
  local g = { fs = vim.tbl_extend("force", { mode = "error", snapshot = false }, extra or {}) }
  for _, name in ipairs({
    "state",
    "scheduled_error",
    "prompt",
    "deprecation",
    "process_net",
    "clock",
  }) do
    g[name] = "off"
  end
  return { guards = g }
end

local function exists(p)
  return uv.fs_stat(p) ~= nil
end

local function raw_write(path, text)
  local f = assert(raw_open(path, "wb"))
  f:write(text or "x")
  f:close()
end

B.case("red_io_open", {
  cfg = only_fs(),
  body = function()
    local f = assert(io.open(sb.outside .. "/a.txt", "w"))
    f:write("leak")
    f:close()
  end,
  after = function()
    return { created = exists(sb.outside .. "/a.txt") }
  end,
})

B.case("red_io_open_append_and_update", {
  cfg = only_fs(),
  body = function()
    io.open(sb.outside .. "/b.txt", "a"):close()
    io.open(sb.outside .. "/b.txt", "r+"):close()
  end,
})

B.case("red_writefile_delete_mkdir_rename", {
  cfg = only_fs(),
  setup = function()
    raw_write(sb.outside .. "/c.txt")
    raw_write(sb.outside .. "/d.txt")
  end,
  body = function()
    vim.fn.writefile({ "x" }, sb.outside .. "/w.txt")
    vim.fn.delete(sb.outside .. "/c.txt")
    vim.fn.mkdir(sb.outside .. "/newdir")
    vim.fn.rename(sb.outside .. "/d.txt", sb.tmp .. "/moved.txt")
  end,
})

B.case("red_uv_calls", {
  cfg = only_fs(),
  setup = function()
    raw_write(sb.outside .. "/u1.txt")
    raw_write(sb.outside .. "/u2.txt")
  end,
  body = function()
    local fd = uv.fs_open(sb.outside .. "/u3.txt", "w", 420)
    uv.fs_close(assert(fd))
    local fd2 =
      uv.fs_open(sb.outside .. "/u4.txt", uv.constants.O_WRONLY + uv.constants.O_CREAT, 420)
    uv.fs_close(assert(fd2))
    uv.fs_unlink(sb.outside .. "/u1.txt")
    uv.fs_mkdir(sb.outside .. "/udir", 493)
    uv.fs_rename(sb.outside .. "/u2.txt", sb.outside .. "/u2b.txt")
    os.remove(sb.outside .. "/u2b.txt")
  end,
})

B.case("red_relative_and_dotdot", {
  cfg = only_fs(),
  setup = function()
    return { start = uv.cwd() }
  end,
  body = function()
    -- `..` leaves the allowed tmp root on paper only
    io.open(sb.tmp .. "/../" .. vim.fs.basename(sb.outside) .. "/dotdot.txt", "w"):close()
    -- a relative path is resolved against the cwd
    vim.api.nvim_set_current_dir(sb.outside)
    io.open("relative.txt", "w"):close()
  end,
  after = function(_, _, env)
    vim.api.nvim_set_current_dir(env.start)
  end,
})

B.case("red_relative_verdict_follows_the_cwd", {
  cfg = only_fs(),
  setup = function()
    return { start = uv.cwd() }
  end,
  body = function()
    -- the same relative name: allowed in the temp dir, a leak after a chdir out of it
    vim.api.nvim_set_current_dir(sb.tmp)
    io.open("same-name.txt", "w"):close()
    vim.api.nvim_set_current_dir(sb.outside)
    io.open("same-name.txt", "w"):close()
  end,
  after = function(_, _, env)
    vim.api.nvim_set_current_dir(env.start)
  end,
})

B.case("red_symlink_escape", {
  cfg = only_fs(),
  setup = function()
    local link = sb.tmp .. "/link-to-outside"
    local ok = uv.fs_symlink(sb.outside, link, { dir = true, junction = true })
    return { link = link, made = ok == true }
  end,
  body = function(_, env)
    -- inside the allowed tmp root by name, outside by resolution
    io.open(env.link .. "/via-link.txt", "w"):close()
  end,
  after = function(_, _, env)
    return { link_made = env.made, written = exists(sb.outside .. "/via-link.txt") }
  end,
})

B.case("red_buffer_write", {
  cfg = only_fs(),
  body = function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello" })
    vim.cmd("silent! write! " .. vim.fn.fnameescape(sb.outside .. "/buf.txt"))
  end,
})

B.case("red_block", {
  cfg = only_fs({ block = true }),
  body = function()
    local _ = io.open(sb.outside .. "/blocked.txt", "w")
  end,
  after = function()
    return { created = exists(sb.outside .. "/blocked.txt") }
  end,
})

B.case("red_snapshot", {
  cfg = only_fs({ snapshot = true, watch = { sb.outside .. "/watched" } }),
  heavy = true,
  setup = function()
    raw_mkdir(sb.outside .. "/watched", "p")
    raw_write(sb.outside .. "/watched/old.txt", "1")
    raw_write(sb.outside .. "/watched/del.txt", "1")
  end,
  body = function()
    -- every write goes around the wrappers (saved references): only the snapshot can see them
    raw_write(sb.outside .. "/watched/new.txt", "1")
    raw_write(sb.outside .. "/watched/old.txt", "changed and longer")
    os.remove(sb.outside .. "/watched/del.txt") -- wrapped: also seen live
  end,
})

B.case("green_tmp", {
  cfg = only_fs(),
  body = function()
    io.open(sb.tmp .. "/a.txt", "w"):close()
    vim.fn.writefile({ "x" }, sb.tmp .. "/w.txt")
    vim.fn.mkdir(sb.tmp .. "/dir/sub", "p")
    local fd = uv.fs_open(sb.tmp .. "/u.txt", "w", 420)
    uv.fs_close(assert(fd))
    vim.fn.delete(sb.tmp .. "/a.txt")
    local t = vim.fn.tempname()
    vim.fn.writefile({ "x" }, t)
    vim.fn.delete(t)
  end,
})

B.case("green_read_only", {
  cfg = only_fs(),
  setup = function()
    raw_write(sb.outside .. "/ro.txt", "data")
  end,
  body = function()
    local f = assert(io.open(sb.outside .. "/ro.txt", "r"))
    f:read("*a")
    f:close()
    vim.fn.readfile(sb.outside .. "/ro.txt")
    uv.fs_stat(sb.outside .. "/ro.txt")
    local fd = uv.fs_open(sb.outside .. "/ro.txt", "r", 420)
    uv.fs_close(assert(fd))
    vim.fn.mkdir(sb.outside, "p") -- exists: no write
  end,
})

B.case("green_allow_list", {
  cfg = only_fs({
    allow = { sb.outside .. "/sessions" },
    allow_patterns = { "calibration%.json$" },
  }),
  setup = function()
    raw_mkdir(sb.outside .. "/sessions", "p")
  end,
  body = function()
    io.open(sb.outside .. "/sessions/s1.json", "w"):close()
    io.open(sb.outside .. "/calibration.json", "w"):close()
  end,
})

B.case("green_suspended", {
  cfg = only_fs(),
  body = function(h)
    h:suspended(function()
      io.open(sb.outside .. "/harness.txt", "w"):close()
    end)
  end,
})

B.case("green_snapshot_nothing_changed", {
  cfg = only_fs({ snapshot = true, watch = { sb.outside .. "/quiet" } }),
  heavy = true,
  setup = function()
    raw_mkdir(sb.outside .. "/quiet", "p")
    raw_write(sb.outside .. "/quiet/stay.txt")
  end,
  body = function() end,
})

B.case("green_snapshot_ignored", {
  cfg = only_fs({ snapshot = true, watch = { sb.outside .. "/noisy" } }),
  heavy = true,
  setup = function()
    raw_mkdir(sb.outside .. "/noisy/.git", "p")
  end,
  body = function()
    raw_write(sb.outside .. "/noisy/app.log", "x")
    raw_write(sb.outside .. "/noisy/.git/HEAD", "x")
  end,
})

B.case("green_light_snapshot_skips_tree", {
  cfg = only_fs({ snapshot = true, watch = { sb.outside .. "/lightroot" } }),
  setup = function()
    raw_mkdir(sb.outside .. "/lightroot", "p")
  end,
  body = function()
    raw_write(sb.outside .. "/lightroot/not-looked-at.txt", "x")
  end,
})

-- ---------------------------------------------------------------------------------------------
-- The sandbox of a child editor (`<base>/{data,state,cache,config,run,tmp}`, see `testing.child.env`):
-- a write below stdpath('data') there is a write into the sandbox, not "outside". The layout decides.
local function with_xdg(base, tmp_base, data_dir)
  local saved = {
    TMPDIR = vim.env.TMPDIR,
    TMP = vim.env.TMP,
    TEMP = vim.env.TEMP,
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
    XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
  }
  raw_mkdir(tmp_base .. "/tmp", "p")
  raw_mkdir(data_dir, "p")
  raw_mkdir(base .. "/state", "p")
  vim.env.TMPDIR, vim.env.TMP, vim.env.TEMP =
    tmp_base .. "/tmp", tmp_base .. "/tmp", tmp_base .. "/tmp"
  vim.env.XDG_DATA_HOME = data_dir
  vim.env.XDG_STATE_HOME = base .. "/state"
  return saved
end

local function restore_env(saved)
  for k, v in pairs(saved) do
    vim.env[k] = v
  end
end

local sandbox_saved
B.case("green_child_sandbox_dirs", {
  cfg = only_fs(),
  setup = function()
    local base = sb.outside .. "/childbox"
    sandbox_saved = with_xdg(base, base, base .. "/data")
  end,
  body = function()
    local dir = vim.fn.stdpath("data") .. "/plugin"
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(dir .. "/usage.json", "w"))
    f:write("{}")
    f:close()
    vim.fn.mkdir(vim.fn.stdpath("state"), "p")
    local g = assert(io.open(vim.fn.stdpath("state") .. "/plugin.log", "w"))
    g:close()
    return { base = require("testing.guard.fs").sandbox_base() }
  end,
  after = function()
    restore_env(sandbox_saved)
  end,
})

-- the same names without the layout (data dir not below <base>/data): still outside
B.case("red_not_a_sandbox_layout", {
  cfg = only_fs(),
  setup = function()
    local base = sb.outside .. "/notbox"
    sandbox_saved = with_xdg(base, base, sb.outside .. "/elsewhere")
  end,
  body = function()
    vim.fn.mkdir(vim.fn.stdpath("data"), "p")
    local f = assert(io.open(vim.fn.stdpath("data") .. "/usage.json", "w"))
    f:write("{}")
    f:close()
    return { base = require("testing.guard.fs").sandbox_base() }
  end,
  after = function()
    restore_env(sandbox_saved)
  end,
})

-- the default snapshot watches the project (the repo root and the cwd), not the real stdpath trees
B.case("green_default_watch_skips_stdpath", {
  cfg = only_fs({ snapshot = true }),
  heavy = true,
  setup = function()
    local saved = {
      XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
    }
    vim.env.XDG_DATA_HOME = sb.outside .. "/xdg-default"
    raw_mkdir(vim.fn.stdpath("data"), "p")
    sandbox_saved = saved
  end,
  body = function()
    raw_write(vim.fn.stdpath("data") .. "/not-looked-at.txt", "x")
  end,
  after = function()
    restore_env(sandbox_saved)
  end,
})

B.case("red_watch_stdpath_opt_in", {
  cfg = only_fs({ snapshot = true, watch_stdpath = true }),
  heavy = true,
  setup = function()
    local saved = {
      XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
    }
    vim.env.XDG_DATA_HOME = sb.outside .. "/xdg-optin"
    raw_mkdir(vim.fn.stdpath("data"), "p")
    sandbox_saved = saved
  end,
  body = function()
    raw_write(vim.fn.stdpath("data") .. "/looked-at.txt", "x")
  end,
  after = function()
    restore_env(sandbox_saved)
  end,
})

B.finish()
