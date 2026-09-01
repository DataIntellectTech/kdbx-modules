# di.pqx

Converts an in-memory kdb+ table into one or more `.parquet` files via `kx.arrow`. Rows are grouped
by instrument and packed into files close to a configurable target size, splitting any single
oversized instrument across multiple files where required. A manifest recording what was written
(file, instruments, row count, time range, on-disk size) is accumulated in the module's private
`manifest` table; `extract` also returns this same information for the files it just wrote.

---

## Features

- Splits a table into one or more `.parquet` files targeting a configurable file size
- Groups rows by instrument so a single instrument's data is not split across files unless it alone exceeds the target size
- Optionally splits any oversized single instrument across multiple files
- Optionally calibrates the raw-to-parquet size ratio with a trial write, or uses a fixed ratio
- Optionally pre-sorts input data by instrument/time before writing
- Optionally partitions output into Hive-style `<col>=<value>/` subdirectories via `virtualcols`, one file per combination, ahead of the size-based bucketing above - the partitioned columns are dropped from the on-disk data and can be reconstructed from the path with `readfile`
- Writes files sequentially or in parallel (`peach`)
- Accumulates a manifest of every file written, including row counts, instrument lists, time bounds and on-disk size
- Builds a queryable virtual table over a directory of previously-written `.parquet` files, without reading any of their data up front - `date`/`virtualcols` values are reconstructed straight from each file's path

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

**Hard dependencies:** `kx.arrow` and `kx.pq` — both loaded automatically (via `use`) when `di.pqx`
is imported, before `pqx.q` itself is loaded. `extract`/`readfile` call
`` .m.di.0pqx.arrow.pq.writeParquetFromTable ``/`` .m.di.0pqx.arrow.pq.readParquetToTable `` to
perform every write/read; `buildvirtualtable` calls `` .m.di.0pqx.pq.pq `` (per-file virtual table)
and `` .m.di.0pqx.pqt.mkP `` (from `` kx.pq.t ``, loaded separately as `pqt`) to compose the
multi-file view.

Both modules must be resolvable on the process's module search path at that point. Where either is
installed as a conda package (e.g. under a `kx.qmamba`-managed root such as
`~/.kx/root/lib/q/mod`), that location needs to already be on `QPATH` — `di.pqx` does not load
`kx.qmamba` itself to arrange this. Confirm `kx.arrow`, `kx.pq`, and `kx.pq.t` each load standalone
(`` use`kx.arrow ``, `` use`kx.pq ``, `` use`kx.pq.t ``) in the target environment before relying on
`di.pqx` there. `kx.arrow`'s bundled `libcurl` may also need a newer OpenSSL than the system default
on the `LD_LIBRARY_PATH` — if `use\`kx.arrow` fails with an `OPENSSL_*` symbol-version error, point
`LD_LIBRARY_PATH` at the `lib` directory the conda-installed `kx.arrow`/`kx.pq` packages ship
alongside it.

The `log` dependency must be passed to `init` inside a dict keyed on `` `log ``. `init` throws
immediately if `log` is absent, is not a dict, or is missing any of `info`/`warn`/`error`. The value
must already conform to the binary `{[c;m]}` contract — `init` performs no adaptation, so a raw
monadic `kx.log` instance must be wrapped by the caller first. Build the dict from `di.log`, or
hand-roll one.

```q
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)
pqx:use`di.pqx
pqx.init[enlist[`log]!enlist logdep]

