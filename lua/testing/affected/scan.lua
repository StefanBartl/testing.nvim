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
M.VERSION = 11

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

---The string literal of `strs` (sorted by position, never overlapping) that holds the byte at `pos`; the quote that
---opens a string is not inside it.
---@param strs Testing.LuaText.String[]
---@param pos integer
---@return Testing.LuaText.String|nil
local function string_at(strs, pos)
  local lo, hi = 1, #strs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local str = strs[mid]
    if pos <= str.s then
      hi = mid - 1
    elseif pos > str.e then
      lo = mid + 1
    else
      return str
    end
  end
  return nil
end

---Number of matches of `pat` in `text`.
---@param text string
---@param pat string
---@return integer
local function count_pattern(text, pat)
  local n = 0
  for _ in text:gmatch(pat) do
    n = n + 1
  end
  return n
end

---Callees whose string argument is an expression or a path the editor expands: `$NAME`, `${NAME}` and a leading `~`
---read the environment (`vim.fn.expand("$HOME/x")`, `vim.fn.exists("$X")`, `vim.api.nvim_eval("$X")`).
---@type table<string, true>
local ENV_EXPRESSION = {
  expand = true,
  expandcmd = true,
  exists = true,
  eval = true,
  nvim_eval = true,
  glob = true,
  globpath = true,
}

---Callees whose string argument is an ex command (`vim.cmd("edit $HOME/x")`, `let x = $X`).
---@type table<string, true>
local ENV_EX_COMMAND =
  { cmd = true, nvim_command = true, nvim_exec = true, nvim_exec2 = true, execute = true }

---How far back from a string literal the call that holds it is looked for.
---@type integer
local ENV_CALL_REACH = 200

