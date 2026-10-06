---@module 'testing.conformance.checks.k01_require'
---@brief K1: every module under `lua/<plugin>/**` can be required on its own (NEW-47, XP-06).
---@description
--- Two halves that fail for the same reason: a module path that does not resolve the way it is
--- spelled.
---
---   static   every literal `require("<plugin>.a.b")` of `lua/`, `plugin/` and `TESTS/` is resolved against
---            the directory LISTING, case-exactly. Windows and macOS find `lua/Foo/bar.lua` for
---            `require("foo.bar")`; a Linux CI runner does not (XP-06). A module of this plugin that
---            exists nowhere is reported too (a require that can only work if something else
---            creates it).
---   runtime  every module is required alone in a fresh editor, the cache entries of its own tree
---            forgotten after each one, so a module that only works because a sibling was loaded first
---            fails. An error is reported with the module; a module of ANOTHER plugin that cannot be found
---            is a warning (a dependency missing from the plugin's minimal environment, `deps` of
---            `.testing.lua`); a module that leaves a global, a keymap, a user command or an autocommand
---            behind when it is merely required is a warning too (top-level side effect).

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K1",
  title = "every module can be required on its own",
  rules = { "NEW-47", "XP-06" },
  kind = "runtime",
  level = "error",
}

---Every literal module name required in a line: `require("a.b")`, `require('a.b')`, `require "a.b"`.
---@param line string
---@return string[]
local function required_names(line)
  return util.required_names(line)
end

