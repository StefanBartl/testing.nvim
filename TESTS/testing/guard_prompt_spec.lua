-- TESTS/testing/guard_prompt_spec.lua -- the prompt guard in a REAL child editor: no prompt ever blocks,
-- an unanswered one raises with the prompt text and the stack (and stays a finding even when the spec
-- catches the error), scripted answers (scalar, list, function, CANCEL) are consumed.

return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("prompt")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
  end

  local c = r.red_input_unanswered
  ok(
    c.body_error and c.body_error:find('vim.fn.input("Name: ")', 1, true),
    "the error names the prompt"
  )
  ok(c.body_error:find("answer_prompts", 1, true), "the error says how to fix it")
  ok(c.body_error:find("stack traceback", 1, true), "the error carries the spec's stack")
  local f = S.of(c, "prompt.unanswered")[1]
  ok(f ~= nil and f.severity == "error", "a finding with severity error")
  eq(c.prompts[1].blocked, true, "the unanswered prompt is in the ledger, marked blocked")

  c = r.red_every_prompt_kind
  for _, kind in ipairs({
    "input",
    "inputdialog",
    "inputsecret",
    "inputlist",
    "confirm",
    "getchar",
    "getcharstr",
    "ui_input",
    "ui_select",
  }) do
    ok(
      tostring(c.value[kind]):find("asked a prompt nobody answered", 1, true),
      kind .. ": raises instead of blocking"
    )
  end
  eq(c.extra.n, 9, "every one of them is also a finding")

  c = r.red_error_names_prompt_and_stack
  ok(c.body_error:find("Rename to: ", 1, true), "the prompt text is in the error")

  c = r.red_exhausted_queue
  eq(c.value.first, "only-one", "the queued answer is consumed")
  eq(c.value.second_raises, true, "an exhausted queue is 'no answer'")
  eq(#S.of(c, "prompt.unanswered"), 1, "exactly one unanswered prompt")

  -- GREEN
  c = r.green_scripted_answers
  eq(c.findings, {}, "scripted answers: no finding")
  eq(c.value.input, "yes", "input answer (scalar answers every prompt)")
  eq(c.value.input2, "yes", "the scalar is not consumed")
  eq(c.value.list, 2, "inputlist answer")
  eq(c.value.confirm, 1, "confirm answer")
  eq(c.value.char, "y", "getcharstr answer")
  eq(c.value.ui_input, "yes", "vim.ui.input answer")
  eq(c.value.ui_item, "b", "vim.ui.select answers by index")
  eq(c.value.ui_idx, 2, "vim.ui.select passes the index")
  eq(c.extra.prompts, 7, "answered prompts are recorded in the ledger as well")

  c = r.green_queue_and_function_and_cancel
  eq(c.findings, {}, "no finding")
  eq(c.value.a, "first", "queue: first")
  eq(c.value.b, "second", "queue: second")
  eq(c.value.last, "y", "function answer (the last of two items)")
  eq(c.value.cancelled, true, "CANCEL cancels vim.ui.select")

  c = r.green_select_by_item
  eq(c.value, { item = "b", idx = 2 }, "select by item value")

  eq(
    r.green_polling_getchar_passes.findings,
    {},
    "getchar(0) / getcharstr(1) poll and never prompt"
  )
  eq(r.green_prompt_off.value.is_wrapped, false, "mode off installs nothing")

  c = r.green_getchar_with_typeahead
  eq(c.findings, {}, "a key typed ahead: getchar() does not prompt, nothing is reported")
  eq(c.body_error, nil, "and nothing raises")
  eq(c.value.c, 74, "getchar() returns the key that was waiting (J)")
  eq(c.value.s, "K", "getcharstr() returns the key that was waiting (K)")

  c = r.green_getchar_fed_by_a_timer
  eq(c.findings, {}, "a key fed by a timer while getchar() waits: no finding")
  eq(c.value.c, 27, "and getchar() returns that key (Esc)")
  c = r.red_getchar_timer_but_no_wait
  eq(c.value.raised, true, "getchar_wait_ms = 0: the same call is refused at once")

  c = r.red_getchar_without_typeahead
  eq(c.value.raised, true, "no key waiting: the blocking getchar() is still refused")
  ok(c.value.text:find("asked a prompt nobody answered", 1, true), "and names the prompt")

  c = r.warn_reports_and_cancels
  eq(c.body_error, nil, "mode warn: the case body does not raise")
  eq(c.value.input, "", "mode warn: input() answers like a cancelled prompt")
  eq(c.value.char, "\27", "mode warn: getcharstr() answers Esc")
  eq(c.value.item, nil, "mode warn: vim.ui.select() answers nil")
  eq(#S.of(c, "prompt.unanswered"), 3, "mode warn: every unanswered prompt is a finding")
  eq(S.of(c, "prompt.unanswered")[1].severity, "warn", "mode warn: with severity warn, not error")
end
