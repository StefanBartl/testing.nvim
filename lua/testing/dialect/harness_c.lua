---@module 'testing.dialect.harness_c'
---@brief Dialect C shim: the `H` of images.nvim (`H.eq/ok/falsy/contains/scratch/tmpdir/write`).
---@description
--- Dialect C is `return function(H) ... end` with the helpers of images.nvim's `TESTS/harness.lua`:
---
---   * `H.eq(actual, expected, msg)` (strict `==`), `H.ok(value, msg)`, `H.falsy(value, msg)` and
---     `H.contains(haystack, needle, msg)` (literal substring; a non-string haystack fails) are the
---     collecting assertions of the kernel: a failed check is recorded, the spec goes on (P1);
---   * `H.scratch(lines?, ft?)`: a fresh scratch buffer, made current, with optional lines and
---     filetype;
---   * `H.tmpdir(fn)`: create a temp directory, run `fn(dir)` (normalized path), remove the directory
---     whatever happens, re-raise a raise of `fn`, return `fn`'s result;
---   * `H.write(path, content)`: write a string to `path` in binary mode, creating parent directories.
---
--- `eq` / `ok` / `falsy` / `contains` are aliases of the context's functions and are not wrapped, so
--- the recorded call site is the spec's own line. Reading an unknown `H` key answers `nil`.

local M = {}

---Build the dialect-C `H` for one assertion context.
---@param a Testing.Assert.Context|table Context or a `scope()` view of it.
---@return table H
function M.new(a)
  local H = {}

  H.eq = a.eq
  H.ok = a.ok
  H.falsy = a.not_ok
  H.contains = a.has

  ---Fresh scratch buffer, made current, with optional lines and filetype.
  ---@param lines? string[]
  ---@param ft? string
  ---@return integer bufnr
  function H.scratch(lines, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    if type(lines) == "string" then
      -- dialect B's form `scratch(ft)`
      lines, ft = nil, lines
    end
    if lines then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
    if ft then
      vim.bo[buf].filetype = ft
    end
    return buf
  end

  ---Create a temporary directory, run `fn(dir)`, then remove it.
  ---@generic T
  ---@param fn? fun(dir: string): T
  ---@return T
  function H.tmpdir(fn)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    if fn == nil then
      -- dialect B's form `tmpdir()`: a fresh directory, absolute, trailing slash
      return vim.fn.fnamemodify(dir, ":p")
    end
    local ok, ret = pcall(fn, vim.fs.normalize(dir))
    vim.fn.delete(dir, "rf")
    if not ok then
      error(ret, 0)
    end
    return ret
  end

  ---Write `content` to `path`, creating parent directories.
  ---@param path string
  ---@param content string
  function H.write(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end

  return H
end

return M
