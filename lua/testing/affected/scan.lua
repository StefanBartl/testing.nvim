---@module 'testing.affected.scan'
---@brief Static reading of Lua sources: which modules a file requires and which hidden inputs it has.
---@description
--- The shared eye of the cache key (`testing.cache`) and the built-in affected heuristic
--- (`testing.affected.heuristic`). It is a SCANNER, not a parser, and it errs on the side of "more
--- dependencies, more hidden inputs": a result may name too much, never too little.
---
--- `analyze(text)` returns
---   * `requires`  literal module names (`require("a.b")`, `pcall(require, "a.b")`, `require "a.b"`),
---   * `prefixes`  the literal head of a computed name (`require("a.dialect." .. name)` -> `a.dialect.`):
---                 a dependency on every module below that prefix,
---   * `dynamic`   a `require(<expression>)` nobody can resolve: a dependency on EVERY module,
---   * `markers`   hidden inputs that make a result depend on something that is not a file of the
---                 project: `time`, `random`, `spawn` (processes, shell), `net`, `io` (file reads and
---                 directory listings), `env` (the names read; `env_computed` when a name is computed,
---                 `env_whole` when the whole environment is read, `env_dynamic` for either),
---   * `directives` what the author of the file states in its first lines (`-- @cache off`, `-- @cache-inputs`,
---                 `-- @cache-allow`, `-- @cache-env`, `-- @require-wrapper`).
---
--- Comments are ignored, string contents are not (a `require` inside `vim.cmd("lua require('x')")` is a
--- dependency; a marker inside a string is not a marker). Pure Lua apart from `index`, which walks the
--- file system.

local lua_text = require("testing.discover.lua_text")

local M = {}

---Version of the analysis. Bump it whenever `analyze` can answer differently for the same text: the index
---of the cache (`testing.cache.hash`) keeps analyses with the hashes and drops the ones of another version.
---@type integer
M.VERSION = 8

---Largest file read by `index`/`read_text` (a bigger file is reported as unreadable, never cut).
---@type integer
M.MAX_FILE_BYTES = 2 * 1024 * 1024

---Modules that exist without a file of the project (the host, the runner itself).
---@type table<string, true>
M.BUILTIN = {
  vim = true,
  jit = true,
  ffi = true,
  bit = true,
  string = true,
  table = true,
  math = true,
  os = true,
  io = true,
  coroutine = true,
  debug = true,
  package = true,
  utf8 = true,
}

---@class Testing.Scan.Markers
---@field time boolean
---@field random boolean
---@field spawn boolean
---@field net boolean
---@field io boolean
---@field dirscan boolean The file lists directories (`vim.fs.dir`, `glob`, `fs_scandir`, ...).
---@field dynload boolean Files are loaded by an ex command or a runtime-path lookup (`:runtime`, `:source`, `:luafile`, `packadd`).
---@field selfscan boolean The file lists directories or loads files AND looks at its own surroundings (`debug.getinfo`, `getcwd`, `stdpath`, the runtime path): it reads the project, not only what its caller hands it.
---@field pathmod boolean The module search path or the runtime path is changed (`package.path`, `rtp`).
---@field outside boolean A string literal names a place outside the project (`../x`, `C:/x`, `~/x`, `/etc/x`).
---@field env string[] Names of environment variables read by a literal name (sorted, unique).
---@field env_dynamic boolean A name is computed or the whole environment is read (`env_computed or env_whole`).
---@field env_computed boolean An environment variable is read by a computed name (`getenv(name)`).
---@field env_whole boolean The whole environment is read (`vim.fn.environ()`, `vim.uv.os_environ()`, `vim.env` as a table).

