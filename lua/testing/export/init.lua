---@module 'testing.export'
-- @cache-allow env
---@brief The machine contract `testing-export/1`: the documents of the fleet, of one repository and of an export folder.
---@description
--- An app, a web page or a panel reads these documents and nothing else of testing.nvim: no `last.json`, no
--- `runs.jsonl`, no IR. The engine writes them, never the app. Three kinds (`kind`):
---
---   fleet      one row per repository: the last local result, the last green run, the last local pipeline run
---              (`ci.json`), the CI adapter's record (`testing ci remote`), counts
---   repo       one repository: the same row and its red cases (message, expected, actual), redacted
---   manifest   the table of contents of an export folder: `files[{ path, sha256, bytes }]`
---
--- Every document starts with the same head: `schema` ("testing-export/1"), `plugin`, `kind`, `form`,
--- `generated_at`, `engine`, `rev` (what the sources looked like), `digest` (the hash of the content WITHOUT
--- `generated_at` and `engine`: two documents of an unchanged state have the same digest), `capabilities`. The
--- manifest's `rev` and `digest` follow the path and digest of each file, never its bytes (which hold the time).
--- `M.export` with `previous` (the folder as it is) keeps `generated_at` and `engine` of a document whose digest did
--- not change: an unchanged state is the same bytes.
---
--- Two forms. `local` is for a process on this machine (the hub): the head and each row carry `root`, the absolute
--- directory. `export` is for a folder, a web page or a panel: no absolute path anywhere, and the document is refused
--- (an error, never a leaky document) when the detector `M.leaks` still finds a path of this machine, the home
--- directory or the user name in it. Free texts are redacted in BOTH forms the way the IR redacts a message
--- (`testing.run.inproc.redact_text`: `<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`, user, host, `NAME=value` pairs of
--- the environment), the bare value of a secret of the environment (`M.secrets`) becomes `<ENV>`, then every absolute
--- path left becomes `<PATH>` (`testing.ci.overview.clean`: drive, UNC with either slash, POSIX, `file:` URIs).
---
--- Sources (nothing is written but the CI adapter's ETag cache in the state directory, with `remote`): the repository list (the index of the fleet: the detection of `testing ci overview`, below a
--- `--repos-root`: workflows, a `ci` section or any `.testing.lua`, no vaults, `lib.nvim` included), `last.json`
--- (`testing.state`), `last_green.json` (`testing.run.green`), `ci.json` of the state directory, git for the head and
--- the CI adapter (`testing.ci.remote.collect`). Nothing here runs a suite, a pipeline or a repository's
--- `.testing.lua` (the CI adapter reads its `ci_remote` section, as `testing ci remote` does).
---
--- Rules a reader keeps (`M.read`): a higher `schema` is refused, unknown fields are ignored, a missing or `null`
--- value is unknown (never 0), a document is at most 8 MiB. Additions come without a new version and are announced in
--- `capabilities`; a break is `testing-export/2`. The JSON Schema is `schemas/testing-export/1/`.
---
--- The command `testing call fleet|repo` (`testing.export.call`) prints the documents; the writing of an export
--- folder (`testing export --out`) builds on `M.export`, which returns the files and the manifest.

local M = {}

M.SCHEMA_VERSION = 1
M.SCHEMA = "testing-export/" .. M.SCHEMA_VERSION
M.PLUGIN = "testing.nvim"
M.ENGINE_VERSION = "0.1.0-dev"

---What this engine writes; sorted.
---@type string[]
M.CAPABILITIES = { "fleet", "manifest", "repo" }

---The kinds a reader of this version knows.
---@type table<string, true>
M.KINDS = { fleet = true, repo = true, manifest = true }

---A document is never bigger (`payload_too_large`).
M.MAX_DOC_BYTES = 8 * 1024 * 1024
---Bytes of a failure text (message, expected, actual, a failing assertion) per field.
M.TEXT_MAX = 4096
---Bytes of a note, a title, a name.
M.NOTE_MAX = 300
---Red cases listed in a `repo` document; the rest is counted in `cases_omitted`.
M.MAX_CASES = 500
---The name of the manifest in an export folder.
M.MANIFEST = "testing-export.json"
---Where the JSON Schema of this version lives, relative to the plugin.
M.SCHEMA_FILE = "schemas/testing-export/1/testing-export.schema.json"

---The statuses of a case, in the order of the IR.
M.STATUSES = { "pass", "fail", "error", "skip", "xfail", "xpass", "timeout", "crash" }

local CI_VERDICTS =
  { green = true, ["green-partial"] = true, red = true, error = true, infra = true }

local NIL = vim.NIL

local plugin_root = vim.fs.dirname(
  vim.fs.dirname(
    vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
  )
)
M.PLUGIN_ROOT = plugin_root

local json = require("lib.nvim.json.canonical")

---@type Lib.Contract.Doc|nil
local builder_cache

---Head, seal, canonical bytes and the 8 MiB limit are `lib.nvim.contract.doc`'s; what a document contains is this
---module's.
---@return Lib.Contract.Doc
local function builder()
  if not builder_cache then
    builder_cache = require("lib.nvim.contract.doc").new({
      plugin = M.PLUGIN,
      schema = M.SCHEMA_VERSION,
      scope_key = "source",
      engine_version = M.ENGINE_VERSION,
      plugin_root = plugin_root,
      max_bytes = M.MAX_DOC_BYTES,
    })
  end
  return builder_cache
