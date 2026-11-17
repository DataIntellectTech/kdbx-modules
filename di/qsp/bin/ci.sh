#!/usr/bin/env bash
# ==============================================================================
# ci.sh - every test qsp has, in one command, for CI
#
# Usage:
#   bin/ci.sh [-o OUTPUT_DIR]          # default di/qsp/ci-output
#
# Runs each suite in turn, against one example HDB built for the run:
#   unit      bin/test.q              the k4unit tests in test.csv
#   example   examples/equities/hdb.q the example's walkthrough: its policy's tests.csv
#                                     and the agent rules' examples
#   policy    bin/policy.q -test      the CI tool a team runs on its own policy, run on
#                                     the example's
#   adminui   examples/equities/demo.q -check   every admin UI endpoint
#   harden    bin/harden.sh           the hardening campaign
#
# Every suite runs even if one before it failed, so one run shows everything that is
# broken. Each suite's output is in OUTPUT_DIR/<suite>.log, and the hardening report in
# OUTPUT_DIR/harden/. Exits 0 only if every suite passed, 1 otherwise.
#
# Needs q on PATH, and di.k4unit for the unit tests: run it from a kdbx-modules checkout,
# or put one on QPATH (QPATH=$QPATH:/path/to/kdbx-modules bin/ci.sh).
# ==============================================================================
set -u

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$BIN_DIR/.." && pwd)"        # di/qsp
EX_DIR="$MOD_DIR/examples/equities"

OUT_DIR="$MOD_DIR/ci-output"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 [-o OUTPUT_DIR]" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qsp-ci.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/hdb"

# a suite that hangs fails, rather than holding the build forever
if command -v timeout >/dev/null; then LIMIT=(timeout 900); else LIMIT=(); fi

NAMES=(); RESULTS=(); TIMES=()

# suite NAME COMMAND...: run it, its output to OUTPUT_DIR/NAME.log, and record pass or fail
suite() {
  local name="$1"; shift
  local log="$OUT_DIR/$name.log" t0=$SECONDS rc=0
  echo "== $name"
  "${LIMIT[@]}" "$@" </dev/null >"$log" 2>&1 || rc=$?
  NAMES+=("$name"); TIMES+=("$(( SECONDS - t0 ))s")
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("pass")
  else
    RESULTS+=("FAIL (exit $rc)")
    echo "   failed, exit $rc - the end of $log:"
    tail -n 25 "$log" | sed 's/^/   | /'
  fi
}

echo "== building the example HDB in $DB"
if ! q "$EX_DIR/mkhdb.q" -db "$DB" -q </dev/null >"$OUT_DIR/mkhdb.log" 2>&1; then
  echo "ci.sh: could not build the example HDB - see $OUT_DIR/mkhdb.log" >&2
  exit 1
fi

suite unit    q "$BIN_DIR/test.q" -q
suite example q "$EX_DIR/hdb.q" -db "$DB" -q
suite policy  q "$BIN_DIR/policy.q" -dir "$EX_DIR/policy" -init "$DB" "$EX_DIR/policy/defs.q" -test -q
suite adminui q "$EX_DIR/demo.q" -db "$DB" -check -q
suite harden  bash "$BIN_DIR/harden.sh" -o "$OUT_DIR/harden"

echo
printf '%-10s %-16s %s\n' suite result time
FAILED=0
for i in "${!NAMES[@]}"; do
  printf '%-10s %-16s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${TIMES[$i]}"
  [[ "${RESULTS[$i]}" == pass ]] || FAILED=1
done
echo
if [[ $FAILED -eq 0 ]]; then
  echo "every suite passed (logs in $OUT_DIR)"
else
  echo "a suite failed (logs in $OUT_DIR)"
fi
exit "$FAILED"
