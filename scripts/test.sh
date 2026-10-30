#!/usr/bin/env bash
#
# Runs this repository's specs through its own runner (dogfood):
#
#   nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . [options]
#
#   scripts/test.sh                    every spec under TESTS/
#   scripts/test.sh --file config      only spec files whose name contains "config"
#   scripts/test.sh --json out.json    additionally write the Result-IR
#   scripts/test.sh --junit out.xml    additionally write a JUnit report
#
# Every option of `scripts/testing.lua --help` is passed through unchanged.
#
#   scripts/test.sh --cached           reuse the results of unchanged spec files (docs/CACHE.md); the cache
#                                      lives in $TESTING_CACHE_HOME (default: a throwaway directory, so a
#                                      second invocation starts cold unless you point it somewhere)
#   TESTING_CACHE_HOME=~/.cache/tn scripts/test.sh --cached
#   scripts/test.sh --changed          only the specs the working tree can reach (a partial run)
#
#   scripts/test.sh fast [options]     `testing fast`: --cached --order priority, the likely specs first with an
#                                      interim finding after them; the verdict of the whole run comes last
#                                      (docs/CLI.md); `--time-budget 2m` stops starting files after that long.
#                                      This script's throwaway state holds no failure history, so the
#                                      "failed last time" stage is empty here (changes still count); with
#                                      history, run `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua
#                                      fast .` directly
#   scripts/test.sh conformance        the conformance suite K1..K15 (docs/CONFORMANCE.md) in the same isolated
#                                      environment; extra options go to `testing conformance .`; exit 1 when the
#                                      repo is gated (`conformance.gate = true`, or `--gate`) and a check failed
#   scripts/test.sh ci [options]       the whole pipeline of `.testing.lua` (`ci` section: stylua, luacheck, the
#                                      suite, conformance; docs/CI.md) in the same isolated environment;
#                                      `scripts/test.sh ci --profile=fast` is the quick check before a push
#
# Exit code: 0 all green, 1 a spec failed, 2 usage or configuration error, 3 infrastructure error
# (nvim is not on PATH, or lib.nvim was not found: the runner then names all four places it looked
# in: $LIB_NVIM_DIR, <repo>/.deps/lib.nvim, <repo>/../lib.nvim, stdpath('data')/lazy/lib.nvim).

set -uo pipefail

cd "$(dirname "$0")/.."

if ! command -v nvim >/dev/null 2>&1; then
  printf '\033[31m%s\033[0m\n' "error: nvim is not on PATH." >&2
  exit 3
fi

# `ci`: the pipeline's document (ci.json) and the suite's stamp must outlive the scratch directory below. The
# developer's real state directory is asked for BEFORE the isolation and handed to `testing ci --state-dir` (an
# argument, not the environment: the specs must not inherit it).
real_state=""
if [ "${1:-}" = "ci" ]; then
  real_state="$(nvim -n -i NONE --headless -u NONE --cmd 'lua io.stdout:write(vim.fn.stdpath("state"))' --cmd 'qa!' 2>/dev/null)"
  if [ -z "$real_state" ]; then
    # without it the document and the stamp would go into the scratch directory and be deleted on exit
    printf '\033[31m%s\033[0m\n' 'error: cannot ask nvim for stdpath("state"); the ci document would be lost.' >&2
    exit 3
  fi
fi

# Throwaway app name, state and cache: the run never reads or writes the developer's real stdpath("state") and
# stdpath("cache"). stdpath("config") and stdpath("data") are not redirected, they only carry the app name below
# (an exported NVIM_APPNAME is kept, then they are that app's).
export NVIM_APPNAME="${NVIM_APPNAME:-testing-nvim-tests}"
# Without a scratch directory the exports below would point at /state and /cache: stop instead
scratch="$(mktemp -d)" || {
  printf '\033[31m%s\033[0m\n' "error: cannot create a scratch directory (mktemp -d failed; is TMPDIR writable?)." >&2
  exit 3
}
trap 'rm -rf "$scratch"' EXIT
if command -v cygpath >/dev/null 2>&1; then
  scratch="$(cygpath -m "$scratch")"
fi
# Windows: TMP/TEMP often hold the 8.3 short form (C:/Users/RUNNER~1/...). Neovim's glob and :checkhealth cannot
# find files below a path with a "~1" component, so the specs are run with the long form.
if command -v cygpath >/dev/null 2>&1; then
  for var in TMP TEMP; do
    val="${!var:-}"
    if [ -n "$val" ]; then
      export "$var=$(cygpath -w -l "$val")"
    fi
  done
fi
export XDG_STATE_HOME="$scratch/state"
# The specs always get a throwaway cache home (they run the runner themselves and must not write into a shared
# cache); a shared one is handed to the outer run only, through --cache-dir.
cache_args=()
if [ -n "${TESTING_CACHE_HOME:-}" ]; then
  cache_args=(--cache-dir "$TESTING_CACHE_HOME")
  unset TESTING_CACHE_HOME
fi
export XDG_CACHE_HOME="$scratch/cache"
# Workspace trust (docs/CONFIG.md): this script IS code of this repository, so running it is the trust decision; and
# the specs run the runner on fixture projects they build in the temp directory. Every root is trusted below.
export TESTING_TRUST=1

# No `exec`: the trap must remove the scratch directory afterwards.
if [ "${1:-}" = "conformance" ]; then
  shift
  nvim -n -i NONE --headless -u NONE -l scripts/testing.lua conformance . "$@"
  exit $?
fi
if [ "${1:-}" = "fast" ]; then
  shift
  nvim -n -i NONE --headless -u NONE -l scripts/testing.lua fast . ${cache_args[@]+"${cache_args[@]}"} "$@"
  exit $?
fi
if [ "${1:-}" = "ci" ]; then
  shift
  state_args=()
  if [ -n "$real_state" ]; then
    state_args=(--state-dir "$real_state")
  fi
  # a shared cache reaches the suite step only when it asks for one (`--cached` after `--`)
  suite_cache=()
  for a in "$@"; do
    if [ "$a" = "--cached" ] && [ ${#cache_args[@]} -gt 0 ]; then
      suite_cache=("${cache_args[@]}")
    fi
  done
  nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ci ${state_args[@]+"${state_args[@]}"} "$@" ${suite_cache[@]+"${suite_cache[@]}"}
  exit $?
fi
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . ${cache_args[@]+"${cache_args[@]}"} "$@"
exit $?
