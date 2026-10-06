---@diagnostic disable: deprecated
-- Scenarios of the prompt guard (RED: a prompt nobody answers, GREEN: scripted answers).
-- Run by TESTS/testing/guard_prompt_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")

local function only_prompt(extra)
  ---@type table<string, any>
  local g = { prompt = vim.tbl_extend("force", { mode = "error" }, extra or {}) }
  for _, name in ipairs({ "fs", "state", "scheduled_error", "deprecation", "process_net", "clock" }) do
    g[name] = "off"
  end
  return { guards = g }
end

B.case("red_input_unanswered", {
  cfg = only_prompt(),
  body = function()
    vim.fn.input("Name: ")
  end,
})

B.case("red_every_prompt_kind", {
  cfg = only_prompt(),
  body = function()
    local errors = {}
    local function try(name, fn)
      local ok, err = pcall(fn)
      errors[name] = not ok and tostring(err):match("^[^\n]*") or "NO ERROR"
    end
    try("input", function()
      vim.fn.input("a")
    end)
    try("inputdialog", function()
      vim.fn.inputdialog("a")
    end)
    try("inputsecret", function()
      vim.fn.inputsecret("a")
    end)
    try("inputlist", function()
      vim.fn.inputlist({ "pick", "1. x" })
    end)
    try("confirm", function()
      vim.fn.confirm("sure?")
    end)
    try("getchar", function()
      vim.fn.getchar()
    end)
    try("getcharstr", function()
      vim.fn.getcharstr()
    end)
    try("ui_input", function()
      vim.ui.input({ prompt = "x" }, function() end)
    end)
    try("ui_select", function()
      vim.ui.select({ "a" }, { prompt = "x" }, function() end)
    end)
    return errors
  end,
  after = function(h)
    return { n = #h:collect().findings }
  end,
})

B.case("red_error_names_prompt_and_stack", {
  cfg = only_prompt(),
  body = function()
    local ok, err = pcall(vim.fn.input, "Rename to: ")
    assert(not ok)
    error(err, 0)
  end,
})

B.case("green_scripted_answers", {
  cfg = only_prompt(),
  body = function(h)
    h:answer_prompts({ input = "yes", select = 2, confirm = 1, getchar = "y" })
    local got = {}
    got.input = vim.fn.input("Name: ")
    got.input2 = vim.fn.input("Again: ")
    got.list = vim.fn.inputlist({ "pick", "1. a", "2. b" })
    got.confirm = vim.fn.confirm("sure?", "&Yes\n&No")
    got.char = vim.fn.getcharstr()
    vim.ui.input({ prompt = "ui" }, function(v)
      got.ui_input = v
    end)
    vim.ui.select({ "a", "b", "c" }, { prompt = "pick" }, function(item, idx)
      got.ui_item, got.ui_idx = item, idx
    end)
    return got
  end,
  after = function(_, res)
    return { prompts = #res.ledger:entries("prompts") }
  end,
})

B.case("green_queue_and_function_and_cancel", {
  cfg = only_prompt(),
  body = function(h)
    h:answer_prompts({
      input = { "first", "second" },
      select = function(items)
        return #items
      end,
    })
    local got = {}
    got.a = vim.fn.input("1")
    got.b = vim.fn.input("2")
    vim.ui.select({ "x", "y" }, {}, function(item)
      got.last = item
    end)
    h:answer_prompts({ select = B.guard.CANCEL })
    vim.ui.select({ "x", "y" }, {}, function(item, idx)
      got.cancelled = item == nil and idx == nil
    end)
    return got
  end,
})

B.case("red_exhausted_queue", {
  cfg = only_prompt(),
  body = function(h)
    h:answer_prompts({ input = { "only-one" } })
    local first = vim.fn.input("1")
    local ok = pcall(vim.fn.input, "2")
    return { first = first, second_raises = not ok }
  end,
})

B.case("green_select_by_item", {
  cfg = only_prompt(),
  body = function(h)
    h:answer_prompts({ select = "b" })
    local got = {}
    vim.ui.select({ "a", "b" }, {}, function(item, idx)
      got.item, got.idx = item, idx
    end)
    return got
  end,
})

B.case("green_polling_getchar_passes", {
  cfg = only_prompt(),
  body = function()
    -- non-blocking forms never wait for the user
    local c = vim.fn.getchar(0)
    local d = vim.fn.getcharstr(1)
    return { c = c, d = d }
  end,
})

-- a key that is already typed ahead: `getchar()` returns at once, nobody is asked anything (a picker
-- test feeds its key with `nvim_feedkeys` and the plugin then calls the blocking form)
B.case("green_getchar_with_typeahead", {
  cfg = only_prompt(),
  body = function()
    vim.api.nvim_feedkeys("J", "n", false)
    local c = vim.fn.getchar()
    vim.api.nvim_feedkeys("K", "n", false)
    local s = vim.fn.getcharstr()
    return { c = c, s = s }
  end,
})

-- a key that arrives while `getchar()` waits (fed from a timer, as ui.nvim's window picker tests do)
B.case("green_getchar_fed_by_a_timer", {
  cfg = only_prompt(),
  body = function()
    vim.api.nvim_feedkeys("", "nx", false)
    vim.defer_fn(function()
      vim.api.nvim_feedkeys("\27", "n", false)
    end, 60)
    return { c = vim.fn.getchar() }
  end,
})

-- ... with the wait switched off it is refused at once
B.case("red_getchar_timer_but_no_wait", {
  cfg = only_prompt({ getchar_wait_ms = 0 }),
  body = function()
    vim.api.nvim_feedkeys("", "nx", false)
    vim.defer_fn(function()
      vim.api.nvim_feedkeys("\27", "n", false)
    end, 60)
    local ok, err = pcall(vim.fn.getchar)
    -- let the late key arrive and swallow it, so that the next scenario starts with nothing typed ahead
    vim.wait(150)
    vim.fn.getchar()
    return { raised = not ok, text = tostring(err):match("^[^\n]*") }
  end,
})

-- ... but without a key waiting it is still refused (the guard did not just stop looking)
B.case("red_getchar_without_typeahead", {
  cfg = only_prompt(),
  body = function()
    vim.api.nvim_feedkeys("", "nx", false) -- flush: nothing is typed ahead
    local ok, err = pcall(vim.fn.getchar)
    return { raised = not ok, text = tostring(err):match("^[^\n]*") }
  end,
})

-- mode `warn` reports and answers like a cancelled prompt; it does not raise
B.case("warn_reports_and_cancels", {
  cfg = only_prompt({ mode = "warn" }),
  body = function()
    local got = { input = vim.fn.input("Name: "), char = vim.fn.getcharstr() }
    vim.ui.select({ "a" }, { prompt = "x" }, function(item, idx)
      got.item, got.idx = item, idx
    end)
    return got
  end,
})

B.case("green_prompt_off", {
  cfg = {
    guards = {
      prompt = "off",
      fs = "off",
      state = "off",
      scheduled_error = "off",
      deprecation = "off",
      process_net = "off",
      clock = "off",
    },
  },
  body = function()
    -- guard not installed: the original function is untouched
    return { is_wrapped = debug.getinfo(vim.fn.input, "S").short_src:find("guard", 1, true) ~= nil }
  end,
})

B.finish()