/ or, skipping the by-hand dict:
/   pqx.init[logger.logdict]
```

---

## Options

Passed as the `o` dictionary to `extract`, merged over the module's own `default` dict. Any keys
omitted from `o` fall back to the default shown below.

| Key | Default | Type | Description |
|---|---|---|---|
| `targetsize` | `512*1024*1024` | long | Target size in bytes for each output file |
| `maxfactor` | `1.5` | float | Hard cap on file size, expressed as a multiple of `targetsize` |
| `splitoversized` | `1b` | boolean | Split any single instrument larger than the cap across multiple files |
| `calibrate` | `1b` | boolean | Run a trial write to measure the raw-to-parquet size ratio instead of using `compressionratio` |
| `onesymperfile` | `0b` | boolean | Write exactly one file per instrument, ignoring the target-size bucketing/packing logic. Forces `splitoversized` off (see below) |
| `compressionratio` | `0.30` | float | Raw-to-parquet size ratio used for size estimation when `calibrate` is `0b` |
| `symcol` | `` `sym `` | symbol | Instrument column |
| `timecol` | `` `time `` | symbol | Time column |
| `presort` | `1b` | boolean | Sort input by `` (symcol;timecol) `` before writing |
| `rowgroupbytes` | `128*1024*1024` | long | Reserved for future use — not currently read by the write path |
| `codec` | `` `zstd `` | symbol | Compression codec, upper-cased and applied to the writer's `` `COMPRESSION `` option |
| `complevel` | `3` | long | Reserved for future use — not currently read by the write path |
| `virtualcols` | `` `symbol$() `` | symbol list | Virtual, path-only partition columns. When non-empty, takes precedence over `onesymperfile`/`splitoversized`: one file is written per distinct combination of these columns' values, forcing both of those off for the call |
| `parallel` | `0b` | boolean | Write files with `peach` instead of `each` |
| `outdir` | `` `:. `` | symbol | Root output directory |
| `filestub` | `"part"` | string | File name stub; files are written as `<filestub>-NNNNN.parquet` |

Output files are written to `<outdir>/<tname>/date=<dt>/<filestub>-NNNNN.parquet`. `extract` throws
(`` `di.pqx: input keys not recognised - ... ``) if `o` contains any key not present in the module's
`default` dict — this is the very first check `extract` performs, before the empty-table check. It
also throws (`` `di.pqx: no symcol found in table `` / `` `di.pqx: no timecol found in table ``) if
the merged `symcol`/`timecol` is not a column of the input table — this check runs unconditionally,
regardless of `presort`. It also throws (`` `di.pqx: cannot extract from empty table ``) if `t` has
zero rows, regardless of `calibrate` — this check runs before the column checks but after the input
key check.

When `onesymperfile` is `1b`, each instrument is written to its own file regardless of `targetsize`
bucketing, and `splitoversized` is forced to `0b` for that call (an oversized single instrument is
still written to one file, not split, even if `splitoversized:1b` is also passed in `o`).

