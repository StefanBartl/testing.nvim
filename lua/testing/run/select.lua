---@module 'testing.run.select'
---@brief Selection and ordering of a run: filters, tags, `--lf` / `--ff`, deterministic shuffle.
---@description
--- Pure: no editor APIs, no I/O except `file_header_tags` which reads the first bytes of a spec.
---
--- WHAT IS SELECTED
---   * `--file <text>`: a spec FILE is selected when its project-relative path contains `<text>`
---     (plain substring, never a Lua pattern, never the absolute path: a project that lives in a
---     directory called `spec` does not select everything). Repeatable, any match selects.
---   * `--filter <text>`: a CASE is selected when its id contains `<text>` (plain substring). The id is
---     `<file>::<describe>::...::<it>` for busted specs and `<file>::<file name>` for the one-case-per-
---     file dialects, so a file name or a describe title selects as well. Repeatable, any match selects.
---   * `--tags a,b`: a case is selected when it carries at least one of the tags;
---     `--exclude-tags c`: a case with one of these tags is dropped (exclusion wins).
---
--- TAG SYNTAX (documented contract)
---   * in a busted spec: a `#tag` word in a `describe` or `it` title (`it("parses #slow input", ...)`).
---     A tag of a `describe` applies to every case below it (it is part of every id). A trailing
---     `#<digits>` is the duplicate counter of the case id, not a tag.
---   * in any spec: a header line `-- @tags slow integration` (also `@tags: a, b`) within the first
---     30 lines tags every case of the file.
---   * tag characters: letters, digits, `_ . : -` (the same set `--tags` accepts).
---
--- ORDER
---   * `--shuffle [--seed N]`: files are shuffled with a private PRNG (Park-Miller, independent of
---     `math.random`, which a spec may reseed), so one seed gives one order on every platform. Cases
---     inside one busted file keep their source order: `it` bodies run where they are written, as in
---     plenary, and a shuffle inside a file would change what the spec means.
---   * `--lf`: only files with a case that failed last time (and in them only those cases); with no
---     remembered failure everything runs and a note says so (pytest does the same).
---   * `--ff`: files with remembered failures first (stable), then the rest.

local M = {}

---Lines of a spec scanned for `@tags`.
M.HEADER_LINES = 30

---Largest number of bytes read from a spec for its tag header.
M.HEADER_BYTES = 4096

-- =========================================================
-- Tags
-- =========================================================

