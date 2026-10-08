-- Every flag and positional argument of `:Testing` has a line in lib.nvim's option float.
--
-- The text comes from the `desc` of each FlagSpec in `testing.bindings.usrcmds`, and for the
-- positional arguments from the text of their type (`TESTING_MIGRATE`; `DIR` / `FILE` explain
-- themselves). A new flag or argument without one shows up as a bare row in the cheatsheet, so
-- this fails until it is described.
---@diagnostic disable: duplicate-set-field, param-type-mismatch, missing-parameter, undefined-field, missing-fields, need-check-nil

return function(H)
  local ok = H.ok
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local usrcmds = require("testing.bindings.usrcmds")

  ok(usrcmds.register(), ":Testing registers")
  ok(composer.registry().Testing ~= nil, ":Testing is registered through the composer")

  local missing = {}
  for _, m in ipairs(composer.help.undocumented("Testing")) do
    missing[#missing + 1] = ("%s %s"):format(m.route ~= "" and m.route or "(root)", m.name)
  end
  H.eq(
    #missing,
    0,
    "every :Testing option has a help text, missing: " .. table.concat(missing, ", ")
  )

  -- the positional arguments too (`migrate [mode] [root]`, `run [root]`, `file [spec]`, ...)
  local missing_args = {}
  for _, m in ipairs(composer.help.undocumented("Testing", { args = true })) do
    missing_args[#missing_args + 1] = ("%s %s %s"):format(m.kind, m.route, m.name)
  end
  H.eq(
    #missing_args,
    0,
    "every :Testing flag and argument has a help text, missing: "
      .. table.concat(missing_args, ", ")
  )
  local migrate_text =
    require("lib.nvim.bindings.usercmd.composer.argtypes").get(usrcmds.TYPE_MIGRATE).desc
  ok(type(migrate_text) == "string" and migrate_text ~= "", "TESTING_MIGRATE has a type text")
  ok(not migrate_text:find("[\r\n]"), "TESTING_MIGRATE: the text is one line")
  ok(not migrate_text:find("%.$"), "TESTING_MIGRATE: the text has no closing full stop")
  ok(#migrate_text <= 80, "TESTING_MIGRATE: the text is " .. #migrate_text .. " characters long")

  -- the float shows one line per option: no line break, no closing full stop, nothing absurdly long
  local seen = 0
  for _, route in ipairs(usrcmds.routes()) do
    for _, flag in ipairs(route.flags or {}) do
      local name = ("%s --%s"):format(table.concat(route.path, " "), flag.name)
      local desc = flag.desc
      ok(type(desc) == "string", name .. " has a desc of its own")
      ok(not desc:find("[\r\n]"), name .. ": the desc is one line")
      ok(not desc:find("%.$"), name .. ": the desc has no closing full stop")
      ok(#desc >= 20 and #desc <= 80, name .. ": the desc is " .. #desc .. " characters long")
      seen = seen + 1
    end
  end
  -- the check above must not pass for the wrong reason (a route table without flags)
  ok(seen >= 30, "the route tree carries the flags of all subcommands, saw " .. seen)

  -- `register()` made :Testing in this editor: leave it as found
  pcall(vim.api.nvim_del_user_command, "Testing")
end
