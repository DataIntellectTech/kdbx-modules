---
description: Query the policed qsp kdb+ server as quant1 (e.g. /qsp:quant1 What was the average traded price of MSFT last Monday?)
argument-hint: <question>
---

Answer the question below as qsp user `quant1` by querying the live policed kdb+ server over IPC using the `qsp` MCP tools (`mcp__qsp__qsp_describe`, `mcp__qsp__qsp_validate`, `mcp__qsp__qsp_explain`, `mcp__qsp__qsp_query`, `mcp__qsp__qsp_rules`).

Question: `$ARGUMENTS`

## Steps

1. Call `qsp_describe` with `user: "quant1"` first to learn which tables and columns `quant1` can read, the partition column (`date`), `quant1`'s row filter, and the rules for writing q that `qsp` accepts. (The example HDB holds five trading days: Monday `2026.10.05` through Friday `2026.10.09`, with the policy clock at Saturday `2026.10.10D00:00`.)
2. Write a q-SQL query following the rules in `describe` and run it with `qsp_query` as `user: "quant1"`.
3. If `qsp_query` returns a `qsp: ...` refusal, match the refusal text to the rule in `describe`, explain why `qsp` refused it, and if the question can be answered by fixing the query, repair and re-run it.
4. Show:
   - **User:** `quant1` (and the relevant policy filter/columns)
   - **Query sent:** the q-SQL query you sent
   - **What qsp ran:** the rewritten query `qsp` actually ran (or the refusal message)
   - **Answer:** the answer from the data
