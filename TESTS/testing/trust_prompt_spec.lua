-- TESTS/testing/trust_prompt_spec.lua -- the trust question from the editor (`testing.bindings.trust_prompt`): a run of
-- `:Testing <cmd>` or `:Testing ci` refused by the workspace trust gate asks once; yes stores the root and runs again,
-- no (or a cancelled question) leaves the refusal, a headless nvim is never asked, a second refusal is not asked about.

---@diagnostic disable: missing-fields, need-check-nil

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local trust = require("testing.trust")
  local prompt = require("testing.bindings.trust_prompt")
  local child = require("testing.bindings.child")
  local editor = require("testing.ci.editor")

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-trust-prompt"
  local proj = base .. "/proj"
  vim.fn.mkdir(proj, "p")
  vim.fn.writefile({ "return {}" }, proj .. "/.testing.lua")
  local store = base .. "/state/trust.json"
  local REFUSAL = trust.refusal(proj, { why = "unknown" }) .. "\n"

  local real = {
    select = vim.ui.select,
    interactive = prompt.interactive,
    ctx = prompt.ctx,
    notify = vim.notify,
    system = editor.system,
    progress = editor.progress,
  }
  local questions = 0
  local answer = prompt.YES
  local ui = true
  vim.ui.select = function(items, opts, cb)
    questions = questions + 1
    eq(items, { prompt.YES, prompt.NO }, "select: yes or no")
    has(opts.prompt, proj, "select: the question names the root")
    cb(answer)
  end
  prompt.interactive = function()
    return ui
  end
  prompt.ctx = { env = {}, store = store }
  vim.notify = function() end

  local function trusted()
    return trust.decide(proj, { env = {}, store = store }).trusted
  end
  local function reset()
    questions, answer, ui = 0, prompt.YES, true
    os.remove(store)
  end
  local function wait_for(cond, what)
    ok(vim.wait(5000, cond, 10), "timed out: " .. what)
  end

  ---A `system` that ends every call with the next of `results` (`{ code, stderr }`); `calls` counts the starts. A
  ---call that is not the driver (the `git rev-parse` of the refresh after a pipeline) fails and is not counted.
  local function scripted(results)
    local calls = { n = 0, argv = {} }
    return function(argv, opts, on_exit)
      if argv[1] ~= vim.v.progpath then
        on_exit({ code = 1, stdout = "", stderr = "" })
        return {}
      end
      calls.n = calls.n + 1
      calls.argv[calls.n] = argv
      local r = results[calls.n] or { code = 0, stderr = "" }
      if opts.stderr then
        opts.stderr(nil, r.stderr)
      end
      on_exit({ code = r.code, stdout = "", stderr = opts.stderr and nil or r.stderr })
      return {}
    end,
      calls
  end

  local passed, err = pcall(function()
    -- ------------------------------------------------------------------- refused()
    eq(prompt.refused(2, REFUSAL), true, "refused: exit 2 with the gate's marker")
    eq(prompt.refused(2, "testing: no .testing.lua\n"), false, "refused: exit 2 without the marker")
    eq(prompt.refused(1, REFUSAL), false, "refused: another exit code")
    eq(prompt.refused(2, nil), false, "refused: no stderr")

    -- ------------------------------------------------------------------- ask() without a UI
    reset()
    ui = false
    local answered
    prompt.ask(proj, function(t)
      answered = t
    end)
    eq(answered, false, "headless: no trust")
    eq(questions, 0, "headless: nobody is asked")
    eq(trusted(), false, "headless: nothing stored")

    -- ------------------------------------------------------------------- :Testing run, yes
    reset()
    local system, calls = scripted({ { code = 2, stderr = REFUSAL }, { code = 0, stderr = "" } })
    local verdict
    eq(
      child.start("list", { root = proj, system = system }, function(v)
        verdict = v
      end),
      true,
      "run/yes: starts"
    )
    wait_for(function()
      return verdict ~= nil
    end, "run/yes: the verdict")
    eq(questions, 1, "run/yes: asked once")
    eq(trusted(), true, "run/yes: the root is in the store")
    eq(calls.n, 2, "run/yes: the run is started again")
    eq(calls.argv[2], calls.argv[1], "run/yes: with the same arguments")
    eq(verdict.level, "info", "run/yes: the verdict is the second run's")

    -- ------------------------------------------------------------------- :Testing run, no
    reset()
    answer = prompt.NO
    system, calls = scripted({ { code = 2, stderr = REFUSAL } })
    verdict = nil
    child.start("list", { root = proj, system = system }, function(v)
      verdict = v
    end)
    wait_for(function()
      return verdict ~= nil
    end, "run/no: the verdict")
    eq(questions, 1, "run/no: asked once")
    eq(calls.n, 1, "run/no: not started again")
    eq(trusted(), false, "run/no: nothing stored")
    eq(verdict.level, "error", "run/no: the refusal is an error")
    has(verdict.message, trust.REFUSED, "run/no: ... with the gate's message")

    -- a cancelled question (nil) is a no
    reset()
    answer = nil
    system, calls = scripted({ { code = 2, stderr = REFUSAL } })
    verdict = nil
    child.start("list", { root = proj, system = system }, function(v)
      verdict = v
    end)
    wait_for(function()
      return verdict ~= nil
    end, "run/cancel: the verdict")
    eq(calls.n, 1, "run/cancel: not started again")

    -- ------------------------------------------------------------------- refused again after yes: asked once only
    reset()
    system, calls = scripted({ { code = 2, stderr = REFUSAL }, { code = 2, stderr = REFUSAL } })
    verdict = nil
    child.start("list", { root = proj, system = system }, function(v)
      verdict = v
    end)
    wait_for(function()
      return verdict ~= nil
    end, "run/twice: the verdict")
    eq(questions, 1, "run/twice: the second refusal is not asked about")
    eq(calls.n, 2, "run/twice: two runs, no third")
    eq(verdict.level, "error", "run/twice: the second refusal is reported")

    -- ------------------------------------------------------------------- headless run: the refusal as before
    reset()
    ui = false
    system, calls = scripted({ { code = 2, stderr = REFUSAL } })
    verdict = nil
    child.start("list", { root = proj, system = system }, function(v)
      verdict = v
    end)
    wait_for(function()
      return verdict ~= nil
    end, "run/headless: the verdict")
    eq(questions, 0, "run/headless: no question")
    eq(calls.n, 1, "run/headless: one run")
    has(verdict.message, "exit 2", "run/headless: exit 2 as before")

    -- ------------------------------------------------------------------- :Testing ci (streamed stderr)
    editor.progress = function()
      return {
        update = function() end,
        finish = function() end,
        cancel = function() end,
      }
    end
    reset()
    editor.system, calls =
      scripted({ { code = 2, stderr = REFUSAL }, { code = 2, stderr = REFUSAL } })
    local ci_verdict
    eq(
      editor.run({
        root = proj,
        on_done = function(v)
          ci_verdict = v
        end,
      }),
      true,
      "ci/yes: starts"
    )
    wait_for(function()
      return ci_verdict ~= nil
    end, "ci/yes: the verdict")
    eq(questions, 1, "ci/yes: asked once")
    eq(trusted(), true, "ci/yes: the root is in the store")
    eq(calls.n, 2, "ci/yes: the pipeline is started again, once")

    reset()
    answer = prompt.NO
    editor.system, calls = scripted({ { code = 2, stderr = REFUSAL } })
    ci_verdict = nil
    editor.run({
      root = proj,
      on_done = function(v)
        ci_verdict = v
      end,
    })
    wait_for(function()
      return ci_verdict ~= nil
    end, "ci/no: the verdict")
    eq(calls.n, 1, "ci/no: not started again")
    eq(ci_verdict.level, "error", "ci/no: the refusal is an error")
  end)

  vim.ui.select, prompt.interactive, prompt.ctx, vim.notify =
    real.select, real.interactive, real.ctx, real.notify
  editor.system, editor.progress = real.system, real.progress
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("testing ci", 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.fn.delete(base, "rf")
  ok(passed, "trust_prompt_spec: " .. tostring(err))
end
