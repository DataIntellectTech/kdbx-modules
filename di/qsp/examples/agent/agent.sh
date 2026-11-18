#!/usr/bin/env bash
# ==============================================================================
# agent.sh - run Claude against a policed qsp kdb+ serve
#
# Usage:
#   di/qsp/examples/agent/agent.sh                        # interactive Claude session
#   di/qsp/examples/agent/agent.sh "question..."          # one-shot question
#   di/qsp/examples/agent/agent.sh -u sales_na "question" # default user (default: llm1)
#   di/qsp/examples/agent/agent.sh -p 5100 "question"     # connect to port (starts server.q if not listening)
#
# If no qsp server is listening on the port yet, agent.sh starts server.q in the
# background for the run and stops it on exit. To watch the server log every IPC
# call live in its own terminal, start server.q yourself first:
#   q di/qsp/examples/agent/server.q -p 5100
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.kx/bin:$HOME/.local/bin:$PATH"

PORT="${QSP_PORT:-5100}"
USER_NAME="${QSP_USER:-llm1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port) PORT="$2"; shift 2 ;;
    -u|--user) USER_NAME="$2"; shift 2 ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

QBIN="${QBIN:-$(command -v q || true)}"
if [[ -z "$QBIN" ]]; then
  echo "agent.sh: cannot find q (KDB-X) on PATH" >&2
  exit 1
fi

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "agent.sh: cannot find claude on PATH" >&2
  exit 1
fi

# Start server.q in the background if nothing is listening on PORT yet
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! "$QBIN" "$HERE/client.q" -port "$PORT" -call users -q >/dev/null 2>&1; then
  SERVER_LOG="${TMPDIR:-/tmp}/qsp-agent-server-$PORT.log"
  echo "Starting qsp server on port $PORT (log: $SERVER_LOG)..." >&2
  tail -f /dev/null | "$QBIN" "$HERE/server.q" -p "$PORT" -q >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  for _ in {1..40}; do
    if "$QBIN" "$HERE/client.q" -port "$PORT" -call users -q >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  if ! "$QBIN" "$HERE/client.q" -port "$PORT" -call users -q >/dev/null 2>&1; then
    echo "agent.sh: server.q failed to start on port $PORT:" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
fi

MCP_JSON=$(cat <<EOF
{"mcpServers":{"qsp":{"command":"python3","args":["$HERE/mcp.py"],"env":{"QSP_PORT":"$PORT","QSP_USER":"$USER_NAME","QBIN":"$QBIN"}}}}
EOF
)

TOOLS="mcp__qsp__qsp_users,mcp__qsp__qsp_describe,mcp__qsp__qsp_rules,mcp__qsp__qsp_validate,mcp__qsp__qsp_explain,mcp__qsp__qsp_query"

cd "$HERE"
if [[ $# -gt 0 ]]; then
  "$CLAUDE_BIN" \
    --mcp-config "$MCP_JSON" \
    --strict-mcp-config \
    --tools "" \
    --allowedTools "$TOOLS" \
    --append-system-prompt "Default qsp user for this session: $USER_NAME." \
    -p "$*" </dev/null
else
  "$CLAUDE_BIN" \
    --mcp-config "$MCP_JSON" \
    --strict-mcp-config \
    --allowedTools "$TOOLS" \
    --append-system-prompt "Default qsp user for this session: $USER_NAME."
fi
