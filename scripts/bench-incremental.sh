#!/usr/bin/env bash
#
# Measures the incremental run of the result cache (the D.7 budget "after one change, under 1 s median").
# A manual tool, never a CI step: wall time depends on the machine and its load.
#
#   scripts/bench-incremental.sh <project> <file> [runs] [flag]
#
#   <project>  a COPY of a project: the script appends a line to <file> for every run
#   <file>     path relative to <project> (below it: no absolute path, no `..`, no symlink out of it): a source
#              module or a spec file. A copy of the file is taken first and put back byte for byte after every run
#              and when the script is interrupted (a trap): uncommitted edits of the file survive
#   runs       timed runs (default 5); the median is what counts
#   flag       ONE selection flag, default `--changed`; `--affected` also works
#
# Protocol: (1) one cold `--cached` run of the whole project fills a throwaway cache and (2) `--cached` again with
# no change shows the all-cached cost (both skipped with BENCH_SKIP_FULL=1: they take as long as the suite);
# (3) one untimed `<flag> --cached` run builds the indexes; (4) per timed run: append one new comment line to <file> (a new content every time, so
# the key never matches an earlier run), time `<flag> --cached`, restore the file. Prints one line per run and the
# median in milliseconds. The cache lives in a temporary directory that is removed afterwards.

set -uo pipefail

project="${1:?usage: bench-incremental.sh <project> <file> [runs] [flag]}"
file="${2:?usage: bench-incremental.sh <project> <file> [runs] [flag]}"
runs="${3:-5}"
flag="${4:---changed}"
runner="$(cd "$(dirname "$0")" && pwd)/testing.lua"

cd "$project" || exit 3

# <file> must be a regular file BELOW the project: the script writes to it (an absolute path, a `..` or a
# symlink pointing out of the project would edit a file that is none of its business)
case "$file" in
  /* | [A-Za-z]:* | *..*)
    echo "error: <file> must be a path below <project> (no absolute path, no '..'): $file" >&2
    exit 2
    ;;
esac
if [ ! -f "$file" ]; then
  echo "error: <file> is not a regular file of <project>: $file" >&2
  exit 2
fi
if [ -L "$file" ]; then
  echo "error: <file> is a symlink (it could point out of <project>): $file" >&2
  exit 2
fi
project_real="$(pwd -P)"
file_real="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
case "$file_real" in
  "$project_real"/*) ;;
  *)
    echo "error: <file> resolves outside <project> (a symlink?): $file_real" >&2
    exit 2
    ;;
esac

scratch="$(mktemp -d)"
original="$scratch.original"
cp -p "$file" "$original" || exit 3
# the file goes back as it was, whatever ends the script (an interrupt included)
restore() {
  cp -p "$original" "$file" 2>/dev/null
}
cleanup() {
  restore
  rm -rf "$scratch" "$original"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if command -v cygpath >/dev/null 2>&1; then scratch="$(cygpath -m "$scratch")"; fi
export XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" NVIM_APPNAME=testing-nvim-bench

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
run() { nvim -n -i NONE --headless -u NONE -l "$runner" . --first-run "$@" >"$scratch/out.txt" 2>&1; }

if [ "${BENCH_SKIP_FULL:-0}" != "1" ]; then
  t0=$(now_ms); run --cached; code=$?; t1=$(now_ms)
  echo "cold --cached (whole project, exit $code): $(( t1 - t0 )) ms"
  t0=$(now_ms); run --cached; code=$?; t1=$(now_ms)
  echo "warm --cached (no change, exit $code): $(( t1 - t0 )) ms"; grep -E "cached, not run|cache \(use\)" "$scratch/out.txt" | head -2
fi
# the analysis index and the hash index of the selection are built by the first selection run (not timed)
run "$flag" --cached

times=()
for i in $(seq 1 "$runs"); do
  printf '\n-- bench edit %s\n' "$i" >>"$file"
  t0=$(now_ms); run "$flag" --cached; code=$?; t1=$(now_ms)
  times+=($(( t1 - t0 )))
  echo "run $i: $(( t1 - t0 )) ms (exit $code)"; grep -E "cached, not run|selected|affected" "$scratch/out.txt" | head -2
  restore
done
printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print "median: " a[int((NR+1)/2)] " ms (min " a[1] ", max " a[NR] ")"}'
