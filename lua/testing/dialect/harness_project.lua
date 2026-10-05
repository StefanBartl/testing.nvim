---@module 'testing.dialect.harness_project'
---@brief Dialect `h`: `return function(H)` specs run on the project's OWN `TESTS/harness.lua`, collecting.
---@description
--- The census of the fleet (`dialect_census.json`) found 14 repositories whose `H` carries helpers of
--- their own (`H.match`, `H.editable`, `H.fixture`, `H.excludes`, `H.capture_notify`, ...): the
--- fixed shims `a`, `b`, `c` cannot know them. Their assertion convention is the same everywhere
--- though: a failed check raises `error("FAIL <msg>: ...", 2)`. This adapter keeps the project's
--- harness and changes only what P1 asks for:
---
---   * the harness file is loaded (`dofile`) and every function of its table is wrapped;
---   * an error whose text is a harness failure (`[<file>:<line>: ]FAIL ...`) is RECORDED as a failed
---     assertion of the open case (call site from the error's own position prefix, else from the
---     stack) and the call returns `false`: the spec keeps running, all failures are visible;
---   * a call to an assertion function that returned normally is recorded as a passed assertion. Which
---     functions are assertions is read from the harness source (a function whose body contains
---     `FAIL`), plus every function that has raised a failure so far;
---   * any other error is not an assertion failure (a helper's own bug, an error raised by a callback
---     like `H.tmpdir(fn)`): it propagates untouched and ends the file as an `error`.
---
--- Non-function fields of the harness are copied by reference. Unknown keys read as `nil`.
--- The harness is not modified; the adapter builds a new `H` per file.
---
--- Limits, honestly: a helper that calls other assertions and fails in the middle stops there (the
--- failure is recorded, its remaining checks do not run); a harness whose failures do not read
--- `FAIL ...` is not recognised and its errors end the file as `error` (loud, never green).

local M = {}

local unpack_fn = table.unpack or unpack

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---@param ... any
---@return table
local function pack(...)
  return { n = select("#", ...), ... }
end

---Names of the functions in the harness source whose body mentions `FAIL` (static scan).
---@param text string
---@return table<string, boolean>
function M.assertion_names(text)
  local names = {}
  -- `function H.name(`, `function M.name(` and `H.name = function(`
  local starts = {}
  for pos, name in text:gmatch("()function%s+[%a_][%w_]*%.([%a_][%w_]*)%s*%(") do
    starts[#starts + 1] = { pos = pos, name = name }
  end
  for pos, name in text:gmatch("()[%a_][%w_]*%.([%a_][%w_]*)%s*=%s*function") do
    starts[#starts + 1] = { pos = pos, name = name }
  end
  table.sort(starts, function(x, y)
    return x.pos < y.pos
  end)
  for i, s in ipairs(starts) do
    local stop = starts[i + 1] and starts[i + 1].pos - 1 or #text
    if text:sub(s.pos, stop):find("FAIL", 1, true) then
      names[s.name] = true
    end
  end
  return names
end

---Directory walk upwards from a spec to the first `harness.lua`, never above the project root.
---@param spec_path string Absolute spec path.
---@param root string Absolute project root.
---@return string|nil path
function M.find_harness(spec_path, root)
  local uv = vim.uv or vim.loop
  root = slashes(root):gsub("/+$", "")
  local dir = vim.fs.dirname(slashes(spec_path))
  while dir and #dir >= #root do
    local candidate = dir .. "/harness.lua"
    local st = uv.fs_stat(candidate)
    if st and st.type == "file" then
      return candidate
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---File and line of the first frame above the wrapper that is not C and not this file.
---@return string|nil file
---@return integer|nil line
local function call_site()
  local level = 3
  while level < 20 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      return nil, nil
    end
    local src = info.source
    local file = slashes(src:sub(1, 1) == "@" and src:sub(2) or info.short_src)
    if info.what ~= "C" and not file:find("lua/testing/dialect/harness_project.lua", 1, true) then
      return file, info.currentline > 0 and info.currentline or nil
    end
    level = level + 1
  end
  return nil, nil
end

---Build `H` from the project's harness table.
---@param a Testing.Assert.Context|table Context (needs `current()`).
---@param harness table The table the project's `harness.lua` returned.
---@param assertions table<string, boolean> Names known to be assertions.
---@return table H
function M.new(a, harness, assertions)
  local H = {}
  for key, value in pairs(harness) do
    if type(value) ~= "function" then
      H[key] = value
    else
      H[key] = function(...)
        local args = pack(...)
        local res = pack(pcall(value, unpack_fn(args, 1, args.n)))
        local case = a.current()
        if res[1] then
          if assertions[key] and case then
            local file, line = call_site()
            case.assertions[#case.assertions + 1] =
              { ok = true, kind = key, file = file, line = line }
          end
          return unpack_fn(res, 2, res.n)
        end
        local err = res[2]
        if type(err) == "string" and case then
          local file, line, text = err:match("^(.-):(%d+): (FAIL.*)$")
          if not text then
            text = err:match("^(FAIL.*)$")
          end
          if text then
            assertions[key] = true
            if not file then
              file, line = call_site()
            end
            case.assertions[#case.assertions + 1] = {
              ok = false,
              kind = key,
              msg = text,
              file = file and slashes(file) or nil,
              line = tonumber(line),
            }
            return false
          end
        end
        error(err, 0)
      end
    end
  end
  return H
end

---Run one `return function(H)` spec file on the project's harness.
---@param a Testing.Assert.Context
---@param spec { path: string, rel: string, harness?: string, root?: string }
---@param opts? { on_case?: fun(case: Testing.Result.Case) }
---@return Testing.Result.Case[] cases
function M.run_file(a, spec, opts)
  local case = a.run_case({ file = spec.rel, name = vim.fs.basename(spec.rel) }, function()
    local path = spec.harness or (spec.root and M.find_harness(spec.path, spec.root))
    if not path then
      error(("dialect h: no harness.lua found above %s"):format(spec.rel), 0)
    end
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    local harness = dofile(path)
    if type(harness) ~= "table" then
      error(("dialect h: %s must return the harness table, got %s"):format(path, type(harness)), 0)
    end
    local H = M.new(a, harness, M.assertion_names(text))
    local run = dofile(spec.path)
    if type(run) ~= "function" then
      error(
        ("%s must return `function(H)`, got %s"):format(
          spec.rel,
          run == nil and "nothing" or type(run)
        ),
        0
      )
    end
    run(H)
  end)
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
