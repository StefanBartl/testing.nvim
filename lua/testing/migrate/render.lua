---@module 'testing.migrate.render'
---@brief A migration plan as readable text (terminal or Markdown) and as JSON.
---@description
--- `M.render(plan, opts)` returns one string. `opts.format` is `"markdown"` (default; headings, fenced
--- diffs) or `"text"` (the same content for a terminal: no fences, diffs indented). Every string that
--- came out of the repository (paths, lines of a diff, module names) goes through `testing.migrate.text.show`,
--- so a hostile file name or a workflow line with escape sequences cannot reach the terminal (SEC-42).
---
--- `M.to_json(plan)` is the machine form: sorted keys, so the same plan is the same bytes; the text of
--- the files read (`before`) is left out, `after` is kept for created files only (a modified file is
--- described by its `diff`).

local text = require("testing.migrate.text")

local M = {}

---@param s any
---@return string
local function sh(s)
  return text.show(s, 300)
end

---Render the plan.
---@param plan Testing.Migrate.Plan
---@param opts? Testing.Migrate.RenderOpts
---@return string
function M.render(plan, opts)
  opts = opts or {}
  local md = opts.format ~= "text"
  local out = {}
  local function add(line)
    out[#out + 1] = line
  end
  local function heading(level, title)
    if md then
      add(("#"):rep(level) .. " " .. title)
    else
      add(level == 1 and title:upper() or title)
      add((level == 1 and "=" or "-"):rep(math.min(#title, 78)))
    end
    add("")
  end
  local function bullet(s)
    add("- " .. s)
  end
  local function block(lang, lines)
    if md then
      add("```" .. lang)
    end
    for _, l in ipairs(lines) do
      add(md and text.show(l, 2000) or ("    " .. text.show(l, 2000)))
    end
    if md then
      add("```")
    end
    add("")
  end

  heading(1, "testing migrate: " .. sh(plan.name))
  add(("Root: `%s`"):format(sh(plan.root)))
  add("")
  if plan.error then
    add("Cannot analyse: " .. sh(plan.error))
    return table.concat(out, "\n") .. "\n"
  end
  if plan.skipped then
    add("Skipped: " .. sh(plan.skipped))
    return table.concat(out, "\n") .. "\n"
  end
  if plan.empty then
    add("Nothing to do: the repository is migrated (the plan is empty).")
  else
    add(("%d operation(s) planned. Dry run: nothing has been written."):format(#plan.ops))
  end
  add("")

  local a = plan.analysis
  if a then
    heading(2, "Analysis")
    local dialects = {}
    local names = vim.tbl_keys(a.by_dialect)
    table.sort(names)
    for _, n in ipairs(names) do
      dialects[#dialects + 1] = ("%s %d"):format(sh(n), a.by_dialect[n])
    end
    bullet(
      ("specs: %d (%s)"):format(
        a.specs_total,
        #dialects > 0 and table.concat(dialects, ", ") or "none"
      )
    )
    bullet(
      ("own harness: %s%s%s"):format(
        a.own_harness and "yes (TESTS/harness.lua)" or "no",
        a.run_lua and ", TESTS/run.lua" or "",
        a.sentinel and (", sentinel " .. sh(a.sentinel)) or ""
      )
    )
    bullet(("plenary lines removed by the plan: %d"):format(a.plenary_lines))
    bullet(
      "suggested deps: "
        .. (#a.deps > 0 and sh(table.concat(a.deps, ", ")) or "none")
        .. (
          #a.optional_deps > 0
            and ("; optional (not in deps): " .. sh(table.concat(a.optional_deps, ", ")))
          or ""
        )
    )
    for _, line in ipairs(a.ci) do
      bullet("CI " .. sh(line))
    end
    if a.policy then
      bullet(
        ("policy: isolated=%s%s; `assertions` and `timeouts` stay at their defaults (see the notes: set them when a run asks for it)"):format(
          sh(a.policy.isolated),
          a.policy.host and (", host=" .. sh(a.policy.host)) or ""
        )
      )
    end
    add("")
  end

  if #plan.ops > 0 then
    heading(2, "Operations")
    for i, op in ipairs(plan.ops) do
      heading(3, ("%d. %s `%s`"):format(i, op.action, sh(op.path)))
      add(sh(op.reason))
      add("")
      block("diff", vim.split((op.diff:gsub("\n$", "")), "\n", { plain = true }))
      if #op.removed > 0 then
        add(("Lines removed from `%s` (%d):"):format(sh(op.path), #op.removed))
        add("")
        block("", op.removed)
      end
    end
  end

  if #plan.notes > 0 then
    heading(2, "Notes (manual work and facts)")
    for _, n in ipairs(plan.notes) do
      bullet(sh(n))
    end
    add("")
  end
  if #plan.risks > 0 then
    heading(2, "Risks")
    for _, r in ipairs(plan.risks) do
      bullet(sh(r))
    end
    add("")
  end
  return table.concat(out, "\n") .. "\n"
end

---The JSON form of a plan.
---@param plan Testing.Migrate.Plan
---@return string|nil json
---@return string|nil err
function M.to_json(plan)
  local copy = vim.deepcopy(plan)
  for _, op in ipairs(copy.ops or {}) do
    op.before = nil
    if op.action == "modify" then
      op.after = nil
    end
  end
  return require("lib.nvim.json").encode(copy)
end

return M
