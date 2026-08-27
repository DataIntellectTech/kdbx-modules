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
- Writes files sequentially or in parallel (`peach`)
- Accumulates a manifest of every file written, including row counts, instrument lists, time bounds and on-disk size

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

**Hard dependency:** `kx.arrow` — loaded automatically (via `use`) when `di.pqx` is imported, before
`pqx.q` itself is loaded. `extract` calls `` .m.di.0pqx.arrow.pq.writeParquetFromTable `` to perform
every write.

`kx.arrow` must be resolvable on the process's module search path at that point. Where it's
installed as a conda package (e.g. under a `kx.qmamba`-managed root such as
`~/.kx/root/lib/q/mod`), that location needs to already be on `QPATH` — `di.pqx` does not load
`kx.qmamba` itself to arrange this. Confirm `kx.arrow` loads standalone (`` use`kx.arrow ``) in the
target environment before relying on `di.pqx` there.

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
| `dictcols` | `` `sym`exchange `` | symbol list | Reserved for future use — not currently read by the write path |
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

---

## Manifest Schema

The module's `manifest` table accumulates one row per file written across all `extract` calls; call
`getmanifest[]` to read the full accumulated table. `extract` itself returns a table of the same
shape, scoped to only the file(s) written by that call.

| Column | Type | Description |
|---|---|---|
| `file` | symbol | Path written |
| `seq` | long | Sequence number within the partition |
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
to a `manifest` sidecar file directly under the partition directory (i.e.
`<outdir>/<tname>/date=<dt>/manifest`), serialized with `set`/readable back with `get`. A repeat
`extract` call into the same partition overwrites the sidecar with just that call's rows, rather
than accumulating across calls — the sidecar mirrors `extract`'s return value, not `getmanifest[]`.
Writing the sidecar is best-effort: if it fails (for example a permissions issue, or something else
already occupying that path) a warning is logged but `extract` still returns normally and still
updates the in-memory `manifest`.

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

The remaining exports — `checkandconvertcols`, `estimate`, `plan`, `writefile`, `tryfn` — are
internal pipeline steps of `extract`, exposed only so `k4unit` can exercise them directly. Call
`extract` for normal use.

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

file                                      seq syms       nsyms rows  mintime                       maxtime                       estbytes bytes   split status
--------------------------------------------------------------------------------------------------------------------------------------------------------------
:./trade/date=2025.07.15/part-00001.parquet 1  `AAPL`MSFT 2     50000 2025.07.15D00:00:00.000000000 2025.07.15D23:59:59.000000000 1153433  1048576 0b    ok

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

---

## Notes

- `rowgroupbytes`, `complevel`, and `dictcols` are accepted in `default` and any `o` override, but
  nothing in the current write path reads them — only `` `PARQUET_VERSION `` (fixed at
  `` `V2.LATEST ``) and `` `COMPRESSION `` (from `codec`) are passed to the writer.
- `symcol`/`timecol` presence is validated unconditionally on every `extract` call, even when
  `presort` is `0b`. A zero-row input table is rejected outright, before that check, regardless of
  `calibrate`.
- A per-file write failure (e.g. an invalid `codec`) is caught and logged at `warn`, and that file
  is recorded with `` status=`error `` (and `bytes:0`) in the manifest — it does not abort the rest of
  `extract`.
