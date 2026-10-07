#!/usr/bin/env bash
#
# Measures the incremental run of the result cache (the D.7 budget "after one change, under 1 s median").
# A manual tool, never a CI step: wall time depends on the machine and its load.
#
#   scripts/bench-incremental.sh <project> <file> [runs] [flags]
#
#   <project>  a COPY of a project (the script edits <file> and restores it with `git checkout`)
#   <file>     path relative to <project>: a source module or a spec file
#   runs       timed runs (default 5); the median is what counts
#   flags      the selection flag, default `--changed`; `--affected` also works
#
# Protocol: (1) one cold `--cached` run of the whole project fills a throwaway cache and (2) `--cached` again with
# no change shows the all-cached cost (both skipped with BENCH_SKIP_FULL=1: they take as long as the suite);
# (3) one untimed `<flag> --cached` run builds the indexes; (4) per timed run: append one new comment line to <file> (a new content every time, so
# the key never matches an earlier run), time `<flag> --cached`, restore the file. Prints one line per run and the
# median in milliseconds. The cache lives in a temporary directory that is removed afterwards.

set -uo pipefail

project="${1:?usage: bench-incremental.sh <project> <file> [runs] [flags]}"
file="${2:?usage: bench-incremental.sh <project> <file> [runs] [flags]}"
runs="${3:-5}"
flag="${4:---changed}"
runner="$(cd "$(dirname "$0")" && pwd)/testing.lua"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
if command -v cygpath >/dev/null 2>&1; then scratch="$(cygpath -m "$scratch")"; fi
export XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" NVIM_APPNAME=testing-nvim-bench

cd "$project" || exit 3
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
  git checkout -- "$file"
done
printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print "median: " a[int((NR+1)/2)] " ms (min " a[1] ", max " a[NR] ")"}'
