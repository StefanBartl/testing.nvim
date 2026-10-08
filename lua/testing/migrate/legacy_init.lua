---@module 'testing.migrate.legacy_init'
---@brief Splits the old init script of a repository (`scripts/minimal_init.lua`) into what the new
---`TESTS/minimal_init.lua` keeps and what it replaces.
---@description
--- The old runner's init script mixes three things: starting the old runner and finding its modules (replaced
--- by the lookup in the new file), the runtimepath of the repository (done by the new file), and the
--- suite's own state: no swapfile / shada, a fake clipboard, options, extra runtimepath entries,
--- environment variables. The last group must survive the migration.
---
--- `M.split(src)` cuts the file into top-level blocks (separated by blank lines; a block that is still
--- open - a function with a blank line inside - is not cut) and classifies each one:
---
---   * `drop`  the header comment, anything whose CODE mentions the old runner, the dependency lookup
---             (`add_dep`, a fatal "not found"), a bare `vim.opt.rtp:append(vim.fn.getcwd())`; a block that
---             also holds statements of the suite is cut statement by statement (`rescue`);
---   * `carry` everything else. Comments of a carried block that mention the old runner are reworded
---             ("the old runner"): the new file never names it.
---
--- Pure functions, nothing is read or written. Nothing is dropped silently: the plan deletes the old
--- file, whose diff shows every line.

local M = {}

---@class Testing.Migrate.InitBlock
---@field kind "carry"|"drop"
---@field reason string Why a block is dropped (empty for a carried one).
---@field lines string[] Lines as they stand in the old file (carried blocks: comments reworded).

---Depth change of each line, from a small scanner that knows strings, comments and long brackets.
---@param lines string[]
---@return integer[] depth_before Depth at the START of each line.
---@return boolean[] in_long Does the line START inside a long string or comment (its blank lines are text)?
local function depths(lines)
  local out, in_long = {}, {}
  local depth = 0
  local long_close ---@type string|nil closing bracket of an open long string / comment
  for i, line in ipairs(lines) do
    out[i] = depth
    in_long[i] = long_close ~= nil
    local pos, n = 1, #line
    while pos <= n do
      if long_close then
        local s, e = line:find(long_close, pos, true)
        if not s then
          pos = n + 1
        else
          long_close = nil
          pos = e + 1
        end
      else
        local c = line:sub(pos, pos)
        if c == "-" and line:sub(pos, pos + 1) == "--" then
          local eq = line:match("^%-%-%[(=*)%[", pos)
          if eq then
            long_close = "]" .. eq .. "]"
            pos = pos + 4 + #eq
          else
            pos = n + 1
          end
        elseif c == '"' or c == "'" then
          local q = c
          pos = pos + 1
          while pos <= n do
            local d = line:sub(pos, pos)
            if d == "\\" then
              pos = pos + 2
            elseif d == q then
              pos = pos + 1
              break
            else
              pos = pos + 1
            end
          end
        elseif c == "[" and line:match("^%[=*%[", pos) then
          local eq = line:match("^%[(=*)%[", pos)
          long_close = "]" .. eq .. "]"
          pos = pos + 2 + #eq
        elseif c == "(" or c == "{" or c == "[" then
          depth = depth + 1
          pos = pos + 1
        elseif c == ")" or c == "}" or c == "]" then
          depth = depth - 1
          pos = pos + 1
        elseif c:match("[%a_]") then
          local word = line:match("^[%w_]+", pos)
          if word == "function" or word == "if" or word == "do" or word == "repeat" then
            depth = depth + 1
          elseif word == "end" or word == "until" then
            depth = depth - 1
          end
          pos = pos + #word
        else
          pos = pos + 1
        end
      end
    end
  end
  return out, in_long
end

---@param l string
---@return boolean
local function is_comment(l)
  return l:match("^%s*%-%-") ~= nil
end