When `virtualcols` is non-empty, it takes precedence over both `onesymperfile` and `splitoversized`
(both are forced to `0b` for that call, regardless of what was passed in `o`), and `targetsize`/
`maxfactor` bucketing does not apply: every distinct combination of the `virtualcols` columns' values
becomes exactly one output file, however large. `extract` throws (`` `di.pqx: not all virtualcols
found in table ``) if any `virtualcols` column is not present in the input table. Output paths gain one
`<col>=<value>/` segment per `virtualcols` column, Hive-style, e.g.
`<outdir>/<tname>/date=<dt>/exchange=NASDAQ/<filestub>-NNNNN.parquet` — the file's combination is also
recorded directly in the manifest's `virtualcols` column (see Manifest Schema below). The `virtualcols`
columns themselves are dropped from the on-disk data before writing (their value is already fixed by the
path, so keeping them in every row would just be redundant storage) — use `readfile` (see below) to
read a file back with its `virtualcols` values (and the `date` partition) reattached as columns.

---

## Manifest Schema

The module's `manifest` table accumulates one row per file written across all `extract` calls; call
`getmanifest[]` to read the full accumulated table. `extract` itself returns a table of the same
shape, scoped to only the file(s) written by that call.

| Column | Type | Description |
|---|---|---|
| `file` | symbol | Path written |
| `seq` | long | Sequence number within the partition |
| `virtualcols` | symbol list | The `virtualcols` option value in effect for this call - the list of columns partitioned into this file's path, not the combination's values themselves (see Options) |
| `syms` | symbol list | Instruments contained in the file |
| `nsyms` | long | Count of instruments in the file |
| `rows` | long | Row count |
| `mintime` | timestamp | Minimum time across the file (for pruning) |
| `maxtime` | timestamp | Maximum time across the file |
| `estbytes` | long | Estimated size at plan time |
| `bytes` | long | Actual on-disk size |
| `split` | boolean | `1b` if this file is a chunk of a split oversized instrument |
| `status` | symbol | `` `ok `` or `` `error `` |

In addition to the in-memory `manifest`, each `extract` call writes this same per-call stats table
to a `manifest.json` sidecar file directly under the partition directory (i.e.
`<outdir>/<tname>/date=<dt>/manifest.json`), serialized to a single line of JSON with `.j.j` and
written with `0:`. A repeat `extract` call into the same partition overwrites the sidecar with just
that call's rows, rather than accumulating across calls — the sidecar mirrors `extract`'s return
value, not `getmanifest[]`. Writing the sidecar is best-effort: if it fails (for example a
permissions issue, or something else already occupying that path) a warning is logged but `extract`
still returns normally and still updates the in-memory `manifest`.

Read it back with `` .j.k first read0 hsym `$"<outdir>/<tname>/date=<dt>/manifest.json" ``. JSON has
no native date/timestamp/symbol type, so the round trip is not type-preserving: `file`, `syms`,
`status` and `virtualcols` come back as plain strings (cast back with `` `$ ``) and `mintime`/`maxtime`
come back as ISO-8601 strings rather than timestamps; numeric columns (`seq`, `nsyms`, `rows`,
`estbytes`, `bytes`) come back as floats rather than longs (cast back with `` "j"$ ``) and `split`
comes back as a native JSON boolean unchanged.

---

## Virtual Tables

`buildvirtualtable` opens every `.parquet` file under `<hdbdir>/<tname>/` as a single queryable
table, without reading any row data up front - it's the read-side counterpart to `extract`'s output
layout. Each file's `date=<dt>/` segment (and any `<col>=<value>/` `virtualcols` segments) is
reconstructed from its path into a virtual column, exactly mirroring what `extract`/`writefile`
stripped from the on-disk data on the way in. Filtering on those virtual columns (e.g.
`` select from vt where date=2025.07.15,exch=`NASDAQ `` ) prunes to just the matching files rather
than scanning everything.

The returned value is not a regular in-memory kdb+ table - it's a functional/composed object from
`kx.pq.t`'s `mkP`. `select` works on it directly; `exec`/`meta`/`cols` do not work applied directly
to it, only to a `select` (or `meta`) result taken from it first (e.g.
`` exec c from meta vt `` to list columns, `` exec count i from select from vt `` to count rows,
not `` count vt `` or `` cols vt ``).

Genuine on-disk columns keep whatever type they were written with - notably, character/symbol
columns come back as **strings**, not symbols, since Parquet has no native symbol type (see
`checkandconvertcols`). Only the path-reconstructed `date`/`virtualcols` columns come back typed as a
real date/symbol.

### `buildvirtualtable[hdbdir;tname;datecol;virtualcols]`
Find every `.parquet` file under `<hdbdir>/<tname>/` and compose them into one virtual table,
partitioned by the `date=<dt>/` segment and any `virtualcols` segments found in each file's path.

| Parameter | Type | Description |
|---|---|---|
| `hdbdir` | symbol (hsym) | Root directory - matches `extract`'s `outdir` |
| `tname` | symbol | Table name - matches `extract`'s `tname` |
| `datecol` | symbol | Name to give the reconstructed date partition column (need not be literally `` `date `` ) |
| `virtualcols` | symbol list | Names of any `virtualcols` path segments to reconstruct, in path order - matches `extract`'s `virtualcols`. Pass `` `symbol$() `` if the data was written without `virtualcols` |

```q
vt:pqx.buildvirtualtable[`:./;`trade;`date;enlist`exchange]
select from vt where date=2025.07.15,exchange=`NASDAQ
```

Building the table succeeds even if no files match (an empty view); querying that empty view then
fails, rather than silently returning zero rows. `virtualcols` here does not need to match a prior
`extract` call exactly - it only needs to match the path segments actually present under
`hdbdir/tname/date=.../`. Passing a `virtualcols` name that collides with a genuine on-disk column
(rather than one `extract` actually stripped to the path) produces unreliable results — the two
columns are not distinguished internally, unlike on the write side where `writefile` always strips
the real column first.

---

## Initialisation

`init[deps]` wires the injected `log` dependency and must be called before the first `extract`. It
does not touch the parquet writer — the `PARQUET_VERSION`/`COMPRESSION` write options are built
fresh inside every `extract` call, and `kx.arrow` is loaded automatically by the module itself (see
Dependencies).

```q
pqx:use`di.pqx
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})
pqx.init[enlist[`log]!enlist logdep]
```

---

## Exported Functions

| Function | Description |
|---|---|
| `init[deps]` | Wire the injected `log` dependency. Call once before the first `extract`. |
| `extract[t;tname;dt;o]` | Write a table out to one or more parquet files, appending one row per file to the module's `manifest`. Returns that same per-file stats table, scoped to this call. |
| `getmanifest[]` | Return the manifest accumulated so far across all `extract` calls. |
| `readfile[path;readopt]` | Read a single file back, reattaching its `virtualcols`/`date` values reconstructed from its path (see Options). |
| `buildvirtualtable[hdbdir;tname;datecol;virtualcols]` | Compose every file under `hdbdir/tname/` into one queryable virtual table, with `date`/`virtualcols` reconstructed from each file's path (see Virtual Tables). |

The remaining exports — `checkandconvertcols`, `estimate`, `plan`, `writefile`, `tryfn`,
`castvirtualcol` — are internal pipeline steps of `extract`/`buildvirtualtable`, exposed only so
`k4unit` can exercise them directly. Call `extract`/`buildvirtualtable` for normal use.

### `init[deps]`
Validate the required `log` dependency and store it for use by every other function.

| Arg | Type | Description |
|---|---|---|
| `deps` | dict | Must contain `` `log `` → `` `info`warn`error!(infofn;warnfn;errfn) `` |

Throws (prefixed `di.pqx:`) if `deps` is not a dict, `log` is missing, or the log dict lacks any
required key.

### `extract[t;tname;dt;o]`
Write table `t` out to one or more parquet files under `<outdir>/<tname>/date=<dt>/`, appending one
row per file written to the module's `manifest` and returning that same set of rows (see Manifest
Schema) scoped to this call only — it does not include rows from any earlier `extract` call. `o` is
merged over `default` (see Options). The output directory is created before the
size-estimation/calibration step, so a fresh `outdir` works with the default `calibrate:1b`.

| Parameter | Type | Description |
|---|---|---|
| `t` | table | Data to write |
| `tname` | symbol | Table name — used in the output path |
| `dt` | date | Partition date — used in the output path |
| `o` | dict | Option overrides, merged over `default` |

```q
pqx.extract[trade;`trade;2025.07.15;`targetsize`codec!(256*1024*1024;`gzip)]
```

### `readfile[path;readopt]`
Read a single parquet file back via `` .m.di.0pqx.arrow.pq.readParquetToTable ``, then reattach any
values that `extract` stripped from the on-disk data and encoded only in the file's path — the
`date=<dt>` partition segment (reconstructed as a date) and any `virtualcols` combination segments
(each reconstructed as a symbol). Every `col=value` segment found in `path` becomes a column in the
returned table, broadcast as a constant across every row. `path` may be a plain string or an hsym,
with or without a leading colon; `readopt` is passed straight through to the underlying reader (e.g.
`` (0#`)!() `` to read every column).

