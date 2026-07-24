# di.pqx

Converts an in-memory kdb+ table into one or more `.parquet` files via `kx.arrow`. Rows are grouped
by instrument and packed into files close to a configurable target size, splitting any single
oversized instrument across multiple files where required. A manifest recording what was written
(file, instruments, row count, time range, on-disk size) is accumulated in the module's private
`manifest` table; `extract` itself has no return value.

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

**Hard dependencies:** `kx.arrow` and `kx.qmamba` — both are loaded automatically (via `use`) when
`di.pqx` is imported, before `pqx.q` itself is loaded. `extract` calls
`` .m.di.0pqx.arrow.pq.writeParquetFromTable `` to perform every write; `kx.qmamba` is loaded but not
currently called anywhere in `pqx.q`.

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
(`` `di.pqx: no symcol found `` / `` `di.pqx: no timecol found ``) if the merged `symcol`/`timecol`
is not a column of the input table — this check runs unconditionally, regardless of `presort`.

---

## Manifest Schema

The module's `manifest` table accumulates one row per file written across all `extract` calls.
`extract` does not return this table (or anything else). `` pqx:use`di.pqx `` only captures a
one-time snapshot of `manifest`/`default` at load time — `pqx.manifest` and `pqx.default` do **not**
track later writes or updates. Query the live state via `` .m.di.0pqx.manifest `` instead (the
private namespace every kdb-x module loads into; see `di.depcheck`'s docs for the `` `.m.di.0<name> ``
convention).

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
| `extract[t;tname;dt;o]` | Write a table out to one or more parquet files, appending one row per file to the module's `manifest`. Returns nothing. |

The remaining exports — `checkandconvertcols`, `estimate`, `calibrateratio`, `calcsize`, `plan`,
`datalookup`, `datalookuponesym`, `writefile`, `tryfn` — are internal pipeline steps of `extract`,
exposed only so `k4unit` can exercise them directly. Call `extract` for normal use.

### `init[deps]`
Validate the required `log` dependency and store it for use by every other function.

| Arg | Type | Description |
|---|---|---|
| `deps` | dict | Must contain `` `log `` → `` `info`warn`error!(infofn;warnfn;errfn) `` |

Throws (prefixed `di.pqx:`) if `deps` is not a dict, `log` is missing, or the log dict lacks any
required key.

### `extract[t;tname;dt;o]`
Write table `t` out to one or more parquet files under `<outdir>/<tname>/date=<dt>/`, appending one
row per file written to the module's `manifest`. `o` is merged over `default` (see Options). The
output directory is created before the size-estimation/calibration step, so a fresh `outdir` works
with the default `calibrate:1b`.

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
pqx.extract[trade;`trade;2025.07.15;`targetsize`codec!(256*1024*1024;`gzip)]

// extract has no return value - inspect the accumulated manifest directly.
// pqx.manifest is a frozen snapshot from load time - query the live namespace instead:
.m.di.0pqx.manifest

file                                      seq syms       nsyms rows  mintime                       maxtime                       estbytes bytes   split status
--------------------------------------------------------------------------------------------------------------------------------------------------------------
:./trade/date=2025.07.15/part-00001.parquet 1  `AAPL`MSFT 2     50000 2025.07.15D00:00:00.000000000 2025.07.15D23:59:59.000000000 1153433  1048576 0b    ok
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.pqx
```

`test.csv` drives `extract` across default and overridden options — presort on/off, an oversized
instrument with `splitoversized` on and off, a `symcol` override, parallel (`peach`) writes, and a
custom `filestub`/non-default codec — then asserts on the resulting `` .m.di.0pqx.manifest `` rows
and (via `` .m.di.0pqx.arrow.pq.readParquetToTable ``) the files written back to disk. It also
covers the failure paths: a zero-row table, a table missing `symcol`/`timecol`, and an invalid
codec (see Notes).

---

## Notes

- `pqx.manifest` and `pqx.default` (the values returned by `` pqx:use`di.pqx ``) are snapshots taken
  once at load time — they never reflect later writes or changes. Always read `` .m.di.0pqx.manifest ``
  for the live manifest.
- `rowgroupbytes`, `complevel`, and `dictcols` are accepted in `default` and any `o` override, but
  nothing in the current write path reads them — only `` `PARQUET_VERSION `` (fixed at
  `` `V2.LATEST ``) and `` `COMPRESSION `` (from `codec`) are passed to the writer.
- `symcol`/`timecol` presence is validated unconditionally on every `extract` call, even when
  `presort` is `0b`.
- A per-file write failure (e.g. an invalid `codec`) is caught and logged, but currently still
  causes `extract` to throw rather than recording that file with `` status=`error `` in the manifest
  as the schema implies it should — see `test.csv`'s invalid-codec case.
