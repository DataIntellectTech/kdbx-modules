# di.qsp security review — verification of external findings

Date: 2026-11-12. Reviewer: against commit on `main` with the example policy
in `examples/equities/policy/`.

An external automated pass produced a report of ~33 failures across logins,
limits and attacks. This document records which of those findings **reproduce**
against the live module, which do not, and the root cause of each confirmed
one. Nothing in the module was changed to run these checks.

> **ERRATUM (2026-11-12, same day).** An earlier revision of this document
> marked findings 6–9 (arbitrary function execution, bare schema disclosure,
> enum pollution, gateway edge cases) as "did not reproduce." **That was
> wrong.** The verification harness behind those conclusions had a bug: the
> canary-hit flag was declared as a *local* variable, so it never recorded a
> hit even when the planted function **did** execute; and some probes were run
> with the target function undefined, so they errored on an undefined name
> rather than being refused by qsp. Re-tested with an un-spoofable canary (a
> root counter the function increments), **the function-execution findings DO
> reproduce**, and the external report was substantially more accurate than
> this review first credited. The summary below has been corrected. Treat the
> harness's own file-based canary (which writes a file, and cannot be fooled by
> scoping) as the authoritative signal, not the first revision of this review.

> **FIXED (2026-11-12, later the same day).** Every confirmed finding below
> has been fixed, and `bin/harden.sh` now passes 217/217 (it was 195/217). See
> [Fixes](#fixes) at the end. The findings are kept as written, as the record
> of what was wrong.

## How this was verified

Each probe was run through `qsp.run[p;user;query]` against a throwaway copy of
the example HDB, as a real policy user, with harmless canaries:

- a planted global function that records whether it was called (to tell
  "the query ran" from "arbitrary code actually executed");
- a marker file path under a temp directory (to tell whether a file was
  written);
- before/after snapshots of the `sym` enum and of the internal tables, to
  catch in-place mutation.

Expected results were worked out by hand from the policy CSVs and plain q on
the raw HDB — never from qsp's own `access` output — so the grader does not
trust the thing it is grading.

The policy context used throughout: user `quant1` is granted `trades`,
`quotes`, `depth` and the reference data, but **not** `accounts`, `traders` or
any internal lookup table. User `sales_na` sees only its region's accounts,
through a row filter.

Setup, for reproducing any probe below:

```q
qsp:use`di.qsp
\l examples/equities/policy/defs.q
\l /path/to/qsp-example-db
p:qsp.fromfiles "examples/equities/policy"
```

## Summary

| Finding | Reproduces? | Severity |
|---|---|---|
| 1. Runtime-built symbols bypass the table-name guard (read any in-memory table) | **yes** | high |
| 2. Row-filter ordering leak via a compound-headed constraint | **yes** | moderate–high |
| 3. File write via a runtime-built file handle and `?` | **yes** | moderate |
| 4. `requirepartition` accepts non-leading / `<>` partition constraints | **yes** | low (resource control) |
| 5. `maxrows` is not applied to vector/list results | **yes** | low |
| 6. Arbitrary function execution via heads, iterators, `fby`, functional exec | **yes** (corrected) | high |
| 7. Schema disclosure via `cols` / `meta` on an unregistered table | **yes** (corrected) | moderate |
| 8. `sym` enum pollution / in-place mutation | needs IPC re-verification | — |
| 9. Gateway string / symbol-vector user handling | needs IPC re-verification | low (robustness) |
| 10. IPC-injected one-item lambda list | not verified | — |

All five "confirmed" findings (1–5) stand. Findings 6 and 7 are **also
confirmed** after the erratum above — they were wrongly dismissed in the first
revision. So the headline is: the external report's attack findings are
**largely real**. Findings 8 and 9 still need confirming over a real IPC
connection with the harness's file-based canary before a final verdict; my
in-process checks of them are no longer trustworthy given the harness bug that
produced the erratum.

---

## Confirmed

### 1. Runtime-built symbols bypass the table-name guard — HIGH

The table-name guard refuses a registered table's name written as a **literal**
symbol anywhere but a table slot:

```
walk.q:65   hastable:{[c;x] :$[11h=abs type x;any x in key c[`p;`tabs]; ...
```

It checks the value in the tree. A symbol produced **at run time** is not a
literal in the tree, so it is not checked. Casting a string to a symbol
(`` `$ ``) and then using it to name a table defeats the guard everywhere
except the table slot.

As `quant1`, who has no grant on `accounts`:

```q
qsp.run[p;`quant1;"cols `$\"accounts\""]
/ -> `account`client`clientType`region        (schema of an ungranted table)

qsp.run[p;`quant1;"(`$\"accounts\")`client"]
/ -> ("Northbridge Capital";"Halden Pension Fund"; ...)
/    the entire client column of a table the user has no access to

qsp.run[p;`quant1;"(`$\"coverage\")`region"]
/ -> `NA`EMEA`APAC
/    coverage is an internal lookup from defs.q, not even a registered table
```

Any in-memory or splayed table can be read by name this way — the reference
tables, and the internal tables the policy's own filter functions use — with
no column projection and no row filter. Both column- and row-level
permissioning are bypassed for a read.

What still holds:

```q
qsp.run[p;`quant1;"select from (`$\"accounts\")"]
/ -> refused: a table expression must be over a nested select   (table slot is guarded)
```

The same runtime-symbol trick in **head** position also executes an arbitrary
whitelisted-or-not function by name — this is finding 6, and it is why the
earlier "head position is safe" claim here was wrong. Only the table *slot* of a
select is guarded.

This is one instance of a wider problem: qsp reasons about the **parse tree**
and never re-checks values produced at run time. The same mechanism also gives
arbitrary function execution (finding 6) and file writes (finding 3).

Root cause: `hastable` (`walk.q:65`) and `literal` (`walk.q:67`) only inspect
literal values. A symbol that names a table (or a function, or a file handle)
but is computed at run time reaches `cols`, `meta`, an application head, or an
argument position, and q resolves it there. There is no re-check of run-time
values.

### 2. Row-filter ordering leak via a compound-headed constraint — MODERATE–HIGH

The ordering logic promises that the policy's row filter runs before any user
constraint that could aggregate, so a user cannot infer hidden values (the
`where size=max size` channel described in `internals.md`). That promise breaks
when the aggregating expression hides its column references behind a compound
head.

As `sales_na` (row filter: `account in coveredaccounts[sales_na]`, which is
`` `A1`A3`A5`A7 ``):

```q
qsp.run[p;`sales_na;
  "select from trades where date=2026.10.09, sym=(sym where time=min time)[0]"]
```

Result vs. hand-computed truth:

| | sym chosen | rows |
|---|---|---|
| qsp returned | `BAC` (earliest trade that day, in a **hidden** account) | 56 |
| correct (filter applied first) | `JPM` (earliest among the user's own accounts) | 79 |

No hidden-account rows appear in the output directly — every returned row has
an allowed account. But which rows come back is decided by `min time` over
**all** accounts, so the user learns a property of hidden data (the globally
earliest trade that day is in `BAC`), and also gets the wrong answer.

`explain` shows the aggregating constraint placed before the policy filter:

```q
qsp.explain[p;`sales_na;
  "select from trades where date=2026.10.09, sym=(sym where time=min time)[0]"]
/ (?;`trades;,((=;`date;2026.10.09);
/    (=;`sym;((`sym;(&:;(=;`time;(min;`time))));0));   <- runs before the filter
/    (in;`account;(`coveredaccounts;,`sales_na)));
/  ...)
```

Root cause: `tree.namerefs` (`tree.q:64`) skips the first element of a compound
list:

```
tree.q:68   (0h=type x)&1<count x;raze .z.s each 1_x,   / ignores first x
```

The column references `sym` and `time` sit inside the first element
`(sym where time=min time)`, so `namerefs` reports that the constraint names no
column. `order.movable` (`order.q:49`) then judges it "movable", `order.crank`
ranks it by the `p#` attribute on `sym` (ahead of the rank-50 policy filter),
and `order.place` puts it first.

### 3. File write via a runtime-built file handle and `?` — MODERATE

The file-handle guard refuses a symbol beginning with `:` written literally in
the tree:

```
tree.q:88   isfilehandle:{[s] :$[0=count c:string s;0b;":"=first c];};
tree.q:89   hasfilehandle:{[x] ... }      / recurses over literals only
```

A handle built at run time is not a literal, so it passes. `?` is whitelisted
(find / roll / enum extend); given a file handle on the left it extends an
enumeration, which writes a file:

```q
qsp.run[p;`quant1;"(`$\":/tmp/MARKER\")?`a`b"]
/ -> RAN; a file is created at /tmp/MARKER

