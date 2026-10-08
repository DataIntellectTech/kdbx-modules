# di.torq.proc.wdb

The write database. Subscribes to a tickerplant, replays the day's log to disk, then during
the day incrementally writes each in-memory table to a **temp** partition as it fills, and at
end of day flushes what remains, sorts each table on disk, **moves** the partition into the
HDB, and triggers a reload of the HDB(s) and RDB(s).

Ported from `TorQ/code/processes/wdb.q` (+ `code/wdb/writedown.q`), including all four writedown
modes and the end-of-day merge.

As in legacy, the same module also runs proctypes **`sort`** and **`sortworker`**, in `mode = sort`:
a `save`-mode wdb hands its end of day to a sort process, which can spread the per-table sort or
merge over sortworkers. See "Modes" and "Sortworkers" below.

## Dependencies

- **Injected** (from di.torq): `log`, `timer`, `servers`.
- **Hard** (`use`-imported): `di.subscriptions` (subscribe + replay), `di.dbwrite` (the sort and
  attributes), `di.merge` (partition-size tracking and the EOD merge), `di.os` (moving and deleting
  directories; not in `deps.toml`, as it has no VERSION for depcheck), `di.tplogmgr` (via
  di.subscriptions).

`di.dbwrite` takes the injected **binary** `di.util.log` dep directly — same contract, no adapter
(the `` `wdb ``-context bridge was removed when dbwrite was re-synced from `main`, same as
di.torq.proc.rdb). No kx.log install is required.

## Config

```toml
mode = "saveandsort"               # saveandsort | save | sort (see Modes)
writedownmode = "default"          # default | partbyattr | partbyenum | partbyfirstchar
mergemode = "part"                 # part | col | hybrid (partitioned writedown modes only)
mergebybytelimit = false           # true: merge limits are byte estimates (mergenumbytes), not rows
mergenumrows = 100000              # default rows per merge batch; mergenumtab overrides per table
mergenumbytes = 500000000          # bytes per merge batch when mergebybytelimit is true
tickerplanttypes = "tickerplant"   # proctype(s) to subscribe to
sorttypes = "sort"                 # proctype(s) to hand the tail to in save mode
sortworkertypes = "sortworker"     # proctype(s) to fan the sort out to (needs a negative -s)
workers = 2                        # sets -s -2 at startup so the sort uses the sortworkers (default 0: unchanged)
wdbtypes = "wdb"                   # proctype(s) a sort process asks to initialise the next partition
hdbtypes = "hdb"                   # proctype(s) to move partitions to / reload at EOD
rdbtypes = "rdb"                   # proctype(s) to reload[date] at EOD (drop their prior day)
idbtypes = "idb"                   # proctype(s) notified: after every flush that wrote something, and (if
                                    # opted into reloadorder) at EOD too (remount the new day's partition)
gatewaytypes = "gateway"           # proctype(s) to block/unblock during reload (none in POC)
savedir = "wdb"                   # wdb working-data root (relative to TORQXDATAHOME, or absolute)
hdbdir = "hdb"                    # HDB root to move sorted partitions into (relative to TORQXDATAHOME)
numrows = 100000                  # global row threshold for an intraday flush
replaynumrows = 100000            # row threshold during log replay (default numrows); replaynumtab per table
partitiontype = "date"            # date | month | year
gc = true                         # .Q.gc[] after each save and after sorting
settimer = 10                     # seconds between flush checks (di.timer mode 1h = seconds)
immediate = false                 # true: flush every table on every timer tick (ignore numrows)
replaylog = true                  # replay the tp log on startup
tpwaittimeout = 30000             # ms to wait for the tickerplant at startup before init fails
reloadorder = "hdb rdb idb"       # order to reload at EOD
eodwaittime = 10                  # seconds to wait for reload callbacks before releasing (0: sync reloads)
permitreload = true               # false: sort and move, but leave downstream alone
# compression (optional) -> e.g. 17 2 6, applied (.z.zd) while sorting/merging, then reset to 16 0 0
# savedownmanipulation (optional, .q settings) -> table!function applied before each write
# getpartition (optional, .q settings) -> niladic function returning the partition value
# upd (optional, .q settings) -> {[t;x]} the live upd, and the one the replay calls; default insert
# postreplay (optional, .q settings) -> {[hdbdir;pt]} called after the move, before the reload
# subscribeto / subscribesyms omitted -> all tables, all syms
# ignorelist omitted -> `heartbeat`logmsg (not written)
# numtab (optional) -> per-table row thresholds; overrides numrows for those tables
# sortcsv (optional) -> di.dbwrite sort/attribute config; else $TORQXAPPCONFIG/sort.csv if present, else time asc
```

The schema comes from the **tickerplant** (via `subdetails`), not a local `database.q` —
di.subscriptions defines the tables at root from what the TP returns.

## Behaviour

- **Startup**: connect (TP/HDB/RDB) via di.torq.servers; clear any stale working-partition data;
  install a **flushing replay `upd`** at root; block until a TP is up; subscribe + replay. The
  replay runs through that flushing `upd`, so it writes to disk past `numrows` and never holds a
  whole day in RAM. After replay the root `upd` is swapped to `insert`, or the configured `upd`.
- **Intraday** (`savetodisk`, timer job every `settimer`s): flush any table over its threshold
  (or every table, if `immediate`) to the working partition — **create on first write, append
  after**, enumerating syms against the **HDB** sym file, then clear it in memory. If that
  flushed at least one table, the partition is filled (`filldb`) and every connected `idbtypes` process is notified
  (`` .idb.intradayreload[] ``, async) — an all-skipped tick (nothing over threshold) stays silent. This is
  unconditional on `reloadorder`; it only needs an idb to be connected.
- **End of day** (`endofday[date]`, published at root): the tickerplant
  broadcasts `(`endofday;date)` at roll (the same trigger as di.torq.proc.rdb). di.torq.proc.wdb flushes what
  remains, then runs `endofdaysort` — `saveandsort` in-process, `save` by an async
  `.wdb.endofdaysort[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]` to each
  connected sort process. With no sort process connected, `save`
  logs an error and runs the tail here anyway rather than stranding the day's data in the working
  directory. The tail's `idbreload` then initialises the next partition and sends
  `` .idb.rollover[date+1] `` to every idb. The intraday `.idb.intradayreload` leg stays in the wdb
  (`notifyidbs`), and after each flush that wrote something the partition is filled with `.Q.chk`
  (`filldb`) first.

## What the wdb publishes for the idb

`init` publishes four root variables the idb reads at startup, the way legacy TorQ's
`setparametersfromwdb` reads `.wdb.savedir` and friends:

```q
set[`.wdb.savedir;.z.m.savedir];
set[`.wdb.hdbdir;.z.m.hdbdir];
set[`.wdb.currentpartition;.z.m.currentpartition];
set[`.wdb.writedownmode;.z.m.writedownmode];
```

They are read with `` (each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition`.wdb.writedownmode) ``,
so the idb is not configured with the two directories by hand — one source of truth, no pair to keep in step.
The writedown mode decides whether the idb mounts `savedir` or `savedir/<currentpartition>`.
`endofday` republishes `currentpartition` after it advances; the other three are fixed for the life
of the process.

## End of period

A segmented tickerplant broadcasts end of period to its subscribers, and the callback has to exist
at root or the publish fails on this side. The wdb has nothing to do on a period roll — its
partition only advances at end of day — so it relies on the default `endofperiod` that
di.subscriptions installs. See di.subscriptions for the contract.

## RDB / WDB interaction

When a wdb is present the rdb must run **`reloadenabled = true`** (see di.torq.proc.rdb). At EOD:

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

## Modes

| `mode` | behaviour |
| --- | --- |
| `saveandsort` (default) | subscribe, save, and run the EOD sort in this process |
| `save` | subscribe and save; hand the EOD sort to a `sorttypes` process over IPC |
| `sort` | no tickerplant: wait for `.wdb.endofdaysort` from a `save`-mode wdb |

Proctypes `sort` and `sortworker` run this module with framework settings
`di/torq/settings/sort.q` and `sortworker.q`, which set `mode:`sort`. That is legacy's
arrangement, where both loaded `wdb.q` with `-parentproctype wdb`. A sort process connects to the
hdb, rdb, idb, gateway, sortworker and wdb types. `endofdaysort`'s `dir`, `tablist` and
`hdbsettings` can be null, meaning this process's own `savedir`, the tables in the working
partition, and its own `hdbdir`/`compression`.

If a `save`-mode wdb finds no sort process connected it logs an error and sorts the day itself,
as legacy does.

## Sortworkers

`settings/sortworker.q` empties every connection type, so a sortworker dials nothing and waits.
`init` defines `.z.pd` to return the connected `sortworkertypes` handles, and the per-table sort
or merge goes to the workers when some are connected **and** the process has a negative `-s`,
from the command line or the `workers` setting. Each worker is first sent the sym file to reload
and, for the `part` and `hybrid` merges, the partition sizes. The work is legacy's `peach`
lambdas, calling root names every mode publishes: `.sort.sorttab`, `.wdb.merge`,
`.wdb.setcompression`, `.wdb.reloadsymfile` and `.wdb.gc`. A worker sorts to its own `sortcsv`,
which defaults to the app's `sort.csv`.

An error on a worker propagates out of the `peach` and stops the sort before the move, leaving the
working copy in place. As legacy, a new hdb partition is moved in with one rename; if the hdb
partition already exists and any table is in both, the whole move is aborted and logged, so nothing
is overwritten.

## Writedown modes

| `writedownmode` | intraday layout | end of day |
| --- | --- | --- |
| `default` | `<savedir>/<pt>/<table>/` | sort each table, move into the hdb |
| `partbyattr` | `<savedir>/<pt>/<table>/<parted value(s)>/` | merge the segments into the hdb |
| `partbyenum` | `<savedir>/<pt>/<enumerated value>/<table>/` | merge the segments into the hdb |
| `partbyfirstchar` | `<savedir>/<pt>/<first character>/<table>/` | sort each segment, then merge |

The parted column comes from the `p` attribute in `sortcsv`; init reports an error if the
partitioned modes find no `default` row with one. Each segment's size is tracked in `di.merge` so
the merge can batch by `mergenumrows` / `mergenumbytes`. In `save` mode the sizes are sent to the
sort process with `.merge.syncpartsizes` before the hand-off.

## Startup

- The working partition is cleared, the log replayed with the `replaynumrows` threshold, and, if
  the tickerplant log date differs from the current partition, the replayed data is moved to the
  log's date (`fixpartition`).
- In `default` and `partbyenum` modes empty table schemas are written into the working partition
  (`initmissingtables`), so an idb can mount it. `.wdb.initmissingtables` is published at root for a
  sort process to call at end of day.

## Not included (deprecated)

- **FinSpace/AWS** — stripped.

## Module-namespace notes

Root tables are **read** with bare `value t` (bare reads fall through to root) but **written**
and **cleared** via `@[`.;..]` — a bare write from a `use`-loaded module (or under `-11!`
replay) lands in the module's private namespace. The replay `upd` is therefore root-safe.

## Testing

`test.csv` + `test.q` (k4unit) cover the dependency contract, the export surface and `mode`
validation. They also run the wdb end to end against a spawned process standing in for the
tickerplant: every writedown mode with every merge method, segment tracking, `initmissingtables`,
`tabsizes`, `savedownmanipulation`, `postreplay`, compression, `fixpartition`, the tickerplant retry
cycles, the `p`-attribute check, replay thresholds, merging on real sortworkers, `save` mode handing
off to a real sort process, and the `eodwaittime` reload handshake against a spawned hdb.
`testsort.q` covers sort mode against an unsorted working partition on disk: the sort and move,
table discovery, the `savedir` fallback, the no-overwrite rule, `permitreload` and `reloadorder`,
string settings, the `sortcsv` default, the sort process's connections, and fanning out to real
sortworker processes.

The full subscribe → replay-to-disk → intraday-append → EOD sort+move → hdb
reload + rdb `dropfirstnrows` flow is proven in the **TorqX-POC end-to-end** (`torqx.sh start
tickerplant1 hdb feed1 rdb1 wdb1`, with `rdb1` in `reloadenabled` mode).

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.proc.wdb
```
