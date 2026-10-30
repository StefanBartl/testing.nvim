---@module 'testing.trust'
---@brief Workspace trust: the runner executes a project's code only for a root the user trusts.
---@description
--- `.testing.lua`, `TESTS/minimal_init.lua` and the specs are Lua that runs with the privileges of the editor. A
--- root is trusted when one of these holds (checked in this order):
---
---   ci      the environment says CI (`CI` set, not empty, not `false`/`0`): a CI job runs in a throwaway machine
---           and the fleet's workflows (`bash scripts/test.sh`) must keep working unchanged
---   env     `TESTING_TRUST=1` (a launcher that IS the project's own code, like this repository's
---           `scripts/test.sh`, says so for the fixture projects its specs build)
---   root    the root lies below one of the directories of `TESTING_TRUST_ROOTS` (a list like PATH: `;` on
---           Windows, `:` elsewhere; only absolute entries count), compared with symlinks resolved (SEC-40)
---   store   the trust store (`stdpath("state")/testing/trust.json`) has an entry for the resolved root whose hash
---           is the sha256 of the current `<root>/.testing.lua` ("none" when there is none): a changed or a new
---           `.testing.lua` is a new question
---
--- The gate is armed by the command-line entry only (`scripts/testing.lua` hands `services.trust` to
--- `testing.cli.main`; `:Testing` starts that entry in a child). A Lua caller of the library (a spec calling
--- `cli.main`, a plugin calling `testing.config.project.load`) already runs code of its own choosing and is not
--- gated. Armed, `M.check(root)` refuses an untrusted root with a message naming the ways to trust it; with
--- `--trust` it stores the root and lets the run go on.
---
--- The store is read as untrusted data (SEC-33): a file that is not a regular file, larger than `MAX_BYTES`, not
--- JSON or not of this schema counts as empty (no trust; never an error that lets a run through); each entry is
--- checked field by field and an invalid one is dropped. It holds the resolved root, the hash and the time it was
--- added, nothing of the file's content; on POSIX it is written with mode 0600.
---
--- Honest limit (D.8): this stops accidents (testing a cloned foreign repository by mistake), not an attacker who
--- can write to the state directory or to the environment. Foreign code belongs in a container or a VM.

local M = {}

M.VERSION = 1

---Largest store file that is read (SEC-32: `MAX_ENTRIES` entries of a long path are far below it; a bigger file
---is not ours and is not parsed).
M.MAX_BYTES = 1024 * 1024

---Most entries kept (SEC-32: a person trusts tens of projects, not thousands; bounds the file and the scan).
M.MAX_ENTRIES = 1000

---Longest root path accepted from the store (SEC-32: Windows long paths stay far below it).
M.MAX_PATH = 1024

---Largest `.testing.lua` that is hashed; `testing.config.project` refuses one far smaller anyway.
M.MAX_HASH_BYTES = 4 * 1024 * 1024

M.ENV_TRUST = "TESTING_TRUST"
M.ENV_ROOTS = "TESTING_TRUST_ROOTS"

---The marker of a refusal in the message (the editor and the specs look for it).
M.REFUSED = "is not trusted"

---@class Testing.Trust.Entry
---@field root string Resolved, normalized, absolute root.
---@field hash string sha256 hex of `<root>/.testing.lua`, or "none".
---@field added integer Unix time.

---@class Testing.Trust.Ctx
---@field env? table<string, string|nil> `CI`, `TESTING_TRUST`, `TESTING_TRUST_ROOTS` (read by the entry script).
---@field save? boolean `--trust`: an untrusted root is stored and the run goes on.
---@field store? string Path of the store (default `M.path()`); a seam for specs.
---@field note? fun(s: string) Where a stored-trust note goes (stderr of the CLI).
---@field is_win? boolean Windows rules (case-insensitive paths, `;` list separator); default: this OS.

---@type Testing.Trust.Ctx|nil
local armed = nil

local uv = vim.uv or vim.loop

