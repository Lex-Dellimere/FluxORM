#!/usr/bin/env bash
# reach/tools/check.sh — the gate, driven through mbuild.
#
#   mbuild check          type-check the package
#   mbuild test           @test fns in the compiler's interpreter, cached
#   mbuild mettle -- ...  the chosen compiler, for the runs mbuild has no verb
#                         for: a test file built and executed in debug and
#                         release
#   mbuild build [-r]     the demo bin, then actually run it
#
# Release is mandatory. Head miscompiles in this project have all been
# release-only (see tools/repros/).
#
# Usage: tools/check.sh [test files...]      (default: every tests/t_*.mettle)
set -uo pipefail
cd "$(dirname "$0")/.."

HEAD=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle
export METTLE=${METTLE:-$HEAD}
MB=${MBUILD:-/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild}

if [[ ! -x "$MB" ]]; then
  echo "no mbuild at $MB (set MBUILD=...)" >&2
  exit 2
fi
if [[ ! -x "$METTLE" ]]; then
  echo "no compiler at $METTLE (set METTLE=...)" >&2
  echo "reach needs the head build: the v0.17.0 release lacks compile-time reflection." >&2
  exit 2
fi

OUT=${CHECK_OUT:-/tmp/reach-check}
mkdir -p "$OUT"

FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  mapfile -t FILES < <(ls tests/t_*.mettle 2>/dev/null)
fi

fail=0
pass=0
run_case() {
  local name="$1"; shift
  local log="$OUT/$name.log"
  if "$@" >"$log" 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$name"
    tail -n 25 "$log" | sed 's/^/       /'
  fi
}

echo "== mbuild check"
run_case "mbuild.check" "$MB" check
echo "== mbuild test (interpreter)"
run_case "mbuild.test" "$MB" test

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "  skip $f (missing)"; continue; }
  b=$(basename "$f" .mettle)
  echo "== $f"
  run_case "$b.debug.build" "$MB" mettle -- --build "$f" -o "$OUT/$b.debug"
  run_case "$b.debug.run" "$OUT/$b.debug"
  run_case "$b.release.build" "$MB" mettle -- --release --build "$f" -o "$OUT/$b.release"
  run_case "$b.release.run" "$OUT/$b.release"
done

echo "== demo bin"
run_case "mbuild.build" "$MB" build
run_case "demo.debug.run" build/linux/debug/reachdemo
run_case "mbuild.build.release" "$MB" build -r
run_case "demo.release.run" build/linux/release/reachdemo

echo
echo "$pass passed, $fail failed (logs in $OUT)"
[[ $fail -eq 0 ]]
