---@module 'testing.discover.positions'
---@brief Case positions of a describe/it style spec file: tree-sitter where a parser loads, regex otherwise.
---@description
--- Concept D.3.6 / D.11: positions come from a tree-sitter query over the Lua parser bundled with
--- Neovim; where `vim.treesitter` cannot load a parser (0.12 lists parsers that do not load) the
--- scan falls back to a line scanner. The answer says which backend produced it (`backend`) so a
--- consumer never mistakes the heuristic for the exact one.
---
--- A position is a `describe`, `it` or `pending` call (also `context`, `xit`, `xdescribe`) with a
--- literal string name. A name that is not a plain string literal (`it("x " .. n, ...)`) is kept with
--- `dynamic = true` and a `nil` name: the position exists, its name cannot be known statically.
---
--- The regex backend works on `lua_text.code_only` (comments and string contents blanked, offsets
--- kept) and nests by indentation: stylua-formatted code, which every repo of the fleet is. The
--- tree-sitter backend nests by the syntax tree and does not care.
---
--- M1 exposes `cases` for describe/it style files only; the other dialects have one case per file.

local lua_text = require("testing.discover.lua_text")

local M = {}

---@class Testing.Position
---@field kind "describe"|"it"|"pending" Normalised kind (`context` is a describe, `xit` is pending).
---@field name? string Literal name; nil when `dynamic`.
---@field dynamic boolean The name is not a plain string literal.
---@field line integer 1-based line of the call.
---@field path string[] Names of the enclosing describes, outermost first (dynamic ones as `<dynamic>`).

---@class Testing.Positions
---@field backend "treesitter"|"regex"
---@field positions Testing.Position[] Source order.
---@field fallback_reason? string Why tree-sitter was not used (regex backend only).

---@type table<string, "describe"|"it"|"pending">
local KIND_OF = {
  describe = "describe",
  context = "describe",
  xdescribe = "pending",
  it = "it",
  specify = "it",
  pending = "pending",
  xit = "pending",
}

---@param s string
---@return string
local function unquote(s)
  local inner = s:match("^(['\"])(.*)%1$")
  if inner then
    local body = s:sub(2, -2)
    -- `\n` and friends are rare in test names; resolve the escapes that matter for an id
    body = body:gsub("\\(['\"\\])", "%1")
    return body
  end
  local long = s:match("^%[=*%[(.*)%]=*%]$")
  return long or s
end

-- =========================================================
-- tree-sitter backend
-- =========================================================

---@param node TSNode
---@param source string
---@return string|nil name Literal name, nil when the first argument is not a plain string.
local function first_arg_name(node, source)
  local args = node:field("arguments")[1]
  if not args then
    return nil
  end
  local first = args:named_child(0)
  if not first or first:type() ~= "string" then
    return nil
  end
  local text = vim.treesitter.get_node_text(first, source)
  return unquote(text)
end

