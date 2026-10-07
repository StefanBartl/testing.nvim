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
| `--cache-clear` | delete the cache of this project and exit |
| `--changed` | only specs affected by the working tree against `HEAD` (tracked changes and untracked files) |
| `--since <rev>` | the same against a revision |
| `--affected [rev]` | the same against `rev` (default `HEAD~1`); a developer tool |

`--changed`, `--since` and `--affected` exclude each other. A revision is validated before it reaches git (no leading
`-`, no range, no whitespace or shell characters).

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
   `run.cache` of the IR carries `{ mode, files_cached, cases_cached, files_ran, stored }`.

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
(`lib.nvim.fs.write.atomic`).

Bounds (`cache.prune`, run once per process after the first write): entries older than 30 days go, then the oldest
until the store is within 64 MB and 5000 entries; a hit renews the age. An entry larger than 4 MB is not stored.

### The key

`cache.key(file_info, ctx)` returns the sha256 over

- the spec path and the content hash of the spec file,
- the content hash of every file it depends on (below),
- the runner version: a content digest of `lua/testing` (a dirty checkout differs from a clean one),
- the Neovim version, API level, OS and CPU architecture,
- name and hashed value of every environment variable the configuration lists (`env_allow`, `PREFIX*` expands over
  the names that are set; a new variable below a listed prefix changes the key),
- a digest of the effective configuration and the content of `.testing.lua`,
- the dialect, and the seed when the run is shuffled.

**Dependencies, as far as they are known.** The transitive closure of the spec's `require`s, resolved in the project,
`ctx.dep_roots` and (default) the runtime path, so a change in lib.nvim invalidates the specs that load it. A literal
`require("a.b")` is an edge; `require("a.dialect." .. name)` is an edge to every module below `a.dialect.`; a
`require(expr)` nobody can resolve is an edge to every module of the checkout it appears in. A graph can replace the
scan (`file_info.deps` with `deps_complete = true`).

**Hidden inputs of the whole closure.** A spec is only as deterministic as the files it loads, so the markers
(below) are read from the spec AND from every file of the closure that belongs to the project (a dependency checkout
such as `lib.nvim`, found on `ctx.dep_roots` or the runtime path, or below `.deps/`, contributes its content to the key
and nothing else: it is tested in its own repository):

- a project module that reads files makes the spec a file reader (next paragraph), and the data files that lie next to
  that module (its directory, without the `.lua` files, which the closure already hashes) join the key,
- a project module that reads a literal environment variable adds that variable's hashed value to the key; one that
  computes a name has no key,
- code that loads files by an ex command or a runtime-path lookup (`:runtime`, `:source`, `:luafile`, `packadd`,
  `nvim_get_runtime_file`), or a spec that changes `package.path`/`rtp` and then `require`s a module that nothing
  resolves, takes the **whole project** (everything below the root except `.git`, `.deps`, `.cache`,
  `node_modules`) into the key,
- a string literal that names a place outside the project (`../x`, `C:/x`, `~/x`, `/etc/x`, read from the root and
  from the directory of the file that names it) in a spec or module that reads files means **no key** when it names a
  file or directory that EXISTS there: the key cannot see it. A literal that names nothing (the string of a test of a
  path function) is no read: it is in the key as absent, and the file that appears there changes the key,
- a spec that runs in a CHILD editor (every `--isolated file|case` file, every busted file by default) is keyed by the
  whole environment that child sees (`testing.child.env`: the allowlist over this process's environment): no variable
  it reads is judged by name any more, and a computed name needs no exception. A file that runs in this editor
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
```

`-- @cache-allow time random spawn net` is the author's statement that the clock, random numbers, a process or the
network that this file uses do not decide what a spec sees; the file is then not judged for them.

A path that is **computed** at run time, with no literal anywhere (`root .. "/" .. ("da" .. "ta") .. "/x.txt"`), is not
seen. That is the one stale pass this key cannot rule out: declare the path, or opt the file out with `-- @cache off`.

### When there is no key (the file is never cached)

`cache.key` returns `nil, reason` when the inputs cannot be known. When in doubt, do not cache. Never cached:

- a spec that reads the clock (`os.time`, `hrtime`, `os.date`, `.now()`, an aliased `os`, ...) or random numbers,
- a spec that starts a process or touches the network (`vim.system`, `jobstart`, `io.popen`, `curl`, ...),
- a spec that reads an environment variable that is not part of the key, or computes the name; a project module that
  computes a name,
- a spec or project module that reads files and names an EXISTING place outside the project,
- a spec with a `require` that no checkout resolves (`ctx.unresolved = "absent"` makes the absence part of the key:
  right for optional plugins checked with `pcall(require, ...)`, valid while the runtime path is the one the run
  uses; with a spec that also changes the search path the whole project joins the key),
- a spec with `-- @cache off`, a spec path outside the project, a declared input outside the project, or a
  dependency closure of more than 3000 files, or a project too large to hash when it has to be.

**Known limit, by decision.** The clock, random numbers, processes and the network of a MODULE do not block the key
(only a spec's own calls do): in `lib.nvim` and in most plugins they are timers, throttles and log stamps, and judging
every helper would leave almost nothing cacheable (measured on markdown.nvim: 3 of 47 files cacheable when every module is judged, 22 of 47 when only the spec is). A process or a connection that a
module really starts is seen by the effects ledger at run time and `put` refuses the file; a clock is not seen. A spec
whose verdict depends on a clock value read inside a module is flaky by nature; mark it `-- @cache off` or vouch for the
module with `-- @cache-allow` (which is then a statement, not a guess).

### What is never stored

`cache.put` refuses a file with a case that is not a plain `pass`, a retried case, an effect in the ledger (spawn,
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

### `testing doctor`: freshness

`affected.graph_freshness(root)` returns `{ status = "ok"|"stale"|"missing"|"unknown", message }`. `docs/map/module_map.json`
is stale when it is older than the last commit that touched anything but `docs/map`, or older than an uncommitted
change of a `lua/` file. `testing doctor` is to warn on `stale` and `missing`.

### Out of scope

Cross-repo selection (a change in lib.nvim selecting the consumers' specs) needs the reverse index of
documentation.nvim (`core/consumers.lua`) in the contract. Until the contract carries it, a changed file of another
checkout is simply not a changed file of this project. The cache covers the other direction: a spec that loads
lib.nvim has the lib.nvim files it loads in its key.

## Measurements

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
- The clock and random numbers of a module, and the processes of a module that the run did not start, do not block a
  key (see "When there is no key"). `-- @cache-allow` and `-- @cache off` are the author's tools for the exceptions.
- The stat pre-check relies on size, mtime and ctime. On a filesystem whose ctime does not change on write (seen on
  Windows CI runners) a content change that restores size and mtime is not detected by the pre-check; use `--no-cache`
  or `--cache-refresh` where that matters.
- A run with cache hits keeps the sentinel (`TESTING_OK`): the cache promises the verdict of a full run. A script that
  must not be satisfied by earlier results passes `--no-cache`; CI does not use the cache by default.
- The graph of `documentation.nvim` does not see a `require(variable)` (documentation.nvim task); this consumer does
  not depend on that, because the heuristic sees it and the selection is the union.
- Conservative defaults over hit rate: a file that reads the clock is not cached even when it only measures a
  duration. Mark a spec's dependencies with `-- @cache-inputs`, or restructure the spec, to get it into the cache.
- The cache key does not include the machine's file system or locale beyond what the configuration lists; a spec that
  depends on them must list the variables (`env_allow`) or opt out.