---Tags written as `#word` in the describe/it part of a case id.
---@param id string
---@return string[]
function M.tags_of_id(id)
  local tags, seen = {}, {}
  -- drop the file part: the path may contain `#`, and a trailing `#2` is the duplicate counter
  local title = id:match("::(.*)$") or ""
  title = title:gsub("#%d+$", "")
  -- one segment per describe/it title: the id separator `::` must not become part of a tag
  for segment in (title .. "::"):gmatch("(.-)::") do
    for tag in segment:gmatch("#([%w_.:%-]+)") do
      if not seen[tag] then
        seen[tag] = true
        tags[#tags + 1] = tag
      end
    end
  end
  return tags
end

---Tags of the header of a spec text (`-- @tags a b`).
---@param text string
---@return string[]
function M.header_tags(text)
  local tags, seen = {}, {}
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > M.HEADER_LINES then
      break
    end
    local rest = line:match("^%s*%-%-+%s*@tags:?%s+(.*)$")
    if rest then
      for tag in rest:gmatch("[^%s,]+") do
        if tag:match("^[%w_.:%-]+$") and not seen[tag] then
          seen[tag] = true
          tags[#tags + 1] = tag
        end
      end
    end
  end
  return tags
end

---Header tags of a spec file; empty when it cannot be read (the run reports unreadable files elsewhere).
---@param path string
---@return string[]
function M.file_header_tags(path)
  local f = io.open(path, "rb")
  if not f then
    return {}
  end
  local text = f:read(M.HEADER_BYTES) or ""
  f:close()
  return M.header_tags(text)
end

---Union of two tag lists, order kept.
---@param a string[]
---@param b string[]
---@return string[]
function M.union(a, b)
  local out, seen = {}, {}
  for _, list in ipairs({ a, b }) do
    for _, t in ipairs(list) do
      if not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  return out
end

-- =========================================================
-- Matching
-- =========================================================

---@class Testing.Select.Spec
---@field file? string[] `--file` texts.
---@field filter? string[] `--filter` texts.
---@field tags? string[]
---@field exclude_tags? string[]
---@field ids? table<string, true> Exact case ids (`--lf`); applied per file via `restrict`.
---@field header_tags? fun(rel: string): string[] Tags of a file header (cached by the caller).

---@class Testing.Select.Selector
---@field active boolean True when any case-level restriction is set (the run is partial by selection).
---@field file_ok fun(rel: string): boolean
---@field case_ok fun(id: string, rel: string): boolean

---@param list string[]|nil
---@return boolean
local function nonempty(list)
  return type(list) == "table" and #list > 0
end

---@param hay string
---@param needles string[]
---@return boolean
local function contains_any(hay, needles)
  for _, n in ipairs(needles) do
    if hay:find(n, 1, true) then
      return true
    end
  end
  return false
end

---@param have string[]
---@param want string[]
---@return boolean
local function shares(have, want)
  for _, h in ipairs(have) do
    for _, w in ipairs(want) do
      if h == w then
        return true
      end
    end
  end
  return false
end

---Build the predicates of a selection.
---@param spec Testing.Select.Spec
---@return Testing.Select.Selector
function M.new(spec)
  local files = spec.file or {}
  local filters = spec.filter or {}
  local tags = spec.tags or {}
  local excl = spec.exclude_tags or {}
  local header = spec.header_tags or function()
    return {}
  end
  local active = nonempty(filters) or nonempty(tags) or nonempty(excl)

  ---@param rel string
  ---@return boolean
  local function file_ok(rel)
    return not nonempty(files) or contains_any(rel, files)
  end

  ---@param id string
  ---@param rel string
  ---@return boolean
  local function case_ok(id, rel)
    if nonempty(filters) and not contains_any(id, filters) then
      return false
    end
    if nonempty(tags) or nonempty(excl) then
      local have = M.union(M.tags_of_id(id), header(rel))
      if nonempty(tags) and not shares(have, tags) then
        return false
      end
      if nonempty(excl) and shares(have, excl) then
        return false
      end
    end
    return true
  end
  ---@type Testing.Select.Selector
  return { active = active, file_ok = file_ok, case_ok = case_ok }
end

-- =========================================================
-- Last failed (--lf / --ff)
-- =========================================================

---Project-relative file part of a case id (`TESTS/a_spec.lua::x::y` -> `TESTS/a_spec.lua`).
---@param id string
---@return string
function M.file_of_id(id)
  return id:match("^(.-)::") or id
end

---The id of the case that stands for "the file itself" (one-case-per-file dialects, load errors).
---@param rel string
---@return string
function M.file_case_id(rel)
  local base = rel:match("([^/]+)$") or rel
  return rel .. "::" .. base
end

---Group remembered failed ids by file.
---@param failed string[]
---@return table<string, table<string, true>> by_file rel -> set of ids
function M.group_failed(failed)
  local by_file = {}
  for _, id in ipairs(failed) do
    local rel = M.file_of_id(id)
    by_file[rel] = by_file[rel] or {}
    by_file[rel][id] = true
  end
  return by_file
end

---Which case ids of a file a `--lf` run may run: nil = all of them (the file itself failed, or it is
---a one-case-per-file dialect), a set = exactly those.
---@param rel string
---@param by_file table<string, table<string, true>>
---@return table<string, true>|nil
function M.lf_ids(rel, by_file)
  local ids = by_file[rel]
  if not ids or ids[M.file_case_id(rel)] then
    return nil
  end
  return ids
end

-- =========================================================
-- Order
-- =========================================================

---Deterministic PRNG (Park-Miller minimal standard): the same seed gives the same sequence on every
---platform, and no spec can disturb it by reseeding `math.random`.
---@param seed integer
---@return fun(n: integer): integer next Returns an integer in 1..n.
function M.rng(seed)
  local state = (math.floor(math.abs(seed)) % 2147483646) + 1
  return function(n)
    -- 48271 * 2147483646 < 2^47: exact in a double
    state = (state * 48271) % 2147483647
    return (state % n) + 1
  end
end

---Fisher-Yates over a copy. Same input list and seed give the same order.
---@generic T
---@param list T[]
---@param seed integer
---@return T[]
function M.shuffle(list, seed)
  local out = vim.list_slice(list, 1, #list)
  local nxt = M.rng(seed)
  for i = #out, 2, -1 do
    local j = nxt(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

---A seed for a shuffle the user did not pin: derived from the clock, always a positive integer
---below 2^31 so that it can be typed back (`--seed N`).
---@param time? integer
---@param ns? number
---@return integer
function M.fresh_seed(time, ns)
  local t = time or os.time()
  local n = ns or (vim.uv.hrtime() % 1000000000)
  return ((t % 2147483) * 1000 + (n % 1000)) % 2147483646 + 1
end

---Failed files first, stable; the others keep their order.
---@generic T
---@param files T[]
---@param rel_of fun(f: T): string
---@param failed_files table<string, any>
---@return T[]
function M.failed_first(files, rel_of, failed_files)
  local first, rest = {}, {}
  for _, f in ipairs(files) do
    if failed_files[rel_of(f)] then
      first[#first + 1] = f
    else
      rest[#rest + 1] = f
    end
  end
  return vim.list_extend(first, rest)
end

return M
