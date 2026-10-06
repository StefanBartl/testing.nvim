---@module 'testing.migrate.ci'
---@brief Reads a GitHub Actions workflow and edits it line by line: no YAML library, no reformatting.
---@description
--- A workflow is edited as TEXT. Only the lines that must change are touched, so comments, key order,
--- quoting and the exact wording of everything else survive, and the result is shown as a unified diff.
--- The parser knows exactly the shape the fleet uses: a top-level `jobs:` map, a `steps:` list per job
--- whose items start with `- `, `run:` as an inline value or a `|` / `>` block.
---
--- What `M.edit` does per job that runs the old test runner (a step whose command is a plenary / busted
--- invocation, `TESTS/run.lua`, `luafile TESTS/...`, `-l TESTS/...`, or `scripts/test.sh`):
---
---   * the old command becomes `bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"` (an existing
---     `scripts/test.sh` call only gains `--json`); more old commands in the same step are removed,
---     `PLENARY*` environment lines of the step too;
---   * `shell: bash` is added to the step when the job runs on Windows and sets no shell (the command is
---     bash syntax);
---   * a `uses: actions/checkout` step for testing.nvim (and for every fleet dependency the job does not
---     mention yet), all from the `ci-verified` branch, is inserted before that step;
---   * the plenary checkout step is removed when plenary is not a dependency of the project any more;
---   * an artifact step that uploads the JSON IR when the job fails is added after it.
---
--- Job names, matrix, `timeout-minutes` and every other step are never touched. A command the migration
--- cannot map (a `dofile` of a CI script, a second runner call in the same job) is left in place and
--- reported in `notes` as manual work.
---
--- Idempotent: every edit tests for its own result (`--json` present, a testing.nvim checkout present,
--- `testing-ir` present, no plenary checkout), so a migrated workflow yields no change.

local text = require("testing.migrate.text")

local M = {}

---Command that replaces the old runner invocation.
M.RUN_COMMAND = 'bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"'

---@class Testing.Migrate.CiStep
---@field first integer First line, including the comment lines right above the dash.
---@field dash integer The line with the `- `.
---@field last integer Last line that belongs to the step (blank and detached comment lines excluded).
---@field indent integer Column of the dash.

---@class Testing.Migrate.CiJob
---@field id string
---@field first integer
---@field last integer
---@field indent integer Column of the job id.
---@field steps Testing.Migrate.CiStep[]

---@class Testing.Migrate.CiDoc
---@field lines string[]
---@field shape { eol: string, final: boolean }
---@field jobs Testing.Migrate.CiJob[]

---@param l string
---@return integer
local function indent_of(l)
  return #l:match("^( *)")
end

---@param l string
---@return boolean
local function blank(l)
  return l:match("^%s*$") ~= nil
end

---@param l string
---@return boolean
local function comment(l)
  return l:match("^%s*#") ~= nil
end

---@param l string
---@return boolean
local function structural(l)
  return not blank(l) and not comment(l)
end