---Resolve a module name below `lua/` by the listing, case-exactly.
---@param fs Testing.Conformance.Fs
---@param name string
---@param cache table<string, table<string, string>>
---@return "ok"|"missing"|"case" verdict
---@return string|nil actual The spelling that exists (for `case`).
local function resolve(fs, name, cache)
  local function entries(dir)
    if not cache[dir] then
      local set = {}
      for _, e in ipairs(fs:list(dir)) do
        set[e.name] = e.type
      end
      cache[dir] = set
    end
    return cache[dir]
  end
  ---The entry named like `want` in `set`, case-insensitively (the exact spelling is preferred).
  local function pick(set, want, kind)
    if set[want] == kind then
      return want
    end
    for n, t in pairs(set) do
      if t == kind and n:lower() == want:lower() then
        return n
      end
    end
    return nil
  end

  local segs = vim.split(name, ".", { plain = true })
  local dir = "lua"
  local actual, mismatch = {}, false
  for i, seg in ipairs(segs) do
    local set = entries(dir)
    local last = i == #segs
    local d = pick(set, seg, "directory")
    local f = last and pick(set, seg .. ".lua", "file") or nil
    local found
    if last and f then
      found = (f:gsub("%.lua$", ""))
    elseif d then
      found = d
    else
      return "missing"
    end
    if found ~= seg then
      mismatch = true
    end
    actual[#actual + 1] = found
    if last then
      if not f and entries(dir .. "/" .. found)["init.lua"] ~= "file" then
        return "missing"
      end
    else
      dir = dir .. "/" .. found
    end
  end
  if mismatch then
    return "case", table.concat(actual, ".")
  end
  return "ok"
end

---The static half: case and in-tree resolution of every literal require.
---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Finding[]
local function static_findings(ctx)
  local findings = {}
  local fs = ctx.fs
  -- the module roots of THIS plugin: a directory below `lua/` that is the plugin, or that has an entry module of
  -- its own. `lua/telescope/_extensions/x.lua` is an extension of another plugin, and `require("telescope.pickers")`
  -- in it is that plugin's module, not a missing file of this one
  local top = {}
  for _, e in ipairs(fs:list("lua")) do
    local name = e.name:gsub("%.lua$", "")
    if e.type == "file" or name == ctx.plugin or fs:is_file("lua/" .. e.name .. "/init.lua") then
      top[name:lower()] = name
    end
  end
  local cache = {}
  local files = {}
  for _, src in ipairs(ctx.sources("lua")) do
    files[#files + 1] = src
  end
  for _, src in ipairs(ctx.sources("plugin")) do
    files[#files + 1] = src
  end
  for _, src in ipairs(ctx.sources("TESTS")) do
    files[#files + 1] = src
  end
  local seen = {}
  for _, src in ipairs(files) do
    -- a spec may require a module that does not exist on purpose (a negative test): that is not a defect of the
    -- plugin's code
    local in_tests = src.rel:sub(1, 6) == "TESTS/"

    for n, line in ipairs(src.lines) do
      if not util.is_comment(line) then
        for _, name in ipairs(required_names(line)) do
          -- `require(".x")` and `require("")` have no first segment: nothing of ours to resolve
          local first = name:match("^[^.]+")
          local real = first and top[first:lower()]
          if first and real then
            local verdict, actual = resolve(fs, name, cache)
            local key = src.rel .. ":" .. n .. ":" .. name
            if verdict ~= "ok" and not seen[key] then
              seen[key] = true
              if verdict == "case" then
                findings[#findings + 1] = util.finding(
                  "K1",
                  "XP-06",
                  in_tests and "warn" or "error",
                  ("require(%q) does not match the directory spelling `%s` (finds the file on Windows/macOS, not on Linux)"):format(
                    name,
                    actual
                  ),
                  src.rel,
                  n
                )
              elseif first == real then
                findings[#findings + 1] = util.finding(
                  "K1",
                  "NEW-47",
                  in_tests and "warn" or "error",
                  ("require(%q) resolves to no file below lua/"):format(name),
                  src.rel,
                  n
                )
              end
            end
          end
        end
      end
    end
  end
  return findings
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local findings = static_findings(ctx)
  local notes = {}
  if not ctx.plugin then
    if #findings == 0 then
      return { na = ctx.plugin_problem or "no Lua module root of the plugin" }
    end
    return { findings = findings }
  end

  local data, err = ctx.probe("require")
  if not data then
    return { findings = findings, error = err }
  end
  local plugin = ctx.plugin
  local own = common.owned(ctx)
  local foreign = {}
  local ok_count = 0
  for _, r in ipairs(data.results or {}) do
    local rel = ctx.module_file(r.module)
    if r.ok then
      ok_count = ok_count + 1
    else
      local msg = util.relativize((tostring(r.err):match("^[^\n]*") or ""), ctx.root)
      if r.missing and r.missing ~= plugin and r.missing:sub(1, #plugin + 1) ~= plugin .. "." then
        findings[#findings + 1] = util.finding(
          "K1",
          "XP-06",
          "warn",
          ("require(%q) needs module %q, which is not in this editor's minimal environment (declare it in `deps` of .testing.lua or guard it with pcall)"):format(
            r.module,
            r.missing
          ),
          rel
        )
      else
        findings[#findings + 1] = util.finding(
          "K1",
          "NEW-47",
          "error",
          ("require(%q) fails: %s"):format(r.module, msg),
          rel
        )
      end
    end
    if r.effects then
      -- what a DEPENDENCY registers while this module loads is the dependency's, not this module's (`common.owned`)
      local fx = { globals = {}, keymaps = r.effects.keymaps or 0, commands = {}, autocmds = 0 }
      for _, g in ipairs(r.effects.globals or {}) do
        if own(g) then
          fx.globals[#fx.globals + 1] = g
        else
          foreign[g] = true
        end
      end
      for _, c in ipairs(r.effects.commands or {}) do
        if own(c) then
          fx.commands[#fx.commands + 1] = c
        else
          foreign[":" .. c] = true
        end
      end
      if r.effects.autocmd_groups then
        for group, n in pairs(r.effects.autocmd_groups) do
          if own(group) then
            fx.autocmds = fx.autocmds + n
          else
            foreign["autocmd group " .. group] = true
          end
        end
      else
        fx.autocmds = r.effects.autocmds or 0
      end
      local parts = {}
      if #fx.globals > 0 then
        parts[#parts + 1] = "global(s) " .. table.concat(fx.globals, ", ")
      end
      if fx.keymaps > 0 then
        parts[#parts + 1] = fx.keymaps .. " keymap(s)"
      end
      if #fx.commands > 0 then
        parts[#parts + 1] = "command(s) " .. table.concat(fx.commands, ", ")
      end
      if fx.autocmds > 0 then
        parts[#parts + 1] = fx.autocmds .. " autocmd(s)"
      end
      if #parts > 0 then
        findings[#findings + 1] = util.finding(
          "K1",
          "NEW-47",
          "warn",
          ("requiring %q alone has a top-level side effect: %s"):format(
            r.module,
            table.concat(parts, "; ")
          ),
          rel
        )
      end
    end
  end
  local foreign_names = vim.tbl_keys(foreign)
  table.sort(foreign_names)
  if #foreign_names > 0 then
    notes[#notes + 1] = "registered by a dependency while the modules load (not counted): "
      .. table.concat(vim.list_slice(foreign_names, 1, 8), ", ")
  end
  notes[#notes + 1] = ("%d of %d module(s) required alone"):format(ok_count, #(data.results or {}))
  return { findings = findings, notes = notes }
end

return M
