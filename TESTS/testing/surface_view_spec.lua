-- TESTS/testing/surface_view_spec.lua -- the matrix view of `:Testing surface --matrix` (testing.surface.view): the
-- child's JSON carries the cells of `render.matrix_rows` (the view computes nothing), the status and kind filters,
-- `<CR>` on a row to the entry's source and on a file column to the spec file, the export of the filtered rows,
-- the keys from `surface_view.keys` (legend, `?` cheatsheet and keymaps from one list) and the route that asks
-- the child for JSON. The child editor is a seam (see surface_main_spec).

---@diagnostic disable: need-check-nil, undefined-field, param-type-mismatch, missing-fields, duplicate-set-field

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local surface = require("testing.surface")
  local render = require("testing.surface.render")
  local view = require("testing.surface.view")
  local config = require("testing.config")
  local kit = require("lib.nvim.ui.kit")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp .. "/lua/fx", "p")
  local function write(name, content)
    local path = tmp .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
  end
  local src_lines = {}
  for i = 1, 60 do
    src_lines[i] = ("-- line %d"):format(i)
  end
  write("lua/fx/init.lua", table.concat(src_lines, "\n") .. "\n")
  write("a_spec.lua", "return function() end\n")
  write("b_spec.lua", "return function() end\n")

  local function entry(id, kind, src)
    return { id = id, kind = kind, name = (id:gsub("^%a+:", "")), src = src }
  end
  local fixed = {
    version = 1,
    plugin = "fx",
    root = tmp,
    notes = {},
    counts = { binding = 1, command = 2, autocmd = 1 },
    entries = {
      entry("binding:<leader>a", "binding", "lua/fx/init.lua:10"),
      entry("command:Open", "command", "lua/fx/init.lua:30"),
      entry("command:Fx status", "command", "module fx.status"),
      entry("autocmd:g:BufEnter", "autocmd", nil),
    },
  }
  fixed.entries[1].detail = { lhs = "<leader>a", modes = { "n" } }
  local services = {
    cwd = tmp,
    config = { plugin = "fx", coverage = { bindings = 0, commands = 0 }, deps = {} },
    collect = function()
      return vim.deepcopy(fixed)
    end,
  }
  local ir = {
    cases = {
      {
        id = "a_spec.lua::x",
        file = "a_spec.lua",
        status = "pass",
        tags = { "command:Fx status" },
        surface = { hit = { "binding:<leader>a" } },
      },
      {
        id = "b_spec.lua::y",
        file = "b_spec.lua",
        status = "pass",
        surface = { hit = { "binding:<leader>a", "autocmd:g:BufEnter" } },
      },
    },
  }
  local ir_path = write("run.json", vim.json.encode(ir))

  -- ------------------------------------------------------------------ the data: the cells of --csv, in the JSON
  local code, csv = surface.main({ "--from", ir_path, "--matrix", "--csv" }, services)
  eq(code, 0, "csv: a report")
  local _, json = surface.main({ "--from", ir_path, "--matrix", "--json" }, services)
  local doc = vim.json.decode(json)
  ok(type(doc.table) == "table", "json --matrix: a table section")
  eq(
    render.tsv(doc.table.header, doc.table.rows),
    csv,
    "json table: the same cells as --matrix --csv"
  )
  eq(doc.table.files, { "a_spec.lua", "b_spec.lua" }, "json table: the spec files of the columns")
  eq(
    doc.table.src,
    { "lua/fx/init.lua:10", "lua/fx/init.lua:30", "module fx.status", "" },
    "json table: the source of each row, empty when there is none"
  )
  local _, json_list = surface.main({ "--from", ir_path, "--json" }, services)
  eq(vim.json.decode(json_list).table, nil, "json without --matrix: no table")

  -- ------------------------------------------------------------------ parse
  local model, perr = view.parse("noise\n" .. json)
  ok(model ~= nil, "parse: the JSON line of the output (" .. tostring(perr) .. ")")
  eq(model.plugin, "fx", "parse: the plugin")
  eq(#model.rows, 4, "parse: every row")
  local _, no_run = surface.main({ "--matrix", "--json" }, services)
  local none, why = view.parse(no_run)
  eq(none, nil, "parse: no tracked run, no model")
  H.has(why, "--matrix needs a tracked run", "parse: the notes say why")
  local bad = vim.json.decode(json)
  bad.table.rows[1] = { "x" }
  eq(view.parse(vim.json.encode(bad)), nil, "parse: a row of the wrong width is refused")
  bad = vim.json.decode(json)
  bad.table.src = {}
  eq(view.parse(vim.json.encode(bad)), nil, "parse: a src list of the wrong length is refused")
  eq(view.parse("not json"), nil, "parse: no JSON")
  eq(view.parse(nil), nil, "parse: nothing")
  local _, ignored_json =
    surface.main({ "--from", ir_path, "--matrix", "--json", "--ignore", "^autocmd:" }, services)
  local ignored_model = assert(view.parse(ignored_json))
  local ignored_rows = view.filter(ignored_model, { status = "ignored" })
  eq(#ignored_rows, 1, "filter ignored: the entry left out by --ignore")
  eq(ignored_model.rows[ignored_rows[1]][3], "autocmd:g:BufEnter", "filter ignored: that one")

  -- ------------------------------------------------------------------ filters
  local function ids_of(shown)
    local out = {}
    for _, i in ipairs(shown) do
      out[#out + 1] = model.rows[i][3]
    end
    return out
  end
  eq(#view.filter(model, {}), 4, "filter: none keeps every row")
  eq(
    ids_of(view.filter(model, { status = "hit" })),
    { "binding:<leader>a", "command:Fx status", "autocmd:g:BufEnter" },
    "filter hit: a `hit (tag)` row is a hit"
  )
  eq(ids_of(view.filter(model, { status = "missing" })), { "command:Open" }, "filter missing")
  eq(ids_of(view.filter(model, { status = "untracked" })), {}, "filter untracked: none here")
  eq(
    ids_of(view.filter(model, { kind = "command" })),
    { "command:Open", "command:Fx status" },
    "filter kind"
  )
  eq(
    ids_of(view.filter(model, { kind = "command", status = "hit" })),
    { "command:Fx status" },
    "filter: both at once"
  )

  -- ------------------------------------------------------------------ lines, cells, targets
  local all = view.filter(model, {})
  local lines, spans = view.lines(model, all)
  eq(#lines, 5, "lines: the header and one line per row")
  ok(
    lines[1]:find("^KIND%s+STATUS%s+ID%s+a_spec%.lua%s+b_spec%.lua%s+TOTAL$") ~= nil,
    "lines: header"
  )
  local a_col = lines[1]:find("a_spec.lua", 1, true) - 1
  eq(view.cell_at(spans[2], a_col), 4, "cell_at: the first spec file column")
  eq(view.cell_at(spans[2], 0), 1, "cell_at: the kind column")
  eq(view.cell_at(spans[2], a_col - 1), 3, "cell_at: the gap belongs to the left cell")
  eq(view.cell_at({}, 3), nil, "cell_at: an empty line has no cell")
  local empty_lines = view.lines(model, {})
  eq(empty_lines[2], "(no entry matches the filter)", "lines: an empty filter says so")

  local t = view.target(model, 2, 1, tmp)
  eq(t, { path = tmp .. "/lua/fx/init.lua", line = 30 }, "target: a row goes to its source")
  t = view.target(model, 2, 5, tmp)
  eq(t, { path = tmp .. "/b_spec.lua", line = 1 }, "target: a file column goes to the spec file")
  local none_t, terr = view.target(model, 3, 1, tmp)
  eq(none_t, nil, "target: a module is no file")
  H.has(terr, "module fx.status", "target: and says what it is")
  eq(view.target(model, 4, 2, tmp), nil, "target: an entry without a source")
  eq(
    view.target(model, 4, 4, tmp),
    { path = tmp .. "/a_spec.lua", line = 1 },
    "target: the file column works on a row without a source"
  )

  eq(
    view.export_text(model, view.filter(model, { status = "missing" })),
    render.tsv(model.header, { model.rows[2] }),
    "export: the filtered rows, tab separated, with the header"
  )

  -- ------------------------------------------------------------------ the view in a window
  local orig_win, first_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  -- a jump `:edit`s in the window below the view; an empty unnamed buffer there would be reused (renamed) by it
  local orig_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, { "below the view" })
  vim.api.nvim_set_current_buf(orig_buf)
  local real_notify = vim.notify
  local said = {}
  vim.notify = function(msg)
    said[#said + 1] = tostring(msg)
  end
  local real_hook = kit.get_dialog_hook()
  local opened = {}
  local passed, err = pcall(function()
    local function key(buf, lhs)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == lhs then
          return m
        end
      end
      return nil
    end
    local handle = assert(view.open(model, { root = tmp }))
    opened[#opened + 1] = handle
    local buf, win = handle.surface.bufnr, handle.surface.winid
    for _, lhs in ipairs({ "<CR>", "s", "t", "e", "?" }) do
      local m = key(buf, lhs)
      ok(
        m ~= nil and type(m.desc) == "string" and m.desc ~= "",
        "view: " .. lhs .. " is bound with a desc"
      )
    end
    local legend = vim.api.nvim_get_option_value("winbar", { win = win })
    for _, word in ipairs({ "jump", "status", "kind", "export" }) do
      ok(legend:find(word, 1, true) ~= nil, "view: the legend names " .. word)
    end
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines, "view: the lines of the model")

    key(buf, "s").callback()
    eq(handle.filter.status, "hit", "s: the status filter moves to hit")
    eq(#vim.api.nvim_buf_get_lines(buf, 0, -1, false), 4, "s: three rows and the header")
    key(buf, "s").callback()
    eq(handle.filter.status, "missing", "s: then missing")
    local round = {}
    for _ = 1, 5 do
      key(buf, "s").callback()
      round[#round + 1] = handle.filter.status or "all"
    end
    eq(round, { "untracked", "ignored", "all", "hit", "missing" }, "s: the whole round")
    key(buf, "t").callback()
    eq(handle.filter.kind, "binding", "t: the kind filter moves to binding")
    eq(
      vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1],
      "(no entry matches the filter)",
      "t: a missing binding there is not"
    )
    key(buf, "t").callback()
    eq(handle.filter.kind, "command", "t: then command")
    eq(handle.shown(), { 2 }, "the shown rows follow the filters")

    -- export: the kit's input asks for the path (answered by its dialog hook)
    local out = tmp .. "/out.tsv"
    local asked
    kit.set_dialog_hook(function(kind, o)
      if kind == "input" then
        asked = o.default
        return true, out
      end
      return false
    end)
    key(buf, "e").callback()
    vim.wait(2000, function()
      return vim.uv.fs_stat(out) ~= nil
    end)
    kit.set_dialog_hook(real_hook)
    eq(asked, tmp .. "/surface-matrix.csv", "e: the default path is in the root")
    local f = assert(io.open(out, "rb"))
    local exported = f:read("*a")
    f:close()
    eq(exported, render.tsv(model.header, { model.rows[2] }), "e: the shown rows are written")

    -- <CR> on the row: the source of its entry, at its line
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    key(buf, "<CR>").callback()
    ok(not vim.api.nvim_win_is_valid(win), "<CR>: the view closes")
    eq(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
      tmp .. "/lua/fx/init.lua",
      "<CR>: the source file is open"
    )
    eq(vim.api.nvim_win_get_cursor(0)[1], 30, "<CR>: at the line of the entry")
    local edited = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(orig_buf)
    vim.api.nvim_buf_delete(edited, { force = true })

    -- <CR> on a spec file column: the spec file
    handle = assert(view.open(model, { root = tmp }))
    opened[#opened + 1] = handle
    buf, win = handle.surface.bufnr, handle.surface.winid
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    vim.api.nvim_win_set_cursor(win, { 2, line:find("b_spec.lua", 1, true) - 1 })
    key(buf, "<CR>").callback()
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), tmp .. "/b_spec.lua", "<CR>: the spec file")
    edited = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(orig_buf)
    vim.api.nvim_buf_delete(edited, { force = true })

    -- <CR> on a row whose source is a module: a warning, the view stays
    handle = assert(view.open(model, { root = tmp }))
    opened[#opened + 1] = handle
    buf, win = handle.surface.bufnr, handle.surface.winid
    vim.api.nvim_win_set_cursor(win, { 4, 0 })
    said = {}
    key(buf, "<CR>").callback()
    ok(vim.api.nvim_win_is_valid(win), "<CR> on a module: the view stays")
    H.has(table.concat(said, "\n"), "module fx.status", "<CR> on a module: says why")
    handle.surface:close()

    -- the keys come from `surface_view.keys`: a dropped one is not bound and not in the legend
    eq(
      config.setup({ surface_view = { keys = { export = false, status = "S" } } }),
      {},
      "config: keys are moved and dropped"
    )
    handle = assert(view.open(model, { root = tmp }))
    opened[#opened + 1] = handle
    buf, win = handle.surface.bufnr, handle.surface.winid
    eq(key(buf, "e"), nil, "export = false: no e")
    ok(key(buf, "S") ~= nil and key(buf, "s") == nil, "status = S: S instead of s")
    ok(key(buf, "<CR>") ~= nil, "a key that was not named keeps its default")
    legend = vim.api.nvim_get_option_value("winbar", { win = win })
    ok(legend:find("export", 1, true) == nil, "export = false: not in the legend either")
    handle.surface:close()
  end)
  for _, h in ipairs(opened) do
    pcall(function()
      h.surface:close()
    end)
  end
  config.reset()
  kit.set_dialog_hook(real_hook)
  vim.notify = real_notify
  if vim.api.nvim_win_is_valid(orig_win) then
    vim.api.nvim_set_current_win(orig_win)
    if vim.api.nvim_buf_is_valid(first_buf) then
      vim.api.nvim_win_set_buf(orig_win, first_buf)
    end
  end
  if vim.api.nvim_buf_is_valid(orig_buf) then
    vim.api.nvim_buf_delete(orig_buf, { force = true })
  end
  if not passed then
    vim.fn.delete(tmp, "rf")
    error(err, 0)
  end

  -- ------------------------------------------------------------------ config: wrong keys are refused
  local problems = config.setup({ surface_view = { keys = { nope = "x" } } })
  eq(#problems, 1, "config: an unknown action is refused")
  problems = config.setup({ surface_view = { keys = { jump = "" } } })
  eq(#problems, 1, "config: an empty lhs is refused")
  problems = config.setup({ surface_view = { keys = { jump = 1 } } })
  eq(#problems, 1, "config: a number is refused")
  problems = config.setup({ surface_view = { other = true } })
  eq(#problems, 1, "config: an unknown key of surface_view is refused")
  config.reset()
  eq(
    config.get().surface_view.keys,
    { jump = "<CR>", status = "s", kind = "t", export = "e" },
    "config: the defaults"
  )

  -- ------------------------------------------------------------------ the route asks the child for JSON
  local usrcmds = require("testing.bindings.usrcmds")
  local child = require("testing.bindings.child")
  ok(usrcmds.register(), ":Testing registers")
  local real_start = child.start
  local started
  child.start = function(sub, opts, on_done)
    started = { sub = sub, opts = opts, on_done = on_done }
    return true
  end
  vim.notify = function() end
  passed, err = pcall(function()
    vim.cmd("Testing surface --matrix")
    eq(started.opts.flags.raw, { "--matrix", "--json" }, "--matrix alone: the child prints JSON")
    ok(type(started.on_done) == "function", "--matrix alone: the view takes the verdict")
    vim.cmd("Testing surface --matrix --csv")
    eq(started.opts.flags.raw, { "--matrix", "--csv" }, "--matrix --csv: text as before")
    eq(started.on_done, nil, "--matrix --csv: the output viewer as before")
    vim.cmd("Testing surface --matrix --markdown")
    eq(started.on_done, nil, "--matrix --markdown: the output viewer as before")
    -- the verdict without a table (no tracked run): no view, the reason
    said = {}
    vim.notify = function(msg)
      said[#said + 1] = tostring(msg)
    end
    local shown = view.show_verdict({
      level = "error",
      message = "testing surface failed (exit 2)",
      items = {},
      lines = { no_run },
    }, tmp)
    eq(shown, nil, "show_verdict: no table, no view")
    H.has(table.concat(said, "\n"), "--matrix needs a tracked run", "show_verdict: the reason")
    local h = view.show_verdict(
      { level = "info", message = "testing surface done", items = {}, lines = { json } },
      tmp
    )
    ok(h ~= nil, "show_verdict: a table opens the view")
    h.surface:close()
  end)
  child.start, vim.notify = real_start, real_notify
  vim.fn.delete(tmp, "rf")
  if not passed then
    error(err, 0)
  end
end