end

---The time a document is stamped with (UTC, `YYYY-MM-DDTHH:MM:SSZ`). A seam: golden files set a fixed one.
---@return string
function M.clock()
  return builder().clock()
end

---What the head says about the engine (same seam, same reason).
---@return { version: string, git: string, nvim: string }
function M.engine_info()
  return builder().engine_info()
end

---The key of a repository in every document: `<basename>-<12 hex>` of the directory name and the repository's
---identity (`M.deps.identity`), never of its absolute path. The same repository below another folder, in a second
---clone or on another machine has the same key, and the key gives away no path of this machine.
---@param dir string
---@param identity string|nil
---@return string
function M.repo_key(dir, identity)
  local name = vim.fs.basename(dir)
  local safe = name:gsub("[^%w_.%-]", "_")
  return safe .. "-" .. vim.fn.sha256(name .. "\n" .. (identity or "")):sub(1, 12)
end

---Replaced by a spec: the key of a repository, its head and the CI adapter.
M.deps = {
  ---The identity of a repository: its root commit (the smallest one when the history has several), nil outside git
  ---or without a commit. The same in every clone of the repository, wherever it lives.
  ---@param dir string
  ---@return string|nil
  identity = function(dir)
    local res = require("lib.nvim.git").run(
      { "rev-list", "--max-parents=0", "HEAD" },
      { dir = dir, timeout_ms = 10000, read_only = true, no_lazy_fetch = true }
    )
    if not res or res.code ~= 0 or type(res.stdout) ~= "string" then
      return nil
    end
    local roots = {}
    for sha in res.stdout:gmatch("%x+") do
      if #sha >= 40 then
        roots[#roots + 1] = sha:lower()
      end
    end
    table.sort(roots)
    return roots[1]
  end,
  ---The key of a repository (`M.repo_key` of its identity).
  ---@param dir string
  ---@return string
  key = function(dir)
    return M.repo_key(dir, M.deps.identity(dir))
  end,
  ---The checkout now, nil outside git.
  ---@param dir string
  ---@return { sha: string, branch: string|nil, dirty: boolean|nil }|nil
  head = function(dir)
    local git = require("lib.nvim.git")
    local o = { dir = dir }
    local sha = git.head_hash(o)
    if not sha or not sha:match("^%x+$") then
      return nil
    end
    return { sha = sha:lower(), branch = git.current_branch(o), dirty = git.is_dirty(o) }
  end,
  ---The records of the CI adapter.
  ---@param repos { dir: string, from_root: boolean }[]
  ---@param opts { state_dir: string }
  ---@return table[] records
  ---@return table info
  remote = function(repos, opts)
    return require("testing.ci.remote").collect(repos, opts)
  end,
}

-- ── small helpers ────────────────────────────────────────────────────────────

---@param v any
---@return any
local function nn(v)
  if v == nil then
    return NIL
  end
  return v
end

---@param v any
---@return string|nil
local function str(v)
  return type(v) == "string" and v or nil
end

---@param v any
---@return integer|nil
local function int(v)
  if type(v) == "number" and v == math.floor(v) and v >= 0 and v < 2 ^ 53 then
    return v
  end
  return nil
end

---@param ts any Seconds since the epoch.
---@return string|nil
local function iso(ts)
  if type(ts) ~= "number" or ts ~= ts or ts < 0 or ts > 4102444800 then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ts)) --[[@as string]]
end

---@param s any
---@return string|nil
local function time_text(s)
  if type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
    return s
  end
  return nil
end

---@param s any
---@return string|nil
local function hex(s)
  if type(s) == "string" and #s <= 64 and s:match("^%x+$") then
    return s:lower()
  end
  return nil
end

---@param url any
---@return string|nil
local function github_url(url)
  if type(url) == "string" and #url <= 500 and url:match("^https://github%.com/[%w%-_./]+$") then
    return url
  end
  return nil
end

---A free text redacted as the IR redacts a message, every absolute path left `<PATH>`, bounded.
---@param s any
---@param dir string The repository (`<REPO>`).
---@param state_dir? string `<STATE>`.
---@param max? integer Default `NOTE_MAX`.
---@param keep_newlines? boolean
---@return string|nil
function M.clean(s, dir, state_dir, max, keep_newlines)
  if type(s) == "string" then
    s = M.redact_secrets(s)
  end
  return require("testing.ci.overview").clean(
    s,
    dir,
    state_dir,
    { max = max or M.NOTE_MAX, keep_newlines = keep_newlines }
  )
end