---@param ctx? Testing.Trust.Ctx
---@return boolean
local function is_win(ctx)
  if ctx and ctx.is_win ~= nil then
    return ctx.is_win
  end
  return require("testing.platform").is_windows()
end

---Default path of the store.
---@return string
function M.path()
  return vim.fs.normalize(vim.fn.stdpath("state") .. "/testing/trust.json")
end

---The canonical key of a root: symlinks resolved (SEC-40), forward slashes, no trailing slash.
---@param root string
---@return string
function M.key(root)
  local k = require("lib.nvim.fs.normkey")(root, { realpath = true })
  if #k > 1 and not k:match("^%a:/$") then
    k = k:gsub("(.)/+$", "%1")
  end
  return k
end

---@param a string
---@param b string
---@param ctx? Testing.Trust.Ctx
---@return boolean
local function same_key(a, b, ctx)
  -- SEC-31: the comparison is case-insensitive exactly where the file system is (Windows), not by an option
  if is_win(ctx) then
    return a:lower() == b:lower()
  end
  return a == b
end

---sha256 of `<root>/.testing.lua`: "none" when there is no such file, nil when it cannot be read or is too large.
---@param root string
---@return string|nil hash
function M.hash(root)
  local path = vim.fs.normalize(root .. "/" .. require("testing.config.project").FILE_NAME)
  local st = uv.fs_stat(path)
  if not st then
    return "none"
  end
  if st.type ~= "file" or st.size > M.MAX_HASH_BYTES then
    return nil
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil
  end
  return vim.fn.sha256(text)
end

---Is the CI environment set?
---@param v string|nil
---@return boolean
local function truthy(v)
  return type(v) == "string" and v ~= "" and v:lower() ~= "false" and v ~= "0"
end

---@param v any
---@return boolean
local function is_abs(v)
  return type(v) == "string" and (v:match("^/") ~= nil or v:match("^%a:[/\\]") ~= nil)
end

