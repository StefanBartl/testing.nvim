---@module 'testing.scaffold.update'
---@brief `testing init --update`: bring `scripts/test.sh` and `TESTS/minimal_init.lua` of a repository to the current
---templates, keeping what is the repository's own.
---@description
--- `testing init` never overwrites, and `--force` replaces all eight files (`.testing.lua` and the CI job included).
--- A fix in the templates (an exit code, the throwaway state directory, the `ci` verb) therefore never reached the
--- repositories set up before it. `M.plan(root)` renders the two bootstrap files again and compares them with what
--- is there; `M.apply(plan)` writes the ones that changed. Nothing else is touched (`.testing.lua` and the CI job are
--- the repository's to edit).
---
--- Kept from the existing files, so a re-render does not undo a deliberate choice:
---   * the dependencies: the `DEPS=(...)` line of `scripts/test.sh` (runner first; the list `.testing.lua` gave when
---     the file was generated), else `deps = { ... }` read from the text of `.testing.lua`; the plugin name from
---     `plugin = "..."` of `.testing.lua`, else detected (`testing.scaffold.detect_plugin`). `.testing.lua` is READ AS
---     TEXT, never executed: running it is what the workspace trust gate decides, not a file generator;
---   * the `--sentinel '<NAME>'` argument of the run line (`testing migrate` sets it for a project whose old runner
---     printed its own sentinel);
---   * a `scripts/test.sh` that does not export `NVIM_APPNAME` on purpose (docmap.nvim): the template's export goes,
---     the file's own comment that says why stays;
---   * what a gate `TESTS/minimal_init.lua` sets up after the runtimepath (the "Carried over" section of a migration,
---     swap and shada settings, ...): everything between the template's runtimepath loop and its last line;
---   * a `TESTS/minimal_init.lua` that is not the gate yet (no four-place lookup) is replaced by it, and what it set up
---     besides the runtimepath is carried over like `testing migrate` does (`testing.migrate.legacy_init.carry`).
--- The new minimal_init is formatted with the repository's `stylua.toml` (as `testing migrate` does), so a file that
--- differs from the template only in formatting is not reported as changed.
---
--- Whatever else is the repository's own (an `OPTIONAL_DEPS` list, a helper of its own) is NOT kept: every code line
--- of the old file that is not in the new one is listed in `dropped` (except the exact lines of an older template,
--- `M.SUPERSEDED_SH`, which are counted), every such comment line in `dropped_comments`, and the diff shows both. Read
--- the plan before `apply`; the CLI shows it and writes only with `--write`. `apply` holds back a file with a risk or
--- with uncommitted changes unless forced.
---
--- Never raises: problems end in `errors` (whole plan) or `risks` (one file).

local scaffold = require("testing.scaffold")
local legacy_init = require("testing.migrate.legacy_init")
local text = require("testing.migrate.text")

local M = {}

---@class Testing.Scaffold.UpdateFile
---@field rel string Path below the root.
---@field before string|nil The file as it is (line ends as LF), nil when it does not exist.
---@field after string The file as the templates render it today, with the kept parts.
---@field changed boolean `after` differs from `before`.
---@field code_changed boolean Differs in more than comments, blank lines and indentation (what `--check` reports).
---@field dropped_comments string[] Comment lines of the old file that the new one does not have.
---@field diff string|nil Unified diff `before` -> `after` (nil when unchanged).
---@field kept string[] What was kept from the old file, one line each.
---@field dropped string[] Code lines of the old file (no comments, no blank lines) that the new one does not have.
---@field risks string[] Problems of this file (a carried block that could not be kept, ...): `apply` holds it back.
---@field notes? string[] Hints that hold nothing back (no stylua to format with).
---@field exec boolean The file is a script (mode 0755).

---@class Testing.Scaffold.UpdatePlan
---@field root string Absolute, forward slashes.
---@field plugin string|nil
---@field deps string[]
---@field files Testing.Scaffold.UpdateFile[]
---@field errors string[]

---@param path string
---@return string|nil
local function read(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("a")
  fh:close()
  return s and (s:gsub("\r\n", "\n")) or nil
end

---Dependencies besides the runner: the `DEPS=(...)` line of `scripts/test.sh`, else `deps = { ... }` in the text of
---`.testing.lua`, else the default. A word that is not a valid name is a risk, and a source that gives a word it
---cannot read is not used (the next one is): a dependency must never vanish from the new files without a word.
---@param test_sh string|nil
---@param dot string|nil
---@return string[] deps
---@return string|nil from Where they came from.
---@return string[] risks
local function deps_of(test_sh, dot)
  local valid = require("testing.deps").is_valid_name
  local risks = {}
  ---Names of a list's words (quoted with ' or ", or bare); nil when one of them is not a valid name.
  ---@param list string
  ---@param from string
  ---@return string[]|nil
  local function names(list, from)
    local out = {}
    for word in list:gmatch("[^%s,{}]+") do
      local name = word:match("^'(.*)'$") or word:match('^"(.*)"$') or word
      if not valid(name) then
        risks[#risks + 1] = ("%s names a dependency this cannot read: %s"):format(
          from,
          text.show(word, 80)
        )
        return nil
      end
      if name ~= "testing.nvim" and not vim.tbl_contains(out, name) then
        out[#out + 1] = name
      end
    end
    return out
  end
  local line = test_sh and test_sh:match("\nDEPS=%(([^)\n]*)%)")
  local got = line and names(line, "the DEPS line of scripts/test.sh")
  if got then
    return got, "scripts/test.sh", risks
  end
  local list = dot and dot:match("\n%s*deps%s*=%s*(%b{})")
  got = list and names(list, "`deps` of .testing.lua")
  if got then
    return got, ".testing.lua", risks
  end
  return vim.deepcopy(scaffold.DEFAULT_DEPS), nil, risks
end

---Lines of `s` that are code: trimmed, no blank lines, no comment lines (`#` for shell, `--` for Lua).
---@param s string
---@param comment string Lua pattern of a comment start.
---@return string[]
local function code_lines(s, comment)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    local t = vim.trim(line)
    if t ~= "" and not t:match("^" .. comment) then
      out[#out + 1] = t
    end
  end
  return out
end

---Lines of `s` that are comments (trimmed).
---@param s string
---@param comment string Lua pattern of a comment start.
---@return string[]
local function comment_lines(s, comment)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    local t = vim.trim(line)
    if t:match("^" .. comment) and not t:match("^#!") then
      out[#out + 1] = t
    end
  end
  return out
end

---Lines of `pick(before)` that `pick(after)` does not have (in the order of `before`, once each).
---@param before string|nil
---@param after string
---@param comment string
---@param pick? fun(s: string, comment: string): string[] Default: the code lines.
---@return string[]
local function dropped_lines(before, after, comment, pick)
  pick = pick or code_lines
  if not before then
    return {}
  end
  local have = {}
  for _, l in ipairs(pick(after, comment)) do
    have[l] = true
  end
  local out, seen = {}, {}
  for _, l in ipairs(pick(before, comment)) do
    if not have[l] and not seen[l] then
      seen[l] = true
      out[#out + 1] = l
    end
  end
  return out
end

---Does `before` set NVIM_APPNAME in a line of code (an export or an assignment, also indented or inside an `if`)?
---@param before string
---@return boolean
local function sets_appname(before)
  for _, l in ipairs(code_lines(before, "#")) do
    if l:find("NVIM_APPNAME=", 1, true) then
      return true
    end
  end
  return false
end

---Lines that earlier versions of `test.sh.tpl` (and the fleet patches that added `conformance` and `surface`) wrote
---and the current one replaces: not the repository's own, so they are counted, not listed as lost. Exactly the forms
---that were written (the verbs `conformance`, `surface`, `ci`, the run line with at most the `--sentinel`), so a block
---or a run argument of the repository's own is never hidden here. `<v>` stands for one of the verbs.
---@type string[]
M.SUPERSEDED_SH = {}
do
  local nvim = 'nvim %-n %-i NONE %-%-headless %-u NONE %-l "%$DRIVER" '
  for _, prefix in ipairs({ "^exec ", "^" }) do
    for _, verb in ipairs({ "conformance", "surface" }) do
      M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix .. nvim .. verb .. ' %. "%$@"$'
    end
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix .. nvim .. 'run %. "%$@"$'
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix
      .. nvim
      .. "run %. %-%-sentinel '[%u%d_]+' \"%$@\"$"
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix
      .. nvim
      .. 'ci %${ci_args%[@%]%+"%${ci_args%[@%]}"} "%$@"$'
  end
  for _, verb in ipairs({ "conformance", "surface", "ci" }) do
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = '^if %[%[ "%${1:%-}" == "' .. verb .. '" %]%]; then$'
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = '^if %[ "%${1:%-}" = "' .. verb .. '" %]; then$'
  end
  M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] =
    '^export NVIM_APPNAME="%${NVIM_APPNAME:%-[%w_%-]+%-tests}"$'
  -- the old `fail()` ended with a fixed code; the new one exits with $FAIL_CODE (3 under `ci`)
  M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = "^exit 1$"
end

---@param line string Trimmed.
---@return boolean
local function superseded(line)
  for _, pat in ipairs(M.SUPERSEDED_SH) do
    if line:match(pat) then
      return true
    end
  end
  return false
end

---Replace the template's `export NVIM_APPNAME=` (and the comment right above it) by the old file's own comment about
---not setting it, when the old file has no such export.
---@param after string
---@param before string
---@return string after
---@return boolean done
local function keep_no_appname(after, before)
  if sets_appname(before) then
    return after, false
  end
  local lines = vim.split(after, "\n", { plain = true })
  local at
  for i, l in ipairs(lines) do
    if l:match("^export NVIM_APPNAME=") then
      at = i
    end
  end
  if not at then
    return after, false
  end
  local first = at
  while first > 1 and lines[first - 1]:match("^#") do
    first = first - 1
  end
  -- the old file's comment block that names NVIM_APPNAME, without the template's own comment lines (a block can run
  -- into the template's next comment)
  local own = {}
  local template_line = {}
  for _, l in ipairs(lines) do
    template_line[l] = true
  end
  local old = vim.split(before, "\n", { plain = true })
  local i = 1
  while i <= #old do
    if old[i]:match("^#") then
      local j = i
      while j + 1 <= #old and old[j + 1]:match("^#") do
        j = j + 1
      end
      local mine = vim.tbl_filter(function(l)
        return not template_line[l]
      end, vim.list_slice(old, i, j))
      if table.concat(mine, "\n"):find("NVIM_APPNAME", 1, true) then
        own = mine
        break
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  if #own == 0 then
    own = { "# NVIM_APPNAME is not set here (the previous scripts/test.sh did not set it either)." }
  end
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, own)
  vim.list_extend(out, vim.list_slice(lines, at + 1))
  return table.concat(out, "\n"), true
end

---The loop that puts the dependencies on the runtimepath: the end of the template's own body (also collapsed onto one
---line by a formatter).
local RTP_LOOP = "vim%.opt%.rtp:append%(found%[name%]%)%s*end[ \t]*\n"

---What a gate minimal_init sets up after the template's body: the text between the runtimepath loop and the last
---line (`legacy_init.GATE_TAIL`), or to the end when the file has no such line. Nil when there is nothing.
---@param before string
---@return string|nil extra
local function gate_extra(before)
  local _, loop_end = before:find(RTP_LOOP)
  if not loop_end then
    return nil
  end
  local rest = before:sub(loop_end + 1)
  local tail = rest:find(legacy_init.GATE_TAIL, 1, true)
  local extra = tail and rest:sub(1, tail - 1) or rest
  extra = extra:gsub("^%s+", ""):gsub("%s+$", "")
  return extra ~= "" and extra or nil
end

---One file of the plan.
---@param rel string
---@param before string|nil
---@param after string
---@param comment string Lua pattern of a comment start.
---@param parts { kept: string[], dropped: string[], risks: string[], exec: boolean }
---@return Testing.Scaffold.UpdateFile
local function entry(rel, before, after, comment, parts)
  local changed = before ~= after
  return {
    rel = rel,
    before = before,
    after = after,
    changed = changed,
    code_changed = before == nil
      or not vim.deep_equal(code_lines(before, comment), code_lines(after, comment)),
    diff = changed and text.unified(before, after, rel) or nil,
    kept = parts.kept,
    dropped = parts.dropped,
    dropped_comments = dropped_lines(before, after, comment, comment_lines),
    risks = parts.risks,
    exec = parts.exec,
  }
end

---Plan the update of the two bootstrap files below `root`.
---@param root string
---@param opts? { owner?: string, format?: table } `format`: options of `testing.migrate.format.lua` (specs).
---@return Testing.Scaffold.UpdatePlan
function M.plan(root, opts)
  opts = opts or {}
  ---@type Testing.Scaffold.UpdatePlan
  local plan = { root = "", deps = {}, files = {}, errors = {} }
  local ok, perr = pcall(function()
    if type(root) ~= "string" or root == "" then
      plan.errors[#plan.errors + 1] = "no root given"
      return
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
    plan.root = abs
    if vim.fn.isdirectory(abs) ~= 1 then
      plan.errors[#plan.errors + 1] = abs .. ": not a directory"
      return
    end
    local old_sh = read(abs .. "/scripts/test.sh")
    local old_minit = read(abs .. "/TESTS/minimal_init.lua")
    local dot = read(abs .. "/.testing.lua")
    if not (old_sh or old_minit or dot) then
      plan.errors[#plan.errors + 1] = abs
        .. ": no testing setup to update (no .testing.lua, scripts/test.sh or TESTS/minimal_init.lua); run `testing init`"
      return
    end

    local plugin = dot and scaffold.sanitize_plugin(dot:match('\n%s*plugin%s*=%s*"([^"\n]+)"'))
      or scaffold.detect_plugin(abs)
    if not plugin then
      plan.errors[#plan.errors + 1] = "cannot derive the plugin name; set `plugin` in .testing.lua"
      return
    end
    plan.plugin = plugin
    local deps, deps_from, deps_risks = deps_of(old_sh, dot)
    plan.deps = deps

    -- ------------------------------------------------------------ scripts/test.sh
    do
      local kept, risks = {}, vim.deepcopy(deps_risks)
      if deps_from then
        kept[#kept + 1] = ("dependencies from %s: %s"):format(
          deps_from,
          #deps > 0 and table.concat(deps, ", ") or "none"
        )
      end
      local extra = { RUN_ARGS = "" }
      local sentinel = old_sh and old_sh:match("run %.( %-%-sentinel '[%u%d_]+') \"%$@\"")
      if sentinel then
        extra.RUN_ARGS = sentinel
        kept[#kept + 1] = "the run line's" .. sentinel
      end
      local vars, verr =
        scaffold.build_vars(plugin, deps, opts.owner or scaffold.DEFAULT_OWNER, extra)
      local after, rerr
      if vars then
        after, rerr = scaffold.render_template("test.sh.tpl", vars)
      end
      if not after then
        plan.errors[#plan.errors + 1] = "scripts/test.sh: " .. tostring(verr or rerr)
        return
      end
      if old_sh then
        local done
        after, done = keep_no_appname(after, old_sh)
        if done then
          kept[#kept + 1] =
            "no NVIM_APPNAME export (the file did not set one), with its own comment"
        end
      end
      local dropped, older = {}, 0
      for _, l in ipairs(dropped_lines(old_sh, after, "#")) do
        if superseded(l) then
          older = older + 1
        else
          dropped[#dropped + 1] = l
        end
      end
      if older > 0 then
        kept[#kept + 1] = ("%d line(s) of an older template version replaced"):format(older)
      end
      plan.files[#plan.files + 1] = entry("scripts/test.sh", old_sh, after, "#", {
        kept = kept,
        dropped = dropped,
        risks = risks,
        exec = true,
      })
    end

    -- ------------------------------------------------------------ TESTS/minimal_init.lua
    do
      local kept, risks = {}, {}
      local vars, verr = scaffold.build_vars(plugin, deps, opts.owner or scaffold.DEFAULT_OWNER)
      local after, rerr
      if vars then
        after, rerr = scaffold.render_template("minimal_init.lua.tpl", vars)
      end
      if not after then
        plan.errors[#plan.errors + 1] = "TESTS/minimal_init.lua: " .. tostring(verr or rerr)
        return
      end
      if legacy_init.is_gate(old_minit) then
        ---@cast old_minit string
        local extra = gate_extra(old_minit)
        local at = after:find(legacy_init.GATE_TAIL, 1, true)
        if extra and at then
          local candidate = after:sub(1, at - 1) .. extra .. "\n\n" .. after:sub(at)
          if loadstring(candidate) then
            after = candidate
            kept[#kept + 1] = ("what the file sets up after the runtimepath (%d line(s))"):format(
              #vim.split(extra, "\n", { plain = true })
            )
          else
            risks[#risks + 1] =
              "what the file sets up after the runtimepath would not compile in the new file: copy it by hand (the diff shows it)"
          end
        end
      elseif old_minit then
        local carried, carry_risks
        after, carried, carry_risks = legacy_init.carry(
          after,
          legacy_init.split(old_minit),
          "TESTS/minimal_init.lua",
          "replaced by testing init --update"
        )
        vim.list_extend(risks, carry_risks)
        kept[#kept + 1] = ("the file was not the gate yet (no four-place lookup): replaced, %d block(s) carried over"):format(
          carried
        )
      end
      local formatted, hint =
        require("testing.migrate.format").lua(after, "TESTS/minimal_init.lua", abs, opts.format)
      after = formatted
      local f = entry("TESTS/minimal_init.lua", old_minit, after, "%-%-", {
        kept = kept,
        dropped = dropped_lines(old_minit, after, "%-%-"),
        risks = risks,
        exec = false,
      })
      -- no stylua: the file is written as the template has it (not a reason to hold it back)
      f.notes = hint and { hint } or {}
      plan.files[#plan.files + 1] = f
    end
  end)
  if not ok then
    plan.errors[#plan.errors + 1] = "internal error: " .. tostring(perr)
  end
  return plan
end

---Uncommitted changes of `rel` (modified, staged or untracked): what `apply` would destroy for good. Nil outside a
---git work tree, or when git cannot answer (then nothing can be told, and nothing is held for it).
---@param root string
---@param rel string
---@return string|nil status The porcelain line.
local function uncommitted(root, rel)
  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", root, "status", "--porcelain", "--", rel }, { text = true })
      :wait()
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local line = vim.trim(res.stdout or "")
  return line ~= "" and line or nil
end

---@class Testing.Scaffold.UpdateHeld
---@field rel string
---@field why string

---Write the files of the plan that changed. Nothing is written when the plan has errors. A file whose plan has a risk,
---or that has uncommitted changes (they would be gone for good), is held back unless `opts.force`.
---@param plan Testing.Scaffold.UpdatePlan
---@param opts? { force?: boolean, git?: fun(root: string, rel: string): string|nil } `git`: the uncommitted-check (specs).
---@return string[] written Paths below the root.
---@return string[] errors
---@return Testing.Scaffold.UpdateHeld[] held
function M.apply(plan, opts)
  opts = opts or {}
  local written, errors, held = {}, {}, {}
  if #plan.errors > 0 then
    return written, vim.deepcopy(plan.errors), held
  end
  local check = opts.git or uncommitted
  for _, f in ipairs(plan.files) do
    local dirty = f.changed and f.before ~= nil and not opts.force and check(plan.root, f.rel)
    if f.changed and not opts.force and #f.risks > 0 then
      held[#held + 1] = { rel = f.rel, why = "it has a risk (see above); --force writes it anyway" }
    elseif dirty then
      held[#held + 1] = {
        rel = f.rel,
        why = ("it has uncommitted changes (%s); commit them first, or --force"):format(dirty),
      }
    elseif f.changed then
      local path = plan.root .. "/" .. f.rel
      local made, merr = require("lib.nvim.fs.mkdirp")(vim.fs.dirname(path))
      local ok, err
      if made then
        ok, err = require("lib.nvim.fs.write.atomic")(path, f.after)
      end
      if made and ok then
        if f.exec then
          -- best effort: a file system without modes keeps what it has (git's index mode is yours to set)
          pcall(vim.uv.fs_chmod, path, tonumber("755", 8))
        end
        written[#written + 1] = f.rel
      else
        errors[#errors + 1] = ("%s: %s"):format(f.rel, tostring(merr or err))
      end
    end
  end
  return written, errors, held
end

---The plan as text lines: per file whether it changes, what was kept, what would be lost, its risks, and (with
---`diff`) the diff. Every value from the repository is shown through `testing.migrate.text.show`.
---@param plan Testing.Scaffold.UpdatePlan
---@param o? { diff?: boolean, written?: string[], held?: Testing.Scaffold.UpdateHeld[] } A held file shows its diff always.
---@return string[] lines
function M.lines(plan, o)
  o = o or {}
  local out = { ("testing init --update %s"):format(text.show(plan.root, 200)) }
  for _, e in ipairs(plan.errors) do
    out[#out + 1] = "error: " .. text.show(e, 300)
  end
  local written, held = {}, {}
  for _, w in ipairs(o.written or {}) do
    written[w] = true
  end
  for _, h in ipairs(o.held or {}) do
    held[h.rel] = h.why
  end
  for _, f in ipairs(plan.files) do
    local state = not f.changed and "up to date"
      or (written[f.rel] and "updated")
      or (held[f.rel] and ("not written: " .. held[f.rel]))
      or (f.before and "out of date" or "missing")
    if f.changed and not f.code_changed then
      state = state .. " (comments only)"
    end
    out[#out + 1] = ("%-24s %s"):format(f.rel, state)
    if f.changed then
      for _, k in ipairs(f.kept) do
        out[#out + 1] = "  kept: " .. text.show(k, 200)
      end
      if #f.dropped > 0 then
        out[#out + 1] = ("  only in the old file (%d code line(s); keep them by hand if they are yours):"):format(
          #f.dropped
        )
        for i, l in ipairs(f.dropped) do
          if i > 20 then
            out[#out + 1] = ("    ... %d more"):format(#f.dropped - 20)
            break
          end
          out[#out + 1] = "    " .. text.show(l, 160)
        end
      end
      if #f.dropped_comments > 0 then
        out[#out + 1] = ("  comments only in the old file (%d; a reason you wrote down goes with them):"):format(
          #f.dropped_comments
        )
        for i, l in ipairs(f.dropped_comments) do
          if i > 10 then
            out[#out + 1] = ("    ... %d more"):format(#f.dropped_comments - 10)
            break
          end
          out[#out + 1] = "    " .. text.show(l, 160)
        end
      end
      if f.exec and f.before == nil and written[f.rel] then
        -- NTFS has no mode bits: git records a new file as 100644, and a clone on Linux or macOS cannot run it
        out[#out + 1] = "  next: git add " .. f.rel .. " && git update-index --chmod=+x " .. f.rel
      end
    end
    for _, r in ipairs(f.risks) do
      out[#out + 1] = "  risk: " .. text.show(r, 300)
    end
    for _, n in ipairs(f.notes or {}) do
      out[#out + 1] = "  note: " .. text.show(n, 300)
    end
    if (o.diff or held[f.rel]) and f.diff then
      for line in (f.diff .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = "  " .. text.show(line, 400)
      end
    end
  end
  return out
end

return M
