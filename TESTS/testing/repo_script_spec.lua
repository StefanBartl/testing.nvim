-- TESTS/testing/repo_script_spec.lua -- the two files that run this repository's own specs: scripts/test.sh stops when
-- it cannot make its scratch directory (state and cache would land in /state and /cache), and every checkout of the
-- CI workflow gives up the token again, except the one job that pushes `ci-verified`.

return function(H)
  local ok = H.ok
  local eq = H.eq

  -- the spec lives in <repo>/TESTS/testing: the repository is two directories up
  local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))

  -- Git Bash on Windows: the first `bash` on the PATH can be the WSL launcher, which knows no Windows path
  local bash = require("lib.nvim.cross.bash").find() or ""
  local script = repo .. "/scripts/test.sh"
  ok(vim.uv.fs_stat(script) ~= nil, "the script exists: " .. script)
  if bash == "" or vim.fn.executable("nvim") == 0 then
    ok(true, "bash or nvim is not available: nothing to run here")
  else
    -- a TMPDIR that cannot be written: `mktemp -d` fails, and so must the script (exit 3, infrastructure). Not every
    -- mktemp reads TMPDIR (the BSD one of macOS asks the system for the user's temp directory), so the failure is
    -- only forced where this one fails with it.
    local missing = vim.fs.normalize(vim.fn.tempname()) .. "/no/such/dir"
    local probe = vim
      .system({ bash, "-c", "mktemp -d" }, { env = { TMPDIR = missing }, text = true })
      :wait(60000)
    if probe.code == 0 then
      vim.fn.delete(vim.trim(probe.stdout or ""), "rf")
      ok(
        true,
        "this mktemp ignores TMPDIR (macOS): the failure of the scratch directory cannot be forced here"
      )
    else
      local res = vim
        .system({ bash, script, "--list" }, { cwd = repo, env = { TMPDIR = missing }, text = true })
        :wait(60000)
      local out = (res.stdout or "") .. (res.stderr or "")
      eq(res.code, 3, "no scratch directory: exit 3 and nothing runs: " .. out)
      ok(
        out:find("cannot create a scratch directory", 1, true) ~= nil,
        "and the message says why: " .. out
      )
    end
  end

  -- every `actions/checkout` step of the workflow says `persist-credentials: false`; the job that pushes keeps the token
  local workflow = repo .. "/.github/workflows/ci.yml"
  if vim.uv.fs_stat(workflow) == nil then
    ok(true, "no workflow in this checkout: nothing to read")
    return
  end
  local lines = vim.fn.readfile(workflow)
  local job
  local checkouts = {}
  for i, line in ipairs(lines) do
    job = line:match("^  ([%w_%-]+):%s*$") or job
    if line:match("^%s*%-%s+uses:%s*actions/checkout@") then
      local indent = #line:match("^(%s*)")
      local persists = false
      for j = i + 1, #lines do
        local nxt = lines[j]
        local next_indent = #nxt:match("^(%s*)")
        if nxt:match("%S") and next_indent <= indent then
          break
        end
        persists = persists or nxt:match("^%s*persist%-credentials:%s*false%s*$") ~= nil
      end
      checkouts[#checkouts + 1] = { job = job, persists = persists }
    end
  end
  ok(#checkouts >= 6, "the workflow was read: " .. #checkouts .. " checkout steps")
  for n, checkout in ipairs(checkouts) do
    eq(
      checkout.persists,
      checkout.job ~= "publish-ci-verified",
      ("checkout %d (job %s) gives the token up unless its job pushes"):format(
        n,
        tostring(checkout.job)
      )
    )
  end
end
