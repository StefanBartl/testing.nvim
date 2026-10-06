---@diagnostic disable: undefined-field, need-check-nil, redundant-parameter, duplicate-set-field
-- TESTS/testing/state_runtime_spec.lua -- what the state guard and the soft isolation see and do NOT touch of the editor's own
-- machinery, found while running a fleet suite in a warm pool: `package.preload` is state (a spec that
-- stubs a module and "restores" it from a table that skips nil values leaves a stub behind), the
-- runtime's own `nvim.*` autocmd groups and the groupless `once` hook on `SafeState` are not a spec's
-- (deleting a group breaks the runtime module that cached its id), and a session can be told to leave
-- buffers, windows and tabs to someone who puts them back and checks.

return function(H)
  local ok, eq = H.ok, H.eq
  local guard = require("testing.guard")
  local snapshot = require("testing.isolation.snapshot")
  local isolation = require("testing.isolation")
  local config = require("testing.guard.config")

  ---@param entries table[]
  ---@param kind string
  ---@return table[]
  local function of_kind(entries, kind)
    local out = {}
    for _, e in ipairs(entries) do
      if e.kind == kind then
        out[#out + 1] = e
      end
    end
    return out
  end

  local function only_state(categories)
    local g = {}
    for _, n in ipairs(config.ORDER) do
      g[n] = "off"
    end
    g.state = { mode = "error", categories = categories }
    return { guards = g }
  end

  -- ===================================================================
  -- package.preload in the soft backend: added, replaced and removed entries are named and undone
  do
    local kept = function()
      return "kept"
    end
    package.preload["zz_state_kept"] = kept
    local before = snapshot.capture()
    package.preload["zz_state_added"] = function() end
    package.preload["zz_state_kept"] = function()
      return "replaced"
    end
    local after = snapshot.capture()
    local entries = of_kind(snapshot.diff(before, after, {}), "preload")
    eq(#entries, 2, "preload: one added, one replaced")
    local text = {}
    for _, e in ipairs(entries) do
      text[#text + 1] = e.change .. ":" .. e.name
    end
    table.sort(text)
    eq(
      text[1]:find("added:package.preload entry `zz_state_added`", 1, true) ~= nil,
      true,
      "the added stub is named"
    )
    eq(
      text[2]:find("changed:package.preload entry `zz_state_kept` was replaced", 1, true) ~= nil,
      true,
      "the replaced stub is named"
    )
    eq(next(snapshot.restore(entries)), nil, "preload: the restore reports no failure")
    eq(package.preload["zz_state_added"], nil, "preload: the added stub is gone")
    eq(package.preload["zz_state_kept"], kept, "preload: the replaced stub is back")
    package.preload["zz_state_kept"] = nil
    -- removed
    package.preload["zz_state_gone"] = kept
    local b2 = snapshot.capture()
    package.preload["zz_state_gone"] = nil
    local removed = of_kind(snapshot.diff(b2, snapshot.capture(), {}), "preload")
    eq(#removed, 1, "preload: a removed entry is a difference")
    snapshot.restore(removed)
    eq(package.preload["zz_state_gone"], kept, "preload: a removed entry is put back")
    package.preload["zz_state_gone"] = nil
  end

  -- ===================================================================
  -- ... and in the state guard: a named finding (category `preload`, warn by default)
  do
    eq(config.DEFAULTS.guards.state.categories.preload, "warn", "preload: a warning by default")
    local h = guard.install(only_state({ preload = "error" }))
    h:begin_case({ id = "s::preload", file = "s.lua" })
    package.preload["zz_guard_stub"] = function() end
    local res = h:end_case()
    package.preload["zz_guard_stub"] = nil
    local found
    for _, f in ipairs(res.findings) do
      if f.id == "state.preload" then
        found = f
      end
    end
    ok(found ~= nil, "the state guard names the stub left in package.preload")
    ok(
      found.message:find('package.preload["zz_guard_stub"]', 1, true) ~= nil,
      "...and which one: " .. tostring(found and found.message)
    )
    eq(found.severity, "error", "the category mode decides the severity")
    h:uninstall()

    -- nothing left behind: no finding
    h = guard.install(only_state({ preload = "error" }))
    h:begin_case({ id = "s::clean", file = "s.lua" })
    package.preload["zz_guard_stub"] = function() end
    package.preload["zz_guard_stub"] = nil
    local clean = h:end_case()
    for _, f in ipairs(clean.findings) do
      ok(f.id ~= "state.preload", "a stub that was removed again is no finding")
    end
    h:uninstall()
  end

  -- ===================================================================
  -- the editor's own groups and idle hook are not the spec's
  do
    local group = vim.api.nvim_create_augroup("nvim.zz_runtime_group", { clear = true })
    local before = snapshot.capture()
    vim.api.nvim_create_autocmd("BufEnter", { group = group, callback = function() end })
    vim.api.nvim_create_autocmd("SafeState", { once = true, callback = function() end })
    local plain = vim.api.nvim_create_augroup("zz_spec_group", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = plain, callback = function() end })
    local entries = of_kind(snapshot.diff(before, snapshot.capture(), {}), "autocmd")
    eq(#entries, 1, "soft backend: only the spec's own autocmd is a difference")
    ok(
      entries[1].name:find("zz_spec_group", 1, true) ~= nil,
      "...and it is the one of the spec's group"
    )
    snapshot.restore(entries)
    ok(
      #vim.api.nvim_get_autocmds({ group = "nvim.zz_runtime_group" }) == 1,
      "the runtime's group is not deleted"
    )

    local h = guard.install(only_state({ autocmds = "error" }))
    h:begin_case({ id = "s::groups", file = "s.lua" })
    local g2 = vim.api.nvim_create_augroup("nvim.zz_runtime_group2", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = g2, callback = function() end })
    vim.api.nvim_create_autocmd("SafeState", { once = true, callback = function() end })
    local res = h:end_case()
    for _, f in ipairs(res.findings) do
      ok(
        f.id ~= "state.autocmd",
        "state guard: no autocmd finding for the runtime's group or its SafeState hook: "
          .. f.message
      )
    end
    h:uninstall()
    pcall(vim.api.nvim_del_augroup_by_name, "nvim.zz_runtime_group2")
    pcall(vim.api.nvim_del_augroup_by_name, "nvim.zz_runtime_group")
    pcall(vim.api.nvim_del_augroup_by_name, "zz_spec_group") -- the soft restore already removed it
  end

  -- ===================================================================
  -- the editor's own provider flags are not state, and a session can be told to unload `lib.*` too
  do
    local before = snapshot.capture()
    vim.g.loaded_clipboard_provider = vim.g.loaded_clipboard_provider or 2
    vim.g.loaded_zz_provider = 1 -- matches `loaded_<name>_provider`: the editor's own flag
    vim.g.loaded_zz_plugin = 1
    local entries = of_kind(snapshot.diff(before, snapshot.capture(), {}), "vim.g")
    local names = {}
    for _, e in ipairs(entries) do
      names[#names + 1] = e.name
    end
    eq(
      names,
      { "global variable g:loaded_zz_plugin" },
      "provider flags: only the other flag is a difference"
    )
    vim.g.loaded_zz_plugin = nil
    vim.g.loaded_zz_provider = nil

    package.loaded["lib.zz_state_mod"] = {}
    local b2 = snapshot.capture()
    package.loaded["lib.zz_state_mod2"] = {}
    local kept = of_kind(snapshot.diff(b2, snapshot.capture(), {}), "package")
    eq(#kept, 0, "by default a lib module stays loaded (the runner's own editor)")
    local unloaded = of_kind(
      snapshot.diff(b2, snapshot.capture(), { keep_prefixes = { "vim", "testing" } }),
      "package"
    )
    eq(#unloaded, 1, "with keep_prefixes that leave lib out it is a difference")
    snapshot.restore(unloaded)
    eq(package.loaded["lib.zz_state_mod2"], nil, "...and is unloaded by the restore")
    package.loaded["lib.zz_state_mod"] = nil
  end

  -- ===================================================================
  -- the structure check of the pool names what a reset left (two windows, two tabs, ...)
  do
    local boot = require("testing.child.pool_boot")
    local bufs_before = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      bufs_before[b] = true
    end
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local problems = table.concat(boot.structure(), "; ")
    vim.cmd("only")
    vim.cmd("tabclose")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not bufs_before[b] then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    ok(
      problems:find("2 tab pages are open", 1, true) ~= nil,
      "structure: two tabs are named: " .. problems
    )
    ok(
      problems:find("windows are open", 1, true) ~= nil,
      "structure: the windows are named: " .. problems
    )
    ok(
      problems:find("buffers exist", 1, true) ~= nil,
      "structure: more than one buffer is named: " .. problems
    )
  end

  -- ===================================================================
  -- a session can leave buffers, windows and tabs to someone else
  do
    local function run(skip)
      local s = isolation.new({ severity = "warn", skip_kinds = skip })
      local frame = s:enter("zz.lua")
      local buf = vim.api.nvim_create_buf(true, false)
      local rep = s:leave(frame)
      local still = vim.api.nvim_buf_is_valid(buf)
      if still then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      return rep, still
    end
    local rep, still = run(nil)
    ok(not still, "without skip_kinds the new buffer is restored (deleted)")
    ok(#rep.items >= 1, "...and named")
    rep, still = run({ "buffer" })
    ok(still, "with skip_kinds = { 'buffer' } the buffer is left alone")
    eq(#rep.items, 0, "...and is not reported either")
  end
end
