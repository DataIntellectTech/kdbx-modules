# di.proc.rdb

The real-time database: subscribe to a tickerplant, replay the day's log to recover
intraday state, accumulate live updates in memory, and at end of day write each table to
the HDB, clear it, and tell the HDB(s) to reload.

Ported from the **critical path** of `TorQ/code/processes/rdb.q`. The scope is deliberately
narrow (see the Chesterton's-Fence audit of rdb.q): subscribe → replay → accumulate →
savedown → HDB reload, and nothing else yet.

## Dependencies

- **Injected** (from di.torq): `log`, `timer`, `handlers`.
- **Hard** (`use`-imported): `di.torq.servers` (connect to TP + HDB), `di.subscriptions`
  (subscribe + replay), `di.dbwrite` (savedown/sort/attr/gc), `di.tplogmgr` (via
  di.subscriptions, for replay).

`di.dbwrite` expects a **monadic** logger (`log[`info]["msg"]`, kx.log style); di.proc.rdb
bridges the injected **dyadic** di.util.log dep (`log[`info][`ctx;"msg"]`) with a small adapter
that folds in a fixed `` `rdb `` context. No kx.log install is required.

## Config

```toml
tickerplanttypes = "tickerplant"   # proctype(s) to subscribe to
hdbtypes = "hdb"                   # proctype(s) to write to / reload at EOD
hdbdir = "hdb"                     # HDB root (relative to TORQXDATAHOME, or absolute)
replaylog = true                   # replay the tp log on startup
tpwaittimeout = 30000              # ms to block waiting for the tickerplant
reloadenabled = false             # false (default): save+clear own tables at EOD (standalone).
                                  # true: a wdb owns the writedown - defer to its reload[] call.
# subscribeto / subscribesyms omitted -> all tables, all syms
# ignorelist omitted -> `heartbeat`logmsg (not saved at EOD)
# sortcsv (optional) -> di.dbwrite sort/attribute config; else dbwrite's default (time asc)
```

Set `reloadenabled = true` **only** when a wdb is present in the stack — otherwise the EOD
writedown is deferred to a wdb that never calls back, and the data is never persisted.

The **schema comes from the tickerplant** (via `subdetails`), not a local `database.q` —
di.subscriptions defines the tables at root from what the TP returns.

## Behaviour

- **Startup**: `di.torq.servers` connects to the TP + HDB(s); block until a TP is up
  (`waitfortype`); `di.subscriptions.subscribe` registers for live data and replays the
  day's log up to the pre-subscription count.
- **Accumulate** (`upd`, published at root): a **root-namespace-safe** append — upserts a
  table payload (live) or a list-of-columns payload (replay) into the root table via
  `@[`.;t;…]`. Set at root **before** subscribing so replay drives it too.
- **End of day** (`endofday[date]`, published at root, also `.u.end`): the tickerplant
  broadcasts `(`endofday;date)` at roll (see below). Behaviour depends on `reloadenabled`:
  - **standalone** (`0b`, default): saves every non-ignored root table to `hdbdir` for `date`
    (`di.dbwrite.savedown` — enumerate, splay, sort, attr, gc), clears each (`@[`.;t;0#]`),
    then tells every connected HDB to `.hdb.reload[]`.
  - **wdb-fronted** (`1b`): a wdb owns the writedown, so di.proc.rdb only **snapshots** the
    per-table row counts (`.z.m.eodtabcount`) and escapes — the data stays live and
    queryable. No save, no clear, no HDB notify. It waits for the wdb's `reload[date]`.
- **Reload** (`reload[date]`, published at root): the IPC entry point the **wdb** calls once
  it has persisted the prior day. Drops exactly the snapshotted row count from each table
  (`n _`, keeping the new day's ticks that arrived since EOD), reapplies attributes (the drop
  loses `` `g# `` etc.), garbage-collects, and clears the snapshot. Harmless if never called
  (standalone rdbs simply never receive it).

## RDB / WDB interaction (why `reload` exists)

When both an rdb and a wdb subscribe to the same tickerplant, the wdb owns the on-disk
writedown and the rdb keeps the prior day **in memory, queryable**, until the wdb confirms
the data is safely on disk. The handshake at roll:

1. the tp broadcasts `(`endofday;date)` to both. The rdb (`reloadenabled=1b`) snapshots its
   row counts and returns — nothing saved, nothing cleared. New-day ticks keep landing.
2. the wdb flushes its buffer to disk, sorts, moves the partition into the hdb, then calls
   `(`reload;date)` on each rdb (and `.hdb.reload` on each hdb).
3. the rdb's `reload` drops the first `eodtabcount[t]` rows of each table — exactly the prior
   day the wdb just persisted — leaving the new day intact.

This mirrors `TorQ/code/processes/rdb.q`'s `reloadenabled`/`dropfirstnrows`. Responsibility
for the writedown is **explicit config** (`reloadenabled`), not auto-detection: the rdb never
probes for a wdb's existence (fail-fast / explicit-config, per the TorQ conventions).

## The EOD trigger (TP-driven, dated)

The RDB's writedown is triggered **by the tickerplant**, not a local timer — so it saves
exactly the day's data, only after the TP has sent its last message for the day. This
required a fix to di.pubsub (vendored into TorqX): `callendofday` now broadcasts
`(`endofday;date)` instead of a bare `` `endofday`` symbol. A bare async symbol is **not**
applied by a default `.z.ps` (it returns the function, doesn't call it) and carries no
partition date; the 2-list form is applied as `endofday[date]` (classic `.u.end` style).
Feed this fix upstream when di.pubsub is next touched.

## Not included (future / other-process / deprecated)

- **Gateway** attribute push + query-partition tracking (`rdbpartition`/`parvaluesrc` —
  that machinery exists *only* so a gateway knows which dates the RDB holds; a standalone
  RDB doesn't need it). Note TorQ's `reloadenabled` EOD branch *also* pushes EOD attributes
  to the gateway; that half is deferred here with the rest of the gateway support.
- **Subscription filters** (`subfiltered`) — experimental/incomplete upstream.
- **FinSpace/AWS** — stripped entirely.

## Module-namespace notes

A `use`-loaded module can't create/populate root tables via bare symbols (they land in the
module's private namespace; a bare `insert` under `-11!` replay does too). di.proc.rdb therefore
reads root tables with bare `value t` (bare **reads** fall through to root), but **writes**
and **clears** target root explicitly via `@[`.;…]`, and its `upd` is root-safe.

## Testing

`test.csv` (k4unit) covers the dependency contract (init errors without `log`/`timer`) and
the export surface. The full subscribe → replay → live-capture → EOD-save → HDB-reload
flow is proven in the **TorqX-POC end-to-end** (`torqx.sh start tickerplant1 hdb feed1
rdb1`): the RDB replays the tp log on startup, accumulates live trade/quote, and on a
forced tickerplant `endofday` writes the partition to the HDB (verified on disk), clears,
and the HDB reloads to see it.

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.proc.rdb
```
