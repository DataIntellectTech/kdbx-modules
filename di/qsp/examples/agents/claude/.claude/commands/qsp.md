---
description: Ask a question against the policed qsp kdb+ server as a named user (e.g. /qsp llm1 What was the average traded price of MSFT on 2026.10.07?)
argument-hint: <user> <question>
---

Answer the question below by querying the live policed kdb+ server over IPC using the `qsp` MCP tools (`mcp__qsp__qsp_describe`, `mcp__qsp__qsp_validate`, `mcp__qsp__qsp_explain`, `mcp__qsp__qsp_query`, `mcp__qsp__qsp_rules`, `mcp__qsp__qsp_users`).

Input: `$ARGUMENTS`

## Steps

1. **Determine the user and the question:**
   - The first token of `$ARGUMENTS` is the qsp policy user (for example `llm1`, `sales_na`, `sales_emea`, `quant1`, `cash_head`, `etf_head`, or `compliance1`), and the remainder is the question.
   - If the first token is not one of the policy users, call `qsp_users` to check and default to `llm1`, treating the full `$ARGUMENTS` as the question.
2. **Call `qsp_describe` for that user first:**
   - Inspect the tables and columns granted to the user, the partition column (`date`), the user's row filter, the policy clock/dates (the example HDB holds five trading days: Monday `2026.10.05` through Friday `2026.10.09`, with the policy clock at Saturday `2026.10.10D00:00`), and the `rules` for writing q that `qsp` accepts.
3. **Write and run the q-SQL query via `qsp_query`:**
   - Follow the `rules` in `describe` (bound `date` first on partitioned tables; wrap `exec` or `select[n]` around a nested `select` on partitioned tables; never use `i`).
   - If `qsp_query` returns a `qsp: ...` refusal, match the refusal text to the rule in `describe`, explain why `qsp` refused it, and if the question can be answered within the user's permissions by adjusting the query (for example narrowing the date range to respect an embargo or fixing syntax), repair and re-run it.
4. **Present the result clearly:**
   - **User:** the policy user you ran as (and their row/column constraints relevant to the question)
   - **Query sent:** the q-SQL query you wrote
   - **What qsp ran:** the rewritten query `qsp` executed (or the refusal message if `qsp` blocked it)
   - **Answer:** the answer from the returned data
