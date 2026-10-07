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
# Exit code: 0 all green, 1 a spec failed, 2 usage or configuration error, 3 infrastructure error
# (nvim is not on PATH, or lib.nvim was not found: the runner then names all four places it looked
# in: $LIB_NVIM_DIR, <repo>/.deps/lib.nvim, <repo>/../lib.nvim, stdpath('data')/lazy/lib.nvim).

set -uo pipefail

cd "$(dirname "$0")/.."

if ! command -v nvim >/dev/null 2>&1; then
  printf '\033[31m%s\033[0m\n' "error: nvim is not on PATH." >&2
  exit 3
fi

# Throwaway app name and state: the run never reads or writes the developer's real
# stdpath("config"/"data"/"state"/"cache").
export NVIM_APPNAME="${NVIM_APPNAME:-testing-nvim-tests}"
scratch="$(mktemp -d)"
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

# No `exec`: the trap must remove the scratch directory afterwards.
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . ${cache_args[@]+"${cache_args[@]}"} "$@"
exit $?
