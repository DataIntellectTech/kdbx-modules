# Example: an AI agent querying a policed HDB

An MCP server and Claude Code slash commands (`/qsp:<user>` and `/qsp <user>`)
that connect `claude` to the policed equities HDB over IPC, using `qsp.api` to
learn what each user may query and the rules its q must follow, and
`.qsp.execasx` to run queries through the gateway login.

```sh
# 1. Start the policed HDB server in one terminal (logs every API call and query live):
q di/qsp/examples/agent/server.q -p 5100

# 2. In another terminal, open Claude through agent.sh:
di/qsp/examples/agent/agent.sh

# ...or start claude in this directory, which picks up .mcp.json and .claude/commands/:
cd di/qsp/examples/agent && claude
```

Claude Code reads `.mcp.json` and `.claude/commands/` only from the directory
it starts in, so the slash commands and the `qsp` MCP server are available when
`claude` runs here, not from the repository root.

Inside Claude, use `/qsp:<user>` (or `/qsp <user>`) to ask questions as any
policy user:

```text
/qsp:llm1 What was the average traded price of MSFT last Monday?
/qsp:sales_na What was total notional by account on Friday?
/qsp:sales_emea What was total notional by account on Friday?
/qsp:quant1 What was total notional by account on Friday?
/qsp:compliance1 Who was refused a query recently in the audit log?
```

You can also pass a slash command directly on the command line:

```sh
di/qsp/examples/agent/agent.sh "/qsp:llm1 What was the average traded price of MSFT last Monday?"
di/qsp/examples/agent/agent.sh "/qsp:sales_na Total notional by clientType on 2026.10.09?"
```

If nothing is listening on port 5100 yet, `agent.sh` starts `server.q` in the
background for the session and stops it on exit.

## Files

| file | what it is |
|---|---|
| `server.q` | Loads the equities example HDB and policy, calls `qsp.serve p` on `-p` (default 5100), and prints every incoming `.qsp.api` call and every query decision (`ALLOWED`, `DENIED`, `ERROR`), showing what was sent, what qsp rewrote it to, and why a query was refused. |
| `client.q` | Connects to `server.q` over IPC as `gateway` (or directly as a user with `-direct`) and runs one call: `users`, `describe`, `rules`, `validate`, `explain` or `query`. |
| `mcp.py` | Minimal Python stdio MCP server (standard library only) exposing `qsp_users`, `qsp_describe`, `qsp_rules`, `qsp_validate`, `qsp_explain` and `qsp_query` as tools backed by `client.q`. |
| `.mcp.json` | Registers the `qsp` MCP server for `claude` started in this directory. `agent.sh` passes its own `--mcp-config` instead. |
| `.claude/commands/qsp/*.md` | Defines `/qsp:llm1`, `/qsp:sales_na`, `/qsp:sales_emea`, `/qsp:quant1`, `/qsp:cash_head`, `/qsp:etf_head`, `/qsp:compliance1` and `/qsp <user> <question>`. |
| `CLAUDE.md` | Agent instructions: call `qsp_describe` before writing q for a user, follow the rules in `describe`, use refusals to repair rejected queries, and show both the query sent and the rewritten query qsp ran. |
| `agent.sh` | Launches `claude` wired to `mcp.py` (starting `server.q` first if needed). |

## Trying the client directly

You can also exercise the IPC endpoints directly from the shell with `client.q`:

```sh
q di/qsp/examples/agent/client.q -call users -q
q di/qsp/examples/agent/client.q -call describe -user llm1 -q
q di/qsp/examples/agent/client.q -call validate -user llm1 -query "select account from trades where date=2026.10.07" -q
q di/qsp/examples/agent/client.q -call explain  -user sales_na -query "select notional:sum notional by account from trades where date=2026.10.09" -q
q di/qsp/examples/agent/client.q -call query    -user sales_na -query "select notional:sum notional by account from trades where date=2026.10.09" -q
```
