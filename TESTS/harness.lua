-- TESTS/harness.lua -- tiny assertion helpers shared by the specs (the runner hands them to each spec as `H`).

local H = {}

---Assert equality; tables are compared deeply. Raises on mismatch.
---@param actual any
---@param expected any
---@param msg string
function H.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      ("FAIL %s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

---Assert a truthy value.
---@param v any
---@param msg string
function H.ok(v, msg)
  if not v then
    error(("FAIL %s: expected truthy, got %s"):format(msg, vim.inspect(v)), 2)
  end
end

---Assert that a string contains a plain substring.
---@param haystack any
---@param needle string
---@param msg string
function H.has(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(("FAIL %s: expected %s to contain %q"):format(msg, vim.inspect(haystack), needle), 2)
  end
end

---`vim.fn.glob` that also works below a Windows 8.3 short path (`C:\Users\RUNNER~1\...`, the temp directory of the
---GitHub runners): there `glob` finds nothing at all, which let "no temp file is left" assertions pass for the wrong reason.
---The directory part of the pattern is resolved to its long form, globbed there, and mapped back to the prefix the caller used.
---@param pattern string
---@return string[]
function H.glob(pattern)
  local pos = pattern:find("[%*%?%[{]")
  if not pos then
    return vim.fn.glob(pattern, false, true)
  end
  local slash = pattern:sub(1, pos - 1):match("^.*()[/\\]")
  if not slash then
    return vim.fn.glob(pattern, false, true)
  end
  local prefix, rest = pattern:sub(1, slash - 1), pattern:sub(slash)
  local real = vim.uv.fs_realpath(prefix)
  if not real then
    return {}
  end
  real = real:gsub("\\", "/")
  local plain = prefix:gsub("\\", "/")
  local out = {}
  for _, hit in ipairs(vim.fn.glob(real .. rest:gsub("\\", "/"), false, true)) do
    hit = hit:gsub("\\", "/")
    out[#out + 1] = hit:sub(1, #real) == real and plain .. hit:sub(#real + 1) or hit
  end
  return out
end

return H
