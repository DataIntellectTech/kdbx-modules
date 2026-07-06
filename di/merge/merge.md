# di.merge

On-disk data-merging utilities for the write-down flow, extracted from TorQ's `code/common/merge.q`. During intraday write-down a process (typically a WDB) writes data to disk in temporary *partition segments* to keep memory flat; at end-of-day those segments are merged into the final HDB partition. `di.merge` performs that merge - whole-partition, column-by-column, or a hybrid of the two chosen per partition by a configurable row-count / byte-size limit - and tracks the size of each segment as it is written to drive that decision.

---

## Features

- Merge on-disk partition segments into a destination partition without holding the whole partition in memory: whole-partition (`mergebypart`), column-by-column (`mergebycol`), or a per-partition hybrid (`mergehybrid`)
- Track each segment's row count and byte-size estimate as it is written (`trackpartition`) and use it to size merge batches (`getpartchunks`) and pick the merge method
- Re-sort a segment by its parted column(s) when the `p#` attribute cannot otherwise be applied, so the merged partition ends up correctly parted
- Batch sizing bounded by both a data limit (rows or bytes, per `mergebybytelimit`) and a maximum partition count per batch (`partlimit`)
- Helpers to validate and enumerate a table's parted columns (`checkpartitiontype`, `checkenumerabletype`, `getextrapartitions`, `getfirstcharpartitions`)
- No hard module dependencies - logging is injected via `init`, and the parted column(s) a merge needs are passed in by the caller rather than read from sort config, so `di.merge` stays independent of `di.sort`

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`/`warn`/`error` - binary `{[c;m]}` where `c` is a symbol context and `m` is a string. A `kx.log` instance is accepted directly and auto-wrapped |

**Hard dependency:** none - the only runtime dependency (`log`) is injected via `init`, so any module exporting the contracted signatures can be supplied.

The parted (`` `p# ``) column(s) for a table - `extrapartitiontype` in the function signatures below - are **passed in by the caller**. TorQ's original `merge.q` read these from the `.sort.params` global; on extraction that coupling was removed so `di.merge` does not depend on `di.sort`. The caller (e.g. `di.wdb`) obtains the parted columns from its sort configuration and passes them to `mergebypart` / `mergehybrid`.

**Logging contract.** Internally the module calls the logger as binary `.z.m.log[\`info][\`merge;"msg"]` (`{[c;m]}` - context symbol + message). You may pass either a `kx.log` instance (its monadic `{[msg]}` functions are detected and auto-wrapped, folding the context tag into the message as `"merge: ..."`) or a custom `` `info`warn`error `` dict of `{[c;m]}` functions, used as-is.

---

## Initialisation

`init[deps]` takes a single dictionary combining the injected `log` dependency with any configuration overrides. Config keys are optional - omit any and the module falls back to the default; unrecognised keys are ignored. `init` throws immediately if `deps` is not a dictionary or `log` is missing or malformed.

| Key | Default | Description |
|---|---|---|
| `` `mergebybytelimit `` | `0b` | `0b` sizes batches / picks the merge method by row count, `1b` by byte-size estimate |
| `` `partlimit `` | `1000` | maximum number of partitions merged together in a single batch |
| `` `log `` | *(required)* | logger providing `info`/`warn`/`error` (a `kx.log` instance is auto-wrapped) |

