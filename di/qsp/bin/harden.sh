#!/usr/bin/env bash
# ==============================================================================
# harden.sh - Defensive security & permission verification campaign for di.qsp
#
# Usage:
#   bin/harden.sh [-o OUTPUT_DIR]
#
# What it does:
#   1. Builds a fresh copy of the 5-day equities HDB in a temp directory.
#   2. Computes ground-truth expected results in an unpoliced q process (never
#      loading di.qsp): each user's view of each table is written by hand from the
#      policy spec, and each case's query is run unchanged over those views.
#   3. Starts a policed HDB server (with harmless canaries planted) and a second
#      server with -T 1 for query-timeout testing, and waits until each listens.
#      A server that will not start is retried on new ports, and after five tries
#      the run stops with its log. Their logs are kept beside the report, as
#      server1.log and server2.log.
#   4. Runs five client suites over IPC/HTTP (permissions, logins_transport,
#      limits, audit, attacks), recording every pass and failure.
#   5. Writes results.csv and report.md, and shuts the servers down on exit.
#
# Exits 0 only if every check passed: 1 if any failed, and non-zero if a step
# could not run at all - so it can gate CI after bin/test.q.
#
# The q programs it runs are separate files under bin/harden/, each taking its
# inputs as -key value args:
#   harden/cases.q       the queries checked against a value, each written once
#   harden/mkexpected.q  ground-truth expectations from a hand-written model of
#                        the policy (never loads di.qsp)
#   harden/server.q      the policed HDB server, with canaries
#   harden/runner.q      the five suites and the report generator
#
# Each check's note in the report says what the check exercises. Why a finding
# happened, and what changed, is in docs/security-review.md.
# ==============================================================================

set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$BIN_DIR/.." && pwd)"        # di/qsp
REPO_ROOT="$(cd "$MOD_DIR/../.." && pwd)"   # holds di/ - the module search root
QDIR="$BIN_DIR/harden"                      # the q programs

OUT_DIR="$MOD_DIR/harden-output"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 [-o OUTPUT_DIR]" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qsp-harden.XXXXXX")"
SERVER_PID=""
TIMEOUT_PID=""

cleanup() {
  for pid in "$SERVER_PID" "$TIMEOUT_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

echo "== [1/5] Building fresh example HDB in $RUN_DIR/hdb =="
q "$MOD_DIR/examples/equities/mkhdb.q" -db "$RUN_DIR/hdb" -days 5 -q

echo "== [2/5] Computing expected results from the hand-written policy model =="
q "$QDIR/mkexpected.q" -db "$RUN_DIR/hdb" -out "$RUN_DIR/expected.bin" -q

# start_server NAME PORT [q args...]: start harden/server.q on PORT, logging to OUT_DIR/NAME.log,
# and wait until it listens. Sets STARTED_PID. Returns 1 if it exits first or is not listening
# within 60s - a port already taken, or a startup error, which its log then shows
start_server() {
  local name="$1" port="$2"; shift 2
  q "$QDIR/server.q" \
    -modroot "$REPO_ROOT" \
    -db "$RUN_DIR/hdb" \
    -poldir "$MOD_DIR/examples/equities/policy" \
    -rundir "$RUN_DIR" \
    -p "$port" "$@" -q </dev/null >"$OUT_DIR/$name.log" 2>&1 &
  STARTED_PID=$!
  local i
  for (( i = 0; i < 600; i++ )); do
    kill -0 "$STARTED_PID" 2>/dev/null || return 1
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 0.1
  done
  kill "$STARTED_PID" 2>/dev/null || true
  return 1
}

# start_pair: both servers on a pair of random ports, below Linux's ephemeral range (32768 up)
# so an outgoing connection cannot already hold one. A pair that will not start is retried on
# new ports; after five tries the run stops, showing the last server's log
start_pair() {
  local try
  for (( try = 1; try <= 5; try++ )); do
    PORT1=$(( 20000 + (RANDOM % 12000) ))
    PORT2=$(( PORT1 + 1 ))
    echo "== [3/5] Starting policed HDB server (port $PORT1) and timeout server (port $PORT2, -T 1) =="
    if start_server server1 "$PORT1"; then
      SERVER_PID=$STARTED_PID
      if start_server server2 "$PORT2" -T 1; then
        TIMEOUT_PID=$STARTED_PID
        return 0
      fi
      FAILED=server2
      kill "$SERVER_PID" 2>/dev/null || true
      wait "$SERVER_PID" 2>/dev/null || true
      SERVER_PID=""
    else
      FAILED=server1
    fi
    echo "   $FAILED did not start - its log:" >&2
    sed 's/^/   | /' "$OUT_DIR/$FAILED.log" >&2
  done
  return 1
}

if ! start_pair; then
  echo "harden.sh: the policed servers would not start (logs in $OUT_DIR) - no checks were run" >&2
  exit 1
fi

echo "== [4/5] Running client verification and attack suites =="
RC=0
q "$QDIR/runner.q" \
  -port1 "$PORT1" \
  -port2 "$PORT2" \
  -rundir "$RUN_DIR" \
  -outdir "$OUT_DIR" \
  -modroot "$REPO_ROOT" \
  -poldir "$MOD_DIR/examples/equities/policy" \
  -q || RC=$?

echo "== [5/5] Done: report in $OUT_DIR/report.md. Shutting down background processes via trap =="
exit "$RC"
