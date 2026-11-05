# di.torq.proc.idb

The intraday database process type, ported from TorQ's `code/processes/idb.q`. It mounts the
**wdb's working directory** and the **hdb's sym file**, so today's data can be queried before the
wdb's end of day moves it into the hdb. Started by `di.torq` through the same
`init[config;deps]` convention as every other built-in proctype.

## How it works

At `init` the idb asks the wdb where it is writing (`setparametersfromwdb`), then force-loads the
sym file and the db (`loaddb`). After that it only reacts to the wdb:

| Call | From | Does |
|---|---|---|
| `.idb.intradayreload[]` | the wdb, after a flush that wrote something | reloads the sym file if it grew, remounts if the partition count changed, clears the `.Q.pn` row-count cache |
| `.idb.rollover[pt]` | the wdb or sort process, at end of day | sets the current partition, moves the mount for it, force-loads the db |

### What gets mounted

As legacy, the mount depends on the wdb's writedown mode:

| `writedownmode` | `idbdir` | Mounted as |
|---|---|---|
| `default` | `savedir` | a date-partitioned db, with a virtual `date` column |
| `partbyenum`, `partbyfirstchar` | `savedir/<currentpartition>` | an int-partitioned db, one partition per enumerated value / first character |

`partbyattr` gets the `savedir/<currentpartition>` mount too, but as in legacy the wdb never sends
it a reload, so it is not served intraday.

For querying the int-partitioned modes, `maptoint` and `mapfctoint` are published at root, as in
legacy: they map a sym (or int) value, or a sym's first character, to its int partition.

### Reloads

`intradayreload` only remounts when `partitioncounthaschanged[]`. Rows appended to a partition
that is already mounted are seen by a `select` without a remount; only `count` is cached, in
`.Q.pn`, which `clearrowcountcache[]` resets. In `default` mode a single partition never needs a
remount at all.

### The sym file

The wdb enumerates against the hdb's `sym`, so the idb loads that file into root `sym`
(`loadsym`). It is reloaded only when its size changes (`symfilehaschanged[]`), since `.Q.en` only
ever appends.

Two differences from legacy:
- **The size is recorded only after a successful load.** Legacy records it as soon as it sees a
  change, so a load that then fails is never retried.
- **`hcount` is trapped.** The sym file does not exist until the wdb's first `.Q.en`, so the idb
  can start before it.

A missing `savedir` at startup is logged as an error by `loadidb`, as legacy, and does not stop
`init`; the next reload after the wdb has written picks it up.

## The wdb handshake

`setparametersfromwdb` connects to a `wdbtypes` process, waits for it, and reads:

```q
(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition`.wdb.writedownmode)
```

The idb takes `savedir` and `hdbdir` from the wdb, never from its own config. Failing to reach a
wdb within `connecttimeoutms` fails `init`.

## Dependencies

- **Injected** (from di.torq): `log`, `servers`.
- **`use`-imported**: none.

## Config

| key | meaning |
|---|---|
| `wdbtypes` | proctype to ask for its directories and writedown mode. Default `` `wdb ``. |
| `connecttimeoutms` | how long to wait for a wdb before failing init. Default 30000. |

## Not ported

- **Registering with the wdb** (`` .servers.registerfromdiscovery ``). The wdb finds the idb
  through `process.csv` and `idbtypes`, like any other peer.
- **`.proc.getattributes`**, for gateway routing. `di.torq.proc.gateway` has no attribute
  reporting for any backend yet.
- **A root `reload`.** The sort process calls `.idb.intradayreload[]` by name.

## Testing

`test.csv`/`test.q` (k4unit) cover the dependency checks, the wdb handshake (including a wdb that
does not publish each variable), the default and `partbyenum` mounts, rollover moving the mount,
reloads remounting only when the partition count changes, the sym-file change detection and
retry, and a missing `savedir`. Every `idb[...]` call is bracket-indexed, not `idb.xxx`. Run in a
fresh q session, as the suite calls `setenv`:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.proc.idb
```
