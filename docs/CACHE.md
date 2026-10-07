# Result cache and affected selection

Two ways to not run what cannot have changed (concept F1 and F2):

- the **cache** (`testing.cache`): a spec file whose inputs are byte-identical to an earlier green run does not run;
  its case list comes back from disk, marked `cached`.
- the **affected selection** (`testing.affected`): from the changed files (git) to the spec files that can reach
  them. It selects fewer files; it never selects fewer than needed.

Both are opt-in. Neither is ever the default in CI. `--no-cache` and "run everything" always work.

> Status: implemented, tested and wired into `testing run` ([CLI.md](CLI.md#result-cache)): the flags below work in
> this editor, in a child editor per file and with the warm pool, and `:Testing run --cached` passes them on.

## Flags

| Flag | Meaning |
|---|---|
| `--cached` | reuse results of unchanged spec files, store new green ones |
| `--no-cache` | never read or write the cache; wins over `--cached`, `--cache-refresh` and the config |
| `--cache-refresh` | run everything and store the results, never read |
| `--cache-audit <0..1\|all>` | run that share of the cache hits anyway and compare with the stored result (a difference is `cache.stale_pass`, exit 1); implies `--cached`. See [The cache proves itself](#the-cache-proves-itself-audit-and-key-flip) |
| `--cache-clear` | delete the cache of this project and exit |
| `--changed` | only specs affected by the working tree against `HEAD` (tracked changes and untracked files) |
| `--since <rev>` | the same against a revision |
| `--affected [rev]` | the same against `rev` (default `HEAD~1`); a developer tool |

`--changed`, `--since` and `--affected` exclude each other. A revision is validated before it reaches git (no leading
`-`, no range, no whitespace or shell characters).

To ask why a spec file was selected, taken from the cache or run, see [`testing explain`](#testing-explain-why-this-spec).

## How a run uses them

`testing.run.cached` is where `testing run` asks the two modules (`lua/testing/run/cached.lua`), so that the
three drivers (this editor, a child per file, the warm pool) neither know about the cache nor about the selection:

1. **Selection.** `--changed` / `--since` / `--affected` narrow the files the path arguments and `--file` left to the
   specs `affected.select` names. `r.all` (everything, with the reason) changes nothing but the note. A narrower
   list is a partial run: the line `partial run: n of m spec files (--changed; no sentinel)` replaces the sentinel.
2. **Keys.** Before the driver starts, the key of every selected file is computed (`cache.key`); the files with a
   valid entry leave the list the driver gets (their child editor is never started), the others run. A run in which
   every file hit starts no driver at all.
3. **Merge.** The cached cases go back into the result in file order, marked `cached = true`; the summary is
   recounted; the files that ran green are stored (`cache.put`), unless the run was stopped by `--maxfail`. The key is
   computed again before a file is stored, and the file is stored only when it is still the key of the run's start:
   an input that was edited while the run was going (an editor that saves, a formatter, a checkout) is `an input
   changed while the run was going`, not a result stored under the old content's key.
   `run.cache` of the IR carries `{ mode, files_cached, cases_cached, files_ran, stored }` (plus the audit fields,
   [below](#the-cache-proves-itself-audit-and-key-flip), when `--cache-audit` asked for them).

What the run adds to the keys of [The key](#the-key): the project's `minit` and the harness of a dialect-h file
(files that decide what a spec does without being required by it), the spec roots as module roots
(`require("harness")` finds `TESTS/harness.lua`), `package.path` entries of this process (a rock), and the
effective options of the run (isolation, guards, `host`, `env_allow`, timeouts, `--strict`, `--first-run`, the
extra `--rtp` directories; **not** `--jobs`, `--shard`, `--watch`). A `require` that nothing resolves is part of
the key as an **absence** (the right reading for `pcall(require, "optional")`), and then the whole spec root joins the
key, because the missing module may be a helper the spec puts on `package.path` itself.

Honesty rules of a cached run: it is off unless asked for (`--cached`, `--cache-refresh`, or `cache.enabled`, which
is ignored in CI); `--no-cache` always wins; a case selection (`--filter`, `--tags`, `--exclude-tags`, `--lf`) or
`--strict` with discovery findings turns it off for that run, with a note; `--list` ignores it; a file with a
discovery finding is never taken from the cache; nothing is stored after a stopped run. The terminal marks a
cached file `ok    TESTS/x_spec.lua (cached)`, the summary counts `N cached, not run`, a `cache (use): ...` line names
how many files were not run and the most frequent reasons the others have no key, and `--profile` and the timing
line show only what ran. Guard findings of severity `info` (the state guard noting that a spec loaded a module)
do not keep a file out of the cache; a finding of `warn` or above does.

## The cache

### Granularity and storage

One entry per spec **file**: the Result-IR case list of that file. Entries live under

    stdpath('cache')/testing/<name>-<12 hex of sha256(project key)>/entries/<64 hex key>.json

(`<project key>` is `lib.nvim.fs.project_key`, the git root). The directory is per user and per machine and is never
shared across a trust boundary. It is regenerable: deleting it costs time, never correctness. Writes are atomic
(`lib.nvim.fs.write.atomic`); a temp file of an interrupted write (`entries/<key>.json.atomic-tmp.*`,
`index.json.atomic-tmp.*`, `keys.json.atomic-tmp.*`) is removed when it is older than an hour.

**State and cache are two directories.** The cache (`stdpath('cache')`) holds the entries and the hash index; what the
run remembers about its own history (`stdpath('state')/testing/<project>/`: `keys.json` the key-flip memory,
`last_green.json`, `order.json`, `runs.jsonl`) lives apart. A CI job that restores only the cache directory starts
every run with an empty key-flip memory: a flip is then found only inside one run, and the "last green run" of a red
verdict is "none recorded". Restore the state directory as well when those matter.

The folder is named by `cache.project_key` of `.testing.lua` when it is set, else by the checkout path. A run keeps the
folder it started with: a spec of the run that calls `cli.main` for another project (as many specs of this suite do)
changes the process-wide key while the files run, and the results of the hosting run are still stored where its next run
looks.

Bounds (`cache.prune`, run once per process after the first write): entries older than 30 days go, then the oldest
until the store is within 64 MB and 5000 entries; a hit renews the age. An entry larger than 4 MB is not stored.

### The key

`cache.key(file_info, ctx)` returns the sha256 over

- the spec path and the content hash of the spec file,
- the content hash of every file it depends on (below),
- a digest of each **runtime directory** of the project root that exists (`runtime <dir>/=<digest>` key lines):
  `after`, `autoload`, `colors`, `compiler`, `ftdetect`, `ftplugin`, `indent`, `keymap`, `lang`, `lsp`, `parser`,
  `plugin`, `queries`, `spell`, `syntax` (`testing.cache.RUNTIME_DIRS`). An editor loads these without a `require`: a
  child editor has the root on its runtime path and runs `filetype plugin indent on`, so a spec that sets a filetype or
  opens a buffer runs the filetype plugin, the indent and syntax files and the Tree-sitter queries of the project, and
  nothing in the spec leads there. They are in EVERY key, whether the scanner saw a file read or not (an edit of
  `ftplugin/` changes the key of every spec; `lua/`, `doc/`, `docs/` and the spec files are not among them). A
  symlinked (or junctioned) directory below one of them is followed, as it is for the files a spec reads,
- the **runtime files** of the project root that exist (`runtime <file>=<sha256>` key lines): `filetype.lua`,
  `filetype.vim`, `ftplugin.vim`, `indent.vim`, `scripts.vim`, `scripts.lua`, `ftoff.vim`, `ftplugof.vim`, `indoff.vim`
  (`testing.cache.RUNTIME_FILES`) and `.editorconfig`. A child editor sources the first ones itself from the root on its
  runtime path (detection of a buffer, `filetype plugin indent on|off`), and the built-in editorconfig plugin reads
  `.editorconfig` for every buffer of a file below the root (`shiftwidth`, `expandtab`, ...), so a spec that opens a
  buffer and asserts on the filetype or the indent depends on them without naming them. A file that is absent is no line
  (creating it changes the key); a link that dangles or a directory of that name has no hash, so no key. An edit of
  `.editorconfig` changes the key of every spec,
- the runner version: a content digest of `lua/testing` (a dirty checkout differs from a clean one),
- the Neovim version, API level (`api_info().version.api_level`), OS and CPU architecture (the key line used to read a
  field that does not exist and carried the word `apinil`: it names the level now, which changed every key once, on top of
  the runner digest, which changes with every edit of the runner),
- name and hashed value of every environment variable the configuration lists (`env_allow`, `PREFIX*` expands over
  the names that are set; a new variable below a listed prefix changes the key). Where the system treats names
  case-insensitively (Windows) a listed `MyVar` finds `MYVAR` and the name is written in upper case; elsewhere
  `MyVar` and `MYVAR` are two variables. The value is hashed with plain sha256 (no salt), and the key lines are kept
  in the entries and shown by `testing explain`: **`env_allow` must not list a variable that holds a secret** (a token,
  a password). A short or guessable value can be recovered from its hash by trying candidates, and the cache directory
  is a plain file store. (A per-directory salt would only make the lines unusable for a comparison across cache
  directories; the plain rule, keep secrets out of the key, is simpler and does not depend on a salt file being
  restored together with the entries.)
- a digest of the effective configuration and the content of `.testing.lua`,
- the dialect, and the seed when the run is shuffled.

**Dependencies, as far as they are known.** The transitive closure of the spec's `require`s, resolved in the project,
`ctx.dep_roots` and (default) the runtime path, so a change in lib.nvim invalidates the specs that load it. A literal
`require("a.b")` is an edge; `require("a.dialect." .. name)` is an edge to every module below `a.dialect.`; a
`require(expr)` nobody can resolve is an edge to every module of the checkout it appears in. The `require`s of the Lua
files below the runtime directories that an editor loads by itself (`ftplugin/`, `indent/`, `after/` except
`after/plugin/`, `colors/`, `lsp/`, ..., not `plugin/`: a child editor starts with `-u NONE` and does not source it) are
edges of EVERY closure, because a spec that sets a filetype loads the file and so the module it requires; a
`require` there that nothing resolves is judged like one of the spec (no key, or an `absent` line where the run says so).
The same holds for the Lua files in the root that an editor loads (`filetype.lua`, `scripts.lua`) and for a Lua file
below a symlinked directory of a runtime directory (the list of files is made by the walk that makes the digest of the
directory, so a file that is hashed is also analysed).
Those Lua files are **members** of every closure, not only edges: what they read, load and declare counts like what a
module the spec requires does (next paragraph).
A graph can replace the scan (`file_info.deps` with `deps_complete = true`; the runtime directories and the runtime files of the root stay in the key, their
`require`s are then the graph's business).

**Hidden inputs of the whole closure.** A spec is only as deterministic as the files it loads, so the markers
(below) are read from the spec AND from every file of the closure that belongs to the project (a dependency checkout
such as `lib.nvim`, found on `ctx.dep_roots` or the runtime path, or below `.deps/`, contributes its content to the key
and nothing else: it is tested in its own repository):

- a Lua file below a runtime directory of the project (`ftplugin/mylang.lua`, `after/ftplugin/`, `indent/`, `colors/`,
  ...) is judged like a project module in EVERY closure: the editor loads it by itself when a spec sets a filetype, so
  an environment variable it reads (`vim.env.MYLANG_INDENT`) joins the key of every spec, the files it reads and the
  data next to it do too, a `:runtime`/`packadd` in it takes the whole project into every key, and its `-- @cache-env`,
  `-- @cache-allow` and `-- @cache off` count. `-- @cache off` in such a file leaves every spec of the project without a
  key (the reason names the file); a computed environment read in it without `-- @cache-env` does as well, unless the
  file runs in a child editor, whose whole environment is in the key,
- a project module that reads files makes the spec a file reader (next paragraph), and the data files that lie next to
  that module (its directory, without the `.lua` files, which the closure already hashes) join the key,
- a project module that reads a literal environment variable adds that variable's hashed value to the key; one that
  computes a name has no key, unless it names the variables the read can reach (`-- @cache-env`, below),
- code that loads files by an ex command or a runtime-path lookup (`:runtime`, `:source`, `:luafile`, `packadd`,
  `nvim_get_runtime_file`), or a spec that changes `package.path`/`rtp` and then `require`s a module that nothing
  resolves, takes the **whole project** (everything below the root except `.git`, `.deps`, `.cache`,
  `node_modules`) into the key,
- a string literal that names a place outside the project (`../x`, `C:/x`, `~/x`, `/etc/x`, read from the root and
  from the directory of the file that names it) in a spec or module that reads files means **no key** when it names a
  file or directory that EXISTS there: the key cannot see it. A literal that names nothing (the string of a test of a
  path function) is no read: it is in the key as absent, and the file that appears there changes the key,
- a spec that runs in a CHILD editor (every `--isolated file|case` file, every busted file by default) is keyed by the
  whole environment that child sees (`testing.child.env`: the allowlist over this process's environment), one key line
  per variable (`child-env NAME=<sha256 of the value>`, so `testing explain` names the variable that changed): no
  variable it reads is judged by name any more, and a computed name needs no exception. What the child does NOT see of
  the parent is not in the key: while the run is deterministic (the default, `--no-determinism` or
  `determinism = false` turn it off) the child gets a fixed `LANG`, `LC_ALL` and `TZ` and no `LANGUAGE` or other `LC_*`
  (`apply_determinism`), so the parent's locale and time zone cannot reach it and two machines with another locale share
  their hits. Every other variable the child receives (`PATH`, `TERM`, `COLORTERM`, `DISPLAY`, `HOME`, ... and what
  `env_allow` adds) stays in the key: a child can read it, and no analysis of the spec proves that it does not. The mode
  (`#determinism=true|false`) is a key line too, A file that runs in this editor
  keeps the rules below (a literal name must be listed, a computed one means no key),

**Files the spec reads.** A spec (or a project module it loads) that reads files (`io.open`, `readfile`, `vim.fs.dir`,
`expand`, an ex command with a file argument, ...) gets into its key: the files of its spec root (helpers, fixtures, the
harness; other spec files only when something in the closure lists directories, because then a lint spec may be
reading them), every path-like string literal that names an existing file or directory below the root (a word of a
command string such as `runtime plugin/x.lua` counts), and what it declares in its header:

```lua
-- @cache-inputs README.md docs/
-- @cache off
-- @cache-allow time random
-- @cache-env CI GITHUB_* *_DIR
```

The directives are read from the **first 30 lines** of the file, counted the way Lua counts lines (`\n`, `\r\n` and a
lone `\r` each end one line, so a file checked out with CRLF has the same window as one with LF); a UTF-8 byte order
mark in front of the first line is skipped. A directive on line 31 or later is ignored: `-- @cache off` there does not
opt the file out. Put them at the top. A directive line is read up to 16384 bytes (`scan.MAX_HEADER_LINE`, cut after a
whole word): a line made to keep the scanner busy (a directive and tens of thousands of blanks) costs the same few
milliseconds as any other, and what lies beyond the bound is not read.

`-- @cache-allow time random spawn net` is the author's statement that the clock, random numbers, a process or the
network that this file uses do not decide what a spec sees; the file is then not judged for them. The directive is a
list of words separated by blanks, and **only the leading run of words from the list counts**
(`time random spawn net outside env nondeterministic`): the first token that is not one of them ends the directive, so
a remark behind it vouches for nothing (`-- @cache-allow time (log stamps only; never random numbers)` grants `time`
and not `random`), and so does a comma (`time, random` grants nothing: write `time random`).
`-- @cache-allow outside` says that the places outside the project this file names (`".."` in path arithmetic, the
sibling-checkout lookup of `testing.deps`, the bad values a path validator is tested with) are not read for what a spec
sees; the file is then not judged for them.

`-- @cache-allow env` says that what a spec sees does not depend on the outer values of the variables this file reads by a
computed name or as a whole (a snapshot that is compared with itself, a redaction of the user name, a function that
takes the environment as an argument and is tested with a fake one). The file is then not judged for those reads; a
name it declares with `-- @cache-env` still joins the key. The runner's own modules that read the whole environment
carry it (`testing.cache`, `testing.child`, `testing.guard.state`, `testing.isolation.snapshot`, `testing.rpc.trace`,
`testing.run.cached`, `testing.run.inproc`, `testing.stamp.collect`): `*` there would put every variable of the process
into the key, and a runner script that exports a per-run directory (`XDG_STATE_HOME` of `scripts/test.sh`) would give
every invocation another key. A module without it takes the key away from every spec whose `require` closure reaches
it (`testing.run.project` loads `testing.stamp.write`, and through it `testing.stamp.collect`): no false green, but the
hit rate of the suite is gone. `TESTS/testing/cache_runner_keyable_spec.lua` keeps the runner modules keyable.

**Vouching is visible.** Every `-- @cache-allow ...` and `-- @cache-env ...` of the spec and of the project files it loads is a statement of the author that the scanner cannot check (`-- @cache-env *` most of all: the whole environment is then trusted not to matter). `testing explain` prints each as a line `vouched: <directive> (<file>)`, and a `cache.stale_pass` finding of the audit repeats them, so a reviewer sees what a cached result rests on. A spec from an untrusted source (a pull request) should be reviewed for these lines.

`-- @cache-env <name|pattern>...` is for a file that reads the environment by a COMPUTED name (`getenv(name)` over a
list, `vim.env[name]`) or reads it as a whole. It names the variables the read can reach (a plain name, `PREFIX_*`,
`*_DIR`; `*` alone for the whole environment): their hashed values (a pattern: every variable it matches, and the
pattern itself) join the key, so the read is not a hidden input any more, and a changed value, or a new variable that a
pattern matches, is another key. Names do not cover a read of the whole environment (`vim.fn.environ()`, `os_environ`,
`vim.env` handed on): that needs `*`, and then every variable of the process is in the key (a second shell with another
`PATH` is another key: the price of the statement). The declaration is the author's, like `@cache-allow`: a name the
file can read and the declaration leaves out is a stale pass. Where a list lives in the code (`testing.affected.CI_ENV`)
a spec compares the two. In a spec, `-- @cache-env A B` also lets the spec itself read `A` and `B` by their literal
names without `env_allow`.

`-- @cache-allow nondeterministic` lifts the mark that the [key-flip detection](#the-cache-proves-itself-audit-and-key-flip)
puts on a spec whose result changed under an unchanged key.

A path that is **computed** at run time, with no literal anywhere (`root .. "/" .. ("da" .. "ta") .. "/x.txt"`), is not
seen. That is the one stale pass of a file of the project that this key cannot rule out: declare the path, or opt the
file out with `-- @cache off`. (What lies outside the project, see "Limits and decisions": the runtime directories of a
dependency checkout, `stdpath('data')/site`.)

**What reads the environment.** `os.getenv`, `vim.fn.getenv`, `vim.uv.os_getenv`, `vim.env.NAME` and `vim.env["NAME"]` in
every spelling (white space and line ends inside the call, `vim.fn["getenv"](...)`, `vim.fn.call("getenv", { "NAME" })`,
`nvim_call_function("getenv", ...)`, `os.getenv"NAME"`, `pcall(os.getenv, "NAME")`), and the string arguments the editor
expands: `vim.fn.expand("$NAME/x")`, `expandcmd`, `exists("$NAME")`, `eval` and `nvim_eval("$NAME")`, `glob`, and ex
commands (`vim.cmd("let g:v = $NAME")`, `vim.cmd.edit("$NAME/x")`, `nvim_command`, `nvim_exec2`, `execute`) with
`$NAME` or `${NAME}`; a leading `~` in such a string (`expand("~/x")`) reads `HOME` or `USERPROFILE`. A literal name is
a variable to list (`env_allow`, `-- @cache-env`); a name that is built (`getenv(name)`, `expand("$" .. name)`) blocks the
key unless the file declares what it can reach. In an ex command only `${NAME}` and an all-upper-case `$NAME` count
(`1,$d`, `s/x$/y/` and `normal! $a` are no variables). A string that merely MENTIONS `os.getenv("X")` is no call: its
name is collected (more variables in the key, never fewer), but it cannot hide a computed read in the same file. The
string has to be an argument of such a call; a literal that is first kept in a variable
(`local p = "$NAME/x"; vim.fn.expand(p)`) is not followed.

### Line endings

The content hash of a text file reads CRLF as LF. Git's `core.autocrlf` writes the same commit with CRLF on one
machine (the Windows runners of GitHub have it on) and with LF on another, and the key of a spec must not depend on
that: a `git reset --hard` or a fresh checkout there used to give another key for an unchanged commit, which cost the
hit and made a stamp written on one checkout unverifiable on the other. (OS and architecture are still part of the key,
so a stamp is never carried between operating systems; what changed is that two checkouts of one system agree.) The
rules:

- Only the pair CR LF becomes LF; a lone CR stays, so a file with old Mac line endings is another file. A mixed file is
  read line by line. The normalization applies to every hash that joins a key: the spec, the closure, the files a spec
  reads, fixture trees, the runner digest.
- A **binary** file is hashed as it is. A file is binary when a NUL byte is among its first 8192 bytes
  (`testing.cache.hash.BINARY_PROBE`), the way git decides.
- A spec that **looks at line endings itself** stays conservative. Then the key is made from the raw hashes (a key line
  `eol raw`), and an LF checkout and a CRLF checkout have different keys again, as before. That is the case when
  - a file of the closure (the spec, a module it requires, a file the editor loads by itself) contains a carriage return
    escape in a string (`\r`, `\13`, `\x0d`, `\u{d}`; the escaped backslash of `"C:\\repos"` does not count), or one of
    the words `crlf`, `autocrlf`, `fileformat`, `fixendofline`, `fixeol`, `eol` (comments do not count). This is a
    heuristic that over-approximates: a hit that has nothing to do with line endings costs only the advantage of the
    normalization for that spec, never a wrong hit;
  - a file the spec reads as data has CRLF line endings: an input (`-- @cache-inputs`, a path literal), a fixture tree,
    the data next to a module that reads files, the spec root of a spec that reads files, or the whole project for a spec
    that loads code by an ex command. Such a spec may assert on the content it reads (its length, a comparison with a
    literal), and on a CRLF checkout that content is different. (On a runner with `core.autocrlf=true` every text file
    has CRLF, so a spec that reads files keeps a checkout-specific key there; a spec that only requires code, the large
    majority, gets the shared key.)
- The index (`index.json`) keeps the raw hash next to the normalized one (`r`, only for a text with CRLF) and a flag `k`.
  Its layout version is 3: an older index is ignored once and written again. The key version is 4 (every old entry is a
  miss once), the analysis version 12 (new marker `eol`).

Not covered: a spec that depends on line endings without any of the words above and without reading a CRLF file, for
example one that runs a program that writes CRLF itself, or one that reads a file through a path computed at run time
(declare that with `-- @cache-inputs`, so that the key sees the file and its line endings).

### When there is no key (the file is never cached)

`cache.key` returns `nil, reason` when the inputs cannot be known. When in doubt, do not cache. Never cached:

- a spec that reads the clock (`os.time`, `hrtime`, `os.date`, `.now()`, an aliased `os`, ...) or random numbers,
- a spec that starts a process or touches the network (`vim.system`, `jobstart`, `io.popen`, `curl`, ...),
- a spec that reads an environment variable that is not part of the key (and does not declare it with `-- @cache-env`) or
  computes the name; a project module that computes a name or reads the whole environment without declaring it,
- a spec or project module that reads files and names an EXISTING place outside the project,
- a spec with a `require` that no checkout resolves (`ctx.unresolved = "absent"` makes the absence part of the key:
  right for optional plugins checked with `pcall(require, ...)`, valid while the runtime path is the one the run
  uses; with a spec that also changes the search path the whole project joins the key),
- a spec with `-- @cache off` (or a project file the spec loads, or a Lua file of a runtime directory of the project,
  which every spec loads), a spec path outside the project, a declared input outside the project, or a
  dependency closure of more than 3000 files, or a project too large to hash when it has to be,
- a directory the key has to read that cannot be listed (`unreadable directory: <path>: <reason>`: a runtime directory, a
  declared input, the data next to a module, the whole project, the modules below a computed `require` prefix, the
  runner's own `lua/testing`: `the runner cannot be hashed`). A directory that cannot be listed is not an empty one:
  the files below it would be missing from the key, and an edit of one of them (a spec can open a file in a directory
  that can be entered but not listed) would be served a stale pass,
- a spec whose key has given different results (`pass` once, `fail` another time): `nondeterministic`, see
  [below](#the-cache-proves-itself-audit-and-key-flip).

**Known limit, by decision.** The clock, random numbers, processes and the network of a MODULE do not block the key
(only a spec's own calls do): in `lib.nvim` and in most plugins they are timers, throttles and log stamps, and judging
every helper would leave almost nothing cacheable (measured on markdown.nvim: 3 of 47 files cacheable when every module is judged, 22 of 47 when only the spec is). A process or a connection that a
module really starts is seen by the effects ledger at run time and `put` refuses the file; a clock is not seen. A spec
whose verdict depends on a clock value read inside a module is flaky by nature; mark it `-- @cache off` or vouch for the
module with `-- @cache-allow` (which is then a statement, not a guess).

### What is never stored

`cache.put` refuses a file with a case that is not a plain `pass`, a retried case (`--retry-failed`: a case that
failed and then passed is flaky, also under `--allow-flaky`, and the run reports the file as flaky), an effect in the ledger (spawn,
network, write outside tmp), a guard finding, a flaky file, a timeout or crash, a partial run (a case selection:
`--filter`, `--lf`, ...), or cases that are themselves cached. Guards that are off do not make a file
uncacheable; the static markers above are the authority for spawn and network.

### A hit

`cache.get(key, opts)` returns the cases with `cached = true` and the note `cached from <run id>`; the status stays
`pass`. A cached case was not executed: the guard layer and the effects ledger must not count it as having run, and
its (empty) effects are not a measurement.

### Entries are untrusted input (SEC-33)

An entry is validated when read back: size cap before decoding, `pcall` around the decode, version, key equal to the
file name and to the key asked for, file equal to the file asked for, every case a `pass` of that file with an empty
ledger and no guard finding or error, and the case list valid against the Result-IR schema. Anything else is a miss
with a reason (`absent`, `corrupt`, `invalid: ...`, `entry too large`), never a partial hit. Anything that is not an
entry (files in the directory that do not have a key as name) is never touched by `prune` or `clear`. The one
exception is a DIRECTORY named like an entry (`<64 hex>.json/`): nothing could ever write that key again, so `put`
replaces it and `clear` removes it (a link is unlinked, never followed).

### Hash index and the stat pre-check

`<dir>/index.json` remembers, per file, `mtime`, `ctime`, inode, size, content hash and the static analysis. A file whose
size, mtime, ctime and inode match, and that was already at least two seconds old when it was hashed (git's "racy"
rule), is not read again. The `ctime` is what `touch -r` cannot reset: an edit that keeps size and mtime exactly still
moves it. The analysis is kept only while the scanner that wrote it is the one that runs (`scan` in the index header,
`testing.affected.scan.VERSION`): a better scanner reads every file again. The index is validated when loaded; a bad
index is ignored (everything is hashed again). Within one run a file is hashed, analysed and stat-ed once (`ctx.memo`),
so a closure of 600 files costs its listing once, not once per spec. `--no-cache` keeps this index off the disk as
well: `--changed --no-cache` reads and analyses the files it needs and writes nothing below the cache directory.

A directory tree that joins a key (fixtures, the spec root, the whole project) is walked **through symbolic links and
junctions**: a linked directory is entered once per real directory (a link that points back at an ancestor ends
there), up to 64 of them; more means no key.

### API

```lua
local cache = require("testing.cache")

cache.key(file_info, ctx)          -- key | nil, reason, parts
cache.get(key, opts)               -- cases | nil, reason
cache.put(key, cases, meta, opts)  -- stored, reason
cache.wrap_file(runner_fn, file_info, ctx) -- cases, { status = "hit"|"miss"|"uncacheable"|"off"|"refreshed", key, reason, stored }
cache.resolve_mode({ cached, no_cache, refresh, config_cached }) -- "use" | "off" | "refresh"
cache.stats(opts)                  -- disk state and the counters of this process
cache.prune(opts)                  -- age, bytes, entries
cache.clear(opts)                  -- --cache-clear; state is reset in place
cache.flush()                      -- write the hash index (once at the end of a run)
cache.analyzer(ctx)                -- abs path -> static analysis, backed by the hash index
```

`file_info = { file = "TESTS/x_spec.lua", dialect?, deps?, deps_complete?, extra? }` (`extra`: files that decide what the spec
does without being required by it, hashed into the key: the `minit`, a harness). `ctx` carries `root` and the key inputs
(see `Testing.Cache.Ctx` in `lua/testing/cache/init.lua`); make a new `ctx` per run, it holds the directory
memo of that run. `runner_fn()` returns the case list of the file and optionally a table
`{ flaky?, timed_out?, crashed?, partial? }` that keeps the result out of the cache.

`testing run` itself uses `key`, `get` and `put` (before and after the driver, see
[above](#how-a-run-uses-them)) and not `wrap_file`: a pool of child editors takes a list of files, not one closure
per file. `wrap_file` is for a caller that runs one file at a time.

### `testing explain`: why this spec

A cache that skips runs has to be answerable. `testing explain <spec>...` says, per spec file and without running or
changing anything:

```
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua explain . TESTS/x_spec.lua [--json] [--parts]
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua explain . --all [--json]
```

- **selection**: selected, or left out by `--changed` / `--since` / `--affected` (give the same flags), with the reason
  `affected.select` gives for the spec (`reaches proj.a <- proj.b (lua/proj/b.lua changed)`); without a flag every spec
  file runs;
- **cache**: `hit` (a valid entry exists under the key; the run that stored it), `miss`, `uncacheable: <reason>`, or
  `off` (a case selection such as `--filter` makes the cache unusable);
- **miss**: what differs from the most recent entry of that file: a dependency or input file by name with its old and
  new hash (12 hex digits, never content), the Neovim version, an environment variable by **name** (never its value),
  the configuration, `.testing.lua`, the runner. An entry of an older version has no key lines: the answer is
  `comparison not possible`, never an error;
- **uncacheable**: the reason with the file and the line the scanner found it at (`TESTS/x_spec.lua:12  local t =
  os.time()`) and the way out (`-- @cache-allow time`, `-- @cache-inputs <path>`, `env_allow`, `-- @cache off`);
- `--parts` lists the lines the key is the hash of. `--all` sums up every spec file: the hit rate and the reasons
  of the files that have no key, most frequent first; with `--json` it is one document (`testing-explain/1`).

Everything else a run accepts (`--config`, `--isolated`, `--env-allow`, ...) is accepted and means the same, because the
key depends on it. Text that comes from the project (file names, environment names, module names) is cleaned like every
line a run prints.

The explanation is **never computed twice**. `cache.key` returns the key, the reason there is none, the lines it is the
hash of (`parts`) and the same reason as data (`detail`: `kind`, file, line) from one call; `testing explain` and the
entry that `cache.put` writes (`parts`: names and hashes, at most 5000 lines of 400 bytes, no file content, no
environment value) both use exactly that, and a spec proves that the sha256 of the lines is the key.

### The cache proves itself: audit and key flip

The key is as sound as the scanner: it cannot see a file read by a path that is computed at run time, or the clock of a
module (see "Known limit" above). Two cheap procedures find out whether it lies.

**Audit** (`--cache-audit <0..1|all>`, implies `--cached`). The given share of the cache hits runs anyway and is
compared with the stored result (the cases and their statuses). `all` re-runs every hit; a fraction picks hits by a hash
of the key and a salt that is the clock by default, so two runs pick different hits (a series of audits covers the
cache; a run is reproducible only with a fixed salt, which the specs use). A difference is the finding `cache.stale_pass`: the file, what
differs, the first key lines, and the two possible causes (an input the key cannot see, or a spec that is not
deterministic); the run exits 1 and prints no sentinel. The stored entry of that file is deleted and nothing new is
stored for it. The **measured stale-pass rate** is `differences / audited hits`; it is in the terminal line

    cache (use): 0 of 27 spec file(s) were not run ...; audit: 27 of 27 hit(s) ran again, 0 differ (stale-pass rate 0.0%)

The first number counts the hits that ran again, the second ALL hits (those that ran again, those that were not
picked, and those that were picked but gave nothing to compare: the run stopped early or the file lost its cases;
the line then says `(n picked but skipped: ...)`). The terminal lists at most 20 findings. In `run.cache` of the IR:
`audit_rate`, `audited`, `audit_skipped`, `stale_pass`, `stale_pass_rate` and the `findings` (code, file, key, message,
key lines; the first 20, with `findings_total` as the count of all of them). A finding is also a red verdict for the
other reporters: the JUnit document carries a failed `run verdict` case, the GitHub summary says FAILED and an error
annotation names the verdict, so a viewer that only counts failed cases does not show a green run. The audit is statistical: a sample that finds nothing does not prove there is nothing. A
spec that is flaky shows up as a stale pass too; the finding names both causes. With a share of 0 nothing changes
(the output is the output of a plain `--cached` run). A nightly recipe on the main branch:

    nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . --cached --cache-audit all

**Key flip** (`testing.cache.keylog`). Per spec file the run remembers `(key, result class)` of the files that ran
(`stdpath('state')/testing/<project>/keys.json`, at most 12 records per file, bounded and untrusted when read back like
the history; an unusable file is an empty memory and a note says so). The result class of a file is `fail` when a case
is red, `flaky` when a case passed only after a retry (`--retry-failed`, also under `--allow-flaky`), `skip` or `pass`;
when the list of a file is full the record that was used longest ago goes. The same key with two different results (`pass` and `fail`, or a skip) is proof that the file is not
deterministic: either it is flaky, or an input the key cannot see changed between the runs. The file is marked
`nondeterministic`: it has no key, nothing is stored for it and its entry is discarded, until the spec declares
`-- @cache-allow nondeterministic` in its header. A changed input is a new key and a new record, and
`--cache-clear` forgets the memory as well. `testing explain` names
the mark and the results the key gave; the run line counts them.

### Stamp

`--cached` answers "may this file be skipped" with entries that live in a path-dependent directory of one machine. A
**stamp** turns the same keys into a small statement that can be carried: "at this commit and this tree, a complete run
was green, and these were the keys". `testing verify` recomputes the keys (no spec runs) and tells whether anything a
key can see has changed since ([CLI.md](CLI.md#stamp-and-verify) has the commands and the answers).

```
testing stamp .              # a full run; after the verdict `green` the stamp is written
testing verify .             # verified | partial | changed | rejected | expired | dirty | untrusted | invalid | no-stamp
```

**What is in it** (`schema = "testing-stamp/1"`, JSON, sorted, no secrets): the commit and the tree of the project
directory (and whether the tree was dirty), the run id and time, the origin (`local`, or `ci` with event and ref and
whether that ref is trusted), runner digest, Neovim version with API level, OS and architecture, the configuration
digest, and per spec file either its cache key or `uncacheable: <reason>` (no absolute path: the root is `<root>`; no
environment value). A `digest` is the sha256 of the canonical text of all that, and an optional `hmac`. Environment
variables are never written, only their names appear in a reason.

**Line endings and the stamp.** The keys read CRLF as LF ([Line endings](#line-endings)), so a stamp written on a
checkout with LF verifies on a checkout of the same commit with CRLF (and the other way round) for every spec file that
does not look at line endings itself. Those that do (and the ones that read a file with CRLF) have a key that depends
on the checkout; `verify` reports them as `changed` on a checkout with other line endings, never as `verified`. The
stamp is still bound to one OS and architecture: `testing stamp` on Linux and `testing verify` on Windows is `rejected`.

**When it is written**: only for the verdict `green` of a run that selected every file and every case (`stamp` refuses
`--changed`, `--filter`, a path, `--maxfail`, ... up front), never for `green-partial` or `red`, never after a
`cache.stale_pass`. A skip, an accepted flaky case or a stop are `green-partial`: no stamp.

**What it is about: the inputs the specs were given.** The keys (and the git facts) are taken BEFORE the first spec
runs, and the stamp lists those. After the run the keys are computed again; if any file has another key now (an editor
that saved, a formatter, a spec that rewrote a source during the run), the run was green against the earlier content
only, and the stamp is **not written** (`testing: stamp: not written: an input changed while the run was going`, exit
1, the same rule that keeps the result cache from storing such a file). The same goes for a changed runner, Neovim or
configuration digest and for a checkout whose commit or tree moved during the run. The keys of after the run are
computed with the runtime path, the environment and `package.path` of before it: an in-process spec that changes those
(they are no input that moved) cannot make the stamp unwritable, but a file can. A file the run itself made
`nondeterministic` (the key gave another result than before) is listed as not provable. `head.dirty` is set when the
tree was dirty before or after the run.

**What `verify` proves, and what not.** It proves that every file has the same cache key as in the green run:
the spec, everything it `require`s, the files it reads, runner, Neovim, configuration, environment names, dialect
and seed. It proves exactly as much as the key does, so every limit above ("Known limit", "Limits and decisions")
applies: a file read by a computed path or a clock inside a module is not seen. A file without a key (clock, process,
network, an unresolvable `require`, `-- @cache off`, a discovery finding, a key that gave different results) is
**never proven**: `partial`, with the reasons ranked, the files named and the command that runs them. A suite that has
such files can therefore never be `verified`; that is the point (markdown.nvim: 27 of 47 files came from the cache, so a
stamp there says `partial` and names the files that must run). The verdict equivalence rule: exit `0` and the
sentinel only when **all** files are proven.

**Rules that bound the claim.**

- *Age*: a stamp older than `--max-age` (default 7 days) is `expired`: the suite must run. A stamp from the future
  (clock skew over 5 minutes) is `invalid`.
- *Dirty tree*: `git status --porcelain` below the project directory must be empty (untracked files count),
  otherwise `dirty`: the keys would describe the working tree, which is not what is committed or pushed. `--allow-dirty`
  overrules, and the answer says it is about the working tree. A stamp that was written on a dirty tree says so
  (`head.dirty`); the keys still decide. `.deps/` (the checkouts of the dependencies, as CI makes them below the project
  directory) is not counted: its content is part of the keys, and without the exception a `.deps/` that is not in the
  `.gitignore` would make every tree `dirty`.
- *Environment of the keys*: `verify` computes the keys the way a run does, **after the `minit` of the project** (the
  runtime path a `minit` builds decides which module a `require` finds and is part of the key lines), and so does
  `testing explain`. The `minit` therefore runs in the process of `verify` and `explain` too, with whatever is in that
  environment (the HMAC secret included); if it fails, `verify` answers `rejected` and `explain` exits 3.
- *Conditions*: runner digest, Neovim version, OS/architecture or configuration digest differ: `rejected`, with the
  cause (`Neovim: v0.12.2|api14 -> v0.12.3|api14`; Neovim and OS are shown whole, the build of a nightly is the part
  that differs). Every key would differ anyway; the cause is the useful part. A stamp that an earlier build wrote
  (it recorded the API level as `apinil`) is `rejected` once for this reason: write it again.
- *Key flip*: a file whose key gave different results (`testing.cache.keylog`) has no key now, so it is not proven.
  A `cache.stale_pass` finding of an audit that found the same result class is not remembered by the stamp: age and the
  nightly audit bound it (the stale-pass rate is measured, see below).
- *Trust*: a **local** stamp counts only on a developer machine, a **CI** stamp only in CI, and in CI only a stamp
  that CI itself wrote on a trusted ref: the event must not be a pull request (`push`, `schedule`, `workflow_dispatch`)
  and the ref must be one of `refs/heads/main`, `refs/heads/master` (or the comma list in
  `TESTING_STAMP_TRUSTED_REFS`). The origin is what the writer said of itself, so on its own it is an honest-writer
  rule, not authentication. Therefore, **in CI a stamp is never green without a checked HMAC**: without
  `TESTING_STAMP_SECRET` the answer is `untrusted`, unless `--allow-unsigned` is passed explicitly (then authenticity
  rests on where the file came from, and the answer says so).
- *HMAC*: with `TESTING_STAMP_SECRET` (at least 16 characters) set when writing, the stamp carries an HMAC-SHA-256 of its
  canonical text; with the secret set when verifying, a stamp without or with a wrong HMAC is `untrusted`. This is what
  makes a forged stamp (digest recomputed by someone with a text editor) fail. Without a secret the digest only shows
  damage and clumsy edits; the answer says that the HMAC was not checked. `--require-hmac` refuses a stamp unless the
  secret is set. The secret is read from the environment only and appears in no file, output or message. Give it to
  CI as a repository secret that pull requests from forks cannot read, and never let a pull request job write stamps.

**The file is untrusted input** (like cache entries, SEC-33): a size cap (8 MiB) before decoding, a decode under `pcall`,
a closed schema and version, every field type-checked, plain text without control characters, bounded lengths and file
count, relative paths without `..`, files strictly sorted and unique, a digest that must match, time values within
bounds. Nothing in a stamp becomes a path, a command or an argument of git. git is called with argv lists only, and
the tree id it returns is checked to be 40 or 64 hex digits before it is used.

**Transports.**

- *File*: the default location is `stamp.json` in the state directory of the project (not in the checkout: it would
  make the tree dirty). `--out <file>` writes anywhere, `verify --stamp <file>` reads from anywhere. This is the form
  for `actions/cache` or an artifact between CI jobs ([CI-CACHE.md](CI-CACHE.md)).
- *git note* (built): `testing stamp --note` attaches the stamp to the **tree** object under `refs/notes/testing`, and
  `testing verify --from-note` reads the note of the tree of `HEAD`. Checked on 2026-10-07 with git 2.53 for Windows:
  `git notes add <tree-id>` works for a tree object (git notes accept any object name), `git notes show <tree-id>`
  reads it back, and a rebase, a squash or a revert that leads to the same tree finds the same note; another tree has
  none. Notes are not fetched or pushed by default (`git push origin refs/notes/testing`, `git fetch origin
  refs/notes/testing:refs/notes/testing`), writing one needs a git identity, and a note is exactly as trustworthy as
  whoever can push `refs/notes/testing`: protect the ref, or use the HMAC. The `pre-push` hook of
  [HOOKS.md](HOOKS.md) lets a push of `refs/notes/*` to `refs/notes/*` through without a check (it carries no code).
- *Commit status* (not built): GitHub accepts a short description with a status; put only the `digest` there
  (`testing-stamp:<digest>`), never the stamp, and compare it with the digest of the file that came by another way.
  It needs a token with write access to statuses, which a command line tool of this project does not hold, so a
  workflow step does it (`gh api`).

**Red run: since when.** After a red run the report already names the last full green run and the files that differ
from its commit (`last_green.json`, [OUTPUT-FORMATS.md](OUTPUT-FORMATS.md)); the stamp's commit and the `changed` list of
`verify` say the same thing for a stamp that came from elsewhere.

**Measured** (Windows 11, Neovim 0.12.2, 2026-10-07, a copy of lib.nvim with 87 spec files, three runs in a row):
`testing verify` took 1.59 s, 1.28 s and 1.21 s from process start to the answer (editor start, discovery, the keys of
all 87 files, three git calls, the runner digest). That answer was `rejected` for the runner digest (the checkout of
this runner changed while the measurement was going), which is decided only after all keys were computed, so the time
covers the whole check. The stamp of that suite says 17 files with a key and 70 without (30 read the environment by a
computed name, 28 the clock, 9 start a process): `verify` there is `partial` by construction, and the stamp is worth
little for lib.nvim today; for a suite of pure specs it is the whole suite. The earlier estimate of 0.2 to 0.5 s is not reached on this machine: the key phase dominates, not the editor start.

### API

```lua
local cache = require("testing.cache")

cache.key(file_info, ctx)          -- key | nil, reason, parts, detail
cache.get(key, opts)               -- cases | nil, reason
cache.peek(key, opts)              -- entry | nil, reason  (like get; changes nothing: no counter, no refreshed age)
cache.put(key, cases, meta, opts)  -- stored, reason  (meta.parts: the key lines kept in the entry)
cache.discard(key, opts)           -- delete the entry of a key
cache.latest(opts)                 -- file -> { key, run, ts, parts } of its most recent entry
cache.wrap_file(runner_fn, file_info, ctx) -- cases, { status = "hit"|"miss"|"uncacheable"|"off"|"refreshed", key, reason, stored }
cache.resolve_mode({ cached, no_cache, refresh, config_cached }) -- "use" | "off" | "refresh"
cache.stats(opts)                  -- disk state and the counters of this process
cache.prune(opts)                  -- age, bytes, entries
cache.clear(opts)                  -- --cache-clear; state is reset in place
cache.flush()                      -- write the hash index (once at the end of a run)
cache.analyzer(ctx)                -- abs path -> static analysis, backed by the hash index
```

## Affected selection

(`testing run --changed`, `--since <rev>`, `--affected[=<rev>]`; how a run uses it: [above](#how-a-run-uses-them).)

```lua
local r = require("testing.affected").select({
  root = root, specs = discovered_spec_files,   -- relative paths
  mode = "changed" | "since" | "affected", since = "<rev>",
  implicit = false,                             -- true: not asked for by the person (a default, a config key)
})
-- r.files    the specs to run, in discovery order
-- r.reason   spec -> why ("spec file changed", "reaches proj.a <- proj.b (lua/proj/b.lua changed)", ...)
-- r.unknown  changed files nobody could place
-- r.all      true: the selection cannot be trusted, r.files is EVERY spec and r.all_reason says why
-- r.source   "graph" | "heuristic" | "none";  r.warnings, r.ci, r.graph
```

### Changed files

`git diff --name-only -z --no-renames --relative <base> --` plus `git ls-files --others --exclude-standard -z`, as
argv lists with `cwd = root`; no shell. `<base>` is `HEAD` (`--changed`), the given revision (`--since`) or `HEAD~1`
(`--affected`). A rename counts as a delete plus an add, so the old path is a changed file too. A revision is verified
as a commit first. A path git prints that is absolute, climbs out of the root or holds a control character is not
trusted and selects everything.
Files that `.gitignore` hides (generated modules, built data) cannot be diffed: those below `lua/` and the spec roots that
are newer than the base commit (`git ls-files --others --ignored`, at most 5000) count as changed, and more than that
selects everything.

### Rules (never fewer than needed)

Selects **all** specs, with the reason named, when

- git cannot tell what changed (not a repository, unknown revision),
- a changed file cannot be placed (`unknown`): not a spec, not a `lua/**.lua` module, not a support file of the spec
  tree, not a document, not an ignored kind (`.github/`, `LICENSE`, `.gitignore`, `.gitattributes`); `.testing.lua`,
  `plugin/` and tool configuration are such cases,
- the module graph is stale, says `complete = false`, names a spec that does not exist, or does not know a changed
  module,
- the run is in CI **and** the selection was implicit.

In CI an explicit `--changed`/`--since`/`--affected` runs but warns. `--affected` is never the default in CI.

Otherwise a changed spec selects itself, and

- a changed module selects the specs that reach it or one of its parents through `require`s (computed names count),
- a changed support file (helper, fixture, harness) selects every spec below the TOPMOST directory that holds specs
  (or below its spec root), and every spec that requires a module its path spells (`TESTS/a/helper.lua` is `a.helper`
  and `helper`): a helper below `TESTS/a/` is put on `package.path` by a spec of `TESTS/b/` as easily,
- a spec that names the changed file, or a directory above it, in a path literal is selected,
- a document (`*.md`, `README*`, `docs/**`, `doc/*.txt`) selects only the specs that name it, and the ones below,
- a spec that LISTS directories (`vim.fs.dir`, `glob`, `fs_scandir`, ...) or loads files by path (`:runtime`,
  `:source`) can see any file: it is selected whenever anything changed; a module of the
  project that does so counts as changed whenever anything changed, so the specs that require it are selected,
- a spec that starts a process is selected whenever a module changed, because the code it runs is invisible to any
  graph,
- ignored files (`.gitignore`) below `lua/` and the spec roots that are newer than the base revision count as changed
  (generated modules; git cannot diff what it ignores).

### The graph: documentation.nvim contract, soft-required

```lua
require("documentation.testing").affected_specs({ root = root, changed = { "lua/a/b.lua", ... }, spec_roots = { "TESTS" } })
  -> { version = 1, specs = { "TESTS/x_spec.lua", ... },                 -- relative paths
       modules = { { id, module, path, role = "changed"|"dependent", specs }, ... },
       unplaced_specs = { "TESTS/dyn_spec.lua" },                        -- the graph cannot place them: run them too
       ignored = { "README.md" },
       complete = true,                                                  -- may a narrowed selection be trusted?
       graph = { generated_at, commit, stale = false, dirty, gaps = { { kind, path, module, reason, message }, ... } } }
   | nil, err
```

This is the shape `documentation.nvim` (`docs/testing-contract.md` there) really answers; a recorded real answer is
in `TESTS/testing/fixtures/affected/`, and the consumer is tested against it. **The graph only adds.** It cannot see a
`require` built from a variable, a spec that names a file by path, or a spec outside the directories it scans; the
heuristic below sees those. The selection is the union of what the heuristic reaches and what the graph names (plus
its `unplaced_specs`); a graph can make the selection bigger, never smaller. `complete = false` (a stale graph, a gap
that blocks) is not narrowed: everything runs, and the reason names the kinds of the gaps. A changed module file the
answer does not place (neither a node, nor a gap, nor `ignored`) is incomplete as well.

When the module is absent, throws, answers `nil, err` or answers a shape that does not match, the built-in heuristic
is used and `r.warnings` says why. The heuristic builds the `require` graph of the project itself (`lua/**.lua`):
literal `require`s, computed prefixes (`require("a." .. x)` depends on every module below `a.`), and an unresolvable
`require(expr)` as a dependency on everything; the reverse closure of the changed modules and of their parent modules
(`a` for `a.b`) selects the specs. It is always current (no generated file), and it only knows this project.

**Require wrappers.** A module that computes `require(name)` for its callers (a lazy loader: `lazy.require("lib.x")`)
is, seen alone, a dependency on everything, and so is every module that requires it. A module can declare itself with
`-- @require-wrapper require module fn` in its first 30 lines (the functions whose **first argument** is the module
that gets loaded: the author vouches for that). The heuristic then reads the call sites: `local lazy =
require("lib.lua.lazy")` followed only by `lazy.require("lib.x")`, or `require("lib.lua.lazy").require("lib.x")`, is
an edge to `lib.x`, and the wrapper is no longer a dependency on everything. A file that uses the wrapper in any
other way (passes it on, a computed or concatenated name, a member that is not declared, `pcall(require, ...)`,
the alias bound twice, a name that matches the wrapper by a prefix) is a dependency on everything, as before: when
in doubt everything is selected. The cache key does not use this reading (a computed `require` stays "every module"
there). The measurement on lib.nvim is in [PERFORMANCE.md](PERFORMANCE.md#incremental-run-the-d7-budget-under-1-s-median-measured-2026-10-07).

### `testing doctor`: freshness

`affected.graph_freshness(root)` returns `{ status = "ok"|"stale"|"missing"|"unknown", message }`. `docs/map/module_map.json`
is stale when it is older than the last commit that touched anything but `docs/map`, or older than an uncommitted
change of a `lua/` file. `testing doctor` is to warn on `stale` and `missing`.

### Out of scope

Cross-repo **selection** (running the specs of the plugins that use lib.nvim) is not done by testing.nvim: a changed
file of another checkout is not a changed file of this project, and a selection never contains a spec of another
repository. What it does is **name** them: `--consumers <dir>` (or `affected.consumers` in `.testing.lua`) passes the
directory to `affected_specs` of documentation.nvim, reads `cross_repo` (per consumer: the affected specs relative to
that consumer's root, or `measured = false` for a checkout without a usable map; "not measured" is not "not
affected") and prints it; see [CLI.md](CLI.md#affected-selection). It is a hint that never changes the selection of
this project. The cache covers the other direction: a spec that loads lib.nvim has the lib.nvim files it loads in its
key.

## Measurements

**Stale-pass rate** (the share of cache hits that a fresh run contradicts, `--cache-audit all` after a warm `--cached`
run; Windows 11, Neovim 0.12.2, 2026-10-07, one run each): markdown.nvim 0 of 27 audited hits, ui.nvim 0 of 29. The key
that this section's other numbers rest on was therefore right for those two suites on that day. A sample of what the
key accepts cannot show what it misses by construction (a path computed at run time): the built-in test of the audit
(`cache_audit_spec`) is exactly such a spec, and the audit finds it.

The numbers are in [PERFORMANCE.md](PERFORMANCE.md#cache-and-affected-selection) (warm and cold runs of six suites,
the cost of a key, the precision of the selection on 20 commits of two repositories). In short: a suite of many small
pure specs is about a third faster warm (markdown.nvim 18.0 s to 12.3 s with 27 of 47 files from the cache), a suite
whose files read the clock, start processes or name places outside the project gets almost nothing (images.nvim,
casedesk.nvim), a cold `--cached` run costs a few percent to a third more than a plain one (the first hashing), and a
key of 100 specs costs about 70 ms once the index is warm. The selection is a superset: lib.nvim 60 of 87 specs on
average, documentation.nvim 67 of 107, with everything selected for a change nobody can place and nothing for a change
that only touches CI files.

## Limits and decisions

- The scanner is not a parser. It over-approximates (more dependencies, more hidden inputs), never under-approximates
  by design; it can miss a dependency that is reached only through a string that is built at run time (see "Files the
  spec reads"): that is the stale pass the key cannot rule out.
- What an editor loads that is not a file of the project is not in the key: the runtime directories of a dependency
  checkout (`.deps/*`, `ctx.dep_roots`, the runtime path: only its `lua/` closure is hashed, a `ftplugin/` or `queries/`
  there is not), the `require`s inside Vim script files of the runtime directories (`lua require("x")` in an
  `ftplugin/*.vim`: only Lua files are followed), and `stdpath('data')/site`, which a child editor has on its runtime
  path for the installed Tree-sitter parsers and queries (a machine input like the Neovim build and the OS: updating a
  parser does not change a key; the Neovim version does). A spec whose verdict depends on one of them runs with
  `--no-cache`, or carries `-- @cache off`.
- Of the files the editor looks for by name, the `.editorconfig` of the project ROOT is in the key; one in a directory
  above the root, or next to a file below it that the key does not hash (the plugin walks up to the first
  `root = true`), is not. The same holds for `~/.editorconfig`. A spec that reads the indent of a file outside the
  project runs with `--no-cache`.
- The clock and random numbers of a module, and the processes of a module that the run did not start, do not block a
  key (see "When there is no key"). `-- @cache-allow` and `-- @cache off` are the author's tools for the exceptions.
- The stat pre-check relies on size, mtime and ctime. On a filesystem whose ctime does not change on write (seen on
  Windows CI runners) a content change that restores size and mtime is not detected by the pre-check; use `--no-cache`
  or `--cache-refresh` where that matters.
- A run with cache hits keeps the sentinel (`TESTING_OK`): the cache promises the verdict of a full run. A script that
  must not be satisfied by earlier results passes `--no-cache`; CI does not use the cache by default.
- The graph of `documentation.nvim` does not see a `require(variable)` (documentation.nvim task); this consumer does
  not depend on that, because the heuristic sees it and the selection is the union.
- What the scanner does NOT count as a hidden input (each has a spec that turns red when the rule is dropped, and the
  contrary cases that still count): a table field or injected function named `environ` (`ctx.environ`, `environ = fake`:
  only `vim.fn.environ`, `os_environ`, `call("environ")` and a bare `environ()` are reads of the whole environment);
  `vim.env` that is only tested (`if vim.env then`, `vim.env and`, `vim.env == nil`); a table field named `os`
  (`{ os = "x" }`: no alias of the `os` table); the literals `".."`, `"../"` and `"~/"` that are only compared with or
  asked for as a prefix, suffix or plain needle (`seg == ".."`, `starts_with(p, "~/")`, `find("..", 1, true)`: a path
  validator, no path read) and a lone `..` word of a command string (the Lua operator); a literal that is only
  backslashes (`"\\"` is one backslash, no UNC path). A literal that is built into a path (`joinpath(root, "..")`,
  `"~/" .. rest`) or an ex command with a file argument (`edit ..`) still names a place outside the project.
- Conservative defaults over hit rate: a file that reads the clock is not cached even when it only measures a
  duration. Mark a spec's dependencies with `-- @cache-inputs`, or restructure the spec, to get it into the cache.
- The cache key does not include the machine's file system or locale beyond what the configuration lists; a spec that
  depends on them must list the variables (`env_allow`) or opt out.