---@class Testing.Scan.Info
---@field requires string[] Sorted, unique.
---@field prefixes string[] Sorted, unique.
---@field dynamic boolean
---@field markers Testing.Scan.Markers
---@field paths string[] Path-like string literals (candidates for files a spec reads).
---@field where table<string, integer> First line (1-based) of the hit of a hidden input that makes a spec uncacheable: keys `time`, `random`, `spawn`, `net` (`testing explain` names it). Absent key: the hit has no single line.
---@field outside_paths string[] The string literals (or words of a command string) that name a place outside the project: `../x`, `C:/x`, `~/x`, `/etc/x`.
---@field wrapped table<string, Testing.Scan.Wrapped> Modules the file uses ONLY as `X.member("literal", ...)` (an alias of `require("X")` or `require("X").member("literal")`): per module the members called and the literal names passed. A module with any other use (passed on, indexed, a computed first argument, `pcall(require, "X")`) is not listed. Read by the affected heuristic for modules that declare `-- @require-wrapper`; the cache key does not use it.
---@field directives { off: boolean, inputs: string[], allow: string[], wrapper: string[], env: string[] } `-- @cache off`, `-- @cache-inputs a b`, `-- @cache-allow time random` (the author vouches that the clock, random numbers, processes or the network a file uses do not decide what a spec sees), `-- @cache-env NAME *_DIR PREFIX_* *` (the variables a computed read can reach, `*` for the whole environment: their hashed values join the key), `-- @require-wrapper require module fn` (the module computes `require(<argument>)`, and only for the first argument of the listed functions: see `testing.affected.heuristic`).

---@class Testing.Scan.Wrapped
---@field members string[] Sorted, unique.
---@field names string[] Sorted, unique: the module names passed as the first argument.

---@param s string
---@return boolean
local function is_ident_char(s)
  return s ~= "" and s:match("[%w_%.]") ~= nil
end