---The directories of `TESTING_TRUST_ROOTS`: split like PATH, empty and relative entries dropped (a relative entry
---would be relative to whatever directory a run starts in).
---@param value string|nil
---@param ctx? Testing.Trust.Ctx
---@return string[] roots
---@return string[] dropped
function M.split_roots(value, ctx)
  local out, dropped = {}, {}
  if type(value) ~= "string" or value == "" then
    return out, dropped
  end
  local sep = is_win(ctx) and ";" or ":"
  for part in (value .. sep):gmatch("(.-)" .. vim.pesc(sep)) do
    part = vim.trim(part)
    if part ~= "" then
      if is_abs(part) and #part <= M.MAX_PATH and not part:find("%c") then
        out[#out + 1] = part
      else
        dropped[#dropped + 1] = part
      end
    end
  end
  return out, dropped
end

---One entry of the store, checked field by field (SEC-33). Unknown keys are ignored.
---@param e any
---@return Testing.Trust.Entry|nil
local function valid_entry(e)
  if type(e) ~= "table" then
    return nil
  end
  local root, hash, added = e.root, e.hash, e.added
  if
    type(root) ~= "string"
    or root == ""
    or #root > M.MAX_PATH
    or root:find("%c")
    or not is_abs(root)
  then
    return nil
  end
  if type(hash) ~= "string" or not (hash == "none" or hash:match("^%x+$") and #hash == 64) then
    return nil
  end
  if hash ~= "none" and hash:lower() ~= hash then
    return nil
  end
  if
    added ~= nil
    and (
      type(added) ~= "number"
      or added ~= added
      or added < 0
      or added ~= math.floor(added)
      or added > 9e15
    )
  then
    return nil
  end
  return { root = root, hash = hash, added = added or 0 }
end

---Read the store. Never raises; anything unusable is an empty store and a note.
---@param path? string
---@return Testing.Trust.Entry[] entries
---@return string|nil note
function M.read(path)
  path = path or M.path()
  local st = uv.fs_stat(path)
  if not st then
    return {}, nil
  end
  if st.type ~= "file" or st.size > M.MAX_BYTES then
    return {},
      ("trust store %s is not a regular file or larger than %d bytes: no root is trusted from it"):format(
        path,
        M.MAX_BYTES
      )
  end
  local text, rerr = require("lib.nvim.fs.read")(path)
  if not text then
    return {}, ("trust store %s cannot be read: %s"):format(path, tostring(rerr))
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if
    not ok
    or type(decoded) ~= "table"
    or decoded.v ~= M.VERSION
    or type(decoded.entries) ~= "table"
  then
    return {},
      ("trust store %s is not a trust store of version %d: no root is trusted from it"):format(
        path,
        M.VERSION
      )
  end
  local out, dropped = {}, 0
  for i, e in ipairs(decoded.entries) do
    if i > M.MAX_ENTRIES then
      dropped = dropped + (#decoded.entries - M.MAX_ENTRIES)
      break
    end
    local v = valid_entry(e)
    if v then
      out[#out + 1] = v
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    return out,
      ("trust store %s: %d unusable entr%s ignored"):format(
        path,
        dropped,
        dropped == 1 and "y" or "ies"
      )
  end
  return out, nil
end

---Write the store atomically (0600 on POSIX).
---@param path string
---@param entries Testing.Trust.Entry[]
---@return boolean ok
---@return string|nil err
local function write(path, entries)
  local text, eerr = require("lib.nvim.json").encode({ v = M.VERSION, entries = entries })
  if not text then
    return false, "cannot encode the trust store: " .. tostring(eerr)
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not ok then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  if not require("testing.platform").is_windows() then
    pcall(uv.fs_chmod, path, 384)
  end
  return true, nil
end

---Change the store under its lock: `fn(entries)` returns the new list.
---@param path string
---@param fn fun(entries: Testing.Trust.Entry[]): Testing.Trust.Entry[]
---@return boolean ok
---@return string|nil err
local function update(path, fn)
  local locked, ok, err = require("testing.statelock").with(path, function()
    local entries = M.read(path)
    local new = fn(entries)
    while #new > M.MAX_ENTRIES do
      table.remove(new, 1)
    end
    return write(path, new)
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err
end

---Store `root` as trusted with the hash of its current `.testing.lua`.
---@param root string
---@param ctx? Testing.Trust.Ctx
---@return boolean ok
---@return string key_or_err The stored key, or why nothing was stored.
function M.add(root, ctx)
  local hash = M.hash(root)
  if not hash then
    return false,
      ("cannot hash %s/.testing.lua (not a regular file, unreadable or too large)"):format(root)
  end
  local key = M.key(root)
  local path = (ctx and ctx.store) or M.path()
  local ok, err = update(path, function(entries)
    local out = {}
    for _, e in ipairs(entries) do
      if not same_key(e.root, key, ctx) then
        out[#out + 1] = e
      end
    end
    out[#out + 1] = { root = key, hash = hash, added = os.time() }
    return out
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, key
end

---Remove `root` from the store.
---@param root string
---@param ctx? Testing.Trust.Ctx
---@return boolean ok
---@return integer|string removed_or_err How many entries were removed, or why the store was not changed.
function M.revoke(root, ctx)
  local key = M.key(root)
  local path = (ctx and ctx.store) or M.path()
  local removed = 0
  local ok, err = update(path, function(entries)
    local out = {}
    for _, e in ipairs(entries) do
      if same_key(e.root, key, ctx) then
        removed = removed + 1
      else
        out[#out + 1] = e
      end
    end
    return out
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, removed
end

---@class Testing.Trust.Decision
---@field trusted boolean
---@field how? "ci"|"env"|"root"|"store" Why it is trusted.
---@field why? "unknown"|"changed"|"unhashable" Why it is not.
---@field key string The resolved root.
---@field entry? Testing.Trust.Entry The store entry of the root, if any.
---@field notes string[] Store and environment problems.

---Is `root` trusted?
---@param root string
---@param ctx? Testing.Trust.Ctx
---@return Testing.Trust.Decision
function M.decide(root, ctx)
  ctx = ctx or {}
  local env = ctx.env or {}
  local key = M.key(root)
  ---@type Testing.Trust.Decision
  local d = { trusted = false, key = key, notes = {} }
  if truthy(env.CI) then
    d.trusted, d.how = true, "ci"
    return d
  end
  if env[M.ENV_TRUST] == "1" then
    d.trusted, d.how = true, "env"
    return d
  end
  local roots, dropped = M.split_roots(env[M.ENV_ROOTS], ctx)
  for _, p in ipairs(dropped) do
    d.notes[#d.notes + 1] = ("%s: entry %q ignored (not an absolute path)"):format(
      M.ENV_ROOTS,
      (p:sub(1, 80):gsub("%c", "?"))
    )
  end
  local is_subpath = require("lib.nvim.fs.is_subpath")
  for _, r in ipairs(roots) do
    if is_subpath(key, r, { realpath = true, ignore_case = is_win(ctx) }) then
      d.trusted, d.how = true, "root"
      return d
    end
  end
  local entries, note = M.read(ctx.store)
  if note then
    d.notes[#d.notes + 1] = note
  end
  for _, e in ipairs(entries) do
    if same_key(e.root, key, ctx) then
      d.entry = e
    end
  end
  local hash = M.hash(root)
  if not hash then
    d.why = "unhashable"
  elseif d.entry and d.entry.hash == hash then
    d.trusted, d.how = true, "store"
  elseif d.entry then
    d.why = "changed"
  else
    d.why = "unknown"
  end
  return d
end

---The message of a refusal.
---@param root string
---@param d Testing.Trust.Decision
---@return string
function M.refusal(root, d)
  local cause = ({
    changed = "its .testing.lua changed since it was trusted",
    unhashable = "its .testing.lua cannot be read to compare it with the trusted one",
  })[d.why] or "it is neither in the trust store nor below TESTING_TRUST_ROOTS"
  -- one line: the CI document and the conformance report show a message on one line
  return (
    "%s %s: %s; running it would execute its .testing.lua, TESTS/minimal_init.lua and specs. "
    .. "Trust it with `testing trust add <root>` or --trust (stored), or list your own directories in "
    .. 'TESTING_TRUST_ROOTS; CI=true trusts every root (docs/CONFIG.md, "Workspace trust")'
  ):format(root, M.REFUSED, cause)
end

---Arm the gate for this process (the CLI entry does, for the duration of one `cli.main`).
---@param ctx Testing.Trust.Ctx|nil nil disarms.
---@return Testing.Trust.Ctx|nil previous
function M.arm(ctx)
  local prev = armed
  armed = ctx
  return prev
end

---The armed context, if any.
---@return Testing.Trust.Ctx|nil
function M.armed()
  return armed
end

---The gate: nil when `root` may run (the gate is not armed, or the root is trusted), else the refusal. With
---`--trust` an untrusted root is stored first. Never raises.
---@param root string
---@return string|nil refusal
function M.check(root)
  local ctx = armed
  if not ctx then
    return nil
  end
  local ok, d = pcall(M.decide, root, ctx)
  if not ok then
    -- fail closed: a gate that cannot decide refuses
    return ("%s %s: the trust check failed: %s"):format(root, M.REFUSED, tostring(d))
  end
  for _, n in ipairs(d.notes) do
    if ctx.note then
      pcall(ctx.note, "testing: note: " .. n)
    end
  end
  if d.trusted then
    return nil
  end
  if ctx.save then
    local stored, key_or_err = M.add(root, ctx)
    if ctx.note then
      pcall(
        ctx.note,
        stored
            and ("testing: note: --trust: %s is trusted from now on (%s)"):format(
              key_or_err,
              ctx.store or M.path()
            )
          or ("testing: warning: --trust: not stored (%s); trusted for this run only"):format(
            key_or_err
          )
      )
    end
    return nil
  end
  return M.refusal(root, d)
end

M.USAGE = table.concat({
  "usage: testing trust list | check [<root>] | add [<root>] | revoke [<root>]",
  "  list           the trusted roots of the store, TESTING_TRUST_ROOTS and the environment",
  "  check [<root>] is <root> (default: the current directory) trusted? exit 0 yes, 1 no",
  "  add [<root>]   trust <root> with its current .testing.lua",
  "  revoke [<root>] remove <root> from the store (exit 1 when it was not there)",
}, "\n")

---`testing trust ...`.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), cwd?: string }
---@param ctx? Testing.Trust.Ctx
---@return integer code
function M.main(argv, sv, ctx)
  ctx = ctx or armed or {}
  local sub, target = argv[1], argv[2]
  if sub == nil or sub == "-h" or sub == "--help" or sub == "help" then
    sv.out(M.USAGE)
    return sub == nil and 2 or 0
  end
  if #argv > 2 or (target and target:sub(1, 1) == "-") then
    sv.err(
      "testing trust: unexpected argument " .. tostring(argv[#argv]):sub(1, 80):gsub("%c", "?")
    )
    sv.err(M.USAGE)
    return 2
  end
  local root
  if sub ~= "list" then
    root = vim.fs
      .normalize(vim.fn.fnamemodify(target or sv.cwd or vim.fn.getcwd(), ":p"))
      :gsub("/+$", "")
    if vim.fn.isdirectory(root) ~= 1 then
      sv.err(("testing trust: not a directory: %s"):format(root))
      return 2
    end
  elseif target then
    sv.err("testing trust: `list` takes no argument")
    return 2
  end
  if sub == "list" then
    local entries, note = M.read(ctx.store)
    if note then
      sv.err("testing: note: " .. note)
    end
    local env = ctx.env or {}
    if truthy(env.CI) then
      sv.out("CI is set: every root is trusted")
    end
    if env[M.ENV_TRUST] == "1" then
      sv.out(M.ENV_TRUST .. "=1: every root is trusted")
    end
    for _, r in ipairs((M.split_roots(env[M.ENV_ROOTS], ctx))) do
      sv.out(("root   %s (%s)"):format(r, M.ENV_ROOTS))
    end
    for _, e in ipairs(entries) do
      local state
      if vim.fn.isdirectory(e.root) ~= 1 then
        state = "missing"
      else
        state = M.hash(e.root) == e.hash and "ok" or "changed"
      end
      sv.out(
        ("stored %s  %s  %s  %s"):format(
          e.root,
          e.hash == "none" and "no .testing.lua" or e.hash:sub(1, 12),
          os.date("!%Y-%m-%d", e.added),
          state
        )
      )
    end
    if #entries == 0 then
      sv.out("(the trust store is empty: " .. (ctx.store or M.path()) .. ")")
    end
    return 0
  elseif sub == "check" then
    local d = M.decide(root, ctx)
    for _, n in ipairs(d.notes) do
      sv.err("testing: note: " .. n)
    end
    if d.trusted then
      sv.out(("%s is trusted (%s)"):format(d.key, d.how))
      return 0
    end
    sv.out(M.refusal(root, d))
    return 1
  elseif sub == "add" then
    local ok, key_or_err = M.add(root, ctx)
    if not ok then
      sv.err("testing trust: " .. key_or_err)
      return 3
    end
    sv.out(("trusted: %s"):format(key_or_err))
    return 0
  elseif sub == "revoke" then
    local ok, n = M.revoke(root, ctx)
    if not ok then
      sv.err("testing trust: " .. tostring(n))
      return 3
    end
    if n == 0 then
      sv.out(("not in the trust store: %s"):format(M.key(root)))
      return 1
    end
    sv.out(("revoked: %s"):format(M.key(root)))
    return 0
  end
  sv.err("testing trust: unknown subcommand " .. (tostring(sub):sub(1, 40):gsub("%c", "?")))
  sv.err(M.USAGE)
  return 2
end

return M