---Parse a workflow.
---@param src string
---@return Testing.Migrate.CiDoc|nil doc
---@return string|nil err
function M.parse(src)
  local lines, shape = text.lines(src)
  local jobs_at
  for i, l in ipairs(lines) do
    if l:match("^jobs:%s*$") or l:match("^jobs:%s+#") then
      jobs_at = i
      break
    end
  end
  if not jobs_at then
    return nil, "no top-level `jobs:` key"
  end
  local doc = { lines = lines, shape = shape, jobs = {} }

  -- job headers
  local ji
  local headers = {}
  for i = jobs_at + 1, #lines do
    local l = lines[i]
    if structural(l) then
      local ind = indent_of(l)
      if ind == 0 then
        break
      end
      ji = ji or ind
      if ind == ji then
        local id = l:match("^ +([%w_%-%.]+):%s*$") or l:match("^ +([%w_%-%.]+):%s+#")
        if id then
          headers[#headers + 1] = { id = id, first = i }
        end
      end
    end
  end
  for n, h in ipairs(headers) do
    local limit = headers[n + 1] and headers[n + 1].first - 1 or #lines
    -- the job ends at its last structural line before the next header or a top-level key
    local last = h.first
    for i = h.first + 1, limit do
      local l = lines[i]
      if structural(l) then
        if indent_of(l) == 0 then
          break
        end
        last = i
      end
    end
    local job = { id = h.id, first = h.first, last = last, indent = ji, steps = {} }
    doc.jobs[#doc.jobs + 1] = job

    -- steps
    local steps_at
    for i = job.first + 1, job.last do
      local ind = indent_of(lines[i])
      if structural(lines[i]) and ind > ji and lines[i]:match("^ +steps:%s*$") then
        steps_at = i
        break
      end
    end
    if steps_at then
      local dashes, di = {}, nil
      local region_end = steps_at
      for i = steps_at + 1, job.last do
        local l = lines[i]
        if structural(l) then
          local ind = indent_of(l)
          di = di or ind
          if ind < di then
            break
          end
          if ind == di then
            if l:match("^ *%- ") or l:match("^ *%-$") then
              dashes[#dashes + 1] = i
            else
              break
            end
          end
          region_end = i
        end
      end
      for k, d in ipairs(dashes) do
        local prev_last = k > 1 and doc.jobs[#doc.jobs].steps[k - 1].last or steps_at
        local first = d
        while first - 1 > prev_last and comment(lines[first - 1]) do
          first = first - 1
        end
        local limit_k = dashes[k + 1] or (region_end + 1)
        -- last structural line before the next step's own comment block
        local last_k = d
        for i = d + 1, limit_k - 1 do
          if structural(lines[i]) then
            last_k = i
          end
        end
        job.steps[k] = { first = first, dash = d, last = last_k, indent = di }
      end
    end
  end
  return doc
end

---@class Testing.Migrate.CiRun
---@field key_line integer
---@field inline? string Value of an inline `run:`.
---@field block_first? integer
---@field block_last? integer
---@field folded? boolean A `>` block: YAML folds its lines into ONE command.

---@class Testing.Migrate.CiCommand
---@field kind "testsh"|"legacy"|"manual"|"other"
---@field cmd string The joined command.
---@field first integer First physical line.
---@field last integer Last physical line.

---Command kind of one logical line.
---@param cmd string
---@return "testsh"|"legacy"|"manual"|"other"
function M.classify(cmd)
  local rest = cmd:gsub("^%s*", "")
  -- what may stand in front of the program: `exec`, redirections (`2>&1`, `> >(tee ...)`, `> file`)
  -- and environment assignments
  while true do
    local before = rest
    rest = rest:gsub("^exec%s+", "")
    rest = rest:gsub("^%d?>&%d%s+", "")
    rest = rest:gsub("^%d?>%s*>%b()%s*", "")
    rest = rest:gsub("^%d?>%s*[^%s>]+%s+", "")
    rest = rest:gsub("^[%a_][%w_]*=%S*%s+", "", 1)
    if rest == before then
      break
    end
  end
  if rest:match("^bash%s+%.?/?scripts/test%.sh") or rest:match("^%.?/?scripts/test%.sh") then
    return "testsh"
  end
  if rest:match("^nvim%f[%s%z]") or rest:match("^nvim%.exe%f[%s%z]") then
    if
      rest:find("PlenaryBusted", 1, true)
      or rest:find("plenary.busted", 1, true)
      or rest:find("TESTS/run.lua", 1, true)
      or rest:match("luafile%s+[\"']?TESTS/")
      or rest:match("%-l%s+[\"']?TESTS/")
      or rest:match("dofile%s*%(%s*[\"']TESTS/")
    then
      return "legacy"
    end
    for path in rest:gmatch("[%w_%./%-]+%.lua") do
      if
        (path:find("test", 1, true) or path:find("/ci/", 1, true))
        and not path:find("gen_", 1, true)
      then
        return "manual"
      end
    end
    return "other"
  end
  if rest:match("^busted%f[%s%z]") then
    return "legacy"
  end
  return "other"
end

---The shell commands of a `run:` of one step: one per logical line (a trailing backslash joins lines).
---@param doc Testing.Migrate.CiDoc
---@param step Testing.Migrate.CiStep
---@return Testing.Migrate.CiCommand[] commands
---@return Testing.Migrate.CiRun|nil run
function M.commands(doc, step)
  local lines = doc.lines
  local fi = step.indent + 2
  local run
  for i = step.dash, step.last do
    local l = lines[i]
    local ind, rest
    if i == step.dash then
      rest = l:match("^ *%- +(.*)$")
      ind = fi
    else
      ind = indent_of(l)
      rest = l:match("^ *(.*)$")
    end
    if rest and ind == fi and structural(l) then
      local value = rest:match("^run:%s*(.*)$")
      if value then
        if value:match("^[|>][%+%-%d]*%s*$") or value:match("^[|>][%+%-%d]*%s+#") then
          local first, last = i + 1, i
          for j = i + 1, step.last do
            local lj = lines[j]
            if blank(lj) or indent_of(lj) > fi then
              last = j
            else
              break
            end
          end
          run = {
            key_line = i,
            block_first = first,
            block_last = last,
            folded = value:sub(1, 1) == ">",
          }
        else
          run = { key_line = i, inline = value }
        end
        break
      end
    end
  end
  if not run then
    return {}, nil
  end
  local commands = {}
  if run.inline then
    local cmd = run.inline:gsub("^%s*[\"']", ""):gsub("[\"']%s*$", "")
    commands[1] = { kind = M.classify(cmd), cmd = cmd, first = run.key_line, last = run.key_line }
    return commands, run
  end
  if run.folded then
    local pieces = {}
    for j = run.block_first, run.block_last do
      if structural(lines[j]) then
        pieces[#pieces + 1] = (lines[j]:gsub("^%s+", ""):gsub("%s+$", ""))
      end
    end
    if #pieces > 0 then
      local cmd = table.concat(pieces, " ")
      commands[1] =
        { kind = M.classify(cmd), cmd = cmd, first = run.block_first, last = run.block_last }
    end
    return commands, run
  end
  local i = run.block_first
  while i <= run.block_last do
    local l = lines[i]
    if blank(l) or comment(l) then
      i = i + 1
    else
      local first = i
      local pieces = {}
      while i <= run.block_last do
        local piece = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
        local cont = piece:sub(-1) == "\\"
        pieces[#pieces + 1] = cont and piece:sub(1, -2):gsub("%s+$", "") or piece
        i = i + 1
        if not cont then
          break
        end
      end
      local cmd = table.concat(pieces, " ")
      commands[#commands + 1] = { kind = M.classify(cmd), cmd = cmd, first = first, last = i - 1 }
    end
  end
  return commands, run
end

---Value of the first top-level-of-the-step key `name:` of a step.
---@param doc Testing.Migrate.CiDoc
---@param step Testing.Migrate.CiStep
---@param name string
---@return string|nil value
---@return integer|nil line
local function field(doc, step, name)
  local fi = step.indent + 2
  for i = step.dash, step.last do
    local l = doc.lines[i]
    local ind, rest
    if i == step.dash then
      rest, ind = l:match("^ *%- +(.*)$"), fi
    else
      rest, ind = l:match("^ *(.*)$"), indent_of(l)
    end
    if rest and ind == fi and structural(l) then
      local v = rest:match("^" .. name .. ":%s*(.*)$")
      if v then
        return v, i
      end
    end
  end
end

---All non-comment text of a line range, for substring tests.
---@param doc Testing.Migrate.CiDoc
---@param first integer
---@param last integer
---@return string
local function code_text(doc, first, last)
  local out = {}
  for i = first, last do
    if not comment(doc.lines[i]) then
      out[#out + 1] = doc.lines[i]
    end
  end
  return table.concat(out, "\n")
end

---@class Testing.Migrate.CiJobInfo
---@field id string
---@field timeout? string `timeout-minutes` as written.
---@field matrix_os boolean The job text mentions `matrix.os`.
---@field windows boolean The job runs on Windows (runs-on or matrix).
---@field commands string[] The old runner commands found (testsh / legacy / manual), as written.
---@field plenary_checkout boolean
---@field testing_checkout boolean
---@field artifact boolean A `testing-ir` artifact exists.

---One job in summary form (for the report).
---@param doc Testing.Migrate.CiDoc
---@param job Testing.Migrate.CiJob
---@return Testing.Migrate.CiJobInfo
function M.job_info(doc, job)
  local body = code_text(doc, job.first, job.last)
  local info = {
    id = job.id,
    timeout = body:match("\n +timeout%-minutes:%s*([^%s#]+)"),
    matrix_os = body:find("matrix.os", 1, true) ~= nil,
    windows = body:find("windows", 1, true) ~= nil,
    commands = {},
    plenary_checkout = false,
    testing_checkout = false,
    -- an artifact upload of a JSON file: ours (`testing-ir`) or one the project already wrote
    artifact = body:find("upload-artifact", 1, true) ~= nil and body:find(".json", 1, true) ~= nil,
  }
  for _, step in ipairs(job.steps) do
    local uses = field(doc, step, "uses")
    local st = code_text(doc, step.dash, step.last)
    if uses and uses:find("actions/checkout", 1, true) then
      if st:find("nvim-lua/plenary.nvim", 1, true) then
        info.plenary_checkout = true
      end
      if st:find("/testing.nvim", 1, true) then
        info.testing_checkout = true
      end
    end
    for _, c in ipairs((M.commands(doc, step))) do
      if c.kind ~= "other" then
        info.commands[#info.commands + 1] = c.kind .. ": " .. c.cmd
      end
    end
  end
  return info
end

---Summary of a workflow.
---@param src string
---@return { jobs: Testing.Migrate.CiJobInfo[] }|nil summary
---@return string|nil err
function M.summarize(src)
  local doc, err = M.parse(src)
  if not doc then
    return nil, err
  end
  local jobs = {}
  for _, job in ipairs(doc.jobs) do
    jobs[#jobs + 1] = M.job_info(doc, job)
  end
  return { jobs = jobs }
end

---@class Testing.Migrate.CiEditCtx
---@field drop_plenary boolean Remove the plenary checkout step.
---@field fleet_deps string[] Fleet dependencies (directory names) a job that runs the specs must check out.
---@field is_self boolean The repository is testing.nvim itself: it needs no checkout of itself.
---@field owner? string
---@field dep_step fun(name: string, prefix?: string): string|nil, string|nil Text of a checkout step (6-space indent, no trailing newline); `prefix` is the directory prefix of its `path:`.
---@field artifact_step fun(suffix: string): string|nil, string|nil
---@field keep_cmd? fun(cmd: string): boolean A runner call that must stay (a test no `spec_pattern` can name).
---@field read_script? fun(rel: string): string|nil Text of a repository script (a CI step that calls `scripts/ci.sh tests` wraps the runner).
---@field names? table

---@class Testing.Migrate.CiEdit
---@field text? string New workflow text; nil when nothing changes.
---@field changes string[] One line per edit.
---@field removed string[] The lines that disappear.
---@field notes string[] Manual work the migration cannot do.
---@field added_deps string[] Dependencies whose checkout step was added.
---@field wrapped boolean A step calls a repository script that wraps the old runner.

---Re-indent a block (lines at 6 spaces) to `indent`.
---@param block string
---@param indent integer
---@return string[]
local function reindent(block, indent)
  local out = {}
  for _, l in ipairs(vim.split(block, "\n", { plain = true })) do
    if l == "" then
      out[#out + 1] = ""
    else
      local ind = indent_of(l)
      out[#out + 1] = (" "):rep(math.max(0, ind - 6) + indent) .. l:sub(ind + 1)
    end
  end
  return out
end

---Does the text of a repository script start the old runner (plenary, `TESTS/run.lua`, `-l TESTS/...`)?
---@param body string
---@return boolean
function M.wraps_old_runner(body)
  for _, line in ipairs(text.lines(body)) do
    if not line:match("^%s*#") and M.classify(line) == "legacy" then
      return true
    end
  end
  return false
end

---Where the job already checks the fleet out: `.deps/` (default), or "" for siblings of the workspace root
---(`path: lib.nvim`). A new checkout follows the same layout, because the repository's own scripts look there.
---@param doc Testing.Migrate.CiDoc
---@param job Testing.Migrate.CiJob
---@return string prefix
function M.checkout_prefix(doc, job)
  for _, step in ipairs(job.steps) do
    local st = code_text(doc, step.dash, step.last)
    if
      st:find("actions/checkout", 1, true) and st:find("repository:%s*[\"']?[%w_%-]+/[%w_%.%-]+")
    then
      local path = st:match("[\r\n]%s*path:%s*([%w._/%-]+)")
      local repo = st:match("repository:%s*[\"']?[%w_%-]+/([%w_%.%-]+)")
      if path and repo and vim.endswith(path, repo) and not path:find("..", 1, true) then
        return (path:sub(1, #path - #repo))
      end
    end
  end
  return ".deps/"
end

---A command that only sets up the shell (`set -e`, `exec > >(tee ...) 2>&1`): nothing is lost when the
---step around it goes.
---@param cmd string
---@return boolean
local function is_shell_setup(cmd)
  return cmd:match("^set%s+%-[%a]+") ~= nil
    or (
      cmd:match("^exec%s+") ~= nil
      and cmd:find("nvim", 1, true) == nil
      and cmd:find("bash", 1, true) == nil
    )
end

---Does one step's command list contain an old runner call?
---@param cmds Testing.Migrate.CiCommand[]
---@return boolean
local function has_legacy(cmds)
  for _, c in ipairs(cmds) do
    if c.kind == "legacy" then
      return true
    end
  end
  return false
end

---Edit a workflow.
---@param src string
---@param ctx Testing.Migrate.CiEditCtx
---@return Testing.Migrate.CiEdit
function M.edit(src, ctx)
  local result = { changes = {}, removed = {}, notes = {}, added_deps = {}, wrapped = false }
  local doc, perr = M.parse(src)
  if not doc then
    result.notes[1] = "the workflow could not be read (" .. tostring(perr) .. "): edit it by hand"
    return result
  end
  local lines = doc.lines
  ---@type { from: integer, to: integer, new: string[], order: integer }[]
  local edits = {}
  ---Replace the lines `from..to` by `new`; `to < from` inserts before `from`.
  ---@param from integer
  ---@param to integer
  ---@param new string[]
  local function add(from, to, new)
    edits[#edits + 1] = { from = from, to = to, new = new, order = #edits }
    for i = from, to do
      result.removed[#result.removed + 1] = lines[i]
    end
  end
  ---@param fmt string
  ---@param ... any
  local function changed(fmt, ...)
    result.changes[#result.changes + 1] = fmt:format(...)
  end

  for _, job in ipairs(doc.jobs) do
    local info = M.job_info(doc, job)
    local job_text = code_text(doc, job.first, job.last)
    ---@type { step: Testing.Migrate.CiStep, cmds: Testing.Migrate.CiCommand[], run: Testing.Migrate.CiRun }[]
    local runners = {}
    for _, step in ipairs(job.steps) do
      local cmds, run = M.commands(doc, step)
      for _, c in ipairs(cmds) do
        if c.kind == "legacy" and ctx.keep_cmd and ctx.keep_cmd(c.cmd) then
          c.kind = "manual"
        end
      end
      local mapped = false
      for _, c in ipairs(cmds) do
        if c.kind == "testsh" or c.kind == "legacy" then
          mapped = true
        elseif
          c.kind == "other"
          and ctx.read_script
          and c.cmd:match("^%.?/?scripts/[%w_%-%.]+%.sh")
        then
          local rel = c.cmd:match("^%.?/?(scripts/[%w_%-%.]+%.sh)")
          local body = ctx.read_script(rel)
          if body and M.wraps_old_runner(body) then
            result.wrapped = true
            result.notes[#result.notes + 1] = ('job %s: `%s` (line %d) wraps the old runner inside %s: change the call there to `bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"`'):format(
              job.id,
              text.show(c.cmd, 100),
              c.first,
              rel
            )
          end
        elseif c.kind == "manual" then
          result.notes[#result.notes + 1] = ("job %s: `%s` (line %d) is not a runner call the migration can map: move it to testing.nvim by hand"):format(
            job.id,
            text.show(c.cmd, 120),
            c.first
          )
        end
      end
      if mapped and run then
        runners[#runners + 1] = { step = step, cmds = cmds, run = run }
      end
    end

    if #runners > 0 then
      local rs = runners[1]
      local step, run = rs.step, rs.run
      local fi = step.indent + 2
      local dash_line = lines[step.dash]
      local need_shell = has_legacy(rs.cmds)
        and info.windows
        and field(doc, step, "shell") == nil
        and not job_text:find("shell:%s*bash")
      local shell_done = false

      -- (a) the commands
      local replaced = false
      for _, c in ipairs(rs.cmds) do
        if c.kind == "legacy" then
          if not replaced then
            replaced = true
            local old = lines[c.first]
            -- keep `exec > >(tee ...) 2>&1` (the log file the job uploads) in front of the new call
            local keep = c.cmd:match("^(exec%s+>%s*>%b()%s*2>&1)%s")
            local command = keep and (keep .. " " .. M.RUN_COMMAND) or M.RUN_COMMAND
            if run.inline then
              local pre = old:match("^(.-run:%s*)") or ""
              if need_shell and c.first == step.dash then
                shell_done = true
                add(c.first, c.last, {
                  (" "):rep(step.indent) .. "- shell: bash",
                  (" "):rep(fi) .. pre:match("^ *%- +(.*)$") .. command,
                })
              else
                add(c.first, c.last, { pre .. command })
              end
            else
              add(c.first, c.last, { (" "):rep(indent_of(old)) .. command })
            end
            changed("job %s: the old runner call becomes `%s`", job.id, M.RUN_COMMAND)
          else
            add(c.first, c.last, {})
            changed("job %s: a second old runner call in the same step is removed", job.id)
          end
        elseif c.kind == "testsh" and not c.cmd:find("--json", 1, true) then
          -- append the flag right behind the script path, on the physical line that holds it
          for ln = c.first, c.last do
            local l = lines[ln]
            local _, e = l:find("scripts/test%.sh")
            if e then
              add(
                ln,
                ln,
                { l:sub(1, e) .. ' --json "$RUNNER_TEMP/testing-ir.json"' .. l:sub(e + 1) }
              )
              changed("job %s: scripts/test.sh gets --json for the IR artifact", job.id)
              break
            end
          end
        end
      end

      -- (b) environment lines of the step the runner makes superfluous: PLENARY* when plenary goes,
      -- and LIB_NVIM_PATH when it points to the sibling checkout `scripts/test.sh` finds by itself
      do
        local env_at
        for i = step.dash, step.last do
          if lines[i]:match("^ +env:%s*$") and indent_of(lines[i]) == fi then
            env_at = i
          end
        end
        if env_at then
          local kept, dropped, dropped_plenary, dropped_lib = 0, {}, false, false
          for i = env_at + 1, step.last do
            local l = lines[i]
            if structural(l) and indent_of(l) <= fi then
              break
            end
            if structural(l) then
              local lib_value = l:match("^ +LIB_NVIM_PATH:%s*(.-)%s*$")
              if ctx.drop_plenary and l:match("^ +PLENARY[%w_]*:") then
                dropped[#dropped + 1] = i
                dropped_plenary = true
              elseif lib_value and lib_value:match("/lib%.nvim[\"']?$") then
                dropped[#dropped + 1] = i
                dropped_lib = true
              else
                kept = kept + 1
              end
            end
          end
          if #dropped > 0 then
            if kept == 0 then
              add(env_at, dropped[#dropped], {})
            else
              for _, i in ipairs(dropped) do
                add(i, i, {})
              end
            end
            if dropped_plenary then
              changed("job %s: the PLENARY* environment of the run step is removed", job.id)
            end
            if dropped_lib then
              changed(
                "job %s: LIB_NVIM_PATH is removed from the run step (scripts/test.sh finds lib.nvim itself)",
                job.id
              )
            end
          end
        end
      end

      -- (c) bash on Windows
      if need_shell and not shell_done then
        if dash_line:match("^ *%- +run:") then
          add(step.dash, step.dash, {
            (" "):rep(step.indent) .. "- shell: bash",
            (" "):rep(fi) .. dash_line:match("^ *%- +(.*)$"),
          })
        else
          add(step.dash + 1, step.dash, { (" "):rep(fi) .. "shell: bash" })
        end
        shell_done = true
      end
      if shell_done then
        changed(
          "job %s: the run step gets `shell: bash` (bash syntax, Windows defaults to pwsh)",
          job.id
        )
      end

      -- (c2) names that still say plenary: the job and the run step (the runner is not plenary any more)
      do
        local key_indent
        for i = job.first + 1, job.last do
          local l = lines[i]
          if structural(l) then
            key_indent = key_indent or indent_of(l)
            if indent_of(l) == key_indent then
              if l:match("^ +steps:") then
                break
              end
              local pre, value = l:match("^( +name:%s*)(.-)%s*$")
              if pre and value:lower():find("plenary", 1, true) then
                local neutral = vim.trim((value:gsub("[Pp][Ll][Ee][Nn][Aa][Rr][Yy]%s*", "")))
                if neutral == "" or neutral == '""' or neutral == "''" then
                  neutral = "tests"
                end
                add(i, i, { pre .. neutral })
                changed("job %s: the job name no longer says plenary", job.id)
              end
            end
          end
        end
        local sname, sline = field(doc, step, "name")
        if sname and sline and sname:lower():find("plenary", 1, true) then
          local pre = lines[sline]:match("^(.-name:%s*)") or ""
          add(sline, sline, { pre .. "Run the specs" })
          changed("job %s: the run step name no longer says plenary", job.id)
        end
      end

      -- (d) checkouts: testing.nvim and the fleet dependencies the job does not mention yet
      local blocks = {}
      local prefix = M.checkout_prefix(doc, job)
      if not ctx.is_self and not info.testing_checkout then
        local t, err = ctx.dep_step("testing.nvim", prefix)
        if t then
          blocks[#blocks + 1] = t
        else
          result.notes[#result.notes + 1] = "testing.nvim checkout step: " .. tostring(err)
        end
      end
      for _, dep in ipairs(ctx.fleet_deps) do
        if dep ~= "testing.nvim" and not job_text:find(dep, 1, true) then
          local t, err = ctx.dep_step(dep, prefix)
          if t then
            blocks[#blocks + 1] = t
            result.added_deps[#result.added_deps + 1] = dep
          else
            result.notes[#result.notes + 1] = ("checkout step of %s: %s"):format(dep, tostring(err))
          end
        end
      end
      if #blocks > 0 then
        local new = {}
        for k, b in ipairs(blocks) do
          if k > 1 then
            new[#new + 1] = ""
          end
          vim.list_extend(new, reindent(b, step.indent))
        end
        add(step.first, step.first - 1, new)
        changed("job %s: %d checkout step(s) added before the run step", job.id, #blocks)
      end

      -- (e) the IR artifact
      if not info.artifact then
        local suffix = "-" .. job.id:gsub("[^%w_%-]", "_")
        if info.matrix_os then
          suffix = "-${{ matrix.os }}"
        end
        local t, err = ctx.artifact_step(suffix)
        if t then
          add(step.last + 1, step.last, reindent(t, step.indent))
          changed("job %s: an artifact step uploads testing-ir.json when the job fails", job.id)
        else
          result.notes[#result.notes + 1] = "artifact step: " .. tostring(err)
        end
      end

      -- Later steps of the job that only start the old runner (one step per script, as replacer.nvim
      -- does) are covered by the single call now: such a step is removed. A step that does anything else
      -- stays and is reported.
      for k = 2, #runners do
        local only_runner = true
        for _, c in ipairs(runners[k].cmds) do
          if not (c.kind == "legacy" or is_shell_setup(c.cmd)) then
            only_runner = false
          end
        end
        local later = runners[k].step
        if only_runner and has_legacy(runners[k].cmds) then
          add(later.first, later.last, {})
          changed(
            "job %s: the step at line %d only started the old runner and is removed",
            job.id,
            later.dash
          )
        else
          for _, c in ipairs(runners[k].cmds) do
            if c.kind == "legacy" then
              result.notes[#result.notes + 1] = ("job %s: a second runner call (line %d, `%s`) is left as it is: it runs the specs again, remove it once the first one is verified"):format(
                job.id,
                c.first,
                text.show(c.cmd, 100)
              )
            end
          end
        end
      end
    end

    -- plenary checkout: removed in every job when plenary is not a dependency of the project
    if ctx.drop_plenary then
      for _, step in ipairs(job.steps) do
        local uses = field(doc, step, "uses")
        local st = code_text(doc, step.dash, step.last)
        if
          uses
          and uses:find("actions/checkout", 1, true)
          and st:find("nvim-lua/plenary.nvim", 1, true)
        then
          add(step.first, step.last, {})
          changed("job %s: the plenary.nvim checkout step is removed", job.id)
        end
      end
    end
  end

  if #edits == 0 then
    return result
  end
  -- Apply bottom-up. At one position the replacements/deletions go first, then the insertions, the
  -- later-created insertion before the earlier one (so the earlier ends up first in the text).
  table.sort(edits, function(a, b)
    if a.from ~= b.from then
      return a.from > b.from
    end
    local a_ins, b_ins = a.to < a.from, b.to < b.from
    if a_ins ~= b_ins then
      return not a_ins
    end
    return a.order > b.order
  end)
  local out = vim.list_slice(lines, 1, #lines)
  for _, e in ipairs(edits) do
    for _ = e.from, e.to do
      table.remove(out, e.from)
    end
    -- a removed step must not leave two blank lines between its neighbours
    if #e.new == 0 and e.to >= e.from and e.from > 1 then
      if out[e.from] ~= nil and blank(out[e.from]) and blank(out[e.from - 1]) then
        table.remove(out, e.from)
      end
    end
    for k = #e.new, 1, -1 do
      table.insert(out, e.from, e.new[k])
    end
  end
  local new_text = text.join(out, doc.shape)
  if new_text ~= src then
    result.text = new_text
  end
  return result
end

return M
