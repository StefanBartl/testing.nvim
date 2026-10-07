---@module 'testing.conformance.util'
---@brief Small helpers the checks share: findings, safe display of repository text, multiset differences.
---@description
--- Text that comes out of the checked repository (file names, lines, error messages of its code) is
--- hostile input (SEC-42): it can carry terminal escape sequences, bidirectional overrides or invalid
--- UTF-8. Everything that ends up in a finding goes through `show`, which makes control characters
--- visible and bounds the length.

local M = {}

---Longest message of a finding (characters; the rest is cut).
M.MAX_MESSAGE = 300

---Text made safe to print and to put into JSON/Markdown, and bounded.
---@param s any
---@param max? integer
---@return string
function M.show(s, max)
  local clean = require("testing.report.util").clean
  local text = clean(tostring(s), { c1 = true, bidi = true }):gsub("[\r\n]+", " ")
  max = max or M.MAX_MESSAGE
  if #text > max then
    local cut = require("testing.report.util").cap(text, max - 3)
    text = cut .. "..."
  end
  return text
end

---@param path any
---@return string
function M.show_path(path)
  return M.show(path, 200)
end

---Build a finding.
---@param check string
---@param rule string
---@param level Testing.Conformance.Level
---@param message string
---@param file? string Repository-relative path.
---@param line? integer
---@return Testing.Conformance.Finding
function M.finding(check, rule, level, message, file, line)
  return {
    check = check,
    rule = rule,
    level = level,
    message = M.show(message),
    file = file and M.show_path((tostring(file):gsub("\\", "/"))) or nil,
    line = line,
  }
end

---Replace the repository root in a text of the repository's own code (an error message) with `<REPO>`.
---Give the cut chunk names of a Lua error their repository path: Neovim shortens a long chunk name to
---`...ame/lua/x/y.lua:12:`, which names a file nobody can open. When exactly one of `rels` ends with the cut
---text it takes its place; an ambiguous or unknown one stays as it is.
---@param text string
---@param rels string[] Repository-relative file names (forward slashes).
---@return string
function M.uncut_paths(text, rels)
  return (
    text:gsub("%.%.%.([%w_%-%./]+%.lua):(%d+)", function(tail, line)
      local found
      for _, rel in ipairs(rels) do
        -- the cut fell inside the repository path (`rel` ends with the text) or above it (the text ends with `rel`)
        if (#rel >= #tail and rel:sub(-#tail) == tail) or tail:sub(-(#rel + 1)) == "/" .. rel then
          if found then
            return nil -- two files end the same way: say nothing wrong
          end
          found = rel
        end
      end
      if found then
        return "<REPO>/" .. found .. ":" .. line
      end
      return nil
    end)
  )
end

---@param text any
---@param root string
---@return string
function M.relativize(text, root)
  local s = tostring(text):gsub("\\", "/")
  -- the spelling the caller used and the resolved one (a Windows 8.3 short name, a symlinked prefix):
  -- the child editor reports paths in the second
  local spellings = { (root:gsub("\\", "/"):gsub("/+$", "")) }
  local real = (vim.uv or vim.loop).fs_realpath(root)
  if real then
    local resolved = real:gsub("\\", "/"):gsub("/+$", "")
    if resolved ~= spellings[1] then
      spellings[#spellings + 1] = resolved
    end
  end
  for _, r in ipairs(spellings) do
    local out, from = {}, 1
    while true do
      local i, j = s:find(r, from, true)
      if not i then
        out[#out + 1] = s:sub(from)
        break
      end
      out[#out + 1] = s:sub(from, i - 1) .. "<REPO>"
      from = j + 1
    end
    s = table.concat(out)
  end
  return s
end

---Counts of the entries of a list.
---@param list string[]
---@return table<string, integer>
local function counts(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = (out[v] or 0) + 1
  end
  return out
end

---Multiset difference of two lists of strings.
---@param before string[]
---@param after string[]
---@return string[] added Entries (repeated by their surplus) that `after` has more of.
---@return string[] removed Entries that `after` has fewer of.
function M.multiset_diff(before, after)
  local b, a = counts(before or {}), counts(after or {})
  local added, removed = {}, {}
  local keys = {}
  for k in pairs(a) do
    keys[k] = true
  end
  for k in pairs(b) do
    keys[k] = true
  end
  local sorted = vim.tbl_keys(keys)
  table.sort(sorted)
  for _, k in ipairs(sorted) do
    local d = (a[k] or 0) - (b[k] or 0)
    for _ = 1, math.abs(d) do
      if d > 0 then
        added[#added + 1] = k
      else
        removed[#removed + 1] = k
      end
    end
  end
  return added, removed
end

---Is a line of Lua source a comment (starts with `--` after blanks)?
---@param line string
---@return boolean
function M.is_comment(line)
  return line:match("^%s*%-%-") ~= nil
end

---Median of a list of numbers.
---@param list number[]
---@return number
function M.median(list)
  local copy = vim.list_slice(list, 1, #list)
  table.sort(copy)
  local n = #copy
  if n == 0 then
    return 0
  end
  if n % 2 == 1 then
    return copy[(n + 1) / 2]
  end
  return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

---Describe a keymap item (`n <leader>x`). The editor lists a mapping with the leader already
---expanded (`\x`); with the leader known the label shows `<leader>x` again.
---@param k table
---@param leader? string
---@return string
function M.keymap_label(k, leader)
  local mode = (k.mode == " " or k.mode == "") and "nvo" or tostring(k.mode)
  local lhs = tostring(k.lhs)
  if
    type(leader) == "string"
    and leader ~= ""
    and lhs:sub(1, #leader) == leader
    and #lhs > #leader
  then
    lhs = "<leader>" .. lhs:sub(#leader + 1)
  end
  return ("%s %s"):format(mode, lhs)
end

---Run a check function that must not raise; a raise is returned as `nil, message`.
---@param fn fun(...): any
---@param ... any
---@return any|nil result
---@return string|nil err
function M.guarded(fn, ...)
  local ok, res = xpcall(fn, debug.traceback, ...)
  if ok then
    return res
  end
  local first = tostring(res):match("^[^\n]*") or tostring(res)
  return nil, first
end

---Every literal module name that a line passes to `require`: `require("a.b")`, `require 'a.b'`,
---`pcall(require, "a.b")` is NOT one (no call). A function that merely ends in `require` (`lib.try_require`,
---`lazy_require`, `M.require`) is not `require` either. Linear in the length of the line: no pattern with two
---adjacent `%s*`, which is quadratic on a line of spaces (SEC-30).
---@param line string
---@return string[] names
function M.required_names(line)
  local out = {}
  local pos = 1
  while true do
    local s, e = line:find("require", pos, true)
    if not s then
      return out
    end
    pos = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or ""
    if not before:match("[%w_%.:]") then
      local i = line:find("[^ \t]", e + 1) or (#line + 1)
      if line:sub(i, i) == "(" then
        i = line:find("[^ \t]", i + 1) or (#line + 1)
      end
      local q = line:sub(i, i)
      if q == '"' or q == "'" then
        local name, close = line:match("^([%w_%.@%-]+)([\"'])", i + 1)
        if name and close == q and name:sub(-1) ~= "." then
          out[#out + 1] = name
        end
      end
    end
  end
end

return M
