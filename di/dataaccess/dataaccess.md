# di.dataaccess

The **query-normalisation / `getdata` layer** over the gateway. It solves the classic
kdb+tick problem that the **RDB has no `date` column** (it's in-memory; `date` is only a
*virtual* partition column on the HDB), so a query like `select … by date from trade` works on
the HDB but breaks on the RDB. `getdata` takes a **structured, time-ranged** request, routes it
across the time-partitioned backends, **builds a valid per-backend query** (normalising `date`),
scatters the shards, and **map-reduces** the results back to the client.

Modelled on kdbx-modules `feature-dataaccess` (early WIP) but rebuilt — see the header of
`dataaccess.q` for the three substantive differences (functional-qSQL building vs string
rewriting; `execqueryto` local dispatch vs the branch's broken `.z.w` reply path; real
map-reduce vs a bare `raze`).

## Dependencies

- **Hard** (`use`): `di.asyncdispatch` (dispatch), `di.serverselect` (which servertypes are
  live). Both are **shared** with di.proc.gateway (idempotent `use`), so getdata dispatches through
  the gateway's already-registered servers and callbacks.
- **Injected** (`init` deps dict): `log`, `timer` (required) + optional `partitions`,
  `timecolumn` (default `` `time ``), `partitioncolumn` (default `` `date ``), `cp`,
  `requestkeeptime`, `resultcallback`.

## `getdata[tablename; starttime; endtime; by; aggs]`

- `tablename` — symbol.
- `starttime`/`endtime` — timestamps; the request's time range.
- `by` — grouping columns (symbol list; `` ` `` / `()` for none). `` `date `` is **normalised
  per backend**: the HDB uses its native `date` column; the RDB derives `` `date$<timecolumn> ``.
- `aggs` — a `(outcol; aggfn; incol)` triple or list of them, e.g.
  `` ((`cnt;`count;`i);(`vol;`sum;`size)) ``; `` ` ``/`()` for a plain row select. `aggfn` ∈
  `` `count`sum`min`max`avg`wavg`vwap ``. For `wavg`/`vwap` the `incol` is a
  `(weight; value)` **pair**, e.g. `` (`vw;`vwap;`size`price) `` (= `size wavg price`).

Deferred-sync from a client: `neg[gw](`.gw.getdata; `trade; st; et; `date`sym; (`cnt;`count;`i)); gw[]`.

### How it normalises + map-reduces
1. **Route** (`getrouting`): clip `[starttime;endtime]` against the `partitions` coverage table
   (one shard per reachable servertype, non-overlapping ranges).
2. **Build** (`buildshardquery`): a **functional** select `?[t;wc;b;a]` per shard — a `within`
   time filter (plus a partition-column filter on the HDB so kdb prunes partitions), the
   date-normalised `by`, and the **shard-level** aggregation (e.g. `count`).
3. **Scatter**: one `di.asyncdispatch.execqueryto[0Ni;…]` per shard (local mode → replies come
   back to the root-published `.dataaccess.shardresult`, not the end client).
4. **Reduce** (`checkresults`): once all shards are in, unkey + `raze` them and re-group on the
   by-keys applying each agg's **reduce** fn — so grouped aggregates recombine correctly instead of
   double-counting. Aggregates that can't be recombined from their own shard value are split into
   **components** (`aggspecs`): `avg` → per-shard `sum` + non-null `count`, recombined as
   `(sum sums)%(sum counts)`; `wavg`/`vwap` → per-shard `sum(w*c)` + `sum(w)`, recombined as
   `(sum nums)%(sum dens)`. `count`/`sum`/`min`/`max` are single-component (`sum`/`sum`/`min`/`max`).

## Partition coverage

```q
partitions:([] servertype:`rdb`hdb; coverfrom:(`timestamp$.z.d; -0Wp); coverto:(0Wp; -1+`timestamp$.z.d))
```
`coverfrom`/`coverto` are timestamps (`-0Wp`/`0Wp` for open ends); **keep them non-overlapping**
or a slice is double-counted. di.proc.gateway builds this from `.z.d` at init (rdb = today onward,
hdb = before today) and **refreshes it at rollover** by calling `setpartitions[parts]` from its EOD
`reloadend` handler — after the wdb has moved the just-ended day's partition into the hdb, `.z.d`
has advanced, so the rolled day now correctly routes to the hdb instead of the rdb (which dropped it).

## `setpartitions[parts]`

Swap the routing coverage table at runtime (same-shape table as above; columns validated). Published
as a module export; di.proc.gateway calls it at EOD `reloadend`. Call it yourself if your stack rolls
partitions on a schedule the gateway doesn't drive.

## Scope / deferred

- **In**: `count`/`sum`/`min`/`max`/`avg`/`wavg`/`vwap` (all map-reduce correctly across shards);
  `` `date `` + plain by-columns; a single time-range filter; rollover refresh of `partitions`
  (`setpartitions`, driven by the gateway at EOD).
- **Deferred**: arbitrary `where` filters and column projections; ordering / `sublist`; typed input
  validation (TorQ's `checkinputs`); attribute-based routing.

`avg` uses a non-null count denominator to match q's null-ignoring `avg`; `wavg`/`vwap` follow the
`sum(w*c)%sum(w)` definition (nulls drop consistently across numerator and denominator).

## Testing

`test.csv` (k4unit) covers the dependency contract + export surface + that init publishes its
local-postback entry points. The functional query-building, date normalisation and map-reduce
recombine are validated directly, and the full **client → getdata → per-backend normalised
shards → map-reduce** flow across a live rdb+hdb is proven in the TorqX-POC end-to-end.

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.dataaccess
```
