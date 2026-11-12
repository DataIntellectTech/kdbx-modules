#!/usr/bin/env bash
# ==============================================================================
# harden.sh - Defensive security & permission verification campaign for di.qsp
#
# Usage:
#   bin/harden.sh [-o OUTPUT_DIR]
#
# What it does:
#   1. Builds a fresh copy of the 5-day equities HDB in a temp directory.
#   2. Computes ground-truth expected results in an unpoliced q process, by hand
#      from the policy spec (never loading di.qsp).
#   3. Starts a policed HDB server (with harmless canaries planted) and a second
#      server with -T 1 for query-timeout testing.
#   4. Runs five client suites over IPC/HTTP (permissions, logins_transport,
#      limits, audit, attacks), recording every pass and failure.
#   5. Writes results.csv and report.md, and shuts the servers down on exit.
#
# The q programs it runs are separate files under bin/harden/, each taking its
# inputs as -key value args:
#   harden/mkexpected.q  ground-truth expectations (never loads di.qsp)
#   harden/server.q      the policed HDB server, with canaries
#   harden/runner.q      the five suites and the report generator
#
# NOTE: the root-cause "notes" recorded in harden/runner.q are from the original
# automated pass and some are inaccurate - see docs/security-review.md for which
# findings actually reproduce.
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

echo "== [2/5] Computing hand-written expected results straight from HDB =="
q "$QDIR/mkexpected.q" -db "$RUN_DIR/hdb" -out "$RUN_DIR/expected.bin" -q

# Pick two free ports (RANDOM so small-PID containers never collide on TIME_WAIT)
PORT1=$(( 20000 + (RANDOM % 25000) ))
PORT2=$(( PORT1 + 1 ))

echo "== [3/5] Starting policed HDB server (port $PORT1) and timeout server (port $PORT2, -T 1) =="
q "$QDIR/server.q" \
  -modroot "$REPO_ROOT" \
  -db "$RUN_DIR/hdb" \
  -poldir "$MOD_DIR/examples/equities/policy" \
  -rundir "$RUN_DIR" \
  -p "$PORT1" -q </dev/null >"$RUN_DIR/server1.log" 2>&1 &
SERVER_PID=$!

q "$QDIR/server.q" \
  -modroot "$REPO_ROOT" \
  -db "$RUN_DIR/hdb" \
  -poldir "$MOD_DIR/examples/equities/policy" \
  -rundir "$RUN_DIR" \
  -p "$PORT2" -T 1 -q </dev/null >"$RUN_DIR/server2.log" 2>&1 &
TIMEOUT_PID=$!

echo "== [4/5] Running client verification and attack suites =="
q "$QDIR/runner.q" \
  -port1 "$PORT1" \
  -port2 "$PORT2" \
  -rundir "$RUN_DIR" \
  -outdir "$OUT_DIR" \
  -modroot "$REPO_ROOT" \
  -poldir "$MOD_DIR/examples/equities/policy" \
  -q

echo "== [5/5] Done. Shutting down background processes via trap =="