---Module names `require` is called with in `text` (comments already removed).
---@param text string
---@return string[] requires
---@return string[] prefixes
---@return boolean dynamic
local function scan_requires(text)
  local reqs, prefs = {}, {}
  local dynamic = false
  local pos = 1
  while true do
    local s, e = text:find("require", pos, true)
    if not s then
      break
    end
    pos = e + 1
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = text:sub(e + 1, e + 1)
    if not is_ident_char(before) and not after:match("[%w_]") then
      local i = e + 1
      local function skip()
        local _, ws = text:find("^%s*", i)
        i = ws + 1
      end
      skip()
      local c = text:sub(i, i)
      if c == "(" or c == "," then
        i = i + 1
        skip()
        c = text:sub(i, i)
      end
      if c == '"' or c == "'" then
        local close = text:find(c, i + 1, true)
        local lit = close and text:sub(i + 1, close - 1) or nil
        if lit and not lit:find("[\r\n]") then
          local rest = text:sub(close + 1, close + 40)
          if rest:match("^%s*%.%.") then
            prefs[#prefs + 1] = lit
          else
            reqs[#reqs + 1] = lit
          end
          pos = close + 1
        else
          dynamic = true
        end
      elseif c == ")" or c == "=" or c == "" or c == "}" then
        -- `pcall(require)`, `local require = ...`, `{ require }`: no module name here, and no call either
        -- (a name passed on and called later is `dynamic`, see below)
        if c == ")" or c == "}" then
          dynamic = true
        end
      elseif c ~= "." and c ~= ":" then
        -- `require(name)`, `require(a .. b)`, `pcall(require, name)`
        dynamic = true
      end
    end
  end
  return reqs, prefs, dynamic
end

---@param list string[]
---@return string[]
local function uniq_sorted(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out)
  return out
end

---Count plain occurrences of `needle` in `text`.
---@param text string
---@param needle string
---@return integer
local function count_plain(text, needle)
  local n, pos = 0, 1
  while true do
    local s, e = text:find(needle, pos, true)
    if not s then
      return n
    end
    n = n + 1
    pos = e + 1
  end
end

---Ex commands that read a file (or load one) named by their argument.
---@type table<string, true>
local FILE_COMMANDS = {}
for _, w in ipairs({
  "runtime",
  "source",
  "so",
  "luafile",
  "luf",
  "edit",
  "e",
  "read",
  "sview",
  "view",
  "pedit",
  "badd",
  "argadd",
  "split",
  "vsplit",
  "new",
  "vnew",
  "tabedit",
  "tabnew",
  "packadd",
}) do
  FILE_COMMANDS[w] = true
end

---Ex commands that run code from a file nothing `require`s: the key has to see that file anyway.
---@type table<string, true>
local DYNLOAD_COMMANDS =
  { runtime = true, source = true, so = true, luafile = true, luf = true, packadd = true }

---Does a string literal name a place outside the project?
---@param s string
---@return boolean
local function outside_literal(s)
  if s == ".." or s:find("^%.%.[/\\]") or s:find("[/\\]%.%.[/\\]") or s:find("[/\\]%.%.$") then
    return true
  end
  if s:find("^%a:[/\\]") or s:find("^~[/\\]") then
    return true
  end
  -- a UNC path: two backslashes and a host (`\\host\share`, `\\.\pipe`), written with doubled backslashes inside
  -- a quoted Lua string. A literal that is only backslashes (`"\\"` is ONE backslash, the separator of a Windows
  -- path) names nothing
  if s:find("^\\\\[%w%.%?]") or s:find("^\\\\\\\\[%w%.%?]") then
    return true
  end
  -- an absolute path with at least two segments (`/etc/hosts`, `/tmp/x/y`); whether it names a real place
  -- outside the project is decided against the file system (`testing.cache`), not here
  return s:find("^/[^/%s]+/[^%s]") ~= nil
end

---Does the code call a function named `environ` that is no member of something (`environ()`, `local environ = ...`
---then `environ()`)? A member (`ctx.environ`, `ctx:environ()`, a table field `environ = fake`) is what a spec injects
---or a context carries, not the process environment; the process environment is reached as `vim.fn.environ`,
---`os_environ` or `call("environ")`, which the other patterns catch.
---@param code string
---@return boolean
local function calls_bare_environ(code)
  for at in code:gmatch("()%f[%w_]environ%s*%(") do
    local prev = code:sub(at - 1, at - 1)
    if prev ~= "." and prev ~= ":" then
      return true
    end
  end
  return false
end

---Is `vim.env` used as a VALUE (assigned, passed on, iterated, returned)? `vim.env.NAME` and `vim.env[...]` are reads of
---one variable (counted elsewhere); `if vim.env then`, `vim.env and ...`, `vim.env == nil` only test that the table
---exists and read nothing.
---@param code string
---@return boolean
local function reads_env_table(code)
  for _, e in code:gmatch("()vim%.env%f[%W]()") do
    local rest = code:sub(e, e + 12):gsub("^%s+", "")
    local nxt = rest:sub(1, 1)
    if nxt ~= "." and nxt ~= "[" and nxt ~= "" then
      local test = rest:find("^then%f[%W]") or rest:find("^and%f[%W]") or rest:find("^[=~]=")
      if not test then
        return true
      end
    end
  end
  return false
end

---Is the literal `".."` only compared with something or searched for as plain text (`seg == ".."`,
---`".." ~= seg`, `ref:find("..", 1, true)`)? That is the test for a parent segment (a path VALIDATOR), no path the
---file reads. Any other use of the literal (a path built or passed on) stays a place outside the project.
---@param text string Text without comments.
---@param str Testing.LuaText.String
---@return boolean
local function compared_not_read(text, str)
  local before = text:sub(math.max(1, str.s - 40), str.s - 1)
  local after = text:sub(str.e + 1, str.e + 40)
  if before:find("[=~]=%s*$") or after:find("^%s*[=~]=") then
    return true
  end
  -- `starts_with(rest, "~/")`, `vim.endswith(path, "..")`: the literal is the prefix or suffix asked for
  if
    before:find("[sS]tarts?_?[wW]ith%s*%(.*,%s*$") or before:find("[eE]nds?_?[wW]ith%s*%(.*,%s*$")
  then
    return true
  end
  return before:find("[:%.]find%s*%(%s*$") ~= nil and after:find("^%s*,%s*1%s*,%s*true%s*%)") ~= nil
end

---@param code string Text without comments and string contents.
---@param text string Text without comments.
---@return Testing.Scan.Markers
---@return string[] outside_paths
---@return table<string, integer> where
local function scan_markers(code, text)
  local where = {}
  ---@param patterns string[]
  ---@param key? string Records the line of the first hit in `where[key]`.
  ---@return boolean
  local function any(patterns, key)
    if not key then
      for _, p in ipairs(patterns) do
        if code:find(p) then
          return true
        end
      end
      return false
    end
    local best
    for _, p in ipairs(patterns) do
      local at = code:find(p)
      if at and (not best or at < best) then
        best = at
      end
    end
    if best then
      where[key] = select(2, code:sub(1, best - 1):gsub("\n", "")) + 1
    end
    return best ~= nil
  end
  ---Does a table that holds hidden inputs travel on without a member access (`local o = os`)?
  ---@param name string A Lua pattern.
  ---@return boolean
  local function aliased(name)
    local pos = 1
    while true do
      local _, e = code:find("[=,%(]%s*" .. name .. "%f[%W]", pos)
      if not e then
        return false
      end
      local nxt, after = code:match("^%s*(.)(.?)", e + 1)
      -- `os = "x"` in a table constructor is a field NAMED os (no alias), `os == x` is a comparison
      local is_key = nxt == "=" and after ~= "="
      if nxt ~= "." and nxt ~= ":" and not is_key then
        return true
      end
      pos = e + 1
    end
  end
  local m = {
    time = any({
      "os%.time%f[%W]",
      "os%.clock%f[%W]",
      "os%.date%f[%W]",
      "hrtime%f[%W]",
      "gettimeofday",
      "clock_gettime",
      "vim%.fn%.localtime",
      "vim%.fn%.strftime",
      "vim%.fn%.reltime",
      "%.now%s*%(", -- uv.now, vim.loop.now: whatever table it travels in
      "%f[%w]uptime%f[%W]",
      "os%[", -- os["time"]: a computed member
      "vim%.fn%[",
      "vim%.uv%[",
      "vim%.loop%[",
    }, "time") or aliased("os") or aliased("vim%.fn") or aliased("vim%.uv") or aliased(
      "vim%.loop"
    ),
    random = any({
      "%.random%s*%(", -- math.random, uv.random
      "vim%.fn%.rand%f[%W]",
      "vim%.fn%.srand",
      "%f[%w]randomseed%f[%W]",
    }, "random"),
    spawn = any({
      "vim%.system%f[%W]",
      "jobstart",
      "termopen",
      "io%.popen",
      "os%.execute",
      "vim%.fn%.system",
      "vim%.fn%.systemlist",
      "%.spawn%s*%(",
      "vim%.cmd%s*%(?%s*%[?[\"']?%s*!",
      "start_blocking",
      "%.start%s*%(%s*{%s*command",
      "vim%.fn%.jobstart",
      "libuv_spawn",
      "run_argv",
    }, "spawn"),
    net = any({
      "curl",
      "tcp_connect",
      "new_tcp",
      "new_udp",
      "getaddrinfo",
      "getnameinfo",
      "vim%.net",
      "http_request",
    }, "net"),
    io = any({
      "io%.open",
      "io%.lines",
      "io%.input",
      "readfile",
      "readblob",
      "dofile",
      "loadfile",
      "fs_open",
      "fs_scandir",
      "fs_stat",
      "fs_lstat",
      "fs_readdir",
      "fs_opendir",
      "fs_read%f[%W]",
      "fs_readfile",
      "vim%.fs%.dir",
      "vim%.fs%.find",
      "vim%.fn%.glob",
      "vim%.fn%.readdir",
      "vim%.fn%.filereadable",
      "vim%.fn%.isdirectory",
      "vim%.fn%.getftime",
      "vim%.fn%.getfsize",
      "vim%.fn%.expand",
      "vim%.fn%.globpath",
      "vim%.fn%.findfile",
      "vim%.fn%.finddir",
      "nvim_get_runtime_file",
      "collect_recursive",
      "luafile",
      "%f[%w]source%f[%W]",
      "%f[%w]runtime%f[%W]",
      "fs%.read",
      "fs_read",
    }),
    dirscan = any({
      "fs_scandir",
      "fs_opendir",
      "fs_readdir",
      "vim%.fs%.dir",
      "vim%.fs%.find",
      "vim%.fn%.glob",
      "vim%.fn%.readdir",
      "vim%.fn%.globpath",
      "nvim_get_runtime_file",
      "collect_recursive",
    }),
    dynload = any({
      "cmd%.runtime",
      "cmd%.source",
      "cmd%.luafile",
      "cmd%.packadd",
      "nvim_get_runtime_file",
    }),
    pathmod = any({
      "package%.path",
      "package%.cpath",
      "package%.loaders",
      "package%.searchers",
      "%f[%w]rtp%f[%W]",
      "runtimepath",
      "packpath",
    }),
    selfscan = false,
    outside = false,
    env = {},
    env_dynamic = false,
    env_computed = false,
    env_whole = false,
  }
  m.selfscan = (m.dirscan or m.dynload)
    and any({
      "nvim_get_runtime_file",
      "debug%.getinfo",
      "getcwd",
      "stdpath",
      "runtimepath",
      "nvim_list_runtime_paths",
    })
  local outside_paths = {}
  -- ex commands and paths inside strings (`vim.cmd("runtime plugin/x.lua")`, `:luafile`, `:edit a.txt`):
  -- the contents of strings are not part of `code`
  for _, str in ipairs(lua_text.strings(text)) do
    local c = str.content
    if #c <= 400 then
      local word = c:match("^%s*:?%s*(%a+)!?%f[%A]")
      if word and FILE_COMMANDS[word] and c:find("%S", #word + 1) then
        m.io = true
        if DYNLOAD_COMMANDS[word] then
          m.dynload = true
        end
      end
      if c:find("dofile%s*%(") or c:find("loadfile%s*%(") then
        m.io = true
      end
      if (c == ".." or c == "../" or c == "~/") and compared_not_read(text, str) then
        -- `seg == ".."`, `ref:find("..", 1, true)`: a test for the word, no path that is read
        c = ""
      end
      if outside_literal(c) then
        m.outside = true
        outside_paths[#outside_paths + 1] = c
      elseif c:find("%s") then
        for piece in c:gmatch("[^%s;]+") do
          -- a lone `..` word is the Lua concatenation operator or prose (`"lua x = a .. b"`), unless the string is
          -- an ex command with a file argument (`edit ..`)
          if (piece ~= ".." or (word and FILE_COMMANDS[word])) and outside_literal(piece) then
            m.outside = true
            outside_paths[#outside_paths + 1] = piece
          end
        end
      end
    end
  end
  -- environment: literal names are collected; a computed name or the whole environment is dynamic
  local names, literal_calls = {}, 0
  for _, pat in ipairs({
    "os%.getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "uv%.os_getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "vim%.fn%.getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "vim%.env%.([%a_][%w_]*)",
    "vim%.env%[%s*[\"']([^\"']+)[\"']%s*%]",
  }) do
    for name in text:gmatch(pat) do
      names[#names + 1] = name
      literal_calls = literal_calls + 1
    end
  end
  local env_calls = count_plain(code, "getenv(")
    + count_plain(code, "getenv (")
    + count_plain(code, "vim.env.")
    + count_plain(code, "vim.env[")
  if env_calls > literal_calls then
    m.env_computed = true
  end
  if
    code:find("fn%.environ%f[%W]")
    or code:find("os_environ")
    or reads_env_table(code)
    or text:find("fn%[%s*[\"']environ[\"']%s*%]")
    or text:find("call%s*%(%s*[\"']environ[\"']")
    or text:find("nvim_call_function%s*%(%s*[\"']environ[\"']")
    or calls_bare_environ(code)
  then
    m.env_whole = true
  end
  m.env_dynamic = m.env_computed or m.env_whole
  m.env = uniq_sorted(names)
  outside_paths = uniq_sorted(outside_paths)
  while #outside_paths > 50 do
    outside_paths[#outside_paths] = nil
  end
  return m, outside_paths, where
end

---Largest number of path-like literals kept per file.
---@type integer
M.MAX_PATHS = 200

---Largest number of names or patterns a file may declare with `-- @cache-env`.
---@type integer
M.MAX_ENV_DECLARED = 64

---Lines of a file scanned for `-- @cache ...` directives.
---@type integer
M.HEADER_LINES = 30

---String literals that look like a relative path (`docs/x.md`, `/README.md`, `fixtures/`, `a/*.lua`).
---@param text string
---@return string[]
local function scan_paths(text)
  local out = {}
  ---@param s string
  local function consider(s)
    if
      #s >= 2
      and #s <= 200
      and not s:find("[%c%s\\%%{}()<>|;,=:\"']")
      and (s:find("/", 1, true) or s:match("%.%a%w?%w?%w?%w?$"))
      and not s:find("^%a[%w+.-]*://")
    then
      out[#out + 1] = s
    end
  end
  for _, str in ipairs(lua_text.strings(text)) do
    local s = str.content
    if #s <= 400 and s:find("[%s;]") and not s:find("%c") then
      -- a command line (`runtime plugin/a.lua`) or a path list (`vendor/?.lua;lua/?.lua`): every word
      for word in s:gmatch("[^%s;]+") do
        consider(word)
      end
    else
      consider(s)
    end
  end
  out = uniq_sorted(out)
  while #out > M.MAX_PATHS do
    out[#out] = nil
  end
  return out
end

---Hidden inputs a file may vouch for with `-- @cache-allow`.
---(`nondeterministic` lifts the mark that the key-flip detection puts on a file whose result changed under an
---unchanged key: see `testing.cache.keylog`.)
---@type table<string, true>
local ALLOWABLE = {
  time = true,
  random = true,
  spawn = true,
  net = true,
  outside = true,
  env = true,
  nondeterministic = true,
}

---`-- @cache off`, `-- @cache-inputs a b c` and `-- @cache-allow time` in the first lines of a file.
---@param text string
---@return { off: boolean, inputs: string[], allow: string[] }
local function scan_directives(text)
  local d = { off = false, inputs = {}, allow = {}, wrapper = {}, env = {} }
  local allowed = {}
  local n = 0
  for line in text:gmatch("[^\r\n]*") do
    n = n + 1
    if n > M.HEADER_LINES then
      break
    end
    local members = require("testing.affected.wrapped").directive(line)
    if members then
      vim.list_extend(d.wrapper, members)
    end
    local body = line:match("^%s*%-%-%s*@cache%s+(.-)%s*$")
    if body and body:match("^off%f[%W]") then
      d.off = true
    end
    local allow = line:match("^%s*%-%-%s*@cache%-allow%s+(.-)%s*$")
    if allow then
      for word in allow:gmatch("%a+") do
        if ALLOWABLE[word] and not allowed[word] then
          allowed[word] = true
          d.allow[#d.allow + 1] = word
        end
      end
    end
    local env = line:match("^%s*%-%-%s*@cache%-env%s+(.-)%s*$")
    if env then
      for word in env:gmatch("%S+") do
        -- a name, or a pattern with `*` (`PREFIX_*`, `*_DIR`, `*` alone for the whole environment)
        if #word <= 100 and word:find("^[%w_%*]+$") and #d.env < M.MAX_ENV_DECLARED then
          d.env[#d.env + 1] = word
        end
      end
    end
    local inputs = line:match("^%s*%-%-%s*@cache%-inputs%s+(.-)%s*$")
    if inputs then
      for word in inputs:gmatch("%S+") do
        if #word <= 200 and #d.inputs < 50 then
          d.inputs[#d.inputs + 1] = word
        end
      end
    end
  end
  return d
end

---Analyze the text of one Lua file.
---@param text string
---@return Testing.Scan.Info
function M.analyze(text)
  local nocomment = lua_text.strip_comments(text)
  local code = lua_text.code_only(text)
  local reqs, prefs, dynamic = scan_requires(nocomment)
  local markers, outside_paths, where = scan_markers(code, nocomment)
  return {
    requires = uniq_sorted(reqs),
    prefixes = uniq_sorted(prefs),
    dynamic = dynamic,
    markers = markers,
    paths = scan_paths(text),
    outside_paths = outside_paths,
    where = where,
    directives = scan_directives(text),
    wrapped = require("testing.affected.wrapped").scan(nocomment, reqs),
  }
end

---@param v any
---@param max integer
---@return boolean
local function string_list(v, max)
  if type(v) ~= "table" or #v > max then
    return false
  end
  local n = 0
  for k, s in pairs(v) do
    n = n + 1
    if type(k) ~= "number" or type(s) ~= "string" or #s > 300 then
      return false
    end
  end
  return n == #v
end

---Validate an analysis that was decoded from disk (untrusted); returns a clean copy.
---@param raw any
---@return Testing.Scan.Info|nil
function M.valid_info(raw)
  if type(raw) ~= "table" or type(raw.markers) ~= "table" or type(raw.directives) ~= "table" then
    return nil
  end
  local m, d = raw.markers, raw.directives
  if
    not (
      string_list(raw.requires, 2000)
      and string_list(raw.prefixes, 2000)
      and type(raw.dynamic) == "boolean"
      and string_list(raw.paths, M.MAX_PATHS)
      and string_list(raw.outside_paths, 50)
      and string_list(m.env, 500)
      and string_list(d.inputs, 50)
      and string_list(d.allow, 8)
      and string_list(d.env == nil and {} or d.env, M.MAX_ENV_DECLARED)
      and type(d.off) == "boolean"
    )
  then
    return nil
  end
  for _, k in ipairs({
    "time",
    "random",
    "spawn",
    "net",
    "io",
    "dirscan",
    "dynload",
    "selfscan",
    "pathmod",
    "outside",
  }) do
    if type(m[k]) ~= "boolean" then
      return nil
    end
  end
  -- an analysis stored before the split into `env_computed` and `env_whole`: a dynamic read counts as the worse
  local env_dynamic = m.env_dynamic == true
  if type(m.env_dynamic) ~= "boolean" then
    return nil
  end
  local env_whole = m.env_whole
  if env_whole == nil then
    env_whole = env_dynamic
  end
  local env_computed = m.env_computed
  if env_computed == nil then
    env_computed = env_dynamic
  end
  if type(env_whole) ~= "boolean" or type(env_computed) ~= "boolean" then
    return nil
  end
  local wrapper = d.wrapper == nil and {} or d.wrapper
  local wrapped = raw.wrapped == nil and {} or raw.wrapped
  wrapped = require("testing.affected.wrapped").valid(wrapped)
  if not (string_list(wrapper, 8) and wrapped) then
    return nil
  end
  local where = {}
  if type(raw.where) == "table" then
    for _, k in ipairs({ "time", "random", "spawn", "net" }) do
      local n = raw.where[k]
      if type(n) == "number" and n >= 1 and n == math.floor(n) and n < 1e9 then
        where[k] = n
      end
    end
  end
  return {
    requires = vim.list_slice(raw.requires, 1),
    where = where,
    prefixes = vim.list_slice(raw.prefixes, 1),
    dynamic = raw.dynamic,
    paths = vim.list_slice(raw.paths, 1),
    outside_paths = vim.list_slice(raw.outside_paths, 1),
    markers = {
      time = m.time,
      random = m.random,
      spawn = m.spawn,
      net = m.net,
      io = m.io,
      dirscan = m.dirscan,
      dynload = m.dynload,
      selfscan = m.selfscan,
      pathmod = m.pathmod,
      outside = m.outside,
      env = vim.list_slice(m.env, 1),
      env_dynamic = env_dynamic,
      env_computed = env_computed,
      env_whole = env_whole,
    },
    directives = {
      off = d.off,
      inputs = vim.list_slice(d.inputs, 1),
      allow = vim.list_slice(d.allow, 1),
      wrapper = vim.list_slice(wrapper, 1),
      env = vim.list_slice(d.env == nil and {} or d.env, 1),
    },
    wrapped = wrapped,
  }
end

---Module name of a project-relative path: `lua/a/b.lua` -> `a.b`, `lua/a/init.lua` -> `a`.
---@param rel string
---@return string|nil
function M.module_of(rel)
  local p = rel:gsub("\\", "/")
  local m = p:match("^lua/(.+)%.lua$")
  if not m then
    return nil
  end
  m = m:gsub("/init$", "")
  if m == "init" or m == "" then
    return nil
  end
  return (m:gsub("/", "."))
end

---Candidate paths (below `lua/`) of a module name.
---@param name string
---@return string[]
function M.candidates(name)
  local p = name:gsub("%.", "/")
  return { "lua/" .. p .. ".lua", "lua/" .. p .. "/init.lua" }
end

---Read a text file of a bounded size.
---@param path string
---@return string|nil text
---@return string|nil err
function M.read_text(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return nil, "not a file"
  end
  if st.size > M.MAX_FILE_BYTES then
    return nil, ("larger than %d bytes"):format(M.MAX_FILE_BYTES)
  end
  return require("lib.nvim.fs.read")(path)
end

---@class Testing.Scan.IndexOpts
---@field extra? string[] More project-relative files to analyze (the specs).
---@field read? fun(path: string): string|nil, string|nil File reader (specs).
---@field analyze? fun(path: string): Testing.Scan.Info|nil Replaces read + analyze (a caller with a persistent analysis cache).

---@class Testing.Scan.Index
---@field root string
---@field modules table<string, string> Module name -> project-relative path.
---@field files table<string, Testing.Scan.Info> Project-relative path -> analysis (only readable files).
---@field unreadable string[] Files that could not be read (too big, permissions): treat as opaque.

---Scan every `lua/**/*.lua` of a root (and any extra relative files) once.
---@param root string
---@param opts? Testing.Scan.IndexOpts
---@return Testing.Scan.Index
function M.index(root, opts)
  opts = opts or {}
  local read = opts.read or M.read_text
  root = vim.fs.normalize(root):gsub("/+$", "")
  local idx = { root = root, modules = {}, files = {}, unreadable = {} }
  local rels = {}
  if vim.fn.isdirectory(root .. "/lua") == 1 then
    local abs = require("lib.nvim.fs.collect_recursive").files(root .. "/lua", {
      ignore = function(p, is_dir)
        return is_dir and p:match("/%.git$") ~= nil
      end,
    })
    for _, p in ipairs(abs) do
      p = vim.fs.normalize(p)
      if p:sub(-4) == ".lua" and p:sub(1, #root + 1) == root .. "/" then
        rels[#rels + 1] = p:sub(#root + 2)
      end
    end
  end
  for _, rel in ipairs(opts.extra or {}) do
    rels[#rels + 1] = rel
  end
  table.sort(rels)
  for _, rel in ipairs(rels) do
    local info, text
    if opts.analyze then
      info = opts.analyze(root .. "/" .. rel)
    else
      text = read(root .. "/" .. rel)
      info = text and M.analyze(text) or nil
    end
    if info then
      idx.files[rel] = info
      local mod = M.module_of(rel)
      if mod then
        -- `a.lua` and `a/init.lua` both name `a`: Lua loads the first found; keep the plain file
        if not idx.modules[mod] or rel:sub(-9) ~= "/init.lua" then
          idx.modules[mod] = rel
        end
      end
    else
      idx.unreadable[#idx.unreadable + 1] = rel
    end
  end
  return idx
end

return M
