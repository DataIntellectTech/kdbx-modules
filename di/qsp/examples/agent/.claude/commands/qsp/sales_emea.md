---
description: Query the policed qsp kdb+ server as sales_emea (e.g. /qsp:sales_emea What was the average traded price of MSFT last Monday?)
argument-hint: <question>
---

Answer the question below as qsp user `sales_emea` by querying the live policed kdb+ server over IPC using the `qsp` MCP tools (`mcp__qsp__qsp_describe`, `mcp__qsp__qsp_validate`, `mcp__qsp__qsp_explain`, `mcp__qsp__qsp_query`, `mcp__qsp__qsp_rules`).

Question: `$ARGUMENTS`

## Steps

1. Call `qsp_describe` with `user: "sales_emea"` first to learn which tables and columns `sales_emea` can read, the partition column (`date`), `sales_emea`'s row filter, and the 20 rules for writing q that `qsp` accepts. (The example HDB holds five trading days: Monday `2026.10.05` through Friday `2026.10.09`, with the policy clock at Saturday `2026.10.10D00:00`.)
2. Write a q-SQL query following the rules in `describe` and run it with `qsp_query` as `user: "sales_emea"`.
3. If `qsp_query` returns a `qsp: ...` refusal, match the refusal text to the rule in `describe`, explain why `qsp` refused it, and if the question can be answered by fixing the query, repair and re-run it.
4. Show:
   - **User:** `sales_emea` (and the relevant policy filter/columns)
   - **Query sent:** the q-SQL query you sent
   - **What qsp ran:** the rewritten query `qsp` actually ran (or the refusal message)
   - **Answer:** the answer from the data