| Parameter | Type | Description |
|---|---|---|
| `path` | string or symbol | Path to a single file, as recorded in a manifest `file` value |
| `readopt` | dict | Options passed through to `` .m.di.0pqx.arrow.pq.readParquetToTable `` |

```q
f:1_string first exec file from pqx.getmanifest[] where file like "*exchange=NASDAQ*"
pqx.readfile[f;(0#`)!()]
```

Only useful for a file written with `virtualcols` set, or to recover the `date` — a file written without
`virtualcols` has nothing to reconstruct beyond `date`, since no other columns were stripped from it.

---

## Usage Example

```q
// Include pqx module in a process
pqx:use`di.pqx

// Wire the log dependency (once per process)
logger:use`di.log
pqx.init[logger.logdict]

// Write `trade` for 2025.07.15, overriding the target file size and codec
res:pqx.extract[trade;`trade;2025.07.15;`targetsize`codec!(256*1024*1024;`gzip)]

// res holds only the row(s) written by this call
res

file                                      seq virtualcols syms       nsyms rows  mintime                       maxtime                       estbytes bytes   split status
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
:./trade/date=2025.07.15/part-00001.parquet 1  `symbol$()  `AAPL`MSFT 2     50000 2025.07.15D00:00:00.000000000 2025.07.15D23:59:59.000000000 1153433  1048576 0b    ok

// getmanifest[] returns the full accumulated table across every extract call so far
pqx.getmanifest[]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.pqx
```