---Which environment-expanding call holds the string literal that starts at `at`: `"expression"`, `"ex"` or nil. The
---nearest enclosing call that is one of them decides (a grouping parenthesis or another call in between is
---looked through: `expand(("$X/%s"):format(n))`); `vim.cmd.edit("$X")` is an ex command with a path argument.
---@param code string Text without comments and string contents (same offsets as the literal).
---@param at integer Offset of the opening delimiter of the literal.
---@return "expression"|"ex"|nil
local function env_expander(code, at)
  ---@param callee string
  ---@param head string The text in front of the opening parenthesis (or of the literal).
  ---@return "expression"|"ex"|nil
  local function classify(callee, head)
    if ENV_EXPRESSION[callee] then
      return "expression"
    end
    if ENV_EX_COMMAND[callee] then
      return "ex"
    end
    if FILE_COMMANDS[callee] and head:find("cmd%s*%.%s*[%a_]+%s*$") then
      return "expression"
    end
    return nil
  end
  -- `vim.cmd"edit $X"`, `vim.cmd[[...]]`: the literal is the whole argument list
  local near = code:sub(math.max(1, at - 60), at - 1)
  local direct = near:match("([%a_][%w_]*)%s*$")
  if direct then
    local found = classify(direct, near)
    if found then
      return found
    end
  end
  local depth = 0
  for i = at - 1, math.max(1, at - ENV_CALL_REACH), -1 do
    local ch = code:byte(i)
    if ch == 41 then -- )
      depth = depth + 1
    elseif ch == 40 then -- (
      if depth == 0 then
        local head = code:sub(math.max(1, i - 60), i - 1)
        local callee = head:match("([%a_][%w_]*)%s*$")
        local found = callee and classify(callee, head)
        if found then
          return found
        end
      else
        depth = depth - 1
      end
    end
  end
  return nil
end

---Does an ex command string only press keys (`normal! $a`)? `$` is the end of the line there, no variable.
---@param content string
---@return boolean
local function keystrokes(content)
  return content:find("^%s*:?%s*%d*%s*norm%a*!?%s") ~= nil
end

---Reads of the environment through string arguments that the editor expands: `vim.fn.expand("$X/y")`,
---`vim.fn.exists("$X")`, `vim.api.nvim_eval("$X")`, `vim.cmd("edit ${X}/y")`, `vim.fn.expand("~")` (reads `HOME` or
---`USERPROFILE`). The names are added to `names`. In an ex command only `${NAME}` and an all-upper-case `$NAME` count
---(`1,$d`, `s/x$/y/`, `normal! $a` are no variables). A name that is built at run time (`expand("$" .. name)`) is
---`computed`. The string has to be an argument of such a call: a literal that is kept in a variable first
---(`local p = "$X/y"; vim.fn.expand(p)`) is not followed (a known limit, `docs/CACHE.md`).
---@param text string Text without comments.
---@param strs Testing.LuaText.String[] The string literals of `text`.
---@param names string[] Receives the names of variables read by a literal name.
---@return boolean computed
local function scan_env_strings(text, strs, names)
  local cands = {}
  for _, str in ipairs(strs) do
    local c = str.content
    if #c <= 20000 then
      local tail = c:find("%$[%w_]*$") or c:find("%${[%w_]*$")
      if
        c:find("%$[%a_{]")
        or c:find("^~[/\\]?$")
        or c:find("^~[/\\]")
        or (tail and text:find("^%s*%.%.", str.e + 1))
      then
        cands[#cands + 1] = str
      end
    end
  end
  if #cands == 0 then
    return false
  end
  local code = lua_text.code_only(text)
  local computed = false
  for _, str in ipairs(cands) do
    local kind = env_expander(code, str.s)
    if kind then
      local c = str.content
      local ex = kind == "ex"
      if not (ex and keystrokes(c)) then
        for name in c:gmatch("%$([%a_][%w_]*)") do
          if not ex or name:find("^[A-Z_][A-Z0-9_]+$") then
            names[#names + 1] = name
          end
        end
        for name in c:gmatch("%${([%a_][%w_]*)}") do
          names[#names + 1] = name
        end
        if not ex and (c == "~" or c:find("^~[/\\]")) then
          names[#names + 1] = "HOME"
          names[#names + 1] = "USERPROFILE"
        end
        -- `"$" .. name`, `"${" .. name .. "}"`, `"$PREFIX_" .. suffix`: the name is built at run time
        if (c:find("%$[%w_]*$") or c:find("%${[%w_]*$")) and text:find("^%s*%.%.", str.e + 1) then
          computed = true
        end
      end
    end
  end
  return computed
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
  local strs = lua_text.strings(text)
  -- ex commands and paths inside strings (`vim.cmd("runtime plugin/x.lua")`, `:luafile`, `:edit a.txt`):
  -- the contents of strings are not part of `code`
  for _, str in ipairs(strs) do
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
  -- environment: literal names are collected; a computed name or the whole environment is dynamic.
  -- Every read is counted twice: all of them on `code` (`env_calls`: no string contents, so a string that mentions
  -- `os.getenv("HOME")` adds nothing), and the ones with a literal name (`literal_calls`). More reads than literal
  -- ones means a name is computed. Both counts must see the same text: a literal hit counts only when it STARTS
  -- outside of a string literal (a mention in a string is no call, and must not hide a computed read next to it); its
  -- name is collected all the same (more variables in the key, never fewer).
  local names, literal_calls = {}, 0
  ---A hit of a pattern that names the variable by a literal. `at` is where the hit starts, `after` the position behind it.
  ---@param at integer
  ---@param name string
  ---@param after integer
  ---@param head_of_name? boolean The pattern does not close the call: `os.getenv"X" .. y` builds the name.
  local function literal_hit(at, name, after, head_of_name)
    local inside = string_at(strs, at)
    -- a hit that starts in a string and runs out of it (`"os.getenv", "x"`: the quote that closes one string and
    -- the one that opens the next) is no read at all
    if inside and after - 1 > inside.e then
      return
    end
    if head_of_name and text:find("^%s*%.%.", after) then
      return
    end
    names[#names + 1] = name
    if not inside then
      literal_calls = literal_calls + 1
    end
  end
  for _, pat in ipairs({
    "os%.getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "uv%.os_getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "vim%.fn%.getenv%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    "vim%.env%s*%.%s*([%a_][%w_]*)",
    "vim%.env%s*%[%s*[\"']([^\"']+)[\"']%s*%]",
    -- `vim.fn["getenv"]("X")`, `os["getenv"]("X")`: the member is named by a string
    "%[%s*[\"'][%w_]*getenv[\"']%s*%]%s*%(%s*[\"']([^\"']+)[\"']%s*[%),]",
    -- `vim.fn.call("getenv", { "X" })`, `vim.call("getenv", "X")`, `nvim_call_function("getenv", { "X" })`
    "call%s*%(%s*[\"']getenv[\"']%s*,%s*{?%s*[\"']([^\"']+)[\"']%s*}?%s*[%),]",
    "nvim_call_function%s*%(%s*[\"']getenv[\"']%s*,%s*{%s*[\"']([^\"']+)[\"']%s*}%s*%)",
  }) do
    for at, name, after in text:gmatch("()" .. pat .. "()") do
      literal_hit(at, name, after)
    end
  end
  -- `os.getenv"HOME"` (call without parentheses) and `pcall(os.getenv, "HOME")` (the function handed on with its
  -- name): the literal name is known
  for _, pat in ipairs({
    "%f[%w_]os%.getenv%s*[\"']([^\"']+)[\"']",
    "%f[%w_]os_getenv%s*[\"']([^\"']+)[\"']",
    "%f[%w_]fn%.getenv%s*[\"']([^\"']+)[\"']",
    "pcall%s*%(%s*[%w_%.]*getenv%s*,%s*[\"']([^\"']+)[\"']%s*[%),]",
  }) do
    for at, name, after in text:gmatch("()" .. pat .. "()") do
      literal_hit(at, name, after, true)
    end
  end
  -- a function reference to the environment reader that is not called right away (`pcall(os.getenv, n)`,
  -- `local g = os.getenv`, `os.getenv"X"`): a read, counted like a call so that an unnamed one is a computed name.
  -- Looked for from `getenv` backwards (three characters): a pattern that starts at the beginning of the
  -- identifier run (`[%w_%.]*getenv`) is quadratic in the length of the run
  local bare_refs = 0
  for at, after in code:gmatch("()getenv()") do
    local before = at > 3 and code:sub(at - 3, at - 1) or ""
    if
      (before == "os." or before == "os_" or before == "fn.") and not code:find("^%s*%(", after)
    then
      bare_refs = bare_refs + 1
    end
  end
  -- readers whose name is a string and which `code` cannot show (its strings are empty): `vim.fn.call("getenv", ...)`,
  -- `nvim_call_function("getenv", ...)`, `vim.fn["getenv"](...)`. Each one is a read; a literal name is counted above
  local named_reads = 0
  for _, pat in ipairs({
    "call%s*%(%s*[\"']getenv[\"']",
    "nvim_call_function%s*%(%s*[\"']getenv[\"']",
    "%[%s*[\"'][%w_]*getenv[\"']%s*%]",
  }) do
    for at in text:gmatch("()" .. pat) do
      if not string_at(strs, at) then
        named_reads = named_reads + 1
      end
    end
  end
  local env_calls = bare_refs
    + named_reads
    + count_pattern(code, "getenv%s*%(")
    + count_pattern(code, "vim%.env%s*%.%s*[%a_]")
    + count_pattern(code, "vim%.env%s*%[")
  -- `vim.fn.expand("$X/y")`, `vim.fn.exists("$X")`, `nvim_eval("$X")`, `vim.cmd("edit $X/y")`
  local expanded_computed = scan_env_strings(text, strs, names)
  if env_calls > literal_calls or expanded_computed then
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

---Longest header line (bytes) a directive is read from; the rest of a longer line is not read (the word the cut
---splits is dropped, so a truncated name never reads as another one). A directive line is a handful of words:
---a line this long is a file made to keep the scanner busy.
---@type integer
M.MAX_HEADER_LINE = 16384

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

---The first `max` lines of `text`, counted the way Lua counts them: `\n`, `\r`, `\r\n` and `\n\r` each end ONE line
---(a pattern such as `[^\r\n]*` also yields an empty match after every line, and two for `\r\n`, which would
---halve the window). The line ends are not part of the lines.
---@param text string
---@param max integer
---@return string[]
local function head_lines(text, max)
  local lines, pos, len = {}, 1, #text
  while pos <= len and #lines < max do
    local stop = text:find("[\r\n]", pos)
    if not stop then
      lines[#lines + 1] = text:sub(pos)
      break
    end
    lines[#lines + 1] = text:sub(pos, stop - 1)
    local ch, nxt = text:sub(stop, stop), text:sub(stop + 1, stop + 1)
    if (nxt == "\r" or nxt == "\n") and nxt ~= ch then
      stop = stop + 1
    end
    pos = stop + 1
  end
  return lines
end

---The part of a header line a directive is read from: at most `M.MAX_HEADER_LINE` bytes, cut after a whole word.
---@param line string
---@return string
local function clip_header_line(line)
  if #line <= M.MAX_HEADER_LINE then
    return line
  end
  local cut = line:sub(1, M.MAX_HEADER_LINE)
  if line:sub(M.MAX_HEADER_LINE + 1, M.MAX_HEADER_LINE + 1):find("%s") then
    return cut -- the cut falls between two words
  end
  local n = #cut
  while n > 0 and not cut:sub(n, n):find("%s") do
    n = n - 1
  end
  return cut:sub(1, n)
end

---`-- @cache off`, `-- @cache-inputs a b c` and `-- @cache-allow time` in the first lines of a file.
---
---The patterns take the rest of the line (`(.*)`), never `(.-)%s*$`: that form is quadratic in the whitespace of
---a line such as `-- @cache x` + 40 000 spaces + `y` (the lazy group is extended one byte at a time and `%s*$` runs
---over the rest of the blanks each time). Every reader of a body ignores blanks at its end.
---@param text string
---@return { off: boolean, inputs: string[], allow: string[] }
local function scan_directives(text)
  local d = { off = false, inputs = {}, allow = {}, wrapper = {}, env = {} }
  local allowed = {}
  for _, raw in ipairs(head_lines(text, M.HEADER_LINES)) do
    local line = clip_header_line(raw)
    local members = require("testing.affected.wrapped").directive(line)
    if members then
      vim.list_extend(d.wrapper, members)
    end
    local body = line:match("^%s*%-%-%s*@cache%s+(.*)")
    if body and body:match("^off%f[%W]") then
      d.off = true
    end
    local allow = line:match("^%s*%-%-%s*@cache%-allow%s+(.*)")
    if allow then
      -- only the LEADING run of allowable words counts, and a word is a whole blank-separated token: the prose behind
      -- it (`time (log stamps only; never random numbers)`, `time -- no env`) is not a statement, and it must not
      -- vouch for an input the author named in order to rule it out. A token that is not on the list ends the
      -- directive (fail closed: a comma, `time, random`, grants nothing).
      for word in allow:gmatch("%S+") do
        if not ALLOWABLE[word] then
          break
        end
        if not allowed[word] then
          allowed[word] = true
          d.allow[#d.allow + 1] = word
        end
      end
    end
    local env = line:match("^%s*%-%-%s*@cache%-env%s+(.*)")
    if env then
      for word in env:gmatch("%S+") do
        -- a name, or a pattern with `*` (`PREFIX_*`, `*_DIR`, `*` alone for the whole environment)
        if #word <= 100 and word:find("^[%w_%*]+$") and #d.env < M.MAX_ENV_DECLARED then
          d.env[#d.env + 1] = word
        end
      end
    end
    local inputs = line:match("^%s*%-%-%s*@cache%-inputs%s+(.*)")
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
  -- a byte order mark is no part of the source (Lua skips it): it must not hide the directive of the first line
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
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