```q
merge:use`di.merge
merge.init[enlist[`log]!enlist kxlog]
/ or with config overrides:
merge.init[`mergebybytelimit`partlimit`log!(1b;500;kxlog)]
```

---

## Exported Functions

### `init[deps]`
Wire config + the injected `log` dependency (one dict). Must be called before anything else.

### `trackpartition[ptdir;rowcount;bytes]`
Accumulate the row count and byte-size estimate for a freshly-written segment, keyed by partition directory. Call each time data is written to a segment.
```q
merge.trackpartition[`:tmp/2025.01.01/trade; count data; -22!data]
```

### `getpartsizes[]`
Return the current tracked segment sizes (keyed on `ptdir`), e.g. to sync to sort-worker processes.

### `clearpartsizes[]`
Drop all tracked segment sizes. Call once end-of-day merging is complete.

### `getpartchunks[partdirs;mergelimit]`
Split `partdirs` into batches to be merged together, each within `mergelimit` (rows or bytes per `mergebybytelimit`) and no larger than `partlimit` partitions. Returns a list of batches (each a list of partition directories).
```q
merge.getpartchunks[partdirs; 1000000]
```

### `mergebypart[extrapartitiontype;dest;partchunks]`
Merge one batch of whole partition segments into destination partition `dest`, re-sorting by the parted column(s) `extrapartitiontype` first if the `p#` attribute cannot otherwise be applied. Typically iterated over the output of `getpartchunks`.
```q
merge.mergebypart[`sym; ` sv dest,`] each merge.getpartchunks[partdirs;lim]
```

### `mergebycol[tableinfo;dest;segment]`
Merge one `segment` into `dest` a column at a time, holding at most a single column in memory. `tableinfo` is `(tablename;schema)`; the schema supplies the column list.
```q
merge.mergebycol[(`trade;schema); dest] each partdirs
```

### `mergehybrid[extrapartitiontype;tableinfo;dest;partdirs;mergelimit]`
Merge `partdirs` using whichever method fits each: whole-partition for those within `mergelimit`, column-by-column for any single partition over it (creating the `.d` file if column-by-column merging produced none).

### `checkpartitiontype[tablename;extrapartitiontype]`
Error-log any parted column named for the table that is absent from it.

### `checkenumerabletype[tablename;extrapartitiontype]`
Confirm every parted column has an enumerable type (`h`/`i`/`j`/`s`) so it can key a partition; error-logs otherwise.

### `getextrapartitions[tablename;extrapartitiontype]`
Return the distinct combinations of the parted column values - one per partition directory.

### `getfirstcharpartitions[tablename;extrapartitiontype]`
Return the partition values grouped by the first character of the (single) parted column.

---

## Partition-size store schema

`getpartsizes[]` returns the store, keyed on `ptdir`:

| Column | Type | Description |
|---|---|---|
| ptdir | `symbol` | partition directory of the segment |
| rowcount | `long` | accumulated row count written to that segment |
| bytes | `long` | accumulated byte-size estimate of that segment |

---

## Usage Example

```q
kxlog:use`kx.log
merge:use`di.merge
merge.init[enlist[`log]!enlist kxlog.createLog[]]

/ as each segment is written down, record its size
merge.trackpartition[seg; count data; -22!data]

/ at end-of-day, merge the segments for a table into its hdb partition
partdirs:merge.getpartsizes[][`ptdir]
merge.mergehybrid[`sym; (`trade;schema); dest; partdirs; 1000000]
merge.clearpartsizes[]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.merge
```

The test suite injects a no-op binary mock logger (and a capturing logger for the log-path assertions). It covers: dependency validation (non-dict deps / missing / non-dict / incomplete `log` all throw, with the `di.merge` error prefix); config application via row-count vs byte-size batching; `trackpartition`/`getpartsizes`/`clearpartsizes`; the `getpartchunks` batching and `partlimit` splitting logic; and end-to-end `mergebypart`, `mergebycol` and `mergehybrid` against real on-disk segments written to a scratch directory (cleaned up afterwards).

---

## Notes

- Extracted from TorQ `code/common/merge.q`. The only behavioural change on extraction is the removal of the `.sort.params` lookup (`getextrapartitiontype`): the parted column(s) are now a parameter (`extrapartitiontype`) supplied by the caller, keeping the module standalone.
- `init` must be called before any other function (it wires the logger).
- The merge functions operate on on-disk paths (`get`/`set`/`upsert` against file symbols); they do not manage the segment or destination directory lifecycle - that remains the caller's responsibility.
