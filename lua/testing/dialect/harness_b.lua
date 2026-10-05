---@module 'testing.dialect.harness_b'
---@brief Dialect B shim: the `H` of markdown.nvim and diff.nvim (`H.eq/ok/scratch` and their helpers).
---@description
--- Dialect B is `return function(H) ... end` like dialect A, with the helpers of the plugins'
--- `TESTS/harness.lua`:
---
---   * `H.eq(actual, expected, msg)` (strict `==`) and `H.ok(value, msg)` are the collecting
---     assertions of the kernel: a failed check is recorded, the spec goes on (P1);
---   * `H.scratch(ft?)`: a fresh scratch buffer, made current, with an optional filetype;
---   * `H.tmproot(name)` (markdown.nvim): a fixture directory under the temp dir, canonical path
---     (symlinks resolved), forward slashes, created;
---   * `H.tmpdir()` (diff.nvim): a fresh empty directory under `vim.fn.tempname()`, absolute with a
---     trailing slash;
---   * `H.canonical(path)` (diff.nvim): the real path with forward slashes, so two spellings of one
---     file compare equal;
---   * `H.write_file(path, lines)` (diff.nvim): write a list of lines, creating parent directories.
---
--- The helpers are copies of the originals' behaviour, not of their error messages (they never
--- raise to report a failed check). `eq` / `ok` are aliases of the context's functions and are not
--- wrapped, so the recorded call site is the spec's own line.
---
--- Reading an unknown `H` key answers `nil` like the old table (feature detection must not raise).

local M = {}

---Build the dialect-B `H` for one assertion context.
---@param a Testing.Assert.Context|table Context or a `scope()` view of it.
---@return table H
function M.new(a)
  local H = {}

  H.eq = a.eq
  H.ok = a.ok

  ---Fresh scratch buffer, made current, with an optional filetype.
  ---@param ft? string
  ---@return integer bufnr
  function H.scratch(ft, ft2)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    if type(ft) == "table" then
      -- dialect C's form `scratch(lines, ft)`: a spec that cannot be told apart from it still runs
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, ft)
      ft = ft2
    end
    if ft then
      vim.bo[buf].filetype = ft
    end
    return buf
  end

  ---Fixture directory under the temp dir; canonical (symlinks resolved), slash-separated, existing.
  ---@param name string
  ---@return string root
  function H.tmproot(name)
    local base = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    local root = (base .. "/" .. name):gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local real = vim.uv.fs_realpath(root)
    return (real and real:gsub("\\", "/")) or root
  end

  ---Fresh, empty directory under `vim.fn.tempname()`: absolute, with a trailing slash.
  ---@return string dir
  function H.tmpdir(fn)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    if type(fn) == "function" then
      -- dialect C's form `tmpdir(fn)`: run, remove, re-raise
      local ok, ret = pcall(fn, vim.fs.normalize(dir))
      vim.fn.delete(dir, "rf")
      if not ok then
        error(ret, 0)
      end
      return ret
    end
    return vim.fn.fnamemodify(dir, ":p")
  end

  ---Canonicalize `path` so two spellings of one file compare equal.
  ---@param path string
  ---@return string
  function H.canonical(path)
    return vim.fs.normalize(vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p"))
  end

  ---Write a list of lines to `path`, creating parent directories.
  ---@param path string
  ---@param lines string[]
  function H.write_file(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end

  return H
end

return M
