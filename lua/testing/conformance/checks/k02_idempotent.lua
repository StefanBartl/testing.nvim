---@module 'testing.conformance.checks.k02_idempotent'
---@brief K2: `setup()` twice is idempotent (LUA-96).
---@description
--- A `setup()` runs again with every config reload. The child calls it twice with the options of
--- `.testing.lua` and compares what exists after each call: keymaps (as the editor lists them),
--- user commands, autocommands (a multiset: a handler that stacks appears twice) and what the lib.nvim
--- registries hold (keymaps, user commands, autocommands, composer verbs). The difference must be empty.
--- More after the second call is an error (handlers stack); fewer is a warning (something is removed
--- and re-created: a window in which the feature is off).

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K2",
  title = "setup() twice is idempotent",
  rules = { "LUA-96" },
  kind = "runtime",
  level = "error",
}

---@param sig string
---@return string
local function pretty(sig)
  return (sig:gsub("\1", " | "))
end

---@param findings Testing.Conformance.Finding[]
---@param kind string
---@param before string[]|nil
---@param after string[]|nil
---@param level? Testing.Conformance.Level Level of an ADDED entry (default `error`).
local function compare(findings, kind, before, after, level)
  local added, removed = util.multiset_diff(before or {}, after or {})
  if #added > 0 then
    local sample = {}
    for i = 1, math.min(#added, 3) do
      sample[#sample + 1] = pretty(added[i])
    end
    findings[#findings + 1] = util.finding(
      "K2",
      "LUA-96",
      level or "error",
      ("the second setup() added %d %s: %s%s"):format(
        #added,
        kind,
        table.concat(sample, "; "),
        #added > 3 and "; ..." or ""
      )
    )
  end
  if #removed > 0 then
    local sample = {}
    for i = 1, math.min(#removed, 3) do
      sample[#sample + 1] = pretty(removed[i])
    end
    findings[#findings + 1] = util.finding(
      "K2",
      "LUA-96",
      "warn",
      ("the second setup() removed %d %s (they are gone until it ends): %s%s"):format(
        #removed,
        kind,
        table.concat(sample, "; "),
        #removed > 3 and "; ..." or ""
      )
    )
  end
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  if not data.load.has_setup then
    return { na = "the plugin module has no setup() function" }
  end
  local findings = {}
  local function setup_failed(which, res)
    findings[#findings + 1] = util.finding(
      "K2",
      "LUA-96",
      "error",
      ("%s setup() raised: %s"):format(
        which,
        util.relativize(tostring(res.err or "?"):match("^[^\n]*") or "?", ctx.root)
      )
    )
  end
  if not (data.setup1 and data.setup1.ok) then
    setup_failed("the first", data.setup1 or { err = "not called" })
    return { findings = findings }
  end
  if not (data.setup2 and data.setup2.ok) then
    setup_failed("the second", data.setup2 or { err = "not called" })
    return { findings = findings }
  end
  local f1, f2 = data.facts1, data.facts2
  if type(f1) ~= "table" or f1.err or type(f2) ~= "table" or f2.err then
    return { error = "the child editor reported no facts" }
  end
  compare(findings, "keymap(s)", f1.sigs.keymaps, f2.sigs.keymaps)
  compare(findings, "user command(s)", f1.sigs.commands, f2.sigs.commands)
  compare(findings, "autocommand(s)", f1.sigs.autocmds, f2.sigs.autocmds)
  local r1, r2 = f1.registry, f2.registry
  if r1 and r2 then
    -- the registries describe the surface (docs, health); the surface itself was compared above, so a
    -- registry that grows on its own is a warning: the generated pages would list entries twice
    compare(findings, "lib.nvim keymap registry entrie(s)", r1.keymaps, r2.keymaps, "warn")
    compare(findings, "lib.nvim user command registry entrie(s)", r1.usercmds, r2.usercmds, "warn")
    compare(findings, "lib.nvim autocommand registry entrie(s)", r1.autocmds, r2.autocmds, "warn")
    compare(findings, "composer verb(s)", r1.composer, r2.composer, "warn")
  end
  return {
    findings = findings,
    notes = {
      ("after one setup(): %d keymap(s), %d command(s), %d autocommand(s)"):format(
        #f1.sigs.keymaps,
        #f1.sigs.commands,
        #f1.sigs.autocmds
      ),
    },
  }
end

return M
