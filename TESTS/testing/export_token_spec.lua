-- TESTS/testing/export_token_spec.lua -- the token the CI adapter used is a secret of every export document,
-- whatever its source: a token of `gh auth token` is no environment variable, so `M.secrets` cannot find it. The
-- adapter (`testing.ci.remote.collect`) hands it over, the export redacts it as a value (`<TOKEN>`) and the leak
-- detector names it. Through the adapter's own fakes (git, transport, token): no network, no real token.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local export = require("testing.export")
  local remote = require("testing.ci.remote")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local fx = fixture.build(fixture.base("token"))
  -- a token as `gh auth token` prints it; no environment variable holds it
  local TOKEN = "gho_" .. string.rep("Kp7x", 9)
  for name, value in pairs(vim.fn.environ()) do
    ok(value ~= TOKEN, "no environment variable holds the fake token: " .. tostring(name))
  end
  local JOBS = "/repos/fixture-owner/alpha.nvim/actions/runs/11/jobs"

  ---Run `fn` with the fixture's fakes, the token from "gh auth token", and a GitHub answer that echoes the token
  ---in a job name (a text the adapter does not mask: only its error texts are).
  local function with_gh_token(fn)
    local restore = fixture.install()
    local used = {}
    local transport = remote.deps.transport
    remote.deps.token = function()
      return TOKEN, "gh auth token"
    end
    remote.deps.transport = function(url, copts, done)
      used[#used + 1] = copts and copts.bearer_token
      return transport(url, copts, done)
    end
    local saved_name = fixture.API[JOBS].jobs[1].name
    fixture.API[JOBS].jobs[1].name = "test (ubuntu-latest) " .. TOKEN
    local pass, err = pcall(fn, used)
    fixture.API[JOBS].jobs[1].name = saved_name
    restore()
    if not pass then
      error(err, 0)
    end
  end

  -- ── the adapter hands over the token it used, whatever its source ──
  with_gh_token(function(used)
    local records, info = remote.collect(
      { { dir = fx.alpha, from_root = false } },
      { state_dir = fx.state .. "/adapter" }
    )
    eq(#records, 1, "one record")
    eq(info.token_source, "gh auth token", "the source")
    eq(info.token, TOKEN, "the token the adapter used is handed to the caller")
    ok(#used > 0 and used[1] == TOKEN, "and it is the one the requests carried")
    -- the document of `testing ci remote` names the source only, never the token field
    local rdoc = remote.document(records, info, {})
    eq(rdoc.token, nil, "testing-ci-remote/1 has no token field")
    eq(rdoc.token_source, "gh auth token", "only its source")
  end)

  -- ── the export redacts it as a value, in both forms ──
  with_gh_token(function()
    for _, form in ipairs({ "export", "local" }) do
      local doc, err = export.fleet(fixture.opts(fx, { form = form }))
      ok(doc, form .. ": the fleet is built: " .. tostring(err))
      local text = export.encode(doc)
      eq(text:find(TOKEN, 1, true), nil, form .. ": the token is in no document")
      local alpha
      for _, row in ipairs(doc.repos) do
        if row.name == "alpha.nvim" then
          alpha = row
        end
      end
      eq(
        alpha.ci_remote.os.ubuntu.job,
        "test (ubuntu-latest) <TOKEN>",
        form .. ": the token became <TOKEN>"
      )
      local valid, problems = export.validate(doc)
      ok(valid, form .. ": still valid: " .. table.concat(problems or {}, "; "))
    end
    local rdoc, rerr = export.repo(fx.alpha, fixture.opts(fx))
    ok(rdoc, "the repo document is built: " .. tostring(rerr))
    eq(export.encode(rdoc):find(TOKEN, 1, true), nil, "repo: the token is in no document")
    has(rdoc.repo.ci_remote.os.ubuntu.job, "<TOKEN>", "repo: redacted")
    local bundle, berr = export.export(fixture.opts(fx))
    ok(bundle, "the export folder is built: " .. tostring(berr))
    for _, f in ipairs(bundle.files) do
      eq(f.text:find(TOKEN, 1, true), nil, f.path .. ": the token is in no file")
    end
    -- the token is the document's secret while it is built, not afterwards
    eq(export.tokens(), {}, "no token is kept after the document")
  end)

  -- ── the leak detector names it ──
  do
    local doc = { kind = "fleet", note = "echo " .. TOKEN }
    local leaks = export.leaks(doc, { roots = {}, secrets = {}, tokens = { TOKEN } })
    eq(#leaks, 1, "one finding")
    eq(leaks[1].path, "$.note", "where")
    eq(leaks[1].what, "the token of the CI adapter", "what")
    eq(#export.leaks(doc, { roots = {}, secrets = {} }), 0, "outside a document no token is known")
  end
end
