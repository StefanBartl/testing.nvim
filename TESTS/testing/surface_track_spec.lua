-- TESTS/testing/surface_track_spec.lua -- runtime tracking in a REAL child editor: which keymaps, commands, composer
-- routes, autocmds and api functions a run exercised, attributed to the open case; every handler stays
-- transparent (arguments, return values, expr mappings, self-deleting autocmds); `uninstall` puts the
-- originals back; what cannot be tracked is said and never counted as "missing".

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/surface_support.lua")

  S.run(function()
    local root = S.fixture()
    local sink = S.new_dir() .. "/sink.jsonl"
    local c = S.spawn(root)

    -- ================================================================ install BEFORE setup()
    c.lua(
      [==[
      local sink = ...
      ORIG = {
        set_keymap = vim.api.nvim_set_keymap,
        buf_set_keymap = vim.api.nvim_buf_set_keymap,
        create_command = vim.api.nvim_create_user_command,
        create_autocmd = vim.api.nvim_create_autocmd,
      }
      -- a keymap that exists BEFORE the install: it is re-set with a wrapped callback
      PRE = function() PRE_CALLS = (PRE_CALLS or 0) + 1 end
      vim.keymap.set("n", "<leader>pre", PRE, { desc = "pre-existing" })
      -- a command and an autocmd that exist before: they cannot be wrapped
      vim.api.nvim_create_user_command("PreCmd", function() end, {})
      vim.api.nvim_create_autocmd("BufReadPost", { pattern = "*.pre", callback = function() end })
      T = require("testing.surface.track").install({ api = { "fxsurf" }, sink = sink })
    ]==],
      sink
    )
    local tracked = c.lua_get("vim.api.nvim_set_keymap ~= ORIG.set_keymap")
    eq(tracked, true, "the creation primitives are patched while installed")
    c.lua("require('fxsurf').setup()")

    -- ---------------------------------------------------------------- case one: keymap, command, route, autocmd
    c.lua("T:begin_case({ id = 'a_spec.lua::one', file = 'a_spec.lua' })")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>fo'), 'mx', false)")
    eq(c.lua("return require('fxsurf').calls.open"), 1, "the keymap still ran its action")
    c.cmd("FxOpen")
    c.cmd("Fx status")
    c.lua("vim.api.nvim_exec_autocmds('BufWritePost', { pattern = 'x.fx' })")
    local one = c.lua("return T:end_case()")
    eq(
      one.hit,
      {
        "action:fxsurf.open",
        "api:fxsurf.on_write",
        "api:fxsurf.open",
        "api:fxsurf.status",
        "autocmd:fxsurf:BufWritePost:*.fx",
        "binding:<leader>fo",
        "command:Fx status",
        "command:FxOpen",
      },
      "case one: keymap (and the name of its action), both commands, the autocmd and the api functions they called"
    )
    -- the keymap holds its own reference to M.open (taken at setup()), the command calls it through the
    -- module: only the second is an api hit. That is the documented limit of aliases.
    eq(
      one.counts["api:fxsurf.open"],
      1,
      "the command called open() through the module, the keymap did not"
    )
    eq(one.counts["binding:<leader>fo"], 1, "the keymap once")
    eq(
      c.lua("return require('fxsurf').calls"),
      { open = 2, status = 1, write = 1 },
      "the handlers did their work"
    )

    -- ---------------------------------------------------------------- case two: nothing of case one leaks in
    c.lua("T:begin_case({ id = 'b_spec.lua::two', file = 'b_spec.lua' })")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>ft'), 'mx', false)")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>fc'), 'mx', false)")
    local two = c.lua("return T:end_case()")
    eq(
      two.hit,
      { "action:fxsurf.close", "api:fxsurf.toggle", "binding:<leader>fc@nx", "binding:<leader>ft" },
      "case two: a plain vim.keymap.set (no action) and a two-mode action (one id, one action name)"
    )

    -- ---------------------------------------------------------------- autocmd ids: the name of a group that is emptied later, one id per event
    c.lua("T:begin_case({ id = 'b_spec.lua::autocmds', file = 'b_spec.lua' })")
    c.lua([==[
      local g = vim.api.nvim_create_augroup("clearme", { clear = true })
      vim.api.nvim_create_autocmd({ "User", "BufEnter" }, {
        group = g,
        pattern = "*",
        callback = function() end,
      })
      vim.api.nvim_create_augroup("plainname", { clear = true })
      vim.api.nvim_create_autocmd("User", { group = "plainname", callback = function() end })
      vim.api.nvim_exec_autocmds("User", { group = "clearme" })
      vim.api.nvim_exec_autocmds("User", { group = "plainname" })
      vim.api.nvim_exec_autocmds("BufEnter", { group = "clearme" })
      -- `nvim_create_augroup(name, { clear = true })` empties the group: its name cannot be asked for any more
      vim.api.nvim_create_augroup("clearme", { clear = true })
    ]==])
    local acs = c.lua("return T:end_case()")
    local acs_hits = {}
    for _, id in ipairs(acs.hit) do
      if id:find("^autocmd:") then
        acs_hits[#acs_hits + 1] = id
      end
    end
    eq(
      acs_hits,
      { "autocmd:clearme:BufEnter", "autocmd:clearme:User", "autocmd:plainname:User" },
      "the group keeps its name after it was emptied, an event is one id each, pattern `*` is no pattern"
    )

    -- ---------------------------------------------------------------- a handler of a spec is not the plugin's
    c.lua("T:begin_case({ id = 'b_spec.lua::foreign', file = 'b_spec.lua' })")
    -- the spec replaces a key of the plugin with a function defined in a `_spec.lua` file
    c.lua([==[
      local chunk = load("return function() SPEC_OWN = (SPEC_OWN or 0) + 1 end", "@C:/x/TESTS/own_spec.lua")
      vim.keymap.set("n", "<leader>ft", chunk(), { desc = "the spec's own" })
      vim.api.nvim_create_user_command("SpecOwn", chunk(), {})
      vim.api.nvim_feedkeys(vim.keycode("<Bslash>ft"), "mx", false)
      vim.cmd("SpecOwn")
    ]==])
    local foreign = c.lua("return T:end_case()")
    eq(c.lua("return SPEC_OWN"), 2, "the spec's own handlers ran")
    eq(foreign.hit, {}, "and counted for nothing: the plugin's handlers did not run")

    -- ---------------------------------------------------------------- the keymap of the other mode, a keymap that existed before
    c.lua("T:begin_case({ id = 'b_spec.lua::three', file = 'b_spec.lua' })")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('v<Bslash>fc<Esc>'), 'mx', false)")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>pre'), 'mx', false)")
    local three = c.lua("return T:end_case()")
    eq(
      three.hit,
      { "action:fxsurf.close", "binding:<leader>fc@nx", "binding:<leader>pre" },
      "case three: the visual-mode binding is the same entry; a keymap that existed at install was re-wrapped"
    )
    eq(c.lua("return PRE_CALLS"), 1, "and it ran")

    -- ---------------------------------------------------------------- outside a window: the run, not a case
    c.lua("require('fxsurf').status()")
    local run = c.lua("return T:collect()")
    eq(#run.cases, 5, "five cases are recorded")
    ok(vim.tbl_contains(run.hit, "api:fxsurf.status"), "a call outside any window is in the run")
    eq(
      c.lua("return T:end_case()"),
      { hit = {}, counts = {} },
      "end_case without begin_case is empty"
    )

    -- ---------------------------------------------------------------- what cannot be tracked
    ok(vim.tbl_contains(run.wrapped, "command:FxOpen"), "wrapped: created while installed")
    ok(vim.tbl_contains(run.wrapped, "binding:<leader>pre"), "wrapped: re-set at install")
    ok(
      not vim.tbl_contains(run.wrapped, "command:PreCmd"),
      "a command that existed before is not wrapped"
    )
    local notes = table.concat(run.notes, "\n")
    has(notes, "exist already and cannot be tracked", "and the run says so")
    has(notes, "install before setup()", "with the remedy")

    -- ---------------------------------------------------------------- the sink
    c.lua("T:flush('s_spec.lua')")
    local lines = {}
    for line in io.lines(sink) do
      lines[#lines + 1] = vim.json.decode(line)
    end
    eq(
      { lines[1].k, lines[1].id, lines[1].file },
      { "case", "a_spec.lua::one", "a_spec.lua" },
      "sink: the first case"
    )
    eq(lines[1].hit, one.hit, "sink: its hits")
    eq(#lines, 6, "sink: five cases and one run")
    eq({ lines[6].k, lines[6].file }, { "run", "s_spec.lua" }, "sink: the run line")
    ok(vim.tbl_contains(lines[6].wrapped, "command:FxOpen"), "sink: with what was wrapped")
    c.lua("T:flush('s_spec.lua')")
    local count = 0
    for _ in io.lines(sink) do
      count = count + 1
    end
    eq(count, 6, "sink: a second flush of the same state writes nothing")

    -- ================================================================ uninstall restores
    local before = c.lua([==[
      return {
        cb_wrapped = vim.fn.maparg("\\fo", "n", false, true).callback ~= require("fxsurf").open,
      }
    ]==])
    eq(before.cb_wrapped, true, "while installed the live keymap carries a wrapper")
    -- a `unique = true` mapping must not make the restore fail with E227 (the wrapper IS the mapping)
    c.lua([==[
      UNIQUE = function() end
      vim.keymap.set("n", "<leader>uq", UNIQUE, { unique = true, desc = "unique" })
    ]==])
    local left = c.lua("return T:uninstall()")
    eq(left, {}, "nothing is left that could not be put back (a unique mapping included)")
    eq(
      c.lua([==[return vim.fn.maparg("\\uq", "n", false, true).callback == UNIQUE]==]),
      true,
      "and the unique mapping is the original function again"
    )
    eq(
      c.lua([==[
        return {
          set = vim.api.nvim_set_keymap == ORIG.set_keymap,
          buf = vim.api.nvim_buf_set_keymap == ORIG.buf_set_keymap,
          cmd = vim.api.nvim_create_user_command == ORIG.create_command,
          au = vim.api.nvim_create_autocmd == ORIG.create_autocmd,
          registered = vim.fn.maparg("\\fo", "n", false, true).callback == require("fxsurf").open,
          pre = vim.fn.maparg("\\pre", "n", false, true).callback == PRE,
          open_is_fn = type(require("fxsurf").open) == "function",
        }
      ]==]),
      {
        set = true,
        buf = true,
        cmd = true,
        au = true,
        registered = true,
        pre = true,
        open_is_fn = true,
      },
      "the primitives and the live keymaps are the originals again"
    )
    -- after the uninstall nothing counts any more, and everything still works
    c.lua("vim.api.nvim_exec_autocmds('BufWritePost', { pattern = 'y.fx' })")
    c.cmd("FxOpen")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>fo'), 'mx', false)")
    eq(
      c.lua("return require('fxsurf').calls.write"),
      2,
      "the (now inert) autocmd wrapper still calls the handler"
    )
    eq(
      c.lua("return T:collect().counts['command:FxOpen']"),
      1,
      "but nothing counts after the uninstall"
    )
    eq(c.lua("return T:uninstall()"), {}, "uninstall is idempotent")
    c.lua("T:begin_case({ id = 'late' })")
    eq(
      c.lua("return T:end_case()"),
      { hit = {}, counts = {} },
      "a case on an uninstalled layer records nothing"
    )

    -- ================================================================ transparency and the other primitives
    c.lua([==[
      vim.cmd("enew!")
      T = require("testing.surface.track").install({})
      LOG = {}
      -- expr mapping: the returned keys are what the mapping types
      vim.keymap.set("n", "<leader>ex", function() return "ihello<Esc>" end, { expr = true })
      -- direct nvim_set_keymap with a callback, and a buffer-local one
      vim.api.nvim_set_keymap("n", "<leader>raw", "", { callback = function(...) LOG[#LOG + 1] = select("#", ...) end })
      vim.api.nvim_buf_set_keymap(0, "n", "<leader>buf", "", { callback = function() LOG[#LOG + 1] = "buf" end })
      -- a string rhs and a string command are left alone
      vim.keymap.set("n", "<leader>str", ":let g:str_ran = 1<CR>")
      vim.api.nvim_create_user_command("StrCmd", "let g:strcmd_ran = 1", {})
      -- a command with arguments, a buffer-local command
      ARG = function(o) LOG[#LOG + 1] = o.args end
      BUFF = function() LOG[#LOG + 1] = "bufcmd" end
      vim.api.nvim_create_user_command("ArgCmd", ARG, { nargs = "*" })
      vim.api.nvim_buf_create_user_command(0, "BufCmd", BUFF, {})
      -- an autocmd whose callback returns true deletes itself (native behaviour)
      ONCE = 0
      vim.api.nvim_create_autocmd("User", { pattern = "Once", callback = function() ONCE = ONCE + 1; return true end })
      -- an autocmd with a vimscript command
      vim.api.nvim_create_autocmd("User", { pattern = "Cmd", command = "let g:cmd_ran = 1" })
      T:begin_case({ id = 'x::transparent' })
    ]==])
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>ex'), 'mx', false)")
    eq(
      c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
      { "hello" },
      "an expr mapping types what it returns"
    )
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>raw'), 'mx', false)")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>buf'), 'mx', false)")
    c.lua("vim.api.nvim_feedkeys(vim.keycode('<Bslash>str'), 'mx', false)")
    eq(c.g.str_ran, 1, "a string rhs keeps working")
    c.cmd("StrCmd")
    eq(c.g.strcmd_ran, 1, "a string command keeps working")
    c.cmd("ArgCmd one two")
    c.cmd("BufCmd")
    c.lua(
      "vim.api.nvim_exec_autocmds('User', { pattern = 'Once' }); vim.api.nvim_exec_autocmds('User', { pattern = 'Once' })"
    )
    eq(c.lua("return ONCE"), 1, "an autocmd callback that returns true still deletes itself")
    c.lua("vim.api.nvim_exec_autocmds('User', { pattern = 'Cmd' })")
    eq(c.g.cmd_ran, 1, "an autocmd with a command keeps working")
    eq(
      c.lua("return LOG"),
      { 0, "buf", "one two", "bufcmd" },
      "arguments reach the handlers (a callback gets none)"
    )
    local transparent = c.lua("return T:end_case()")
    eq(
      transparent.hit,
      {
        "autocmd:-:User:Once",
        "binding:<leader>buf",
        "binding:<leader>ex",
        "binding:<leader>raw",
        "command:ArgCmd",
        "command:BufCmd",
      },
      "every primitive is seen; a string rhs, a string command and a vimscript autocmd are not (and are not entries to miss)"
    )
    -- originals back, buffer-local ones too
    eq(c.lua("return T:uninstall()"), {}, "second uninstall")
    eq(
      c.lua([==[
        return {
          arg = vim.api.nvim_get_commands({}).ArgCmd.callback == ARG,
          buf = vim.api.nvim_buf_get_commands(0, {}).BufCmd.callback == BUFF,
        }
      ]==]),
      { arg = true, buf = true },
      "global and buffer-local commands are the original functions again"
    )
    c.cmd("ArgCmd after")
    eq(c.lua("return LOG[#LOG]"), "after", "and still work")

    -- ================================================================ a command that is restored is the ORIGINAL function
    c.lua([==[
      T = require("testing.surface.track").install({})
      PLAIN = function() PLAIN_RAN = (PLAIN_RAN or 0) + 1 end
      vim.api.nvim_create_user_command("PlainCmd", PLAIN, {})
    ]==])
    eq(
      c.lua("return vim.api.nvim_get_commands({}).PlainCmd.callback ~= PLAIN"),
      true,
      "wrapped while installed"
    )
    c.lua("T:uninstall()")
    eq(
      c.lua("return vim.api.nvim_get_commands({}).PlainCmd.callback == PLAIN"),
      true,
      "the original function is back"
    )
    c.cmd("PlainCmd")
    eq(c.lua("return PLAIN_RAN"), 1, "and runs")
  end)
end