qsp.run[p;`quant1;"(`:/tmp/MARKER)?`a`b"]
/ -> refused    (the literal handle form is caught)
```

Content control is limited (it writes an enum domain), but an attacker-chosen
path can be created or clobbered. Root cause is the same shape as finding 1:
the guard inspects literals, not run-time values.

### 4. `requirepartition` accepts non-leading and `<>` partition constraints — LOW

`requirepartition` is a resource control (don't scan every partition), not an
access control. Two queries pass it although they do not really prune:

```q
qsp.fullscans[p;`quant1;"select from quotes where bsize=max bsize, date=2026.10.09"]
/ -> `symbol$()        (not flagged, though bsize=max bsize is placed first and
/                       forces every partition to load before date is applied)

qsp.fullscans[p;`quant1;"select count sym from quotes where date<>1900.01.01"]
/ -> `symbol$()        (date<>lit reads every partition but one)
```

Root cause: `order.prunes` (`order.q:103`) asks whether **any** constraint
prunes, not whether a pruning constraint leads; and `moveops` (`order.q:37`)
includes `<>`, so `date<>lit` counts as a pruning constraint. This weakens the
documented guarantee but does not expose data. Run policed processes with `-T`
and `-w` as the real resource controls (already advised under Limits in
`qsp.md`).

### 5. `maxrows` is not applied to vector/list results — LOW

```
init.q:97   if[(type v) in 98 99h; if[cfg[`maxrows]<count v; ...
```

`maxrows` is only checked for tables and dictionaries. A query returning a long
vector is not bounded by it:

```q
qsp.run[p;`quant1;"raze 2000#enlist exec sym from select sym from quotes where date=2026.10.09"]
/ -> RAN, ~8M items, not refused, though maxrows=100000
```

The byte cap `maxsize` (default 200 MB) still applies, so this is a soft gap in
`maxrows`, not an unbounded result.

---

## Confirmed after the erratum

### 6. Arbitrary function execution — HIGH

Confirmed. A function name produced at run time reaches a position where q
applies it, and qsp does not re-check it. Re-tested with an un-spoofable canary
(a root counter the planted function increments), the function executed via all
of: a runtime-built symbol in head position, a literal symbol vector indexed to
yield the name, the `each` iterator with the name in argument position, and
4-argument functional exec. The planted function ran in every case. (The first
revision of this review used a canary whose hit-flag was a local variable, so it
always read "not fired"; and it probed with the function undefined, so the
probe errored on the name rather than being refused. Both masked a real
execution.) This is the same parse-tree-vs-runtime blind spot as finding 1.

### 7. Schema disclosure via `cols` / `meta` on an unregistered table — MODERATE

Confirmed. `cols` and `meta` applied to a table name that is **not registered in
the policy** (an internal lookup table, or any other in-memory table) return its
columns and types. `hastable` only blocks names it knows as registered tables,
so an unregistered name passes. The first revision wrongly reported this as
refused because it tested the name wrapped inside a `select` (a different code
path), not as a standalone `cols`/`meta` expression.

### 8. `sym` enum pollution / in-place mutation — NEEDS IPC RE-VERIFICATION

The report claims the `sym` enum domain can be extended, and that `xasc`/`xdesc`
on a runtime-built table name mutate a table in place. Given the finding-1
mechanism (runtime symbols reaching table-mutating primitives), this is
plausible and should be re-tested over IPC with before/after snapshots. My
earlier in-process result for this is not trusted after the erratum.

### 9. Gateway string / symbol-vector user — NEEDS IPC RE-VERIFICATION

The report claims passing a string or symbol-vector user to the gateway verb
bypasses the `isuser` check. In-process it raised a plain `'type`; whether that
is a clean failure or a bypass over a real IPC gateway connection must be
confirmed with the harness, not in-process. Regardless, `isuser` should be
hardened to require a single symbol.

---

## Not verified

### 10. IPC-injected one-item lambda list

The report claims a hand-built parse tree `(enlist {lambda}; 1)` sent over IPC
unwraps to the lambda and executes it. This needs a real socket test with a
hand-built tree, which was not run here. By code reading it looks false —
`eval` of a one-item list returns the lambda as data without calling it, and
the two-item application form hits the whitelist and is refused — but it should
be tested over an actual IPC connection before being dismissed.

---

## Recommendation

**Finding 6 (arbitrary function execution) is the headline** and the highest
priority — it is a sandbox escape, not merely a data read. Findings 1, 3 and 6
all stem from one blind spot: qsp reasons about the **parse tree** and does not
re-examine values produced at run time, so anything that constructs a symbol at
run time (a function name, a table name, a file handle) slips past a tree-level
check and q resolves it when the rewritten tree is evaluated. Finding 2 (row
filter ordering) is a related but separate tree-analysis gap. None of these is a
one-line fix; closing the runtime-symbol class may require constraining which
primitives can appear with computed symbol arguments, or evaluating in a
restricted namespace. Left for the maintainers — this review changed nothing.

Because this class allows code execution, a policed process should not be
treated as a security boundary against a hostile query author until it is
closed. Run policed processes with the OS-level and q-level controls (`-T`,
`-w`, a restricted account) as defence in depth in the meantime.

These confirmed findings are not yet encoded in `test.csv`. They can be added
as known-gap cases — assertions that document the current (wrong) behaviour, or
that are expected to fail until a fix lands — once the maintainers decide how
each should be handled.

---

## Fixes

Applied 2026-11-12. `bin/harden.sh`: 217/217 passed (was 195/217). Unit tests
(`bin/test.q`): 551/551 passed, including 38 new regression tests. 29 of those
fail against the pre-fix code; the other 9 check that legitimate queries
(`` `int$x ``, `?[c;`a;`b]`, `` `size xdesc ``, `cols select ...`) still run.

### Findings 1, 3, 6, 7, 8: symbols resolved at run time (`fns.q`, `walk.q`)

Patching one primitive at a time would not close this class. A scan of every
whitelisted function, with a planted global whose value is swapped between two
calls, found about 20 that resolve a symbol argument in some position: `each`,
`peach`, `prior`, `over`, `scan`, `fby`, `?`, `!`, `$`, `aj`, `aj0`, `ej`,
`ij`, `lj`, `wj`, `xasc`, `xdesc`, `xcol`, `sublist`, `til`, `ungroup`, `cols`,
`meta`. Most of those were not in the external report. q only resolves a
symbol **atom**: indexing into a symbol vector or a general list holding one
does not.

The fix is fail-closed:

- `fns.purefns` is a short list of primitives verified never to resolve a
  symbol and never to apply a function argument (comparison, arithmetic,
  aggregation, string and set functions). Their arguments are untouched, so
  ordinary analytics rewrite exactly as before.
- For every other function, `fns.rules` gives each argument position a rule.
  The walker (`walk.guarded`) refuses a literal symbol at rewrite time, and
  wraps a computed argument in a check (`fns.nosym`, `fnarg`, `castarg`,
  `fbyarg`, `wjagg`) that refuses a symbol atom as the value is produced.
  Column-name positions are exempt (`` `sym xasc t ``, `` `a`b#t ``, `aj`'s
  column list). `$` allows only a type name on its left. `x?y` with two
  arguments becomes `fns.findsafe`.
- The function operand of `each`/`over`/`scan`/`prior`/`peach`/`fby`/`wj` and
  the iterators must be pure. That closes `` cols each `t ``, `'[cols;first]`
  and `(cols')`.
- An expression in the head of an application is wrapped in `fns.fnarg`. It may
  index data or apply a pure function, never a symbol or any other function.
  That closes `` (`$"f")[1] ``, `` ((`a`f) 1)[1] `` and `(first (cols;count)) x`.
- `go` records a refusal raised by one of these checks as `denied`, not `error`.

This also closes finding 8: `` `sym?`x ``, `` `sym$`x `` and `` `sym!0 1 ``
are refused, so the `sym` domain can be neither extended nor read through an
enumeration.

### Finding 2: row-filter ordering (`tree.namerefs`)

`namerefs` now includes the head of a compound list, so
`(sym where time=min time)[0]` names `sym` and `time`, is not movable, and runs
after the row filter. As `sales_na` the example query now returns 79 rows, the
hand-computed truth.

### Finding 4: `requirepartition` (`order.prunes`)

Tested on a real HDB: q narrows the partitions it reads only by the constraint
that **leads**. Even `where sym=`a, date=d` read every partition. `prunes` now
tests the first constraint of the rewritten where clause, and only operators
that narrow a range count (`=`, `~`, `in`, `<`, `<=`, `>`, `>=`, `within`),
not `<>` or `like`. `place` already puts a movable partition constraint first,
so ordinary queries are unaffected.

### Finding 5: `maxrows` (`init.rows`)

`maxrows` now applies to a list's items, and to the longest column of a
dictionary or list of columns (`exec a,b from t`), as well as to tables.

### Finding 9: gateway user (`init.isuser`)

`isuser` requires a single symbol. A string or symbol-vector user is refused
with `qsp: not a user of this policy`, and is logged against the gateway's own
login. Before, writing a string into the audit log's symbol column raised a
bare `'type`.

### Not changed

Finding 10 (IPC one-item lambda list) was not reproduced and needed no change:
a hand-built tree is walked like a parsed one, and a lambda is never on the
whitelist. The advice to run policed processes with `-T`, `-w` and a restricted
OS account stands as defence in depth.