---The name of an environment variable whose value is a secret (a token, a password, a key).
local SECRET_NAME =
  { "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "AUTH", "CREDENTIAL" }

---A secret this short is no secret worth a placeholder (and would hit ordinary words).
M.SECRET_MIN = 8

---@type string[]|nil
local secrets_cache

---The values of the environment variables that hold a secret (`SECRET_NAME`), longest first. Cached while a document
---is built (`protect`), read fresh otherwise.
---Reading the whole environment here is why the header says `-- @cache-allow env` (as `testing.run.inproc` does for
---the same redaction): the values only become `<ENV>`, they never decide what else a document holds.
---@return string[]
function M.secrets()
  if secrets_cache then
    return secrets_cache
  end
  local out = {}
  for name, value in pairs(vim.fn.environ()) do
    local upper = type(name) == "string" and name:upper() or ""
    if type(value) == "string" and #value >= M.SECRET_MIN then
      for _, part in ipairs(SECRET_NAME) do
        if upper:find(part, 1, true) then
          out[#out + 1] = value
          break
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return out
end

---A free text with every secret of the environment (a bare value, not only `NAME=value`) replaced by `<ENV>`.
---@param s string
---@return string
function M.redact_secrets(s)
  for _, v in ipairs(M.secrets()) do
    if s:find(v, 1, true) then
      s = s:gsub(vim.pesc(v), "<ENV>")
    end
  end
  return s
end

---@param path string
---@return string|nil text
local function read_text(path)
  return require("lib.nvim.fs.read_bounded")(path, 16 * 1024 * 1024)
end

---The hash of a source file for `rev`, of its text with the paths of this machine replaced by their placeholders
---(the redaction of the IR): the same state in another checkout, below another home, has the same rev.
---@param text string|nil
---@param dir string
---@param state_dir? string
---@return string
local function sha_or_dash(text, dir, state_dir)
  if not text then
    return "-"
  end
  local redacted = require("testing.run.inproc").redact_text(text, dir, { state = state_dir })
  return vim.fn.sha256(redacted):sub(1, 16)
end

-- ── the sources of one repository ───────────────────────────────────────────

---@class Testing.Export.Sources
---@field st Testing.State
---@field green Testing.Green.Record|nil
---@field ci table|nil
---@field notes string[]
---@field rev string The rev line of this repository.

---@param dir string
---@param state_dir? string
---@param remote_rec? table
---@param key string
---@return Testing.Export.Sources
local function sources(dir, state_dir, remote_rec, key)
  local sopts = { state_dir = state_dir }
  local state = require("testing.state")
  local sdir = require("testing.history").dir(dir, sopts)
  local st = state.load(dir, sopts)
  local notes = vim.list_slice(st.notes or {}, 1)
  local green, green_note = require("testing.run.green").load(dir, sopts)
  if green_note then
    notes[#notes + 1] = green_note
  end
  local ci_text = read_text(sdir .. "/ci.json")
  local ci
  if ci_text then
    local ok, decoded = pcall(vim.json.decode, ci_text)
    if ok and type(decoded) == "table" then
      ci = decoded
    else
      notes[#notes + 1] = sdir .. "/ci.json is not valid JSON: ignored"
    end
  end
  local run = remote_rec and type(remote_rec.run) == "table" and remote_rec.run or {}
  local rev = table.concat({
    key,
    "last:" .. sha_or_dash(read_text(state.path(dir, sopts)), dir, state_dir),
    "green:"
      .. sha_or_dash(read_text(require("testing.run.green").path(dir, sopts)), dir, state_dir),
    "ci:" .. sha_or_dash(ci_text, dir, state_dir),
    ("remote:%s:%s:%s"):format(
      tostring(remote_rec and remote_rec.overall or "-"),
      tostring(run.id or "-"),
      tostring(run.updated_at or "-")
    ),
  }, "\t")
  return { st = st, green = green, ci = ci, notes = notes, rev = rev }
end

---@param st Testing.State
---@param green Testing.Green.Record|nil
---@return table|vim.NIL local
---@return table|vim.NIL counts
local function local_part(st, green)
  if not st.run and #st.cases == 0 then
    return NIL, NIL
  end
  local snap = require("testing.state").snapshot(st)
  local summary = json.object({})
  for _, s in ipairs(M.STATUSES) do
    summary[s] = int(snap.summary[s]) or 0
  end
  local verdict = "green"
  if snap.failed > 0 then
    verdict = "red"
  elseif snap.partial or summary.skip > 0 then
    verdict = "green-partial"
  end
  local flaky = 0
  for _, c in ipairs(st.cases) do
    if c.flaky then
      flaky = flaky + 1
    end
  end
  local commit = green and st.run and green.run == st.run and hex(green.sha) or nil
  return {
    run_id = nn(str(st.run)),
    ts = nn(iso(st.ts)),
    verdict = verdict,
    summary = summary,
    cases = snap.cases,
    files = snap.files,
    partial = snap.partial == true,
    stale = snap.stale,
    commit = nn(commit),
  }, { fail = snap.failed, flaky = flaky }
end

---@param doc table|nil The decoded `ci.json`.
---@param dir string
---@param state_dir? string
---@return table|vim.NIL
local function ci_local_part(doc, dir, state_dir)
  if not doc or not CI_VERDICTS[doc.verdict] then
    return NIL
  end
  local function bool(v)
    if type(v) == "boolean" then
      return v
    end
    return NIL
  end
  return {
    verdict = doc.verdict,
    profile = nn(M.clean(str(doc.profile), dir, state_dir)),
    partial = bool(doc.partial),
    commit = nn(hex(doc.commit)),
    tree = nn(hex(doc.tree)),
    dirty = bool(doc.dirty),
    first_red = nn(M.clean(str(doc.first_red), dir, state_dir)),
    time = nn(time_text(doc.time)),
  }
end

local REMOTE_STATES = {}
for _, s in ipairs({
  "failure",
  "rejected",
  "cancelled",
  "unknown",
  "waiting_runner",
  "queued",
  "running",
  "success",
  "skipped",
  "no_run",
  "no_github",
}) do
  REMOTE_STATES[s] = true
end

---The note of a repository the CI adapter was asked about and gave no record for.
M.NO_RECORD = "the CI adapter gave no record (see remote.error)"

---@param rec table|vim.NIL|nil A record of the CI adapter; `vim.NIL`: asked, no record; nil: not asked.
---@param dir string
---@param state_dir? string
---@return table|vim.NIL
local function ci_remote_part(rec, dir, state_dir)
  if not rec then
    return NIL
  end
  if rec == NIL then
    -- asked, but the adapter gave no record for this directory (it failed, or skipped it): unknown, never "not asked"
    local none = json.object({})
    for _, sys in ipairs({ "ubuntu", "windows", "macos" }) do
      none[sys] = NIL
    end
    return {
      state = "unknown",
      repo = NIL,
      sha = NIL,
      branch = NIL,
      workflow = NIL,
      os = none,
      run = NIL,
      note = M.NO_RECORD,
    }
  end
  local function state_of(s)
    return REMOTE_STATES[s] and s or "unknown"
  end
  local os_ = json.object({})
  for _, sys in ipairs({ "ubuntu", "windows", "macos" }) do
    local cell = type(rec.os) == "table" and rec.os[sys] or nil
    if type(cell) == "table" then
      os_[sys] = {
        state = state_of(cell.state),
        url = nn(github_url(cell.url)),
        job = nn(M.clean(str(cell.job), dir, state_dir)),
      }
    else
      os_[sys] = NIL
    end
  end
  local run = NIL
  if type(rec.run) == "table" then
    local r = rec.run
    run = {
      id = nn(int(r.id)),
      url = nn(github_url(r.url)),
      status = nn(M.clean(str(r.status), dir, state_dir)),
      conclusion = nn(M.clean(str(r.conclusion), dir, state_dir)),
      created_at = nn(time_text(r.created_at)),
      updated_at = nn(time_text(r.updated_at)),
      event = nn(M.clean(str(r.event), dir, state_dir)),
      attempt = nn(int(r.attempt)),
    }
  end
  local repo = str(rec.owner) and str(rec.repo) and (rec.owner .. "/" .. rec.repo) or nil
  if repo and not repo:match("^[%w%-_.]+/[%w%-_.]+$") then
    repo = nil
  end
  return {
    state = state_of(rec.overall),
    repo = nn(repo),
    sha = nn(hex(rec.sha)),
    branch = nn(M.clean(str(rec.branch), dir, state_dir)),
    workflow = nn(M.clean(str(rec.workflow), dir, state_dir)),
    os = os_,
    run = run,
    note = nn(M.clean(str(rec.note), dir, state_dir)),
  }
end

---The row of one repository and what its documents need besides.
---@param dir string Absolute.
---@param ctx { form: "local"|"export", state_dir?: string, remote: table<string, table>|nil }
---@return table row
---@return Testing.Export.Sources src
local function row_of(dir, ctx)
  local rec = ctx.remote and ctx.remote[dir] or nil
  local key = M.deps.key(dir, ctx.state_dir)
  local src = sources(dir, ctx.state_dir, rec, key)
  local h = M.deps.head(dir)
  local head = NIL
  if h then
    local dirty = NIL
    if type(h.dirty) == "boolean" then
      dirty = h.dirty -- `x and false or y` would turn a clean tree into unknown
    end
    head = {
      sha = nn(hex(h.sha)),
      branch = nn(M.clean(str(h.branch), dir, ctx.state_dir)),
      dirty = dirty,
    }
  end
  local loc, counts = local_part(src.st, src.green)
  local green = NIL
  if src.green then
    green = {
      run_id = src.green.run,
      ts = iso(src.green.ts) or "1970-01-01T00:00:00Z",
      sha = nn(hex(src.green.sha)),
    }
  end
  local row = {
    key = key,
    name = vim.fs.basename(dir),
    head = head,
    ["local"] = loc,
    last_green = green,
    ci_local = ci_local_part(src.ci, dir, ctx.state_dir),
    ci_remote = ctx.remote and ci_remote_part(rec or NIL, dir, ctx.state_dir) or NIL,
    counts = counts,
  }
  if ctx.form == "local" then
    row.root = dir
  end
  return row, src
end

-- ── heads, seal, leaks ───────────────────────────────────────────────────────

---@param kind string
---@param form "local"|"export"
---@param root? string Only in the local form.
---@return table
local function head(kind, form, root)
  local h = {
    schema = M.SCHEMA,
    plugin = M.PLUGIN,
    kind = kind,
    form = form,
    generated_at = M.clock(),
    engine = json.object(M.engine_info()),
    capabilities = vim.list_slice(M.CAPABILITIES, 1),
  }
  if form == "local" and root then
    h.root = root
  end
  return h
end

---Put `rev` and `digest` on a document (`lib.nvim.contract.doc`: the digest leaves out `generated_at` and `engine`).
---@param doc table
---@param lines string[]
---@return table
local function seal(doc, lines)
  local b = builder()
  return b.seal(doc, b.rev_of(lines))
end

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---Whether `s` holds an absolute path right after a `>` that closes no placeholder (`<nil>/etc/x`, not `<REPO>/x`).
---@param s string
---@return boolean
function M.after_tag(s)
  local placeholders = require("testing.ci.overview").PLACEHOLDERS
  local init = 1
  while true do
    local i = s:find(">/[%w._%-]", init)
    if not i then
      return false
    end
    local tag = s:sub(1, i - 1):match("<([%w_%-]+)$")
    if not (tag and placeholders[tag]) then
      return true
    end
    init = i + 1
  end
end

---Whether `low` holds the directory `root` (both lower case, forward slashes) as a whole path: where a path can
---begin (not the `/root` inside `TESTS/root/x`) and up to the end of a segment (not the `/root` of `/rootless`).
---@param low string
---@param root string
---@return boolean
function M.find_root(low, root)
  local init = 1
  while true do
    local i, j = low:find(root, init, true)
    if not i then
      return false
    end
    local before = i > 1 and low:sub(i - 1, i - 1) or ""
    local after = low:sub(j + 1, j + 1)
    local starts = before == "" or not before:find("[%w._~%-/<>]")
    -- a root that starts with a letter (`c:/users/x`) begins at any character that is no part of a word
    if root:find("^%a") then
      starts = before == "" or not before:find("[%w_]")
    end
    if starts and (after == "" or not after:find("[%w._%-]")) then
      return true
    end
    init = i + 1
  end
end

---The fields that hold a name the user chose and that are never redacted: the name and the key of a repository and
---the path of a file of the export folder (`repos/<key>.json`). The user name is no leak there.
---@param path string Where in the document (`$.repos[0].name`).
---@return boolean
function M.is_name_field(path)
  return path:match("^%$%.repos%[%d+%]%.name$") ~= nil
    or path:match("^%$%.repos%[%d+%]%.key$") ~= nil
    or path == "$.repo.name"
    or path == "$.repo.key"
    or path:match("^%$%.files%[%d+%]%.path$") ~= nil
end

---The things of this machine an export must not contain, found in every string (and key) of a document: a drive
---path, a UNC path, an absolute POSIX path, the home directory, the user name, one of `ctx.roots` (any slash, any
---case). The answer names WHERE (`$.repos[1].ci_remote.note`) and WHAT, never the text itself.
---@param doc any A document (or any decoded value).
---@param ctx? { roots?: string[], home?: string, user?: string, secrets?: string[] } `secrets`: default `M.secrets()`.
---@return { path: string, what: string }[]
function M.leaks(doc, ctx)
  ctx = ctx or {}
  local home = ctx.home or vim.uv.os_homedir()
  local user = ctx.user
  if user == nil then
    local ok, pw = pcall(vim.uv.os_get_passwd)
    user = ok and type(pw) == "table" and pw.username or vim.env.USERNAME or vim.env.USER
  end
  local needles = {}
  local function need(s, what)
    if type(s) == "string" and #s >= 3 then
      needles[#needles + 1] = { text = slashes(s):lower():gsub("/+$", ""), what = what }
    end
  end
  need(home, "the home directory")
  for _, r in ipairs(ctx.roots or {}) do
    need(r, "a root of this machine")
  end
  local user_pat = type(user) == "string"
      and #user >= 3
      and ("%f[%w]" .. vim.pesc(user:lower()) .. "%f[%W]")
    or nil
  local secrets = ctx.secrets or M.secrets()
  local found = {}
  local function check(s, path)
    local function hit(what)
      found[#found + 1] = { path = path, what = what }
    end
    if s:find("%f[%w]%a:[\\/]") then
      return hit("a drive path")
    end
    if s:lower():find("%f[%w]file:/") then
      return hit("a file URI")
    end
    if s:find("\\\\[%w._%-]") or (" " .. s):find("[^%w._~%-/\\<>:]//[%w._%-]") then
      return hit("a UNC path")
    end
    if (" " .. s):find("[^%w._~%-/\\<>]/[%w._%-]") or M.after_tag(s) then
      return hit("an absolute path")
    end
    local low = slashes(s):lower()
    for _, n in ipairs(needles) do
      if M.find_root(low, n.text) then
        return hit(n.what)
      end
    end
    for _, v in ipairs(secrets) do
      if s:find(v, 1, true) then
        return hit("a secret of the environment")
      end
    end
    -- the owner of a GitHub repository may be spelled like the local user: a link or `owner/name` is no leak; the
    -- name and the key of a repository and the path of its file are the names the user chose, never redacted
    if
      user_pat
      and not s:match("^https://github%.com/")
      and not path:match("%.ci_remote%.repo$")
      and not M.is_name_field(path)
    then
      if s:lower():find(user_pat) then
        return hit("the user name")
      end
    end
  end
  local function walk(v, path)
    if type(v) == "string" then
      check(v, path)
    elseif type(v) == "table" and v ~= NIL then
      if vim.islist(v) and next(v) ~= nil then
        for i, x in ipairs(v) do
          walk(x, ("%s[%d]"):format(path, i - 1))
        end
      else
        local keys = vim.tbl_keys(v)
        table.sort(keys, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, k in ipairs(keys) do
          local where = path .. "." .. tostring(k)
          if type(k) == "string" then
            check(k, where)
          end
          walk(v[k], where)
        end
      end
    end
  end
  walk(doc, "$")
  return found
end

---Refuse an export document that still holds something of this machine.
---@param doc table
---@param roots string[]
---@param state_dir? string
---@return string|nil problem
local function refuse_leaks(doc, roots, state_dir)
  local all = vim.list_slice(roots, 1)
  if state_dir then
    all[#all + 1] = state_dir
  end
  local leaks = M.leaks(doc, { roots = all })
  if #leaks == 0 then
    return nil
  end
  local shown = {}
  for i = 1, math.min(#leaks, 5) do
    shown[i] = ("%s (%s)"):format(leaks[i].path, leaks[i].what)
  end
  return ("the %s document would leak a path of this machine: %s%s"):format(
    tostring(doc.kind),
    table.concat(shown, ", "),
    #leaks > 5 and (", ... %d more"):format(#leaks - 5) or ""
  )
end

-- ── the repository list (the index of the fleet) ────────────────────────────

---@class Testing.Export.Selection
---@field roots? string[] Repositories named directly.
---@field repos_roots? string[] Every repository below these (the detection of `testing ci overview`).
---@field include? string[] Also these names below a repos root (added to the default `lib.nvim`).
---@field exclude? string[] Leave these names out.

---The repositories of a selection, sorted by name, and how many were left out (vaults, excludes).
---@param sel Testing.Export.Selection
---@return string[]|nil dirs
---@return { excluded: string[], missing: string[] }|string info_or_problem
function M.resolve(sel)
  local overview = require("testing.ci.overview")
  local cfg = vim.deepcopy(require("testing.config.DEFAULTS").project.ci_overview)
  return overview.resolve({
    roots = sel.roots or {},
    repos_roots = sel.repos_roots or {},
    include = sel.include or {},
    exclude = sel.exclude or {},
  }, cfg)
end

---@class Testing.Export.Opts: Testing.Export.Selection
---@field form? "local"|"export" Default "export".
---@field state_dir? string The state directory (default `stdpath('state')`).
---@field remote? boolean Ask the CI adapter (default false).
---@field previous? fun(path: string): string|nil `export` only: the text of a file of the export folder as it is now
---(nil: none). A document whose digest did not change keeps that file's `generated_at` and `engine`, so an
---unchanged state is the same bytes (no git diff in a results repository).

---The CI adapter's records by directory, and what the document says about asking it.
---@param dirs string[]
---@param opts Testing.Export.Opts
---@return table<string, table>|nil by_dir nil: not asked.
---@return { asked: boolean, error: string|vim.NIL }
local function ask_remote(dirs, opts)
  if not opts.remote then
    return nil, { asked = false, error = NIL }
  end
  if not pcall(require, "lib.nvim.net.github") then
    return nil, { asked = false, error = "lib.nvim has no net.github" }
  end
  local list = {}
  for i, dir in ipairs(dirs) do
    list[i] = { dir = dir, from_root = false }
  end
  local base = opts.state_dir or vim.fn.stdpath("state")
  local ok, records, info = pcall(M.deps.remote, list, { state_dir = base })
  local where = dirs[1] or base
  if not ok then
    return {}, {
      asked = true,
      error = nn(M.clean("the CI adapter failed: " .. tostring(records), where, opts.state_dir)),
    }
  end
  local by_dir = {}
  for _, r in ipairs(records or {}) do
    if type(r) == "table" and type(r.dir) == "string" then
      by_dir[r.dir] = r
    end
  end
  local err = type(info) == "table"
      and info.token_error
      and M.clean("no GitHub token: " .. tostring(info.token_error), where, opts.state_dir)
    or nil
  return by_dir, { asked = true, error = nn(err) }
end

-- ── documents ────────────────────────────────────────────────────────────────

---@param dirs string[]
---@param info { excluded: string[] }
---@param opts Testing.Export.Opts
---@param remote table<string, table>|nil
---@param remote_info table
---@return table doc
---@return table<string, { row: table, src: Testing.Export.Sources, dir: string }> by_key
local function build_fleet(dirs, info, opts, remote, remote_info)
  local form = opts.form or "export"
  local root
  if form == "local" and #(opts.repos_roots or {}) == 1 and #(opts.roots or {}) == 0 then
    root = vim.fs.normalize(vim.fn.fnamemodify(opts.repos_roots[1], ":p")):gsub("([^:/])/+$", "%1")
  end
  local doc = head("fleet", form, root)
  local rows, lines, by_key = {}, {}, {}
  for _, dir in ipairs(dirs) do
    local row, src = row_of(dir, { form = form, state_dir = opts.state_dir, remote = remote })
    if by_key[row.key] then
      error(
        ("two repositories have the key %s (%s and %s): one checkout inside the other?"):format(
          row.key,
          by_key[row.key].row.name,
          row.name
        ),
        0
      )
    end
    by_key[row.key] = { row = row, src = src, dir = dir }
    rows[#rows + 1] = row
    lines[#lines + 1] = src.rev
  end
  doc.repos = rows
  doc.excluded = #(info.excluded or {})
  doc.remote = remote_info
  return seal(doc, lines), by_key
end

---@param c Testing.State.Case
---@param dir string
---@param state_dir? string
---@return table
local function case_of(c, dir, state_dir)
  local fails = {}
  for i, f in ipairs(c.fails or {}) do
    fails[i] = {
      line = nn(int(f.line)),
      msg = nn(M.clean(f.msg, dir, state_dir, M.TEXT_MAX)),
    }
  end
  local describe = {}
  for _, d in ipairs(c.describe or {}) do
    describe[#describe + 1] = M.clean(d, dir, state_dir) or ""
  end
  return {
    id = M.clean(c.id, dir, state_dir, 1000) or "",
    file = M.clean(c.file, dir, state_dir, 1000) or "",
    line = nn(int(c.line) ~= 0 and int(c.line) or nil),
    status = c.status,
    name = nn(M.clean(c.name, dir, state_dir)),
    describe = describe,
    duration_ms = type(c.duration_ms) == "number" and c.duration_ms >= 0 and c.duration_ms or 0,
    flaky = c.flaky == true,
    message = nn(M.clean(c.message, dir, state_dir, M.TEXT_MAX)),
    expected = nn(M.clean(c.expected, dir, state_dir, M.TEXT_MAX, true)),
    actual = nn(M.clean(c.actual, dir, state_dir, M.TEXT_MAX, true)),
    fails = fails,
    fails_total = nn(int(c.fails_total)),
  }
end

---@param dir string
---@param row table
---@param src Testing.Export.Sources
---@param opts Testing.Export.Opts
---@param remote_info table
---@return table
local function build_repo(dir, row, src, opts, remote_info)
  local form = opts.form or "export"
  local doc = head("repo", form, dir)
  doc.repo = row
  local red = require("testing.state").failures(src.st)
  local cases = {}
  for i = 1, math.min(#red, M.MAX_CASES) do
    cases[i] = case_of(red[i], dir, opts.state_dir)
  end
  doc.cases = cases
  doc.cases_red = #red
  doc.cases_omitted = #red - #cases
  local notes = {}
  for _, n in ipairs(src.notes) do
    notes[#notes + 1] = M.clean(n, dir, opts.state_dir) or ""
  end
  doc.notes = notes
  doc.remote = remote_info
  return seal(doc, { src.rev })
end

---@generic T
---@param fn fun(): T
---@return T|nil
---@return string|nil err
local function protect(fn)
  local outer = secrets_cache
  secrets_cache = nil
  secrets_cache = M.secrets()
  local ok, res, err = pcall(fn)
  secrets_cache = outer
  if not ok then
    return nil, tostring(res)
  end
  return res, err
end

---The `fleet` document.
---@param opts Testing.Export.Opts
---@return table|nil doc
---@return string|nil err
function M.fleet(opts)
  return protect(function()
    local dirs, info = M.resolve(opts)
    if not dirs then
      return nil, tostring(info)
    end
    ---@cast info { excluded: string[], missing: string[] }
    local remote, remote_info = ask_remote(dirs, opts)
    local doc = build_fleet(dirs, info, opts, remote, remote_info)
    if (opts.form or "export") == "export" then
      local problem = refuse_leaks(doc, dirs, opts.state_dir)
      if problem then
        return nil, problem
      end
    end
    return doc
  end)
end

---The `repo` document of one repository.
---@param dir string
---@param opts Testing.Export.Opts
---@return table|nil doc
---@return string|nil err
function M.repo(dir, opts)
  return protect(function()
    dir = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")):gsub("([^:/])/+$", "%1")
    if vim.fn.isdirectory(dir) ~= 1 then
      return nil, ("%s is not a directory"):format(dir)
    end
    local remote, remote_info = ask_remote({ dir }, opts)
    local form = opts.form or "export"
    local row, src = row_of(dir, { form = form, state_dir = opts.state_dir, remote = remote })
    local doc = build_repo(dir, row, src, opts, remote_info)
    if form == "export" then
      local problem = refuse_leaks(doc, { dir }, opts.state_dir)
      if problem then
        return nil, problem
      end
    end
    return doc
  end)
end

---The canonical bytes of a document: compact (the form that is hashed and printed), or with `indent` (the form of
---a file: readable, one line per field, ends in a line feed). Bigger than 8 MiB is an error, never a cut document.
---@param doc table
---@param opts? { indent?: integer }
---@return string|nil text
---@return string|nil err
function M.encode(doc, opts)
  local text, err = builder().encode(doc, opts and opts.indent and { indent = opts.indent } or nil)
  if not text then
    return nil, err and err.message or "cannot encode the document"
  end
  if opts and opts.indent then
    text = text .. "\n"
  end
  return text
end

---A document whose content did not change since the file `path` of the export folder was written keeps that file's
---`generated_at` and `engine`: an unchanged state is then the same bytes. A file that does not read as a document of
---this contract, of the same kind, form and digest, changes nothing.
---@param doc table A sealed document.
---@param path string
---@param previous? fun(path: string): string|nil
local function carry(doc, path, previous)
  if not previous then
    return
  end
  local okp, text = pcall(previous, path)
  if not okp or type(text) ~= "string" then
    return
  end
  local old = M.read(text)
  if
    not old
    or old.schema ~= doc.schema
    or old.kind ~= doc.kind
    or old.form ~= doc.form
    or old.digest ~= doc.digest
    or not time_text(old.generated_at)
    or type(old.engine) ~= "table"
  then
    return
  end
  local e = old.engine
  if type(e.version) ~= "string" or type(e.git) ~= "string" or type(e.nvim) ~= "string" then
    return
  end
  doc.generated_at = old.generated_at
  doc.engine = json.object({ version = e.version, git = e.git, nvim = e.nvim })
end

---@class Testing.Export.File
---@field path string Relative to the export folder.
---@field text string The bytes (canonical, indented, LF).
---@field sha256 string
---@field bytes integer

---@class Testing.Export.Bundle
---@field files Testing.Export.File[] The documents, sorted by path (`fleet.json`, `repos/<key>.json`).
---@field manifest Testing.Export.File `testing-export.json`, to be written LAST.
---@field docs table<string, table> The documents by path (the manifest too).

---Everything an export folder holds, in the export form: `fleet.json`, `repos/<key>.json` per repository and the
---manifest. Nothing is written; `testing export --out` writes the files and the manifest last. Every document passed
---the leak detector.
---@param opts Testing.Export.Opts `form` is always "export".
---@return Testing.Export.Bundle|nil bundle
---@return string|nil err
function M.export(opts)
  return protect(function()
    local o = vim.tbl_extend("force", {}, opts or {}, { form = "export" })
    local dirs, info = M.resolve(o)
    if not dirs then
      return nil, tostring(info)
    end
    ---@cast info { excluded: string[], missing: string[] }
    local remote, remote_info = ask_remote(dirs, o)
    local fleet, by_key = build_fleet(dirs, info, o, remote, remote_info)
    local docs = { ["fleet.json"] = fleet }
    local problem = refuse_leaks(fleet, dirs, o.state_dir)
    if problem then
      return nil, problem
    end
    for key, entry in pairs(by_key) do
      local doc = build_repo(entry.dir, entry.row, entry.src, o, remote_info)
      problem = refuse_leaks(doc, { entry.dir }, o.state_dir)
      if problem then
        return nil, problem
      end
      docs["repos/" .. key .. ".json"] = doc
    end
    local paths = vim.tbl_keys(docs)
    table.sort(paths, json.bytes_less)
    local files, entries, lines, contents = {}, {}, {}, {}
    for _, path in ipairs(paths) do
      carry(docs[path], path, o.previous)
      local text, err = M.encode(docs[path], { indent = 2 })
      if not text then
        return nil, ("%s: %s"):format(path, tostring(err))
      end
      local sum = vim.fn.sha256(text)
      files[#files + 1] = { path = path, text = text, sha256 = sum, bytes = #text }
      entries[#entries + 1] = { path = path, sha256 = sum, bytes = #text }
      contents[#contents + 1] = { path = path, digest = docs[path].digest }
      lines[#lines + 1] = path .. "\t" .. docs[path].digest
    end
    -- rev and digest of the manifest follow the CONTENT of its files (path and digest of each document), never their
    -- bytes: the bytes hold generated_at and engine, so an unchanged state keeps its manifest digest at any time
    local view = head("manifest", "export")
    view.files = contents
    seal(view, lines)
    local manifest = head("manifest", "export")
    manifest.files = entries
    manifest.rev, manifest.digest = view.rev, view.digest
    carry(manifest, M.MANIFEST, o.previous)
    local mtext, merr = M.encode(manifest, { indent = 2 })
    if not mtext then
      return nil, tostring(merr)
    end
    docs[M.MANIFEST] = manifest
    return {
      files = files,
      manifest = {
        path = M.MANIFEST,
        text = mtext,
        sha256 = vim.fn.sha256(mtext),
        bytes = #mtext,
      },
      docs = docs,
    }
  end)
end

-- ── the reader side ──────────────────────────────────────────────────────────

---@class Testing.Export.ReadError
---@field code "invalid"|"unsupported_schema"|"unknown_kind"|"payload_too_large"
---@field message string

---Read a document as a client of the contract does: at most 8 MiB, JSON, `schema` "testing-export/<n>" with n not
---higher than this version, a known `kind`. Unknown fields are kept and ignored; nothing else is checked here
---(`M.validate` checks the shape against the JSON Schema).
---@param text string
---@return table|nil doc
---@return Testing.Export.ReadError|nil err
function M.read(text)
  if type(text) ~= "string" then
    return nil, { code = "invalid", message = "no text" }
  end
  if #text > M.MAX_DOC_BYTES then
    return nil,
      {
        code = "payload_too_large",
        message = ("%d bytes, more than %d"):format(#text, M.MAX_DOC_BYTES),
      }
  end
  local ok, doc = pcall(vim.json.decode, text)
  if not ok or type(doc) ~= "table" then
    return nil, { code = "invalid", message = "not a JSON object" }
  end
  local n = type(doc.schema) == "string" and doc.schema:match("^testing%-export/(%d+)$")
  if not n then
    return nil, { code = "invalid", message = "not a testing-export document" }
  end
  if tonumber(n) > M.SCHEMA_VERSION then
    return nil,
      {
        code = "unsupported_schema",
        message = ("%s is newer than %s: update testing.nvim"):format(doc.schema, M.SCHEMA),
      }
  end
  if not M.KINDS[doc.kind] then
    return nil, { code = "unknown_kind", message = ("unknown kind %s"):format(tostring(doc.kind)) }
  end
  return doc
end

---@type table|nil
local schema_cache

---The decoded JSON Schema of this version.
---@return table
function M.schema()
  if not schema_cache then
    schema_cache = require("testing.export.schema").load(plugin_root .. "/" .. M.SCHEMA_FILE)
  end
  return schema_cache
end

---Validate a document (its text, or the decoded value) against the JSON Schema. A Lua table is encoded and decoded
---first, so that what is checked is what a client reads.
---@param doc string|table
---@return boolean ok
---@return string[] problems
function M.validate(doc)
  local text = doc
  if type(doc) == "table" then
    local err
    text, err = M.encode(doc)
    if not text then
      return false, { tostring(err) }
    end
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return false, { "not JSON: " .. tostring(decoded) }
  end
  return require("testing.export.schema").validate(M.schema(), decoded)
end

return M
