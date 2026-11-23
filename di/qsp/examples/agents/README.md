# Agent examples

AI agents querying a qsp-policed kdb+ database:

- **browser chat** — now part of agenticq, which serves it with plans, fixes, receipts, workspaces and answer checking.
- **[claude/](claude/README.md)** — Claude Code wired to qsp's MCP server, which is in q (`di/qsp/mcp`): `agent.sh` and slash commands, connecting to `server.q` over IPC.
- **[eval/](eval/README.md)** — Evaluation harness (`run.py`, `converse.py`, `judge.py`, `score.q`) and recorded results ([eval/results.md](eval/results.md)).
- **`server.q`** — Shared policed HDB IPC server used by `claude/` and `eval/`.
