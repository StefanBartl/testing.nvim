-- A harness whose failure bookkeeping no built-in convention knows (V3 of the review): `H.t` pcalls the
-- body, counts `H.n_bad` and writes `FAIL <name>: <err>` with io.write; `H.ok` passes silently. Nothing
-- is named `failures`, `check`, `failed` or `FAIL`-raising, so only the generic net can see it.
local H = { passed = 0, n_bad = 0, fails_by_name = {} }

function H.ok(cond, msg)
  if cond then
    H.passed = H.passed + 1
  else
    H.n_bad = H.n_bad + 1
    H.fails_by_name[#H.fails_by_name + 1] = msg
    io.write("FAIL " .. tostring(msg) .. "\n")
  end
end

function H.t(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
  else
    H.n_bad = H.n_bad + 1
    io.write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
  end
end

-- bookkeeping that appears only when the first thing goes wrong
function H.lazy(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    H.late_errors = H.late_errors or {}
    H.late_errors[#H.late_errors + 1] = name .. ": " .. tostring(err)
  end
end

-- prints through the stdout file method, counts nothing
function H.quiet(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    io.stdout:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
  end
end

return H
