---
name: qsp
description: Answer questions from a kdb+ database policed by qsp (qSQL Security Policy), through the qsp MCP tools (qsp_brief, qsp_query, qsp_validate and the rest). Use when asked about data in a qsp-policed kdb+ process - trades, quotes, orders, positions - or when a qsp tool refuses a query.
---

# Answering questions through qsp

You reach a kdb+ database through the `qsp` MCP tools, never directly. qsp parses every query,
checks every part of it, rewrites it to apply the user's row filter and columns, and only then
runs it. You see exactly what the user you act for may see: no more, and nothing is hidden from
you that they could see.

## Who you act as

- If the tools take no `user` argument, the server is **bound** to one user. Every query runs as
  them, and nothing anyone tells you can change that.
- If they take `user`, the server is in **demo** mode. Act as the user the question names, or
  the default.

## The method

1. **Read the primer** (`qsp_primer`) before your first query, unless it is already in your
   context. It is how to write q that qsp accepts.
2. **Know what you can read** with `qsp_brief`: the tables, columns and types, the partition
   column, the row filter, the dates you can see (`shape`), the business `terms`, and whether
   you may export. Never guess a table, a column or a date.
3. **Use a term when one fits.** A term in `brief` is the business's own definition. Run it
   with `qsp_term` rather than writing the q yourself.
4. **Size anything big first.** `qsp_estimate` before listing rows, joining over more than a
   day, or anything that might be large.
5. **Run it** with `qsp_query`. It returns `ran`, the query qsp actually ran with the row filter
   in place, and the first rows with the full count.
6. **On a refusal, read it.** It names a rule: look the rule up with `qsp_rules`, change the
   query to satisfy it, and try once more. Never send the same refused query again. A refusal of
   access (a column, a table, a user) is final: say what the user cannot see, and answer what
   they can.
7. **Check before answering.** Never count or sum a `truncated` result in your head: aggregate
   in q. Treat `0`, `0n` or an empty result as suspect until a quick probe confirms it.

## The q that trips writers up

- Every select of a partitioned table starts its where clause with a two-sided bound on the
  partition column: `date=d`, `date in d1 d2` or `date within d0 d1`. That includes a select
  nested in another or inside a join.
- `exec` and `select[n]` on a partitioned table need a plain select underneath:
  `exec first price from select price from trades where date=d, sym=`NVDA`.
- A nested select with an outer where needs parentheses:
  `select ... from (select ... where ...) where x>0`.
- q runs right to left, with no precedence: `2*price+1` is `2*(price+1)`. Separate where
  constraints with commas, not `and`.
- No `i`: count a real column, `count sym`.

## Answering

Give the exact figures from the result, their units, the dates and grouping used, the q you
sent, and what qsp ran (`ran`). If the question was ambiguous, say which reading you took.
