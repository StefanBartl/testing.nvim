-- TESTS/testing/surface_read_spec.lua -- the surface of a REAL plugin, read in a REAL child editor: the fixture
-- plugin (3 keymaps, 2 commands, 1 autocmd, health, api, config) in a temp directory. Ids, sources,
-- details, what is left out (other plugins, the composer verb itself), a setup() that fails, the kinds
-- filter, a child that cannot start.

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
  local surface = require("testing.surface")

  S.run(function()
    local root = S.fixture()
    local s, err = surface.collect(root, {
      plugin = "fxsurf",
      minit = root .. "/TESTS/minimal_init.lua",
    })
    ok(s, "the surface is read: " .. tostring(err))
    ---@cast s table
    eq(s.plugin, "fxsurf", "plugin")
    eq(s.version, 1, "version")
    local by = S.by_id(s)

    -- ---------------------------------------------------------------- bindings
    eq(
      S.ids(s, "binding"),
      { "binding:<leader>fo", "binding:<leader>fc@nx", "binding:<leader>ft" },
      "three keymaps: two registered actions (one in two modes) and a plain vim.keymap.set"
    )
    eq(by["binding:<leader>fo"].detail.action, "open", "the action name of a registered keymap")
    eq(by["binding:<leader>fo"].aliases, { "action:fxsurf.open" }, "and its stable alias")
    eq(by["binding:<leader>ft"].aliases, nil, "a plain keymap has none")
    eq(by["binding:<leader>fc@nx"].detail.modes, { "n", "x" }, "the modes of an action")
    eq(by["binding:<leader>fo"].desc, "fxsurf: open", "the description")
    eq(
      by["binding:<leader>ft"].detail.native,
      true,
      "a keymap the registry never saw is found natively"
    )
    eq(by["binding:<leader>ft"].desc, "fxsurf: toggle", "with its description")
    has(by["binding:<leader>fo"].src, "lua/fxsurf/init.lua:", "source file relative to the root")
    ok(by["binding:<leader>fo"].src:match(":%d+$"), "and a line")

    -- ---------------------------------------------------------------- commands
    eq(
      S.ids(s, "command"),
      { "command:Fx status", "command:FxOpen" },
      "two commands: the route of the composer verb and the plain one; the verb itself is no entry"
    )
    eq(by["command:Fx status"].detail.verb, "Fx", "the verb of a route")
    eq(by["command:Fx status"].desc, "show the status", "the description of a route")
    eq(by["command:FxOpen"].desc, "open the fixture", "the description of a command")
    has(by["command:FxOpen"].src, "lua/fxsurf/init.lua:", "a command's call site")

    -- ---------------------------------------------------------------- autocmds
    eq(
      S.ids(s, "autocmd"),
      { "autocmd:fxsurf:BufWritePost:*.fx" },
      "the autocmd: group, event, pattern"
    )
    eq(by["autocmd:fxsurf:BufWritePost:*.fx"].detail.group, "fxsurf", "its group")
    eq(by["autocmd:fxsurf:BufWritePost:*.fx"].desc, "count writes", "its description")

    -- ---------------------------------------------------------------- the rest
    eq(S.ids(s, "health"), { "health:fxsurf" }, "health.lua exists")
    eq(S.ids(s, "api"), {
      "api:fxsurf.close",
      "api:fxsurf.on_write",
      "api:fxsurf.open",
      "api:fxsurf.setup",
      "api:fxsurf.status",
      "api:fxsurf.toggle",
    }, "the functions of the module (the `calls` table is no entry)")
    eq(
      S.ids(s, "config"),
      { "config:keymaps", "config:limits.max", "config:limits.names", "config:notify" },
      "the keys of the typed DEFAULTS, nested tables flattened"
    )
    eq(by["config:notify"].detail.type, "boolean", "a config key's type")
    eq(by["config:limits.names"].detail.type, "list", "a list")
    eq(by["config:keymaps"].detail.type, "table", "an empty table is a leaf")
    eq(
      s.counts,
      { binding = 3, command = 2, autocmd = 1, health = 1, api = 6, config = 4 },
      "counts"
    )

    -- nothing of the other plugins in the child (testing.nvim's own :Testing command is there)
    for _, id in ipairs(S.ids(s)) do
      ok(not id:find("Testing", 1, true), "no entry of another plugin: " .. id)
    end

    -- the kinds filter
    local only, oerr = surface.collect(root, {
      plugin = "fxsurf",
      minit = root .. "/TESTS/minimal_init.lua",
      kinds = { "command", "autocmd" },
    })
    ok(only, "kinds: " .. tostring(oerr))
    eq(only.counts, { command = 2, autocmd = 1 }, "only the asked kinds are read")

    -- a setup() that raises does not fail the read; what was registered before stays
    local broken = surface.collect(root, {
      plugin = "fxsurf",
      minit = root .. "/TESTS/minimal_init.lua",
      setup = { keymaps = 42 },
    })
    ok(broken, "a setup that fails still gives a surface")
    local noted = false
    for _, n in ipairs(broken.notes) do
      if n:find("setup() raised", 1, true) then
        noted = true
      end
    end
    ok(noted, "the failure is a note: " .. vim.inspect(broken.notes))

    -- a registered action is filed under the name the plugin chose (not the plugin's own); what appears
    -- while the plugin is set up is its own. A string rhs is listed, but nothing can observe it.
    local weird = surface.collect(root, {
      plugin = "fxsurf",
      minit = root .. "/TESTS/minimal_init.lua",
      setup_chunk = [[require("lib.nvim.bindings.keymap").register("Weird Name", {
        actions = { go = { default = "<leader>g", rhs = "<cmd>echo 1<cr>", desc = "go" } },
      }, nil)]],
    })
    ok(weird, "a setup chunk that registers a keymap")
    eq(
      S.ids(weird, "binding"),
      { "binding:<leader>g" },
      "the action of a plugin that filed it under another name"
    )
    local go = S.by_id(weird)["binding:<leader>g"]
    eq(go.aliases, { "action:Weird Name.go" }, "its stable identity is the action name")
    eq(go.detail.untrackable, true, "a string rhs cannot be observed")
    eq(go.detail.action, "go", "the action")
    eq(weird.counts.command, nil, "(no commands: the setup chunk replaced setup())")

    -- an own setup chunk replaces setup(): here it registers nothing and then raises
    local bad_chunk = surface.collect(root, {
      plugin = "fxsurf",
      minit = root .. "/TESTS/minimal_init.lua",
      setup_chunk = "vim.g.surface_probe = 1; error('boom')",
    })
    ok(bad_chunk, "a chunk that raises")
    eq(bad_chunk.counts.binding, nil, "nothing was set up: no bindings")
    eq(bad_chunk.counts.api, 6, "but the module still has its api")
    ok(table.concat(bad_chunk.notes, "\n"):find("boom", 1, true), "is a note too")
  end)

  -- ------------------------------------------------------------------ a child that cannot start
  local s2, err2 = surface.collect("/nonexistent/x", {
    plugin = "fxsurf",
    spawn = function()
      return nil, "no nvim"
    end,
  })
  eq(s2, nil, "no child, no surface")
  has(err2, "no nvim", "the reason is passed on")
  local s3, err3 = surface.collect("/nonexistent/x", {
    plugin = "fxsurf",
    spawn = function()
      return {
        lua = function()
          error("RPC call timed out")
        end,
        kill = function() end,
      }
    end,
  })
  eq(s3, nil, "a child that fails the read")
  has(err3, "RPC call timed out", "says why")
end