---@param text string
---@return Testing.Positions|nil
---@return string|nil err
local function by_treesitter(text)
  if not (vim.treesitter and vim.treesitter.get_string_parser and vim.treesitter.query) then
    return nil, "vim.treesitter is not available"
  end
  local parsed, parser = pcall(vim.treesitter.get_string_parser, text, "lua")
  if not parsed or not parser then
    return nil, ("no lua parser: %s"):format(tostring(parser))
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return nil, ("lua parser failed: %s"):format(tostring(trees))
  end
  local root = trees[1]:root()
  local ok_query, query =
    pcall(vim.treesitter.query.parse, "lua", "(function_call name: (identifier) @fn)")
  if not ok_query or not query then
    return nil, ("query did not compile: %s"):format(tostring(query))
  end

  ---@type Testing.Position[]
  local positions = {}
  ---Describe nodes already seen: node id -> path including the describe's own name.
  ---@type table<string, string[]>
  local describe_paths = {}

  ---`it` calls seen: a call inside one is runtime code of that case, not a position of its own.
  ---@type table<string, boolean>
  local it_ids = {}

  ---@param node TSNode
  ---@return string[] path Describe path of the nearest enclosing describe.
  ---@return boolean inside_it Some enclosing call is an `it`.
  local function enclosing(node)
    local inside = false
    local p = node:parent()
    while p do
      if p:type() == "function_call" then
        if it_ids[p:id()] then
          inside = true
        end
        local path = describe_paths[p:id()]
        if path then
          return path, inside
        end
      end
      p = p:parent()
    end
    return {}, inside
  end

  for _, node in query:iter_captures(root, text, 0, -1) do
    local call = node:parent()
    if call then
      local head = vim.treesitter.get_node_text(node, text)
      local kind = KIND_OF[head]
      if kind then
        local path, inside_it = enclosing(call)
        if kind == "it" then
          it_ids[call:id()] = true
        end
        if not inside_it then
          local name = first_arg_name(call, text)
          local srow = call:range()
          positions[#positions + 1] = {
            kind = kind,
            name = name,
            dynamic = name == nil,
            line = srow + 1,
            path = vim.list_slice(path, 1, #path),
          }
          if kind == "describe" then
            local own = vim.list_slice(path, 1, #path)
            own[#own + 1] = name or "<dynamic>"
            describe_paths[call:id()] = own
          end
        end
      end
    end
  end
  return { backend = "treesitter", positions = positions }, nil
end

-- =========================================================
-- regex backend
-- =========================================================

---@param text string
---@param reason string
---@return Testing.Positions
local function by_regex(text, reason)
  local code = lua_text.code_only(text)
  local code_lines = vim.split(code, "\n", { plain = true })
  local src_lines = vim.split(text, "\n", { plain = true })
  ---@type Testing.Position[]
  local positions = {}
  ---@type { indent: integer, name: string, kind: string }[]
  local stack = {}

  for idx, cline in ipairs(code_lines) do
    local indent, head, quote = cline:match("^(%s*)([%a_][%w_]*)%s*%(%s*(['\"])")
    local kind = head and KIND_OF[head]
    if kind then
      -- the string content is blanked in `cline`; read the name from the original line
      local from = #indent + #head
      local src = src_lines[idx] or ""
      local open = src:find(quote, from, true)
      local name, dynamic = nil, true
      if open then
        local close = open + 1
        while close <= #src do
          local c = src:sub(close, close)
          if c == "\\" then
            close = close + 2
          elseif c == quote then
            break
          else
            close = close + 1
          end
        end
        if src:sub(close, close) == quote then
          -- only the first character after the literal matters (`(.-)%s*$` would be quadratic in the blanks of
          -- a hostile line)
          local rest = src:sub(close + 1):match("^%s*(%S)") or ""
          -- `"name", function` / `"name")` end a plain literal; `.. x` makes the name dynamic
          if rest == "," or rest == ")" then
            name, dynamic = unquote(src:sub(open, close)), false
          end
        end
      end
      local depth = #indent
      while #stack > 0 and stack[#stack].indent >= depth do
        stack[#stack] = nil
      end
      local path, inside_it = {}, false
      for _, s in ipairs(stack) do
        if s.kind == "it" then
          inside_it = true
        else
          path[#path + 1] = s.name
        end
      end
      -- a call inside an `it` body is runtime code of that case (`pending("why")` skips it), not a case
      if not inside_it then
        positions[#positions + 1] =
          { kind = kind, name = name, dynamic = dynamic, line = idx, path = path }
      end
      if kind == "describe" or kind == "it" then
        stack[#stack + 1] = { indent = depth, name = name or "<dynamic>", kind = kind }
      end
    end
  end
  return { backend = "regex", positions = positions, fallback_reason = reason }
end

-- =========================================================
-- Public
-- =========================================================

---All describe/it/pending positions of a source text, in source order.
---@param text string
---@param opts? { backend?: "treesitter"|"regex" } Force a backend (specs); default: tree-sitter, regex as the fallback.
---@return Testing.Positions
function M.scan(text, opts)
  local forced = opts and opts.backend
  if forced == "regex" then
    return by_regex(text, "regex backend requested")
  end
  local ok, res, err = pcall(by_treesitter, text)
  if ok and res then
    return res
  end
  if forced == "treesitter" then
    return { backend = "treesitter", positions = {}, fallback_reason = tostring(ok and err or res) }
  end
  return by_regex(text, tostring(ok and err or res))
end

---The test cases (`it` / `pending`) of a describe/it style file with their describe path.
---@param text string
---@param opts? { backend?: "treesitter"|"regex" }
---@return Testing.Position[] cases
---@return Testing.Positions scan The full scan, for the backend and the fallback reason.
function M.cases(text, opts)
  local scan = M.scan(text, opts)
  local cases = {}
  for _, p in ipairs(scan.positions) do
    if p.kind == "it" or p.kind == "pending" then
      cases[#cases + 1] = p
    end
  end
  return cases, scan
end

return M
