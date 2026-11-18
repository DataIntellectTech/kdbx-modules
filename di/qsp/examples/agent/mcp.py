#!/usr/bin/env python3
"""MCP server (stdio) connecting Claude to a policed qsp kdb+ process.

Talks to the qsp server over IPC via client.q using the gateway login, exposing
qsp.api (`users`, `describe`, `rules`, `validate`, `explain`) and `.qsp.execasx`
(`query`) as MCP tools. Uses only the Python standard library.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT_Q = os.path.join(HERE, "client.q")
PORT = os.environ.get("QSP_PORT", "5100")
HOST = os.environ.get("QSP_HOST", "localhost")
DEFAULT_USER = os.environ.get("QSP_USER", "llm1")


def find_q():
    if "QBIN" in os.environ:
        return os.environ["QBIN"]
    q = shutil.which("q")
    if q:
        return q
    kx = os.path.expanduser("~/.kx/bin/q")
    if os.path.exists(kx):
        return kx
    return "q"


QBIN = find_q()


def call_q(call, user=None, query=None):
    cmd = [QBIN, CLIENT_Q, "-host", HOST, "-port", str(PORT), "-call", call, "-q"]
    if user:
        cmd += ["-user", user]
    if query is not None:
        cmd += ["-query", query]
    proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    out = (proc.stdout + proc.stderr).strip()
    return proc.returncode == 0, out


TOOLS = [
    {
        "name": "qsp_users",
        "description": (
            "List the users defined in the qsp policy on the server (`.qsp.api;`users;`json). "
            "Use this to see which user personas (e.g. llm1, sales_na, sales_emea, quant1, "
            "cash_head, etf_head, compliance1) you can query as."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "qsp_describe",
        "description": (
            "Call (`.qsp.api;`describe;user;`json) on the qsp server. Returns everything an "
            "agent needs to know before writing q for `user`: the tables and columns they may "
            "read, column types, partition columns, the row filter applied to each table, "
            "permitted functions, limits, and the qsp query rules. ALWAYS call this for a user "
            "before writing your first query as that user."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user": {
                    "type": "string",
                    "description": f"Policy user to describe (default: {DEFAULT_USER})",
                }
            },
        },
    },
    {
        "name": "qsp_rules",
        "description": (
            "Call (`.qsp.api;`rules;`json) on the qsp server. Returns the rules for writing q "
            "that qsp accepts, each with its reason, good and bad example queries, and the "
            "refusal text it produces. Use this to match a refusal message to the rule that "
            "explains how to fix the query."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "qsp_validate",
        "description": (
            "Call (`.qsp.api;`validate;user;query;`json) to check whether `query` would be "
            "allowed for `user` (checking syntax, tables, columns, functions, partition bounds, "
            "and maxpartitions) without running it or logging an audit entry."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user": {
                    "type": "string",
                    "description": f"User to validate as (default: {DEFAULT_USER})",
                },
                "query": {
                    "type": "string",
                    "description": "The q-SQL query string to validate",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "qsp_explain",
        "description": (
            "Call (`.qsp.api;`explain;user;query) to see the rewritten query that qsp would "
            "actually execute for `user`, with the policy's column projection and row filter "
            "in place."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user": {
                    "type": "string",
                    "description": f"User to explain for (default: {DEFAULT_USER})",
                },
                "query": {
                    "type": "string",
                    "description": "The q-SQL query string to explain",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "qsp_query",
        "description": (
            "Run a q-SQL query against the policed kdb+ server as `user` via "
            "(`.qsp.execasx;query;user). Returns both the rewritten query that qsp ran and "
            "the result table/value, or the `qsp: ...` refusal message if the policy refused it."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user": {
                    "type": "string",
                    "description": f"User to run the query as (default: {DEFAULT_USER})",
                },
                "query": {
                    "type": "string",
                    "description": "The q-SQL query string to execute",
                },
            },
            "required": ["query"],
        },
    },
]


def handle_tool(name, args):
    user = (args or {}).get("user") or DEFAULT_USER
    query = (args or {}).get("query")
    mapping = {
        "qsp_users": ("users", None, None),
        "qsp_describe": ("describe", user, None),
        "qsp_rules": ("rules", None, None),
        "qsp_validate": ("validate", user, query),
        "qsp_explain": ("explain", user, query),
        "qsp_query": ("query", user, query),
    }
    if name not in mapping:
        return True, f"Unknown tool: {name}"
    call, u, q = mapping[name]
    ok, out = call_q(call, u, q)
    return (not ok), out


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        method = req.get("method")
        req_id = req.get("id")
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "qsp", "version": "0.1.0"},
                },
            })
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = req.get("params") or {}
            is_err, text = handle_tool(params.get("name"), params.get("arguments"))
            send({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": is_err,
                },
            })
        elif req_id is not None:
            send({
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            })


if __name__ == "__main__":
    main()
