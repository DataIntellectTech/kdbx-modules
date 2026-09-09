# Reconciliation — `dataaccess` (stays flat: `di.dataaccess`)

**Status:** LANDED + verified (86 k4unit green; 20-module regression 1325 checks, 0 failures).
**Decision:** **MERGE** — kdbx's structure and request lifecycle kept, TorqX's query/agg layer and
working dispatch layered on, **both entry points retained**. Chosen by the user over
"TorqX as-is" and "TorqX + lifecycle only".
**Sides:** kdbx `origin/feature-dataaccess:di/dataaccess` · TorqX `di/dataaccess`
**Version:** 0.2.0 → **0.3.0** (new public API: `execquery`, `getdatafull`)

## Why this one was a genuine fork

Unlike every other module so far, neither side was a superset — and unusually, the *proposed*
canonical was TorqX. TorqX had evaluated this branch and chosen to rebuild on its skeleton, so the
two share function names, ordering and architecture almost exactly (`getrouting`,
`shardresult`/`sharderror`/`checkresults`/`sendreply`/`finishrequest`/`submitshards`,
`requests`/`shardresults` bookkeeping). What differed:

| | kdbx `execquery` | TorqX `getdata` |
|---|---|---|
| query | arbitrary **string**, time-filter rewritten in | typed; **functional** `?[t;wc;b;a]` |
| the rdb-has-no-`date`-column problem | not addressed | solved by building **per backend** |
| recombination | caller's `joinfn` | real **map-reduce** (component split for avg/wavg/vwap) |
| dispatch | `execquery` — **documented as broken** | `execqueryto` local mode — the fix |
| timeout / deferred-sync / postback | ✅ | dropped (hardcoded `0Wn`/`0b`/`()`) |
| tests | 87 lines | 18 lines |

The dispatch point is the decisive one. The branch's own `.md` carries a ⚠️ noting that
`asyncdispatch.execquery` captures `clienth:.z.w` at call time, so called in-process it replies to
the *end client* rather than back to dataaccess — "needs an asyncdispatch change, not fixable
here". `asyncdispatch` has since gained `execqueryto` (in-process routing, `replyto 0Ni`), which is
exactly that change; TorqX's version uses it. So the branch's blocker is now resolvable, and the
merged module resolves it.

## What the merge does

Base = TorqX's implementation. Grafted back from kdbx:

- **`execquery[query;start;end;joinfn;postback;timeout;sync]`** — the string entry point, kept as a
  first-class API over the shared core, with its string builder preserved as
  `buildstringshardquery` (renamed only to sit alongside the functional `buildshardquery`). It
  keeps a capability nothing else has: `.gw.asyncexecjpt` sends a raw string but does **no**
  time-range routing; `getdata` routes but only builds query shapes it knows.
- **The full request lifecycle for both paths** — `timeout` threaded through `submitshards` into
  dispatch (it was hardcoded `0Wn`, so a hung backend leaked an in-flight request forever),
  `postback` wrapping, and deferred-`sync` (`-30!`) gated by the `synccallsallowed` config.
- **The empty-range reply** now honours postback/sync and still burns a request id (TorqX sent a
  bare async empty and ignored both).
- **kdbx's 87-line test suite**, adapted — it stubs asyncdispatch, so it exercises routing, string
  rewriting and bookkeeping, all of which the merged module shares.

`mode` (`` `getdata ``/`` `execquery ``) was added to the request row; `checkresults` branches on it
to pick structured map-reduce or the caller's `joinfn`. `getdata` keeps its **5-arg** signature and
delegates to the new 8-arg `getdatafull`, mirroring the gateway's own `asyncexec`/`asyncexecjpt`
pairing — so existing `.gw.getdata` callers are untouched.

## Bugs found while merging (all mine, all fixed)

- **`'params`** — a q lambda takes at most **8 parameters**; the row builder needed nine values.
  Fixed by passing the mode-specific `(by;aggs;joinfn)` triple as one argument.
- **`'type` on upsert** — a row carrying more than one empty-list cell (an unused `joinfn` *and* no
  postback) is ambiguous to q, which cannot tell one row from a set of column vectors. Fixed by
  upserting an **enlisted dict** (`newrequest`) instead of a bare tuple.
- **`'type` on the second request** — `execquery` stored `` ` `` (a symbol *atom*) for `by`, which
  typed the general `by` column as a simple symbol column; the next `getdata` (whose `by` is a
  *vector*) then failed to upsert. Fixed by storing `` `$() ``.

## Test-harness gotchas hit (worth knowing for every future suite)

- **`x::expr` at the top level of a k4unit row defines a VIEW, not a global.** The view
  re-evaluates on read, so a value "captured" in a `run` row silently changed by the time a later
  `true` row read it — the assertion failed while the identical expression evaluated `1b` when run
  directly. Use plain `x:expr`. kdbx's rows only use `::` *inside* lambdas, where it does mean
  global-assign, which is why theirs were unaffected.
- `valid=0` in the k4unit results means the row **threw**; `valid=1, ok=0` means it ran and
  returned something other than `1b`. Checking that column first localises a failure immediately.
- A `fail` row passes on *any* throw, so it silently masks a broken expression — several existing
  `fail` rows would pass even if the function under test did not exist.

## Verification

- **`di.dataaccess` k4unit: 86/86 green** — routing, both shard builders (incl. the hdb-native vs
  rdb-derived `date` normalisation), two-shard accumulation, error short-circuit, duplicate-result
  no-op, purge + the keyed-table regression, and the grafted lifecycle (mode recorded, timeout
  reaching dispatch, postback normalised, 5-arg delegation defaults, sync refusal, uncovered-range
  reply).
- `di.asyncdispatch` placed alongside (a clean re-sync — our callback-baking patch is already
  upstream as `f175f9d`): **125/125 green**.
- **Full 20-module regression: 1325 checks, 0 failures.** `di.proc.gateway` is no longer inert —
  every module in the tree now loads and passes.

## Feeding back

The merged module is a strict superset of the branch's API, so it can go back to
`feature-dataaccess` as-is. Worth saying explicitly in that PR: the ⚠️ integration concern in the
branch's `.md` is **resolved** by `execqueryto`, and the `.md` should lose that warning.
