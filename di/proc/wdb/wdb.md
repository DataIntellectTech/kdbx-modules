# di.proc.wdb

The write database. Subscribes to a tickerplant, replays the day's log to disk, then during
the day incrementally writes each in-memory table to a **temp** partition as it fills, and at
end of day flushes what remains, sorts each table on disk, **moves** the partition into the
HDB, and triggers a reload of the HDB(s) and RDB(s).

Ported from the **critical path** of `TorQ/code/processes/wdb.q` (+ `code/wdb/writedown.q`).
The scope is deliberately the classic, in-process, `default`-writedown-mode WDB (see the
Chesterton's-Fence audit of wdb.q).

## Dependencies

- **Injected** (from di.torq): `log`, `timer`.
- **Hard** (`use`-imported): `di.torq.servers` (connect to TP/HDB/RDB), `di.subscriptions`
  (subscribe + replay), `di.dbwrite` (EOD sort/attr only), `di.tplogmgr` (via di.subscriptions).

`di.dbwrite` expects a **monadic** logger; di.proc.wdb bridges the injected **dyadic** di.util.log dep
with a `` `wdb ``-context adapter (same as di.proc.rdb). No kx.log install is required.

## Config

```toml
tickerplanttypes = "tickerplant"   # proctype(s) to subscribe to
hdbtypes = "hdb"                   # proctype(s) to move partitions to / reload at EOD
rdbtypes = "rdb"                   # proctype(s) to reload[date] at EOD (drop their prior day)
gatewaytypes = "gateway"           # proctype(s) to block/unblock during reload (none in POC)
savedir = "wdb"                   # wdb working-data root (relative to TORQXDATAHOME, or absolute)
hdbdir = "hdb"                    # HDB root to move sorted partitions into (relative to TORQXDATAHOME)
numrows = 100000                  # global row threshold for an intraday flush
settimer = 10                     # seconds between flush checks (di.timer mode 1h = seconds)
immediate = false                 # true: flush every table on every timer tick (ignore numrows)
replaylog = true                  # replay the tp log on startup
tpwaittimeout = 30000             # ms to block waiting for the tickerplant
reloadorder = "hdb rdb"           # order to reload at EOD (hdb first, then rdb)
# subscribeto / subscribesyms omitted -> all tables, all syms
# ignorelist omitted -> `heartbeat`logmsg (not written)
# numtab (optional) -> per-table row thresholds; overrides numrows for those tables
# sortcsv (optional) -> di.dbwrite sort/attribute config; else dbwrite's default (time asc)
```

The schema comes from the **tickerplant** (via `subdetails`), not a local `database.q` —
di.subscriptions defines the tables at root from what the TP returns.

## Behaviour

- **Startup**: connect (TP/HDB/RDB) via di.torq.servers; clear any stale working-partition data;
  install a **flushing replay `upd`** at root; block until a TP is up; subscribe + replay. The
  replay runs through that flushing `upd`, so it writes to disk past `numrows` and never holds a
  whole day in RAM. After replay the root `upd` is swapped to a plain accumulate.
- **Intraday** (`savetodisk`, timer job every `settimer`s): flush any table over its threshold
  (or every table, if `immediate`) to the working partition — **create on first write, append
  after**, enumerating syms against the **HDB** sym file, then clear it in memory.
- **End of day** (`endofday[date]`, published at root, also `.u.end`): the tickerplant
  broadcasts `(`endofday;date)` at roll (the same trigger as di.proc.rdb). di.proc.wdb flushes what
  remains, sorts each working partition (`di.dbwrite.sort` — driven by `sortcsv` or the time-asc
  default), **moves** each table dir into `hdbdir/date/` (skipping any that already exist, to
  never corrupt the hdb), then reloads downstream in `reloadorder`.

## RDB / WDB interaction

When a wdb is present the rdb must run **`reloadenabled = true`** (see di.proc.rdb). At EOD:

1. the tp broadcasts `(`endofday;date)` to **both**. The rdb snapshots its row counts and
   escapes (keeping the prior day live+queryable); the wdb owns the writedown.
2. the wdb flushes → sorts → moves the partition into the hdb.
3. the wdb reloads in order: `.hdb.reload[]` on each hdb (it re-reads the new partition), then
   `(`reload;date)` on each rdb (it `dropfirstnrows` — drops exactly the prior day it held,
   keeping the new day's ticks).

This split is also **why only one process writes `hdb/sym`**: with `reloadenabled=1b` the rdb
does not enumerate/save, so the wdb is the sole writer — no concurrent-`.Q.en` race.

## Why a separate working dir + move (not write-straight-to-hdb)

The `savedir` (default `wdb`, under `TORQXDATAHOME`) is the wdb's **permanent working
directory** — data passes through it transiently on its way to the hdb, but the directory
itself is used every day and is **not** a manually-created scratch dir to be cleaned up. (It is
deliberately named `wdb`, not `wdbtemp`, so it isn't mistaken for disposable.)

The hdb partition only ever appears **complete and sorted**, after the move — a mid-day crash
can't leave partial/unsorted data in the hdb, and (later) an idb can read the working partition
intraday. Enumeration is against the **hdb** sym file, so the moved partition's enum indices
already match `hdb/sym`. This is also why `di.dbwrite.savedown`/`appenddown` (which assume the
enumerate dir == the write dir) don't fit the write path — the create-or-append write is
wdb-local; di.dbwrite is reused only for the EOD `sort`/`applyattr`. (A future di.dbwrite could
grow an optional enum-dir param and absorb this.)

## Not included (future / other-process / deprecated)

- **Sort / sortworker as separate processes** (`mode` = `save`/`sort`, `.z.pd` worker fan-out).
  v1 is `saveandsort` in-process only.
- **Advanced writedown modes** (`partbyattr`/`partbyenum`/`partbyfirstchar`) and all of
  `merge.q`. v1 is `default` writedown only.
- **IDB tier** (`notifyidbs`/`idbreload`/`filldb`/`initmissingtables`).
- **Compression** (`.z.zd`).
- **Cross-date replay** (`fixpartition` — moving already-written temp data when the tp log date
  differs from today). v1 assumes same-day start; it logs a warning and uses the log date, but
  does not relocate data already written under the wrong partition.
- **Gateway** block/unblock is a no-op until a gateway is connected (di.proc.gateway not built).
- **FinSpace/AWS** and the `endofperiod` STP stub — stripped.

## Module-namespace notes

Root tables are **read** with bare `value t` (bare reads fall through to root) but **written**
and **cleared** via `@[`.;..]` — a bare write from a `use`-loaded module (or under `-11!`
replay) lands in the module's private namespace. The replay `upd` is therefore root-safe.

## Testing

`test.csv` (k4unit) covers the dependency contract (init errors without `log`/`timer`) and the
export surface. The full subscribe → replay-to-disk → intraday-append → EOD sort+move → hdb
reload + rdb `dropfirstnrows` flow is proven in the **TorqX-POC end-to-end** (`torqx.sh start
tickerplant1 hdb feed1 rdb1 wdb1`, with `rdb1` in `reloadenabled` mode).

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.proc.wdb
```
