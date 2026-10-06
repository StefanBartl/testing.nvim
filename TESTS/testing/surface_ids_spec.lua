-- TESTS/testing/surface_ids_spec.lua -- the stable ids of surface entries (`kind:name`): bindings with a
-- mode suffix, composer routes, autocmds with a number for equal bases, spellings of one key.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local ids = require("testing.surface.ids")

  -- ------------------------------------------------------------------ bindings
  eq(ids.binding("<leader>ss", "n"), "binding:<leader>ss", "normal mode has no suffix")
  eq(ids.binding("<leader>ss"), "binding:<leader>ss", "the default mode is normal")
  eq(ids.binding("<leader>ss", { "n" }), "binding:<leader>ss", "a list with only n has none either")
  eq(ids.binding("gx", "x"), "binding:gx@x", "another mode is a suffix")
  eq(ids.binding("gx", { "x", "n" }), "binding:gx@nx", "modes are sorted")
  eq(ids.binding("gx", { "n", "x", "n" }), "binding:gx@nx", "and de-duplicated")
  eq(ids.binding("gx", "nv"), "binding:gx@nv", "the letters of an nvim_set_keymap mode string")
  eq(ids.mode_list(""), { "n", "o", "v" }, "an empty mode string means n, v and o")

  local lhs, modes = ids.parse_binding("binding:<leader>ss")
  eq({ lhs, modes }, { "<leader>ss", { "n" } }, "parse: no suffix is normal mode")
  lhs, modes = ids.parse_binding("binding:gx@nx")
  eq({ lhs, modes }, { "gx", { "n", "x" } }, "parse: suffix")
  lhs, modes = ids.parse_binding("binding:@q")
  eq({ lhs, modes }, { "@q", { "n" } }, "parse: an @ that starts the lhs is not a suffix")
  eq({ ids.parse_binding("command:Foo") }, { nil }, "parse: other kinds are not bindings")

  -- ------------------------------------------------------------------ commands
  eq(ids.command("FxOpen"), "command:FxOpen", "a plain command")
  eq(ids.route("Session", { "save" }), "command:Session save", "a composer route")
  eq(ids.route("Session", { "a", "b" }), "command:Session a b", "a nested route")
  eq(ids.route("Session", {}), "command:Session", "the verb itself (default or root route)")
  eq(ids.route("Session"), "command:Session", "no path is the verb")

  -- ------------------------------------------------------------------ others
  eq(ids.api("fxsurf", "open"), "api:fxsurf.open", "api")
  eq(ids.config("limits.max"), "config:limits.max", "config")
  eq(ids.health("fxsurf"), "health:fxsurf", "health")
  eq(ids.kind_of("binding:gx"), "binding", "kind_of")
  eq(ids.kind_of("nonsense"), nil, "kind_of without a colon")
  eq(ids.TRACKABLE.binding, true, "bindings can be observed")
  eq(ids.TRACKABLE.config, nil, "config keys cannot")
  eq(ids.COVERAGE_KINDS, { "binding", "command", "autocmd" }, "the kinds of the ratio")

  -- ------------------------------------------------------------------ autocmds
  eq(
    ids.autocmd_base("grp", { "BufEnter", "WinEnter" }, "*.lua", nil),
    "autocmd:grp:BufEnter,WinEnter:*.lua",
    "group, events, pattern"
  )
  eq(ids.autocmd_base(nil, "FileType", nil, nil), "autocmd:-:FileType", "no group is a dash")
  eq(ids.autocmd_base("g", { "BufEnter" }, nil, 3), "autocmd:g:BufEnter:buf", "buffer-local")
  eq(
    ids.autocmd_base("g", { "BufEnter" }, { "*.a", "*.b" }, nil),
    "autocmd:g:BufEnter:*.a,*.b",
    "a pattern list"
  )
  eq(
    ids.autocmd_ids({
      { group = "g", events = { "BufEnter" } },
      { group = "g", events = { "BufEnter" } },
      { group = "g", events = { "BufLeave" } },
      { group = "g", events = { "BufEnter" } },
    }),
    { "autocmd:g:BufEnter", "autocmd:g:BufEnter#2", "autocmd:g:BufLeave", "autocmd:g:BufEnter#3" },
    "equal bases are numbered in creation order"
  )

  -- ------------------------------------------------------------------ spellings of one key
  eq(ids.norm_lhs("<C-X>"), ids.norm_lhs("<c-x>"), "key notation is case-insensitive")
  eq(ids.norm_lhs("<Space>a"), " a", "<Space> is a space")
  ok(ids.norm_lhs("<leader>a") ~= ids.norm_lhs("<leader>b"), "different keys stay different")
end
