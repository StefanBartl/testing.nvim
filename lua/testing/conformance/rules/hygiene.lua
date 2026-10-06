---@module 'testing.conformance.rules.hygiene'
---@brief Static rules read from the text of the repository: vault references, lazy-load trigger, config validation, grep-able review items.
---@description
--- Rules that are heuristics say so in their title and report WARNINGS (`level = "warn"` on the item):
--- a grep cannot tell a legitimate mention from a defect, so these never fail the gate. A finding names
--- the file and line; the author decides, or waives it with a reason.

local util = require("testing.conformance.util")

local M = {}

---Most items one grep rule returns before it summarizes the rest.
local MAX_ITEMS = 20

---@param items table[]
---@param item table
---@param total integer
---@return integer
local function push(items, item, total)
  total = total + 1
  if #items < MAX_ITEMS then
    items[#items + 1] = item
  end
  return total
end

---@param items table[]
---@param total integer
local function summarize(items, total)
  if total > MAX_ITEMS then
    items[#items + 1] = { message = ("... and %d more"):format(total - MAX_ITEMS), level = "warn" }
  end
end

---Files whose text is documentation: README, `docs/**/*.md`, `doc/*.txt`.
---@param ctx Testing.Conformance.Ctx
---@return { rel: string, lines: string[] }[]
local function doc_files(ctx)
  local out = {}
  local function add(rel)
    local lines = ctx.fs:lines(rel)
    if lines then
      out[#out + 1] = { rel = rel, lines = lines }
    end
  end
  add("README.md")
  for _, rel in ipairs(ctx.fs:walk("docs", { ext = "md", limit = 300 })) do
    add(rel)
  end
  for _, e in ipairs(ctx.fs:list("doc")) do
    if e.type == "file" and e.name:match("%.txt$") then
      add("doc/" .. e.name)
    end
  end
  return out
end

---The fenced Lua blocks of the README: `{ first = <line of the first code line>, lines = string[] }`.
---@param ctx Testing.Conformance.Ctx
---@return { first: integer, lines: string[] }[]
local function readme_lua_blocks(ctx)
  local lines = ctx.fs:lines("README.md")
  local blocks = {}
  if not lines then
    return blocks
  end
  local current
  for i, line in ipairs(lines) do
    local fence = line:match("^%s*```%s*([%w_%-]*)")
    if fence then
      if current then
        if current.lua then
          blocks[#blocks + 1] = current
        end
        current = nil
      else
        current = { lua = fence == "lua", first = i + 1, lines = {} }
      end
    elseif current then
      current.lines[#current.lines + 1] = line
    end
  end
  return blocks
end

---@type table[]
M.rules = {
  {
    id = "REL-35",
    also = { "NEW-14" },
    title = "no reference to the vault in the repository (heuristic)",
    gate = "RELEASE",
    severity = "critical",
    run = function(ctx)
      local items, total = {}, 0
      local function scan(rel, lines)
        for n, line in ipairs(lines) do
          -- a path INTO the author's vault (the vault directory and the plugin notes directory below it), not every
          -- mention of the word: a feature that works on `<dir>-x/proj/README.md` paths names such a directory as an
          -- example
          local lower = line:lower()
          local at = lower:find("wkdbooks[/\\]") or lower:find("wkdbook%-myplugins")
          if at then
            local from = math.max(1, at - 30)
            total = push(items, {
              message = "refers to the author's vault (a dead path for every other reader): "
                .. util.show(vim.trim(line:sub(from, at + 50)), 80),
              file = rel,
              line = n,
              level = "warn",
            }, total)
          end
        end
      end
      for _, d in ipairs(doc_files(ctx)) do
        scan(d.rel, d.lines)
      end
      for _, src in ipairs(ctx.sources("lua")) do
        scan(src.rel, src.lines)
      end
      summarize(items, total)
      return items
    end,
  },
  {
    id = "REL-13",
    title = "no `dir = vim.env...` in the README",
    gate = "RELEASE",
    severity = "recommended",
    run = function(ctx)
      local lines = ctx.fs:lines("README.md")
      if not lines then
        return nil, "no README.md (NEW-11)"
      end
      local items = {}
      for n, line in ipairs(lines) do
        if line:match("dir%s*=%s*vim%.env") then
          items[#items + 1] =
            { message = "local development spec in the README", file = "README.md", line = n }
        end
      end
      return items
    end,
  },
  {
    id = "LUA-93",
    also = { "REL-11" },
    title = "the README's lazy.nvim spec carries its own trigger (heuristic)",
    gate = "RELEASE",
    severity = "critical",
    run = function(ctx)
      if not ctx.fs:is_file("README.md") then
        return nil, "no README.md (NEW-11)"
      end
      local items, specs = {}, 0
      for _, block in ipairs(readme_lua_blocks(ctx)) do
        local text = table.concat(block.lines, "\n")
        -- a lazy.nvim spec: a `"owner/name"` string
        local spec_line
        for i, l in ipairs(block.lines) do
          if l:match("^%s*{?%s*[\"'][%w_%-%.]+/[%w_%-%.]+[\"']") then
            spec_line = block.first + i - 1
            break
          end
        end
        if spec_line then
          specs = specs + 1
          local lazy_false = text:match("lazy%s*=%s*false") ~= nil
          local trigger = text:match("event%s*=")
            or text:match("ft%s*=")
            or text:match("cmd%s*=")
            or text:match("keys%s*=")
          if not lazy_false and not trigger and not text:match("lazy%s*=%s*true") then
            items[#items + 1] = {
              message = "the spec names no trigger (lazy = false, event, ft, cmd or keys): being required by another module is not a trigger",
              file = "README.md",
              line = spec_line,
              level = "warn",
            }
          end
          if lazy_false and (text:match("cmd%s*=") or text:match("ft%s*=")) then
            items[#items + 1] = {
              message = "lazy = false together with cmd/ft is a contradiction: lazy.nvim ignores the trigger",
              file = "README.md",
              line = spec_line,
              level = "warn",
            }
          end
        end
      end
      if specs == 0 then
        return nil, "the README holds no lazy.nvim spec"
      end
      return items
    end,
  },
  {
    id = "LUA-82",
    also = { "NEW-28", "ERR-50" },
    title = "the configuration is validated and its keys are typed (heuristic)",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local plugin = ctx.plugin
      if not plugin or not ctx.fs:is_dir("lua/" .. plugin .. "/config") then
        return nil, "the plugin has no config/ directory"
      end
      local validated, typed = false, false
      for _, src in ipairs(ctx.sources("lua")) do
        local own = src.rel:sub(1, #("lua/" .. plugin .. "/")) == "lua/" .. plugin .. "/"
        if own and src.rel:find("/config/", 1, true) then
          -- `vim.validate`, a `validate` function, an unknown-key walk, or the type checks a hand-written
          -- validator is made of
          local _, type_checks = src.text:gsub("[^%w_]type%s*%(", "")
          if
            src.text:find("validate", 1, true)
            or src.text:find("unknown_keys", 1, true)
            or src.text:find("unknown keys", 1, true)
            or src.text:find("FAIL_CLOSED", 1, true)
            or type_checks >= 5
          then
            validated = true
          end
        end
        -- the keys are typed by a `---@class ...Config|Opts|Options` with `---@field` lines,
        -- in config/ or in an @types/ folder
        if own and src.text:find("---@field", 1, true) then
          for _, line in ipairs(src.lines) do
            local class = line:match("^%-%-%-@class%s+([%w_%.]+)")
            if class and class:lower():find("conf") or class and class:lower():find("opt") then
              typed = true
              break
            end
          end
        end
      end
      local items = {}
      if not validated then
        items[#items + 1] = {
          message = "nothing in config/ validates the options (vim.validate or a validate function): a wrong type passes silently",
          file = "lua/" .. plugin .. "/config",
        }
      end
      if not typed then
        items[#items + 1] = {
          message = "no `---@field` in config/: the keys of the options carry no type (LUA-82)",
          file = "lua/" .. plugin .. "/config",
        }
      end
      return items
    end,
  },
  {
    id = "CMT-15",
    title = "no open `--- CDX:` tag (grep)",
    gate = "REVIEW",
    severity = "recommended",
    run = function(ctx)
      local items, total = {}, 0
      for _, src in ipairs(ctx.sources("lua")) do
        local previous = false
        for n, line in ipairs(src.lines) do
          local tagged = line:match("^%s*%-%-%- CDX:") ~= nil
          -- a tag of several lines is one tag
          if tagged and not previous then
            total = push(items, {
              message = "open CDX tag (resolved, or the author's decision written next to it): "
                .. util.show(vim.trim(line), 80),
              file = src.rel,
              line = n,
              level = "info",
            }, total)
          end
          previous = tagged
        end
      end
      summarize(items, total)
      return items
    end,
  },
  {
    id = "SEC-47",
    title = "no os.tmpname() and no hard-coded /tmp (grep)",
    gate = "REVIEW",
    severity = "recommended",
    run = function(ctx)
      local items, total = {}, 0
      for _, src in ipairs(ctx.sources("lua")) do
        for n, line in ipairs(src.lines) do
          if not util.is_comment(line) then
            -- `"/tmp/"` alone is a prefix list (to RECOGNIZE temp paths); `"/tmp/name"` names a file
            -- `os.tmpname(` counts as code, not inside a string literal (this very rule names it)
            local code = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
            if code:find("os.tmpname(", 1, true) or line:match("[\"']/tmp/[%w_%.%-]") then
              total = push(items, {
                message = "temporary files come from vim.fn.tempname(): "
                  .. util.show(vim.trim(line), 80),
                file = src.rel,
                line = n,
              }, total)
            end
          end
        end
      end
      summarize(items, total)
      return items
    end,
  },
  {
    id = "XP-01",
    title = "no glob/globpath on a concatenated path (grep)",
    gate = "REVIEW",
    severity = "critical",
    run = function(ctx)
      local items, total = {}, 0
      for _, src in ipairs(ctx.sources("lua")) do
        for n, line in ipairs(src.lines) do
          if not util.is_comment(line) and not line:find("globbable", 1, true) then
            local call = line:match("vim%.fn%.glob%((.*)")
              or line:match("vim%.fn%.globpath%((.*)")
              or line:match("[^%w_]globpath%((.*)")
            -- command completion globs what the user typed: `glob(arg_lead .. "*")` is the point of it
            local completion = call
              and (call:find("%f[%w_]arg_?[Ll]ead%f[^%w_]") or call:find("%f[%w_]lead%f[^%w_]"))
            if call and call:find("..", 1, true) and not completion then
              total = push(items, {
                message = "glob/globpath reads its argument as a pattern, not as a path: "
                  .. util.show(vim.trim(line), 80),
                file = src.rel,
                line = n,
                level = "warn",
              }, total)
            end
          end
        end
      end
      summarize(items, total)
      return items
    end,
  },
}

return M
