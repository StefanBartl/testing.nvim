-- TESTS/testing/child_rpc_surface_spec.lua -- REAL child editors (testing.rpc): the surface a spec drives:
-- lua/lua_get/api/fn/cmd, the scope accessors, feed vs input, settle (what it waits for and what it
-- reports), mouse, notifies/messages/prompts, screen, reset, errors with the child's traceback (ERR-33).

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")

  S.run(function()
    -- ===================================================================
    -- 1. lua / lua_get / api / fn / cmd
    local c = S.spawn({ minit = S.minit })
    ok(c.alive(), "the child runs")
    eq(c.lua("return 1 + 1"), 2, "lua returns a value")
    eq(c.lua("local a, b = ...; return a .. b", "x", "y"), "xy", "lua takes arguments")
    eq(c.lua_get("vim.fn.fnamemodify('a/b.txt', ':t')"), "b.txt", "lua_get evaluates an expression")
    eq(c.lua_get("select('#', ...)", 1, nil, 3), 3, "a nil argument keeps its position")
    eq(c.lua("return nil"), nil, "nil comes back as nil")
    eq(c.lua("return { a = { 1, 2 }, b = 'x' }"), { a = { 1, 2 }, b = "x" }, "tables round-trip")
    eq(c.g.rpc_minit_ran, true, "the project's minit ran in the child")
    eq(c.lua_get("vim.v.argv[2]"), "--embed", "started as an embedded editor")
    ok(c.lua_get("vim.v.servername ~= nil"), "(the default server exists but is never used)")

    -- api: `nvim_` prefix optional, handles are plain integers, `{}` is an empty DICT where nvim wants one
    local buf = c.api.nvim_get_current_buf()
    eq(type(buf), "number", "a buffer handle is an integer")
    eq(c.api.get_current_buf(), buf, "the nvim_ prefix is optional")
    c.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
    eq(c.api.nvim_buf_get_lines(buf, 0, -1, false), { "alpha", "beta" }, "buffer lines")
    eq(c.api.nvim_get_option_value("lines", {}), 24, "an empty table becomes an empty dictionary")
    eq(c.api.nvim_get_option_value("tabstop", { buf = buf }), 8, "options with a buffer scope")

    -- fn goes through vim.fn
    eq(c.fn.toupper("abc"), "ABC", "fn")
    eq(c.fn.line("$"), 2, "fn.line")
    eq(c.fn.expand("%:t"), "", "fn with an empty result")

    -- cmd / cmd_capture
    c.cmd("let g:from_cmd = 7")
    eq(c.g.from_cmd, 7, "cmd")
    eq(c.cmd_capture("echo 'captured'"), "captured", "cmd_capture")

    -- ===================================================================
    -- 2. scope accessors: the CURRENT buffer/window at the moment of the call (ERR-33)
    c.g.answer = 42
    eq(c.g.answer, 42, "g set/get")
    eq(c.lua_get("vim.g.answer"), 42, "g is vim.g in the child")
    c.g.answer = nil
    eq(c.g.answer, nil, "g = nil removes the variable")
    c.o.shiftwidth = 3
    eq(c.o.shiftwidth, 3, "o set/get")
    c.b.flag = "first"
    eq(c.b.flag, "first", "b is the current buffer")
    c.cmd("enew")
    eq(c.b.flag, nil, "after :enew `b` means the NEW buffer: handles are not cached")
    c.cmd("buffer 1")
    eq(c.b.flag, "first", "and the first one again")
    c.bo.filetype = "lua"
    eq(c.bo.filetype, "lua", "bo")
    c.w.winvar = "w"
    eq(c.w.winvar, "w", "w")
    eq(c.v.version >= 800, true, "v")
    c.env.RPC_ENV_PROBE = "set-in-child"
    eq(c.lua_get("vim.fn.getenv('RPC_ENV_PROBE')"), "set-in-child", "env")

    -- a stale handle is refused by the CHILD when the call executes
    local stale_ok, stale_err = pcall(c.api.nvim_buf_get_name, 9999)
    ok(not stale_ok, "a stale buffer handle raises")
    has(stale_err, "Invalid buffer id", "with the child's message")
    local bad_buf = c.api.nvim_create_buf(false, true)
    c.api.nvim_buf_delete(bad_buf, { force = true })
    ok(
      not pcall(c.api.nvim_buf_set_lines, bad_buf, 0, -1, false, { "x" }),
      "a deleted buffer is invalid when used"
    )

    -- ===================================================================
    -- 3. errors carry the child's traceback; the child survives them
    local eok, eerr =
      pcall(c.lua, "local function inner() error('boom from the child') end inner()")
    ok(not eok, "an error in the child raises in the parent")
    has(eerr, "boom from the child", "the message")
    has(eerr, "stack traceback", "and the child's traceback")
    has(eerr, "nvim_exec_lua", "naming the call")
    ok(c.alive(), "the child survives a Lua error")
    eq(c.lua("return 'still here'"), "still here", "and answers the next call")
    local cok, cerr = pcall(c.cmd, "this_is_not_a_command")
    ok(not cok, "a failing :command raises")
    has(cerr, "E492", "with nvim's error code")

    -- ===================================================================
    -- 4. feed (sync, mappings) vs input (async) and settle
    c.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    c.feed("ihello world<Esc>")
    eq(
      c.api.nvim_buf_get_lines(0, 0, -1, false),
      { "hello world" },
      "feed runs the keys to completion"
    )
    eq(c.fn.mode(), "n", "back in normal mode")
    c.feed("0dw")
    eq(c.api.nvim_buf_get_lines(0, 0, -1, false), { "world" }, "feed with an operator")

    -- `gz` (fixture mapping) arms a 250 ms timer: feed returns before the work is done; settle waits for it
    eq(c.g.deferred, nil, "nothing deferred yet")
    c.feed("gz")
    eq(
      c.g.deferred,
      nil,
      "feed returns before the mapping's timer fired (that is what settle is for)"
    )
    local settled, why = c.settle(3000)
    ok(settled, "settle waits for the timer: " .. tostring(why))
    eq(c.g.deferred, "done", "the deferred work is done after settle")

    -- input is queued typing: after settle the keys were processed
    c.g.deferred = nil
    c.input("gz")
    ok(c.settle(3000), "settle after input")
    eq(c.g.deferred, "done", "input + settle reaches the same state")
    c.input("A!<Esc>")
    ok(c.settle(1000), "settle after typed text")
    eq(c.api.nvim_buf_get_lines(0, 0, -1, false), { "world!" }, "typed text arrived")

    -- scheduled callbacks count as pending work
    c.lua("vim.g.sched = nil; vim.schedule(function() vim.g.sched = 'ran' end)")
    ok(c.settle(1000), "settle after vim.schedule")
    eq(c.g.sched, "ran", "the scheduled callback ran before settle returned true")

    -- settle reports what is busy, and does not return true early
    c.lua("vim.defer_fn(function() vim.g.late = 1 end, 700)")
    local early, early_why = c.settle(60)
    ok(early == false, "settle times out while a timer is pending")
    has(early_why, "timer=1", "and names the handle type that is busy: " .. tostring(early_why))
    ok(c.settle(3000), "it settles once the timer fired")
    eq(c.g.late, 1, "the timer fired")
    local rok, rerr = pcall(c.settle, 10, { raise = true })
    ok(
      rok or tostring(rerr):find("not idle", 1, true),
      "settle(raise) raises with the reason when it times out"
    )

    -- a half typed mapping is pending work (the mapping timeout timer)
    c.cmd("nnoremap gqq <Cmd>let g:gqq = 1<CR>")
    c.input("gq")
    local half = c.settle(80)
    ok(half == false, "a pending mapping prefix is not idle")
    c.input("<Esc>")
    ok(c.settle(3000), "idle again after <Esc>")

    -- a timer the plugin keeps for ever never settles, until the baseline is retaken on purpose
    c.lua("_G.keeper = vim.uv.new_timer(); _G.keeper:start(0, 50, function() end)")
    ok(c.settle(120) == false, "a repeating timer is busy")
    c.rebaseline()
    ok(c.settle(1000), "rebaseline accepts it")
    c.lua("_G.keeper:stop(); _G.keeper:close(); _G.keeper = nil")

    -- ===================================================================
    -- 5. mouse
    c.o.mouse = "a"
    c.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "line two", "line three" })
    c.mouse("left", "press", "", 1, 5)
    c.mouse("left", "release", "", 1, 5)
    eq(
      c.api.nvim_win_get_cursor(0),
      { 2, 5 },
      "a mouse click moves the cursor (row/col are 0-based screen cells)"
    )
    c.mouse("left", "press", "", 2, 2)
    c.mouse("left", "release", "", 2, 2)
    eq(c.api.nvim_win_get_cursor(0), { 3, 2 }, "a second click")
    ok(not pcall(c.mouse, "nonsense", "press", "", 0, 0), "an invalid button is an error")

    -- ===================================================================
    -- 6. notifies, messages, prompts
    c.lua("vim.notify('first', vim.log.levels.INFO); vim.notify('second', vim.log.levels.ERROR)")
    local notes = c.notifies()
    eq(#notes, 2, "both notifications are captured")
    eq({ notes[1].msg, notes[1].level_name }, { "first", "INFO" }, "first")
    eq({ notes[2].msg, notes[2].level_name }, { "second", "ERROR" }, "second, with its level")
    eq(#c.notifies({ clear = true }), 2, "clear returns and empties")
    eq(c.notifies(), {}, "emptied")

    c.cmd("echomsg 'a message line'")
    local joined = table.concat(c.messages(), "\n")
    has(joined, "a message line", "messages() reads :messages")

    -- a prompt is answered with "cancelled" and recorded, not waited for
    eq(c.fn.input("Name? "), "", "input() answers with an empty string")
    eq(c.fn.confirm("Sure?", "&Yes\n&No"), 0, "confirm() answers 0")
    eq(c.fn.inputlist({ "pick", "1. a", "2. b" }), 0, "inputlist() answers 0")
    local prompts = c.prompts()
    eq(#prompts, 3, "three prompts were recorded")
    eq({ prompts[1].fn, prompts[1].text }, { "input", "Name? " }, "the first prompt and its text")
    eq(prompts[2].fn, "confirm", "second")
    eq(#c.prompts({ clear = true }), 3, "clear")
    eq(c.prompts(), {}, "cleared")

    -- ===================================================================
    -- 7. screen
    c.cmd("enew")
    c.api.nvim_buf_set_lines(0, 0, -1, false, { "screen text", "second row" })
    local shot = c.screen()
    eq(shot.size, { rows = 24, cols = 80 }, "the screen size")
    eq(#shot.lines, 24, "one entry per row")
    has(shot.lines[1], "screen text", "buffer text is on row 1")
    has(shot.lines[2], "second row", "and row 2")
    eq(shot.cursor.row, 1, "cursor row (1-based screen)")
    ok(#shot.attrs[1] == #shot.lines[1], "attrs have one letter per cell")
    has(shot.text, "second row", "text is the trimmed joined grid")
    c.cmd("set hlsearch | /second")
    c.cmd("redraw")
    local shot2 = c.screen()
    ok(
      shot2.attrs[2]:find("%a") ~= nil,
      "a highlighted match shows up as an attribute letter on its row: " .. shot2.attrs[2]
    )

    -- ===================================================================
    -- 8. reset: a clean editor stays clean, leaks are NAMED
    local r = S.spawn({ minit = S.minit })
    r.cmd("enew")
    r.lua("vim.cmd('vsplit'); vim.cmd('tabnew'); vim.cmd('split')")
    r.cmd("silent! normal! ihello")
    eq(r.reset(), {}, "reset of an editor without leaks reports none")
    eq(#r.api.nvim_list_wins(), 1, "one window again")
    eq(#r.api.nvim_list_tabpages(), 1, "one tab again")
    eq(r.fn.mode(), "n", "normal mode again")
    eq(#r.api.nvim_list_bufs() >= 1, true, "a buffer remains (the editor always has one)")
    eq(r.api.nvim_buf_get_lines(0, 0, -1, false), { "" }, "and it is empty")
    c = r
    c.lua(
      "vim.api.nvim_create_augroup('LeakyGroup', { clear = true }); vim.api.nvim_create_autocmd('BufEnter', { group = 'LeakyGroup', callback = function() end })"
    )
    c.lua("vim.g.leaked_global = 1; vim.keymap.set('n', '<F9>', '<Nop>')")
    local leaks = table.concat(c.reset(), "\n")
    has(leaks, "autocmd BufEnter in group LeakyGroup", "the leaked autocmd is named with its group")
    has(leaks, "vim.g.leaked_global", "the leaked global is named")
    has(leaks, "<F9>", "the leaked mapping is named")
  end)
end