---A comment line with every mention of the old runner reworded.
---@param l string
---@return string
local function reword(l)
  l = l:gsub("[Pp]lenary%.nvim", "the old runner")
  l = l:gsub("[Pp]lenary's", "the old runner's")
  l = l:gsub("[Pp][Ll][Ee][Nn][Aa][Rr][Yy]", "the old runner")
  return l
end

---A line of code without its trailing comment (good enough for the heuristic below).
---@param l string
---@return string
local function code_part(l)
  return (l:gsub("%s*%-%-.*$", ""):gsub("%s+$", ""))
end

---Operators that end a line before its statement is over, and that start the line after one.
local ENDS_WITH = {
  "%.%.$",
  "[,=%+%-%*/%%%^<>~]$",
  "%f[%w_]and$",
  "%f[%w_]or$",
  "%f[%w_]not$",
  "[%.:]$",
}
local STARTS_WITH = {
  "^%.%.",
  "^[%.:][%a_]",
  "^and%f[^%w_]",
  "^or%f[^%w_]",
  "^[%+%*/%%%^]",
  "^%-[^%-]",
  "^[=~<>]=",
  "^[<>]",
}

---Is `cur` the continuation of the statement that `prev` belongs to (an operator at the end of `prev`, an operator
---or a method chain at the start of `cur`), although no bracket is open?
---@param prev string
---@param cur string
---@return boolean
local function continues(prev, cur)
  local p = code_part(prev)
  for _, pat in ipairs(ENDS_WITH) do
    if p:find(pat) then
      return true
    end
  end
  local c = cur:match("^%s*(.*)$")
  for _, pat in ipairs(STARTS_WITH) do
    if c:find(pat) then
      return true
    end
  end
  return false
end

