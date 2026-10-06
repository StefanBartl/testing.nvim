---@diagnostic disable: undefined-field, need-check-nil, redundant-parameter
-- TESTS/testing/guard_core_spec.lua -- the guard framework IN-PROCESS (the variant the in-process driver
-- uses): configuration, restorable patches, the case window, findings (dedupe, strict, bounds,
-- redaction), tags, soft isolation and the overhead budget. The per-guard behavior is covered in
-- real child editors by the other guard_*_spec.lua files.
--
-- Nothing here starts a process or blocks: process / prompt guards are only asked to REFUSE.

return function(H)
  local ok, eq = H.ok, H.eq
  local guard = require("testing.guard")
  local config = require("testing.guard.config")
  local patch = require("testing.guard.patch")
  local uv = vim.uv or vim.loop

  local function only(name, section, top)
    local g = {}
    for _, n in ipairs(config.ORDER) do
      g[n] = "off"
    end
    g[name] = section or { mode = "error" }
    return vim.tbl_extend("force", { guards = g }, top or {})
  end

  -- ---------------------------------------------------------------- config
  local cfg, problems = config.normalize(nil)
  eq(problems, {}, "defaults are valid")
  eq(cfg.guards.deprecation.mode, "warn", "deprecation: warn by default")
  eq(cfg.guards.clock.mode, "off", "clock: off by default")
  eq(cfg.guards.process_net.mode, "error", "process / network: blocked by default")
  eq(cfg.guards.state.categories.modules, "info", "state: loaded modules are info only")

  cfg, problems =
    config.normalize({ guards = { fs = "off", prompt = false, state = { mode = "warn" } } })
  eq(problems, {}, "shorthand modes are valid")
  eq(cfg.guards.fs.mode, "off", "bare string = mode")
  eq(cfg.guards.prompt.mode, "off", "false = off")
  eq(cfg.guards.state.mode, "warn", "table section")
  eq(cfg.guards.state.categories.autocmds, "error", "a section keeps the defaults it does not name")

  local _, bad = config.normalize({
    strict = false,
    guards = {
      nonsense = "off",
      fs = { mode = "loud" },
      state = { categories = { autocmd = "error", options = "sometimes" } },
      process_net = { allow_exec = "git" },
      scheduled_error = { notify = "x" },
    },
    settle_ms = -1,
    restore = "yes",
  })
  local blob = table.concat(bad, "\n")
  for _, needle in ipairs({
    "guards.nonsense: unknown guard",
    'guards.fs.mode: "loud"',
    "guards.state.categories.autocmd: unknown category",
    "guards.state.categories.options",
    "guards.process_net.allow_exec: must be a list",
    "guards.scheduled_error.notify",
    "settle_ms",
    "restore",
  }) do
    ok(blob:find(needle, 1, true), "problem reported: " .. needle .. " in " .. blob)
  end
  local okc, err = pcall(guard.install, { guards = { fsx = "off" } })
  ok(
    not okc and tostring(err):find("invalid config", 1, true),
    "install raises on an invalid config"
  )

  -- ---------------------------------------------------------------- patcher
  local t = {
    f = function()
      return 1
    end,
  }
  local p = patch.new()
  local orig = t.f
  eq(
    p:wrap(t, "f", function(o)
      return function()
        return o() + 1
      end
    end),
    orig,
    "wrap returns the original"
  )
  eq(t.f(), 2, "the wrapper is in place")
  eq(
    p:wrap(t, "missing", function(o)
      return o
    end),
    nil,
    "a missing function is not wrapped"
  )
  eq(t.missing, nil, "and not created")
  eq(p:count(), 1, "one active patch")
  eq(p:restore(), {}, "restore reports nothing unrestored")
  eq(t.f, orig, "the original is back")
  eq(p:restore(), {}, "restore is idempotent")

  -- somebody wrapped over us: their wrapper must survive, the slot is reported
  local p2 = patch.new()
  p2:wrap(t, "f", function(o)
    return function()
      return o() + 10
    end
  end, "t.f")
  local theirs = function()
    return 99
  end
  t.f = theirs
  eq(p2:restore(), { "t.f" }, "a slot someone else replaced is reported")
  eq(t.f, theirs, "and left alone")
  t.f = orig

  -- a lazily created slot goes back to lazy
  local lazy = setmetatable({}, {
    __index = function()
      return function()
        return "lazy"
      end
    end,
  })
  local p3 = patch.new()
  p3:wrap(lazy, "x", function(o)
    return function()
      return "wrapped"
    end
  end)
  eq(lazy.x(), "wrapped", "wrapped")
  p3:restore()
  eq(rawget(lazy, "x"), nil, "a slot that was not materialized before is not materialized after")
  eq(lazy.x(), "lazy", "the lazy accessor works again")

  -- ---------------------------------------------------------------- install / uninstall restore EVERYTHING
  local tcp = uv.new_tcp()
  local tcp_methods = getmetatable(tcp).__index
  tcp:close()
  local slots = {
    { io, "open" },
    { io, "output" },
    { io, "popen" },
    { os, "remove" },
    { os, "rename" },
    { os, "execute" },
    { os, "time" },
    { os, "clock" },
    { os, "date" },
    { vim.fn, "input" },
    { vim.fn, "inputlist" },
    { vim.fn, "confirm" },
    { vim.fn, "getcharstr" },
    { vim.fn, "writefile" },
    { vim.fn, "delete" },
    { vim.fn, "system" },
    { vim.fn, "jobstart" },
    { vim.fn, "strftime" },
    { vim.ui, "input" },
    { vim.ui, "select" },
    { vim, "system" },
    { vim, "schedule" },
    { vim, "notify" },
    { vim, "deprecate" },
    { uv, "fs_open" },
    { uv, "fs_unlink" },
    { uv, "spawn" },
    { uv, "now" },
    { uv, "getaddrinfo" },
    { tcp_methods, "connect" },
  }
  local before = {}
  for i, s in ipairs(slots) do
    before[i] = s[1][s[2]]
    ok(before[i] ~= nil, "slot exists on this editor: " .. s[2])
  end
  local raw_secret = rawget(vim.fn, "inputsecret")
  local h = guard.install({ guards = { clock = "error" } })
  local wrapped = 0
  for i, s in ipairs(slots) do
    if s[1][s[2]] ~= before[i] then
      wrapped = wrapped + 1
    end
  end
  ok(wrapped >= #slots - 2, ("the guards wrap the entry points (%d of %d)"):format(wrapped, #slots))
  eq(h:uninstall(), {}, "uninstall: nothing left over")
  for i, s in ipairs(slots) do
    ok(s[1][s[2]] == before[i], "restored: " .. s[2])
  end
  eq(rawget(vim.fn, "inputsecret"), raw_secret, "lazy vim.fn slots are lazy again")
  eq(h:uninstall(), {}, "uninstall is idempotent")
  local group_ok, group_autocmds = pcall(vim.api.nvim_get_autocmds, { group = "testing.guard.fs" })
  ok(
    not group_ok or #group_autocmds == 0,
    "the fs guard autocmd is gone (the group does not exist any more)"
  )

  -- ---------------------------------------------------------------- tags
  h = guard.install(only("process_net"))
  h:begin_case({ id = "f.lua::d::does a thing @Network", tags = { "@spawn", "slow" } })
  ok(h:has_tag("network"), "tag from the case id (lower-cased)")
  ok(h:has_tag("spawn"), "tag from the tags list, `@` stripped")
  ok(h:has_tag("slow"), "plain tag")
  ok(not h:has_tag("clock"), "an absent tag")
  h:end_case()
  eq(
    guard.tags_from_name("a @b and @c-d, not@this"),
    { b = true, ["c-d"] = true, this = true },
    "tags_from_name"
  )
  eq(guard.tags_from_name(nil), {}, "tags_from_name of nothing")
  h:uninstall()

  -- ---------------------------------------------------------------- the window, findings, effects
  h = guard.install(only("prompt", { mode = "error" }, { max_findings = 3 }))
  ok(not h:is_active(), "not active before a case")
  h:begin_case({ id = "w::a", file = "w.lua" })
  ok(h:is_active(), "active inside a case")
  local okp, perr = pcall(vim.fn.input, "How? ")
  ok(not okp, "an unanswered prompt raises instead of blocking")
  ok(tostring(perr):find("How? ", 1, true), "the error names the prompt")
  h:suspended(function()
    ok(not h:is_active(), "suspended: inactive")
  end)
  local res = h:end_case()
  ok(not h:is_active(), "not active after the case")
  eq(#res.findings, 1, "one finding")
  eq(res.findings[1].id, "prompt.unanswered", "stable id")
  eq(res.findings[1].case, "w::a", "the finding knows its case")
  eq(h:check(), res.findings, "check() twice gives the same findings (idempotent)")
  eq(#h:check(), 1, "and does not duplicate them")
  eq(res.ledger:entries("prompts")[1].blocked, true, "the prompt is in the ledger")
  local rebuilt = require("testing.core.ledger").deserialize(res.ledger_data)
  eq(
    assert(rebuilt):encode(),
    res.ledger:encode(),
    "ledger_data is the plain, RPC-safe form of the ledger"
  )
  eq(
    res.effects,
    { spawned = {}, network = {}, fs_outside_tmp = {} },
    "case effects have the IR shape"
  )

  -- a second case does not inherit the first one's findings; the run keeps both
  h:begin_case({ id = "w::b" })
  local res2 = h:end_case()
  eq(res2.findings, {}, "the next case starts clean")
  local run = h:collect()
  eq(#run.findings, 1, "collect() has the findings of the whole run")
  eq(
    run.effects.prompts,
    { 'vim.fn.input("How? ") [unanswered] [blocked]' },
    "collect() has the extra ledger kinds"
  )
  ok(run.ledger:total("prompts") >= 1, "collect() hands out the ledger")

  -- same id + message folds into one finding with a count; max_findings bounds the run
  h:begin_case({ id = "w::c" })
  for _ = 1, 3 do
    pcall(vim.fn.input, "same")
  end
  for i = 1, 4 do
    pcall(vim.fn.input, "other " .. i)
  end
  local res3 = h:end_case()
  eq(#res3.findings, 5, "folded: 'same' once, four others")
  eq(res3.findings[1].count, 3, "the repetition is counted")
  local run3 = h:collect()
  eq(#run3.findings, 3, "max_findings bounds what the run keeps")
  ok(
    vim.tbl_contains(run3.notes, "3 findings dropped (max_findings bound)"),
    "and says how many it dropped"
  )
  eq(#h:collect({ reset = true }).findings, 3, "collect{ reset } returns, then clears")
  eq(#h:collect().findings, 0, "cleared")
  eq(h:collect().effects.prompts, nil, "the ledger is cleared as well")
  h:uninstall()

  -- strict promotes warn; messages are redacted
  h = guard.install(only("deprecation", { mode = "warn" }, { strict = true, repo = "/work/proj" }))
  h:begin_case({ id = "s::a" })
  vim.deprecate("/work/proj/lua/x.lua", "y", "9.9", "Nvim", false)
  local res4 = h:end_case()
  eq(res4.findings[1].severity, "error", "strict: warn -> error")
  ok(res4.findings[1].message:find("<REPO>", 1, true), "paths in messages are redacted")
  h:uninstall()

  -- the process guard refuses without spawning anything
  h = guard.install(only("process_net"))
  h:begin_case({ id = "p::a" })
  local okx, errx = pcall(os.execute, "echo guard-test-must-not-run")
  ok(not okx and tostring(errx):find("blocked", 1, true), "os.execute is refused inside a case")
  ok(tostring(errx):find("@spawn", 1, true), "with the way out in the message")
  local res5 = h:end_case()
  eq(
    res5.effects.spawned,
    { "echo guard-test-must-not-run [blocked]" },
    "refused spawn is in the case effects"
  )
  eq(#res5.findings, 1, "one finding")
  h:uninstall()

  -- ---------------------------------------------------------------- soft isolation in-process
  h = guard.install(only("state", { mode = "error" }, { restore = true }))
  local nbuf = #vim.api.nvim_list_bufs()
  h:begin_case({ id = "r::a" })
  local leaked = vim.api.nvim_create_buf(true, false)
  local grp = vim.api.nvim_create_augroup("GuardCoreLeak", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = grp, command = "echo 1" })
  local res6 = h:end_case()
  ok(
    vim.iter(res6.findings):any(function(f)
      return f.message:find("leaves autocmd BufEnter in group GuardCoreLeak", 1, true)
    end),
    "the leak is named"
  )
  eq(res6.restored.buffers, 1, "restore deleted the buffer")
  eq(res6.restored.autocmds, 1, "restore deleted the autocmd")
  ok(not vim.api.nvim_buf_is_valid(leaked), "the buffer is gone")
  eq(#vim.api.nvim_get_autocmds({ group = "GuardCoreLeak" }), 0, "the autocmd is gone")
  eq(#vim.api.nvim_list_bufs() - nbuf, 0, "no new buffer")
  pcall(vim.api.nvim_del_augroup_by_id, grp)
  h:uninstall()

  -- ---------------------------------------------------------------- overhead
  h = guard.install({ guards = { clock = "error" } })
  local t0 = uv.hrtime()
  for _ = 1, 20 do
    h:begin_case({ id = "o::a" })
    h:end_case()
  end
  local per_case_ms = (uv.hrtime() - t0) / 1e6 / 20
  ok(
    per_case_ms < 50,
    ("a light snapshot + check costs %.1f ms per case (budget 50 ms)"):format(per_case_ms)
  )
  h:uninstall()

  local tmp = vim.fn.tempname()
  vim.fn.writefile({ "x" }, tmp)
  local function bench(n)
    local s = uv.hrtime()
    for _ = 1, n do
      local f = io.open(tmp, "r")
      f:close()
      local _ = os.time()
    end
    return (uv.hrtime() - s) / 1e3 / n
  end
  bench(200)
  local bare = bench(3000)
  h = guard.install({ guards = { clock = "error" } })
  h:begin_case({ id = "o::b" })
  local guarded = bench(3000)
  h:end_case()
  h:uninstall()
  vim.fn.delete(tmp)
  ok(
    guarded - bare < 25,
    ("wrapper overhead of an open+close+time call is %.1f us (budget 25 us)"):format(guarded - bare)
  )
end
