# CI cache recipe

How to carry the result cache ([CACHE.md](CACHE.md)) and the green stamp ([CACHE.md, Stamp](CACHE.md#stamp)) from one
CI run to the next with `actions/cache`. The workflows of this repository (`.github/workflows/ci.yml`,
`nightly.yml`) and the `ci.yml` that `testing init` writes use exactly this.

## Why the key of `actions/cache` is only transport

Every cache entry is a file named by its full spec key (`entries/<64 hex>.json`) and is checked against that key when it
is read (SEC-33, [CACHE.md](CACHE.md#entries-are-untrusted-input-sec-33)). The key you give `actions/cache` therefore
decides only **which folder arrives on the runner**. A folder from the wrong commit, the wrong OS or the wrong
Neovim cannot produce a false hit: its entries carry other keys and are never looked up. The worst a bad restore does
is lower the hit rate. So the recipe may use a coarse key (per commit, with a prefix to fall back on) and does not have
to be clever.

What it cannot do is make a **forged** entry safe: structure is checked, origin is not. An entry that someone with
write access to the cache built correctly, with the matching key, is believed. That is the whole reason for the
rules below: never let a pull request or a fork write.

## The recipe

```yaml
- uses: rhysd/action-setup-vim@v1
  with:
    neovim: true
    version: v0.12.2            # pinned: the version is part of every key, `stable` moves and empties the cache
- uses: actions/cache/restore@v4   # restore only: a pull request must never write
  with:
    path: ${{ runner.temp }}/testing-cache
    key: testing-${{ runner.os }}-nvim0.12.2-${{ github.sha }}
    restore-keys: testing-${{ runner.os }}-nvim0.12.2-
- name: Run the specs
  env:
    TESTING_CACHE_HOME: ${{ runner.temp }}/testing-cache
  run: scripts/test.sh --cached --github --json "$RUNNER_TEMP/ir.json"
- uses: actions/cache/save@v4      # only the main branch, only after a green run
  if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'
  with:
    path: ${{ runner.temp }}/testing-cache
    key: testing-${{ runner.os }}-nvim0.12.2-${{ github.sha }}
```

- `--cached` is explicit on purpose: in CI `cache.enabled` of `.testing.lua` is ignored, only the flag counts.
- The key has the OS and the pinned Neovim in front of the commit: per commit so that every green main run stores a
  new state, with the prefix as `restore-keys` so the newest one of that OS and version is restored.
- `--cached` keeps the sentinel, because a cache hit promises the verdict of a full run.
- Move the Neovim version on purpose, in one place, and expect one cold run.

### Where the folder is, and why it must not depend on the checkout path

The cache folder is named `<name>-<12 hex sha256(project key)>` and the project key defaults to the absolute path of the
git root. On another runner or checkout path that is another folder, and the restored one would not be found. Two
switches fix that, and neither changes what an entry is:

- `cache = { project_key = "my-plugin" }` in `.testing.lua` names the folder after that key instead of the path
  (letters, digits, `_ . -`, at most 64).
- `--cache-dir <dir>` or the environment variable `TESTING_CACHE_HOME` sets the **base** directory (default
  `stdpath("cache")`); the folder `testing/<name>-<hash>` lies below it. The flag wins over the variable.
  `scripts/test.sh` passes the variable through.

A spec (`ci_cache_spec`) proves the premise: the same project in two checkouts at different paths has the same keys, no
key line contains a path of the checkout, a stamp made in one verifies in the other, and with `cache.project_key` a run
in the second checkout hits the entries of the first.

### State and cache are two directories

The result cache (`entries/`, the hash index) lives under the **cache** base. The run **state** (`runs.jsonl` for `--lf`,
`keys.json` of the key-flip memory, `last_green.json`, `durations.json`, the default `stamp.json`) lives under
`stdpath("state")`. `scripts/test.sh` gives each run a throwaway state directory. Consequences in CI:

- A cache restored without its state still works; what is lost is the memory of keys that gave different results (key
  flip), the failed-first order and the durations. A nightly audit (below) is what catches what CI cannot remember.
- If you want that memory to travel, cache the state directory as a second path with the same rules. It is not needed
  for soundness.
- Do not put `--out` of a stamp inside the checkout: a file in the tree makes the tree dirty and `verify` says so.

## Rules that keep it sound

1. **Pull requests and forks read, never write.** `actions/cache/restore` for them, `save` only on the main branch.
2. **Never run `save` after a red run, or in a job a pull request controls** (`pull_request_target` with a checkout of
   the pull request's code is the classic mistake).
3. **Pin Neovim**, and let the version be in the key.
4. **Audit on a schedule.** `.github/workflows/nightly.yml` runs the suite once without the cache and once with
   `--cache-audit all` against the restored cache (every hit runs again and is compared; a difference is
   `cache.stale_pass`, exit 1). The measured stale-pass rate is the number that says whether the key can be trusted for
   this suite ([CACHE.md](CACHE.md#the-cache-proves-itself-audit-and-key-flip)).
5. **Size**: the store prunes itself to 64 MB, 5000 entries and 30 days; keep the provider limits below in mind.

## What `actions/cache` guarantees (checked at the provider, 2026-10-07)

From the GitHub documentation "Dependency caching reference" (fetched 2026-10-07):

- *Immutable per key*: you cannot change the contents of an existing cache; a new cache needs a new key. A `save` to an
  existing key does not replace it, hence the commit in the key.
- *Visibility*: a run can restore caches created in the current branch or the default branch; a pull request can also
  restore those of its base branch; sibling and child branches do not share caches (a cache created for a child branch
  is not accessible to a run on its parent); forks follow the rules of the base repository's branches.
- *Limits*: 10 GB per repository by default; entries not accessed for 7 days are removed; beyond the limit the least
  recently accessed go first.
- *Matching*: `restore-keys` are tried in order, a prefix match restores the most recently created matching cache.

Re-check that page when the recipe is changed; these are the provider's rules, not ours.

## Reusing the stamp in CI

A stamp ([CACHE.md](CACHE.md#stamp)) lets a commit that changes nothing a spec can see skip the test jobs after checkout
and Neovim setup (not before: the keys need the checkout, and lib.nvim's files are in them). Write it on the main branch
after a full green run, restore it first in every other run, and let the test jobs depend on the answer:

```yaml
jobs:
  verify:
    runs-on: ubuntu-latest
    outputs:
      verified: ${{ steps.verify.outputs.verified }}
    steps:
      - uses: actions/checkout@v5
      # ... the dependency checkouts and the pinned Neovim, as in the test job
      - uses: actions/cache/restore@v4
        with:
          path: ${{ runner.temp }}/stamp
          key: testing-stamp-${{ runner.os }}-${{ github.sha }}
          restore-keys: testing-stamp-${{ runner.os }}-
      - id: verify
        env:
          TESTING_STAMP_SECRET: ${{ secrets.TESTING_STAMP_SECRET }}   # optional, see below
        run: |
          if nvim -n -i NONE --headless -u NONE -l scripts/testing.lua verify . \
               --stamp "$RUNNER_TEMP/stamp/stamp.json" --max-age 7d; then
            echo "verified=true" >> "$GITHUB_OUTPUT"
          else
            echo "verified=false" >> "$GITHUB_OUTPUT"
          fi
  tests:
    needs: verify
    if: needs.verify.outputs.verified != 'true'
    # ... the test job as above; on main, after a green run:
    #   nvim ... -l scripts/testing.lua stamp . --cached --out "$RUNNER_TEMP/stamp/stamp.json"
    #   then actions/cache/save@v4 with key testing-stamp-${{ runner.os }}-${{ github.sha }}
```

Rules specific to the stamp:

- `verify` answers `verified` only when **every** file is proven. A suite with files that have no key (clock, process, ...)
  is `partial` for good: those files must run. Use the stamp job only where it helps, or run just the files `verify`
  names (its output has the command).
- In CI `verify` accepts only a stamp that CI itself wrote on a trusted ref (a push to `main` or `master`, a schedule or
  a manual dispatch; never a pull request). The stamp says so itself, which is believed only as far as its transport is.
  With a secret in `TESTING_STAMP_SECRET` (a repository secret, at least 16 characters, **not** given to pull requests
  from forks) the stamp carries an HMAC and `verify` refuses one without or with a wrong HMAC. Use the secret wherever
  pull requests can reach the cache.
- The stamp is bound to OS, architecture, Neovim version, runner and configuration: one stamp per matrix entry.
- A skipped job is not a failed job, but what a required status check does with a skipped job is **not established**
  here: the workflow-syntax page fetched on 2026-10-07 says only that a workflow skipped by `paths` filtering leaves its
  checks "Pending". Do not use `paths-ignore` on the workflow; try the job-level `if` on a throwaway branch with the
  required checks switched on before relying on it.
- The age limit (default 7 days) bounds how long a statement about a tree can outlive the audit that backs it.

## Measured

Not measured in CI: that needs a real workflow run on the hosted runners (the hit rate and time of a CI run with the
cache restored from the previous main run), which could not be made from the machine this page was written on. What was
measured locally, the same way a restored folder would behave (Windows 11, Neovim 0.12.2, 2026-10-07, markdown.nvim with
47 spec files, a fresh cache base, one run each, the machine busy with other work):

| Run | Time | Files from cache |
| --- | --- | --- |
| `--no-cache` | 19.7 s | 0 of 47 |
| `--cached`, cold (empty folder, stores 27) | 29.2 s | 0 of 47 |
| `--cached`, warm (the folder of the run before) | 13.8 s | 27 of 47 |

The cold run costs more than a plain one (first hashing and storing); the warm run is about 30 percent faster than no
cache. 20 files are not cacheable (12 read a file outside the project, 4 the clock, 1 starts a process, ...). On CI the cold
run is the first run after a Neovim bump or a pruned cache. Measure your own suite with `testing explain . --all` (hit rate
and the reasons) before deciding the cache is worth a step in the workflow; a suite with a hit rate below a quarter gains
little.