`test.csv` drives `extract` across default and overridden options — presort on/off, an oversized
instrument with `splitoversized` on and off, a `symcol` override, parallel (`peach`) writes, and a
custom `filestub`/non-default codec — then asserts on the resulting `getmanifest[]` rows and (via
`` .m.di.0pqx.arrow.pq.readParquetToTable ``) the files written back to disk. It also covers a
zero-row table and a table missing `symcol`/`timecol` (both fail outright), and an invalid `codec`
(degrades gracefully — see Manifest Schema's `status` column).

It also builds `buildvirtualtable` views over several of those same `extract` outputs — no
`virtualcols`, a single `virtualcols` level, and two `virtualcols` levels (one overlapping `symcol` itself) —
asserting row counts, virtual-column types, and that filtering on a virtual column prunes to the
right file(s). `castvirtualcol` is exercised directly for both the datecol and non-datecol cases,
including a datecol not literally named `` `date `` . A directory with no matching files is covered
too: building the view over it succeeds, but querying it then fails.

It also covers the `manifest.json` sidecar directly — parsing it back with `.j.k`/`read0` and casting
its columns against `extract`'s returned per-call stats table (see Manifest Schema), that a repeat
`extract` call into the same partition overwrites rather than accumulates the sidecar, and that a
sidecar write failure (something else already occupying that path) still lets `extract` return
normally and update the in-memory `manifest`.

---

## Notes

- `rowgroupbytes` and `complevel` are accepted in `default` and any `o` override, but nothing in the
  current write path reads them — only `` `PARQUET_VERSION `` (fixed at `` `V2.LATEST ``) and
  `` `COMPRESSION `` (from `codec`) are passed to the writer. `virtualcols` (see Options) is read by
  `plan`/`estimate`/`writefile` for file planning and output paths only.
- `symcol`/`timecol` presence is validated unconditionally on every `extract` call, even when
  `presort` is `0b`. A zero-row input table is rejected outright, before that check, regardless of
  `calibrate`.
- A per-file write failure (e.g. an invalid `codec`) is caught and logged at `warn`, and that file
  is recorded with `` status=`error `` (and `bytes:0`) in the manifest — it does not abort the rest of
  `extract`.
- `buildvirtualtable` has only been tested pointed at a single `date=` partition at a time; pointing
  it at `hdbdir/tname/` directories that span multiple dates is expected to work (the `date` segment
  is reconstructed the same way as any other level) but isn't covered by `test.csv` yet.