---Cut the lines of a block into its top-level statements (a comment line between them is one of its own). A
---statement starts at a line that begins outside every bracket, block and long string and does not continue the
---line before.
---@param block string[]
---@return string[][]
local function statements(block)
  local depth, in_long = depths(block)
  local out, cur = {}, nil
  for i, l in ipairs(block) do
    if cur and (depth[i] > 0 or in_long[i] or continues(block[i - 1], l)) then
      cur[#cur + 1] = l
    else
      cur = { l }
      out[#out + 1] = cur
    end
  end
  return out
end

---The names a statement introduces (`local a, b = ...`, `local function f`, `function f`).
---@param text string
---@return string[]
local function defined_names(text)
  local names = {}
  for n in text:gmatch("%f[%w_]function%s+([%a_][%w_]*)") do
    names[#names + 1] = n
  end
  for list in text:gmatch("%f[%w_]local%s+([%a_][%w_%s,]-)%s*=[^=]") do
    for n in list:gmatch("[%a_][%w_]*") do
      names[#names + 1] = n
    end
  end
  return names
end

---Does `text` use `name` as a word?
---@param text string
---@param name string
---@return boolean
local function uses(text, name)
  return text:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

---A block that names the old runner may also hold statements of the suite (`vim.o.swapfile = false` right below
---the lines that start the old runner). They are kept, statement by statement: a statement goes when it names the
---old runner or its lookup (`plenary`, `add_dep`, `prepend_env`), and so does every statement after it that uses a
---name it introduced (`local dir = vim.env.PLENARY_DIR` and the `vim.opt.rtp:append(dir)` below it). A statement
---over several lines goes whole or not at all. Nil when nothing but comments is left, or when a statement that is
---left does not compile on its own (a cut that did not follow the statements): the block then stays dropped.
---@param block string[]
---@return string[]|nil lines
local function rescue(block)
  local gone_names = {}
  local lines, has_code = {}, false
  for _, st in ipairs(statements(block)) do
    local text = table.concat(st, "\n")
    local low = text:lower()
    local comment = #st == 1 and is_comment(st[1])
    local gone = low:find("plenary", 1, true)
      or low:find("add_dep", 1, true)
      or low:find("prepend_env", 1, true)
    if not gone and not comment then
      for name in pairs(gone_names) do
        if uses(text, name) then
          gone = true
          break
        end
      end
    end
    if gone then
      for _, n in ipairs(defined_names(text)) do
        gone_names[n] = true
      end
    else
      if not comment then
        if not loadstring(text) then
          return nil
        end
        has_code = true
      end
      vim.list_extend(lines, st)
    end
  end
  if not has_code or not loadstring(table.concat(lines, "\n")) then
    return nil
  end
  return lines
end

---Split the text of the old init script.
---@param src string
---@return Testing.Migrate.InitBlock[] blocks In file order.
function M.split(src)
  local lines = require("testing.migrate.text").lines(src)
  local depth, in_long = depths(lines)
  ---@type string[][]
  local raw = {}
  local cur
  for i, l in ipairs(lines) do
    if l:match("^%s*$") and depth[i] == 0 and not in_long[i] then
      cur = nil
    else
      if not cur then
        cur = {}
        raw[#raw + 1] = cur
      end
      cur[#cur + 1] = l
    end
  end
  ---@type Testing.Migrate.InitBlock[]
  local blocks = {}
  for idx, b in ipairs(raw) do
    local code = {}
    for _, l in ipairs(b) do
      if not is_comment(l) and not l:match("^%s*$") then
        code[#code + 1] = l
      end
    end
    local code_text = table.concat(code, "\n")
    local whole = table.concat(b, "\n")
    local kind, reason = "carry", ""
    if #code == 0 and idx == 1 then
      kind, reason = "drop", "header comment of the old file (how the old runner started it)"
    elseif #code == 0 and whole:lower():find("plenary", 1, true) then
      kind, reason = "drop", "comment about the old runner"
    elseif code_text:lower():find("plenary", 1, true) then
      kind, reason = "drop", "starts or locates the old runner (the runner is testing.nvim now)"
      -- A block that also holds other statements (`vim.o.swapfile = false` right below the lines that
      -- start the old runner) keeps those (see `rescue`).
      local rest = rescue(b)
      if rest then
        b = rest
        kind, reason = "carry", ""
      end
    elseif code_text:find("prepend_env", 1, true) then
      kind, reason =
        "drop", "runtimepath from environment variables (replaced by the lookup of the new file)"
    elseif code_text:find("add_dep", 1, true) then
      kind, reason = "drop", "dependency lookup (replaced by the lookup of the new file)"
    elseif code_text:find("os.exit", 1, true) and code_text:lower():find("not found", 1, true) then
      kind, reason = "drop", "dependency lookup (replaced by the lookup of the new file)"
    else
      local only_rtp = #code > 0
      for _, l in ipairs(code) do
        if not l:match("^%s*vim%.opt%.rtp:%a+%(%s*vim%.fn%.getcwd%(%)%s*%)%s*$") then
          only_rtp = false
        end
      end
      if only_rtp then
        kind, reason = "drop", "runtimepath of the repository (the new file does it)"
      end
    end
    local out = {}
    for _, l in ipairs(b) do
      out[#out + 1] = (kind == "carry" and is_comment(l)) and reword(l) or l
    end
    blocks[#blocks + 1] = { kind = kind, reason = reason, lines = out }
  end
  return blocks
end

---The carried blocks as one commented section for the new file.
---@param blocks Testing.Migrate.InitBlock[]
---@param from string Project-relative path of the old file.
---@param fate? string What happens to that file (default `removed by the migration`).
---@return string|nil section Nil when nothing is carried. Ends with a newline.
function M.section(blocks, from, fate)
  local out = {}
  for _, b in ipairs(blocks) do
    if b.kind == "carry" then
      if #out > 0 then
        out[#out + 1] = ""
      end
      vim.list_extend(out, b.lines)
    end
  end
  if #out == 0 then
    return nil
  end
  local head = {
    ("-- Carried over from %s (%s): what the suite needs"):format(
      from,
      fate or "removed by the migration"
    ),
    "-- besides the runtimepath. Review each block; the diff of the removed file shows all of it.",
    "",
  }
  return table.concat(vim.list_extend(head, out), "\n") .. "\n"
end

return M
