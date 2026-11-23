# Example: an AI agent querying a policed HDB

An MCP server that connects an agent (`claude`) to the policed equities HDB over
IPC. It uses `qsp.api` to learn what its user may query and the rules its q
must follow, and runs queries through qsp, which rewrites each one for that user.

```sh
# 1. Start the policed HDB server in one terminal (logs every API call and query live):
q di/qsp/examples/agents/server.q -p 5100

# 2. In another terminal, ask a question as one user, or open a session:
di/qsp/examples/agents/claude/agent.sh -u quant1 "What was the VWAP by sym on 2026.10.07?"
di/qsp/examples/agents/claude/agent.sh -u sales_na               # interactive, as sales_na
```

If nothing is listening on port 5100 yet, `agent.sh` starts `server.q` in the
background for the session and stops it on exit.

## Bound to one user, or the demo

**Bound (the default).** `agent.sh -u USER`, or `-user USER` for
`qsp-mcp`, binds the agent to one user, `llm1` if none is given.
- The MCP server logs in as that user, so qsp takes the user from the connection.
- No tool takes a user, and `qsp_users` is not offered.
- A tool call that names anyone else is refused.
- Nothing the agent reads or is told - a document, a result row, a person
  asking "run that as compliance1" - can make it act as someone else. The
  process holds no credential that could.

This is how an agent that acts for a person should run. In production, that
login should also be authenticated (`-U`, or a `.z.pw` hook such as LDAP:
`qsp.serve` keeps an existing `.z.pw` and calls it after its own name check).

**Demo.** `agent.sh --demo`, or `QSP_DEMO_GATEWAY=1`, logs in as the
`gateway` login, and every tool takes the user to act as. One session can try
every role, so this is for exploring the example, not for an agent that acts
for someone: a gateway can be anyone.

The `/qsp:<user>` slash commands use the demo mode. `.mcp.json` sets it for
`claude` started in this directory:

```sh
cd di/qsp/examples/agents/claude && claude      # picks up .mcp.json and .claude/commands/
```

```text
/qsp:llm1 What was the average traded price of MSFT last Monday?
/qsp:sales_na What was total notional by account on Friday?
/qsp:compliance1 Who was refused a query recently in the audit log?
```

Claude Code reads `.mcp.json` and `.claude/commands/` only from the directory
it starts in, so they are available when `claude` runs here, not from the
repository root.

## The primer

`agent.sh` also reads the server's primer, `` (`.qsp.api;`primer) ``, and puts
it in Claude's system prompt. The primer covers how to write q that qsp accepts:
- a method for answering a question;
- the q that matters;
- the query shapes qsp takes;
- the names a column cannot have;
- time-series techniques;
- what each refusal means.

The text comes from qsp, which ships it as `di/qsp/api/primer.md`. The
equities example's walkthrough runs every q example in it, so it describes the
qsp that serves it.

It goes in the system prompt because it only helps if it is in context before
the agent writes its first query. The mistakes it prevents are first attempts,
made from habit, such as a column named `fills` or `time.minute`. It is about
15 KB, and Claude Code cuts an MCP server's instructions and a hook's output
to about 4 KB, so neither can carry it. When `claude` is started here without
`agent.sh`, the MCP server's instructions instead tell the agent to call the
`qsp_primer` tool before its first query.

## Files

| file | what it is |
|---|---|
| `server.q` | Loads the equities example HDB and policy, calls `qsp.serve p` on `-p` (default 5100), and prints every incoming `.qsp.api` call and every query decision (`ALLOWED`, `DENIED`, `ERROR`), showing what was sent, what qsp rewrote it to, and why a query was refused. |
| `client.q` | Connects to `server.q` over IPC as `gateway` (or directly as a user with `-direct`) and runs one call - a query's result as JSON with `-json`, its first `-rows N` rows - `users`, `describe`, `rules`, `primer`, `validate`, `explain` or `query`. |
| `../../../mcp/qsp-mcp` | qsp's MCP server, in q (`di/qsp/mcp/mcp.q`): `qsp_brief`, `qsp_describe`, `qsp_rules`, `qsp_primer`, `qsp_validate`, `qsp_explain`, `qsp_estimate`, `qsp_query`, `qsp_history`, `qsp_term`, and in demo mode `qsp_users`. See its README. |
| `.mcp.json` | Registers the `qsp` MCP server, in demo mode, for `claude` started in this directory. `agent.sh` passes its own `--mcp-config` instead. |
| `.claude/commands/qsp/*.md` | Defines `/qsp:llm1`, `/qsp:sales_na`, `/qsp:sales_emea`, `/qsp:quant1`, `/qsp:cash_head`, `/qsp:etf_head`, `/qsp:compliance1` and `/qsp <user> <question>`. |
| `CLAUDE.md` | Agent instructions: call `qsp_describe` before writing q for a user, follow the rules in `describe`, use refusals to repair rejected queries, and show both the query sent and the rewritten query qsp ran. |
| `agent.sh` | Launches `claude` wired to `qsp-mcp`, bound to one user (`-u`, default `llm1`) or in demo mode (`--demo`), with the server's primer in the system prompt (starting `server.q` first if needed). |

## Trying the client directly

You can also exercise the IPC endpoints directly from the shell with `client.q`:

```sh
q di/qsp/examples/agents/claude/client.q -call users -q
q di/qsp/examples/agents/claude/client.q -call describe -user llm1 -q
q di/qsp/examples/agents/claude/client.q -call validate -user llm1 -query "select account from trades where date=2026.10.07" -q
q di/qsp/examples/agents/claude/client.q -call explain  -user sales_na -query "select notional:sum notional by account from trades where date=2026.10.09" -q
q di/qsp/examples/agents/claude/client.q -call query    -user sales_na -query "select notional:sum notional by account from trades where date=2026.10.09" -q
```
