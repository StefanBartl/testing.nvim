-- TESTS/testing/bench_script_spec.lua -- scripts/bench-incremental.sh edits a file of the project it measures:
-- the file must lie below the project, and it comes back byte for byte (an uncommitted edit included).

return function(H)
  local ok = H.ok
  local eq = H.eq

  local bash = vim.fn.exepath("bash")
  if bash == "" or vim.fn.executable("nvim") == 0 then
    ok(true, "bash or nvim is not available: nothing to measure here")
    return
  end
  -- the spec lives in <repo>/TESTS/testing: the script is two directories up
  local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local script = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))
    .. "/scripts/bench-incremental.sh"
  ok(vim.uv.fs_stat(script) ~= nil, "the script exists: " .. script)

  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local function write(rel, text)
    local f = assert(io.open(root .. "/" .. rel, "wb"))
    f:write(text)
    f:close()
  end
  local original = "return function(H)\n  H.ok(true, 'edited but not committed')\nend\n"
  write("TESTS/a_spec.lua", original)
  write("outside.txt", "not below TESTS but below the project\n")

  local function run(args, env)
    local cmd = { bash, script }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { cwd = root, text = true, env = env }):wait(120000)
    return res.code, (res.stdout or "") .. (res.stderr or "")
  end

  local code, out = run({ root, "../escape.txt" })
  eq(code, 2, "a path with '..' is refused: " .. out)
  ok(out:find("no '..'", 1, true) ~= nil, "and the message names the rule: " .. out)
  code, out = run({ root, root .. "/TESTS/a_spec.lua" })
  eq(code, 2, "an absolute path is refused: " .. out)
  code, out = run({ root, "TESTS/missing_spec.lua" })
  eq(code, 2, "a file that is not there is refused: " .. out)
  ok(out:find("regular file", 1, true) ~= nil, "and the message says why: " .. out)

  -- a symlink out of the project (where symlinks can be made)
  local outside = vim.fs.normalize(vim.fn.tempname())
  local f = assert(io.open(outside, "wb"))
  f:write("outside the project\n")
  f:close()
  if vim.uv.fs_symlink(outside, root .. "/TESTS/link_spec.lua") then
    code, out = run({ root, "TESTS/link_spec.lua" })
    eq(code, 2, "a symlink that leaves the project is refused: " .. out)
    local fh = assert(io.open(outside, "rb"))
    eq(fh:read("*a"), "outside the project\n", "and the file behind it is untouched")
    fh:close()
  end

  -- one timed run: the edit of the file is undone byte for byte
  local _, timed = run({ root, "TESTS/a_spec.lua", "1", "--affected" }, { BENCH_SKIP_FULL = "1" })
  ok(timed:find("run 1:", 1, true) ~= nil, "one run was timed: " .. timed)
  local fh = assert(io.open(root .. "/TESTS/a_spec.lua", "rb"))
  local after = fh:read("*a")
  fh:close()
  eq(after, original, "the file is back as it was (no `git checkout`: it was never committed)")

  vim.fn.delete(root, "rf")
  vim.fn.delete(outside)
end
