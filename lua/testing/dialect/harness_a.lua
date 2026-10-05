---@module 'testing.dialect.harness_a'
---@brief Dialect A shim: the `H` object of lib.nvim's specs, mapped onto the collecting assertions.
---@description
--- Dialect A is `return function(H) ... end` with file-level code (lib.nvim's `TESTS/*_spec.lua`).
--- `H` is the table the old runner handed over: `eq`, `ok`, `tmpfile`, `read_lines`,
--- `with_patched`, `with_stdpath_config`. This module builds the same table on top of one
--- `testing.core.assert` context:
---
---   * `H.eq(actual, expected, msg)` and `H.ok(value, msg)` are the context's own `a.eq` / `a.ok`
---     (strict `==`, truthiness: the exact semantics of the old harness) - but a failed check is
---     recorded on the bound case and the spec goes on, so ALL failures of a file are visible (P1);
---   * the helpers (`tmpfile`, `read_lines`, `with_patched`, `with_stdpath_config`) behave like the
---     originals, including "restore first, then re-raise" in `with_patched`;
---   * `H.eq` / `H.ok` are NOT wrapped: the spec's call site is then frame 3 of the assertion and
---     `a.depth` stays 0 (a non-tail wrapper would need `a.depth = 1`).
---
--- Reading an `H` key that does not exist answers `nil`, exactly like the old table: feature
--- detection (`if H.x then`, `vim.inspect(H)`, `pairs(H)`) must not raise (M0 review follow-up). A
--- spec that calls a key the shim lacks still dies at the call ("attempt to call a nil value (field
--- 'x')"), which names the key; the dialect sniffer reports specs that use keys of no known
--- harness (`testing.discover.sniff`).
---
--- Differences to the old harness, all by design and documented in `docs`/the M0 notes:
---   * `eq`/`ok` never raise, `with_patched` still re-raises a raise of its body;
---   * a spec file that makes no `H.eq`/`H.ok` call at all would fail under the zero-assertion rule;
---     the driver decides what that means for a file (see `testing.run.inproc`).

local M = {}

---Build the dialect-A `H` for one assertion context.
---@param a Testing.Assert.Context
---@return table H
function M.new(a)
  local H = {}

  H.eq = a.eq
  H.ok = a.ok

  ---Fresh temp file path (not created on disk).
  ---@param suffix? string
  ---@return string
  function H.tmpfile(suffix)
    return vim.fn.tempname() .. (suffix or ".tmp")
  end

  ---All lines of a file (empty list if it cannot be opened). CRLF is kept off the lines by
  ---`io.lines` in text mode on Windows, exactly as in the old harness.
  ---@param path string
  ---@return string[]
  function H.read_lines(path)
    local out = {}
    local f = io.open(path, "r")
    if not f then
      return out
    end
    for line in f:lines() do
      out[#out + 1] = line
    end
    f:close()
    return out
  end

  ---Run `fn` with `target[key]` replaced by `value`; the original is restored whatever happens
  ---inside `fn`, then a raise of `fn` is re-raised (the old `assert(ok, err)`).
  ---@param target table
  ---@param key any
  ---@param value any
  ---@param fn fun()
  function H.with_patched(target, key, value, fn)
    local orig = target[key]
    target[key] = value
    local ok, err = pcall(fn)
    target[key] = orig
    if not ok then
      error(err, 0)
    end
  end

  ---Run `fn` with `vim.fn.stdpath("config")` answering `link`.
  ---@param link string
  ---@param fn fun()
  function H.with_stdpath_config(link, fn)
    local orig = vim.fn.stdpath
    H.with_patched(vim.fn, "stdpath", function(what)
      if what == "config" then
        return link
      end
      return orig(what)
    end, fn)
  end

  return H
end

return M
