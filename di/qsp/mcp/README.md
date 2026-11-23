# qsp's MCP server

`mcp.q` gives an MCP client - Claude Code, or any other - qsp's own calls as tools, over MCP's
stdio transport. It is a q process that connects to a policed kdb+ process over IPC. Nothing else
needs installing: no Python, no Node.

```sh
# bound: it logs in as llm1, so every call runs as llm1 and no message can name anyone else
claude mcp add qsp -- /path/to/di/qsp/mcp/qsp-mcp -port 5100 -user llm1

# demo: it logs in as a gateway, and each tool takes the user to act as
claude mcp add qsp -- /path/to/di/qsp/mcp/qsp-mcp -port 5100 -gateway gateway -default llm1
```

Or in a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "qsp": {
      "command": "/path/to/di/qsp/mcp/qsp-mcp",
      "args": ["-port", "5100", "-user", "llm1"]
    }
  }
}
```

`qsp-mcp` runs `q mcp.q -q`. The `-q` matters: without it q prints its banner on stdout, where the
client expects only protocol messages. Set `QBIN` if `q` is not on the client's `PATH`.

## Options

| option | default | |
|---|---|---|
| `-host` | `localhost` | the policed process |
| `-port` | `5100` | |
| `-user` | | bound mode: log in as this user |
| `-gateway` | `gateway` | demo mode: log in as this gateway login |
| `-default` | `llm1` | demo mode: the user a tool acts as when it names none |
| `-pass` | `x` | the password to log in with |
| `-rows` | `100` | rows of a result sent back; `rows` in the reply is the full count |

## Tools

| tool | qsp call |
|---|---|
| `qsp_brief` | `(`.qsp.api;`brief)` |
| `qsp_describe` | `(`.qsp.api;`describe)` |
| `qsp_rules` | `(`.qsp.api;`rules)` |
| `qsp_primer` | `(`.qsp.api;`primer)` |
| `qsp_validate` | `(`.qsp.api;`validate;q)`, with the refusal as data: code, kind, subject |
| `qsp_explain` | `(`.qsp.api;`explain;q)` |
| `qsp_estimate` | `(`.qsp.api;`estimate;q)` |
| `qsp_query` | `(`.qsp.execasx;q;user)` |
| `qsp_history` | `(`.qsp.api;`history;n)` |
| `qsp_term` | `(`.qsp.api;`term;name;args)`, then `qsp_query` on the query it fills in |
| `qsp_users` | `(`.qsp.api;`users)`, demo mode only |

A term's arguments arrive as JSON. Each is read as the type the term declares, as `terms.csv`
examples are, so qsp receives typed values and never text.

## Protocol

It implements what a tool server needs: `initialize` (versions 2024-11-05 to 2025-06-18),
`ping`, `tools/list` and `tools/call`. Notifications are accepted and need no reply. A refused
query is a tool result with `isError` set and qsp's refusal as its text, which the model reads.
The connection to qsp is opened on the first call and reopened if it drops. The process exits
when the client closes its stdin.

For an agent that should be able to plan, get fixes for refused queries, receipts for its
answers and a workspace for its results, use agenticq instead: it serves MCP over HTTP with
those tools.

The skill in `../skill/qsp/SKILL.md` teaches an agent how to use these tools. Copy it to
`.claude/skills/qsp/` in a project, or `~/.claude/skills/qsp/`.
