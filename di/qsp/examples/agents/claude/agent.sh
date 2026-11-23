#!/usr/bin/env bash
# ==============================================================================
# agent.sh - run Claude against a policed qsp kdb+ serve
#
# Usage:
#   di/qsp/examples/agents/claude/agent.sh                        # interactive Claude session, as llm1
#   di/qsp/examples/agents/claude/agent.sh "question..."          # one-shot question
#   di/qsp/examples/agents/claude/agent.sh -u sales_na "question" # act for another user
#   di/qsp/examples/agents/claude/agent.sh --demo                 # demo: any user, through the gateway
#   di/qsp/examples/agents/claude/agent.sh -p 5100 "question"     # connect to port (starts server.q if not listening)
#
# By default the agent is bound to one user (-u, default llm1): it logs in as that user, its tools
# take no user, and nothing it is told can make it run as anyone else. --demo logs in as the
# gateway instead, so one session can try every role - and so can anything that talks the model
# into it. The /qsp:<user> slash commands are for --demo.
#
# If no qsp server is listening on the port yet, agent.sh starts ../server.q in the
# background for the run and stops it on exit. To watch the server log every IPC
# call live in its own terminal, start server.q yourself first:
#   q di/qsp/examples/agents/server.q -p 5100
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.kx/bin:$HOME/.local/bin:$PATH"

PORT="${QSP_PORT:-5100}"
USER_NAME="${QSP_USER:-llm1}"
DEMO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port) PORT="$2"; shift 2 ;;
    -u|--user) USER_NAME="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
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
  tail -f /dev/null | "$QBIN" "$HERE/../server.q" -p "$PORT" -q >"$SERVER_LOG" 2>&1 &
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

# The server's primer - how to write q that qsp accepts - goes in the system prompt, so it is in
# context before the first query. It is about 15 KB: Claude Code cuts MCP server instructions and
# hook output to about 4 KB, so the system prompt is where it fits whole
PRIMER="$("$QBIN" "$HERE/client.q" -port "$PORT" -call primer -q </dev/null 2>/dev/null || true)"
BRIEF=""
if [[ "$DEMO" == 1 ]]; then
  SYSTEM="Demo mode: the qsp tools take the user to act as. Default qsp user for this session: $USER_NAME."
else
  SYSTEM="You act for qsp user $USER_NAME: every query runs as $USER_NAME, and no tool can act as anyone else."
  BRIEF="$("$QBIN" "$HERE/client.q" -port "$PORT" -call brief -direct -user "$USER_NAME" -q </dev/null 2>/dev/null || true)"
fi
if [[ -n "$BRIEF" ]]; then
  SYSTEM="$SYSTEM"$'\n\n'"## Active user schema, shape, limits, and business terms (\`qsp.api.brief\`)"$'\n```json\n'"$BRIEF"$'\n```'
fi
if [[ -n "$PRIMER" ]]; then
  SYSTEM="$SYSTEM"$'\n\n'"$PRIMER"
else
  echo "agent.sh: could not read the primer from the server; the agent will be told to call qsp_primer" >&2
fi

# qsp's MCP server, in q (di/qsp/mcp): bound to the user, or, in demo mode, logged in as the gateway
MCP="$HERE/../../../mcp/qsp-mcp"
if [[ "$DEMO" == 1 ]]; then
  MODE_ARGS="\"-gateway\",\"gateway\",\"-default\",\"$USER_NAME\""
else
  MODE_ARGS="\"-user\",\"$USER_NAME\""
fi

MCP_JSON=$(cat <<EOF
{"mcpServers":{"qsp":{"command":"$MCP","args":["-port","$PORT",$MODE_ARGS],"env":{"QBIN":"$QBIN"}}}}
EOF
)

TOOLS="mcp__qsp__qsp_users,mcp__qsp__qsp_describe,mcp__qsp__qsp_rules,mcp__qsp__qsp_primer,mcp__qsp__qsp_validate,mcp__qsp__qsp_explain,mcp__qsp__qsp_estimate,mcp__qsp__qsp_query,mcp__qsp__qsp_history"

cd "$HERE"
if [[ $# -gt 0 ]]; then
  "$CLAUDE_BIN" \
    --mcp-config "$MCP_JSON" \
    --strict-mcp-config \
    --tools "" \
    --allowedTools "$TOOLS" \
    --append-system-prompt "$SYSTEM" \
    -p "$*" </dev/null
else
  "$CLAUDE_BIN" \
    --mcp-config "$MCP_JSON" \
    --strict-mcp-config \
    --allowedTools "$TOOLS" \
    --append-system-prompt "$SYSTEM"
fi
