#!/usr/bin/env bash
#
# Runs the spec suite headlessly: nvim -n -i NONE --headless -u NONE -l TESTS/run.lua
#
#   scripts/test.sh            every spec under TESTS/testing/
#   scripts/test.sh config     only specs whose file name contains "config"
#
# Exit code 0: all specs passed. 1: a spec failed, or nvim / lib.nvim was not found.
# lib.nvim is a hard dependency and is looked up in, in this order:
#   1. $LIB_NVIM_DIR
#   2. <repo>/.deps/lib.nvim
#   3. <repo>/../lib.nvim (a sibling checkout)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf '\033[31m%s\033[0m\n' "$1" >&2
  exit 1
}

command -v nvim >/dev/null 2>&1 || fail "error: nvim is not on PATH."

is_lib() { [[ -n "${1:-}" && -d "$1/lua/lib/nvim" ]]; }

if ! is_lib "${LIB_NVIM_DIR:-}" && ! is_lib ".deps/lib.nvim" && ! is_lib "../lib.nvim"; then
  fail "error: lib.nvim not found. Searched:
  - \$LIB_NVIM_DIR (${LIB_NVIM_DIR:-unset})
  - $(pwd)/.deps/lib.nvim
  - $(cd .. && pwd)/lib.nvim
Set LIB_NVIM_DIR, or clone it to .deps/lib.nvim, or place it beside this repo."
fi

# Throwaway app name: the run gets its own stdpath("config"/"data"/"state"), never the developer's.
export NVIM_APPNAME="${NVIM_APPNAME:-testing-nvim-tests}"

exec nvim -n -i NONE --headless -u NONE -l TESTS/run.lua "$@"
