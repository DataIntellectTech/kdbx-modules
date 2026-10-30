# di.torq.proc.compression

A one-shot process type that compresses an existing hdb. It walks the partitions up to a maximum
age and rewrites every column named in a compression config csv, using the algorithm, block size
and level that csv gives it.

Ported from TorQ's `code/processes/compression.q` and `config/settings/compression.q`.

The compression itself is **not** here — it lives in `di.compression`, which was ported
separately. This module is the process wrapper: config resolution, validation, and the one-shot
run/exit lifecycle.

## Dependencies

| | |
|---|---|
`log` | injected by di.torq, required |
`di.compression` | the compression engine, `use`d directly |

## Config

Defaults ship in `di/torq/settings/compression.q`; an app overrides them per proctype or
procname, or on the command line.

| setting | default | meaning |
|---|---|---|
`csvpath` | `:appconfig/compressionconfig.csv` | the compression config csv. Resolved under `TORQXAPPHOME` — it is config, not data |
`hdbpath` | `:hdb` | hdb root to compress. Resolved under `TORQXDATAHOME`, falling back to `TORQXAPPHOME` |
`maxage` | `365` | only scan partitions this many days old or newer |
`exitonfinish` | `1b` | exit the process when the pass completes |

### Migrating from TorQ

| TorQ | here |
|---|---|
`.cmp.inputcsv` | `csvpath` — renamed to match `di.compression`'s own `compressmaxage[hdbpath;csvpath;maxage]` parameter |
`.cmp.hdbpath` | `hdbpath` |
`.cmp.maxage` | `maxage` |
`.cmp.exitonfinish` | `exitonfinish` |

TorQ's settings file also switched off `.usage`, `.clients`, `.servers` and `.hb`. Here those are
ordinary settings sections, so an app turns them off in its own `compression.toml` if it wants
them off — the framework tier does not force it.

## The compression csv

Unchanged from TorQ, and read by `di.compression`, not by this module:

```
table,minage,column,calgo,cblocksize,clevel
trade,0,price,2,17,5
```

`calgo` is kdb's algorithm number (0 none, 1 ipc, 2 gzip, 3 snappy on 3.4+), `cblocksize` the
power-of-two block size 12–19, `clevel` 0–9.

## Behaviour

The pass runs from di.torq's post-init hook as `.compression.run[]`, **not** from `init`.

- `init` must not exit — `torqx.sh` owns the process lifecycle, and exiting from inside `init`
  would fight it. This is the same reasoning `di.torq.proc.housekeeping` gives for declining to
  port legacy's one-shot mode.
- keeping the pass in its own function leaves it re-triggerable by hand or over IPC as
  `.compression.compressnow[]`, without killing the session.

Both names are published at real root names, because `use`-loading this module compiles it into a
private namespace where neither the runhook nor an IPC caller could reach them.

### `process.csv`

A batch job with no listening port:

```
host,port,proctype,procname,startwithall
localhost,0,compression,compression1,1
```

### A bad hdb path is fatal

`init` refuses a `hdbpath` that does not exist. Without that check the partition traverse simply
returns nothing and the run reports success having compressed zero columns — which reads exactly
like a correctly-configured no-op.

## Known divergence: an invalid csv does not abort the run

`di.compression.loadcsv` traps its own `checkcsv` and returns, logging an error:

```q
res:.[checkcsv;(loadedcsv;string inputcsv);{.z.m.logerr[...];:0b}];
if[res~0b;:(::)];
```

TorQ's `loadcsv` calls `checkcsv[compressioncsv]` **untrapped**, so an invalid algorithm, block
size or level throws and aborts the run.

So a misconfigured csv here is logged and skipped, and the pass continues with whatever config
was previously loaded — or none. The process still exits 0. This divergence predates this module
(it came in with `di.compression` itself) and is **not** changed here; it is recorded so that an
operator reading a successful compression log knows to check for an error line above it. The test
suite asserts the current behaviour rather than TorQ's, so changing it will fail a test
deliberately.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.compression
```

The suite builds a real two-partition hdb under `/tmp`, compresses it, and asserts with `-21!`
that the configured column is compressed in both partitions while an unconfigured one is not.
It uses 200,000 rows per partition on purpose: kdb will not compress a file smaller than its
block size, so a token few rows would leave the test asserting on a no-op indistinguishable from
a failure.

`run[]` is deliberately never called by the tests — with the default `exitonfinish` it would
terminate the test process.
