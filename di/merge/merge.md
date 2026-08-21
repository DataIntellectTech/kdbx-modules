# di.merge

On-disk data-merging utilities for the write-down flow, extracted from TorQ's `code/common/merge.q`. During intraday write-down a process (typically a WDB) writes data to disk in temporary *partition segments* to keep memory flat; at end-of-day those segments are merged into the final HDB partition. `di.merge` performs that merge - whole-partition, column-by-column, or a hybrid of the two chosen per partition by a configurable row-count / byte-size limit - and tracks the size of each segment as it is written to drive that decision.

---

## Features

- Merge on-disk partition segments into a destination partition without holding the whole partition in memory: whole-partition (`mergebypart`), column-by-column (`mergebycol`), or a per-partition hybrid (`mergehybrid`)
- Track each segment's row count and byte-size estimate as it is written (`trackpartition`) and use it to size merge batches (`getpartchunks`) and pick the merge method
- Sync a partsizes table received from a peer process into local tracked state (`syncpartsizes`) - see "Cross-process partition-size sync" below
- Re-sort a segment by its parted column(s) when the `p#` attribute cannot otherwise be applied, so the merged partition ends up correctly parted
- Batch sizing bounded by both a data limit (rows or bytes, per `mergebybytelimit`) and a maximum partition count per batch (`partlimit`)
- Helpers to validate and enumerate a table's parted columns (`checkpartitiontype`, `checkenumerabletype`, `getextrapartitions`, `getfirstcharpartitions`)
- No hard module dependencies - logging is injected via `init`, and the parted column(s) a merge needs are passed in by the caller rather than read from sort config, so `di.merge` stays independent of `di.sort`

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | binary `{[c;m]}` functions keyed `` `info`error `` - `c` is a symbol context, `m` is a string. `di.merge` never calls `warn`, confirmed against every log call site in the legacy source, so it is not required (extra keys, e.g. from `di.log`'s `logdict`, are accepted and ignored) |

**Hard dependency:** none - the only runtime dependency (`log`) is injected via `init`, so any module exporting the contracted signatures can be supplied.

The parted (`` `p# ``) column(s) for a table - `extrapartitiontype` in the function signatures below - are **passed in by the caller**. TorQ's original `merge.q` read these from the `.sort.params` global (populated from `sort.csv`); on extraction that coupling was removed so `di.merge` does not depend on `di.sort`. The caller (e.g. `di.wdb`) obtains the parted columns from its own sort configuration and passes them to `mergebypart` / `mergehybrid` / the check functions.

**Logging contract.** Internally the module calls the logger through `.z.m.loginfo[\`ctx;"msg"]` / `.z.m.logerr[\`ctx;"msg"]` (binary `{[c;m]}` - context symbol + message). Pass a plain `` `info`error `` (or fuller) dict of `{[c;m]}` functions - `di.log`'s `logdict` is a ready-made example. No auto-detection or adaptation is performed; the dict must already conform.

---

## Initialisation

`init[deps]` takes a single dictionary combining the injected `log` dependency with any configuration overrides. Config keys are optional - omit any and the module falls back to the default; unrecognised keys are ignored. `init` throws immediately, before any state is wired, if `deps` is not a dictionary or `log` is missing, not a dict, or missing `info`/`error`. There is no default logger and no silent fallback.

| Key | Default | Description |
|---|---|---|
| `` `mergebybytelimit `` | `0b` | `0b` sizes batches / picks the merge method by row count, `1b` by byte-size estimate |
| `` `partlimit `` | `1000` | maximum number of partitions merged together in a single batch |
| `` `log `` | *(required)* | logger providing at least `info`/`error` |

```q
merge:use`di.merge
logging:use`di.log
merge.init[logging.logdict]
/ or with config overrides:
merge.init[logging.logdict,`mergebybytelimit`partlimit!(1b;500)]
```

Every exported function except `init` and `getapimeta` calls `init` must have run first - see "requireinit guard" below.

---

## requireinit guard

Every exported function except `init`/`getapimeta` refuses to run before `init` has wired the
dependencies, throwing a clear `` "di.merge: <function>: init must be called before any other
function" `` instead of failing on an unset logger with a confusing raw error. The guard probes
`.z.m.loginfo`, the one piece of module state with no load-time default anywhere in the file -
unlike `partsizes`/`mergebybytelimit`/`partlimit`, which all start with real, valid-looking
defaults whether `init` has run or not and so cannot reliably signal "not yet initialised".

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

### `syncpartsizes[t]`
Upsert a `getpartsizes[]`-shaped table `t`, typically received over IPC from a peer process, into local tracked state. See "Cross-process partition-size sync" below.

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
Error-log any parted column supplied for the table that is absent from it.

### `checkenumerabletype[tablename;extrapartitiontype]`
Confirm every parted column has an enumerable type (`h`/`i`/`j`/`s`) so it can key a partition; error-logs otherwise.

### `getextrapartitions[tablename;extrapartitiontype]`
Return the distinct combinations of the parted column values - one per partition directory.

### `getfirstcharpartitions[tablename;extrapartitiontype]`
Return the partition values grouped by the first character of the (single) parted column.

### `version`
Module version string (from the `VERSION` file), for `di.depcheck` to check against dependants' minimum-version requirements.

### `getapimeta[]`
This module's API metadata, one row per callable API function, for `di.torq` to register with `di.api`. `init`/`getapimeta` are framework plumbing and are not registered.

---

## Two callers, not fully symmetric

Both legacy callers (`wdb.q`, `tickerlogreplay.q`) call `checkpartitiontype`, `getextrapartitions`,
`getpartchunks`, `mergebypart`, `mergebycol` and `mergehybrid`. **`checkenumerabletype` and
`getfirstcharpartitions` are wdb.q-only** - they back wdb's `partbyenum` and `partbyfirstchar`
writedown modes, which `tickerlogreplay.q`'s simpler `partandmerge` replay mode has no equivalent
of. A future consumer that only exercises the tickerlogreplay-style call pattern (as `di.wdb` will
initially, most likely) should not assume the full API surface is exercised end-to-end by that
usage alone - `getfirstcharpartitions` needs its own coverage, which it now has (see `test.csv`);
`checkenumerabletype` is covered by the parted-column-checks block.

---

## Partition-size store schema

`getpartsizes[]` returns the store, keyed on `ptdir`:

| Column | Type | Description |
|---|---|---|
| ptdir | `symbol` | partition directory of the segment |
| rowcount | `long` | accumulated row count written to that segment |
| bytes | `long` | accumulated byte-size estimate of that segment |

`getpartchunks[partdirs;mergelimit]` drops any requested `partdirs` entry that has not been
`trackpartition`'d - it filters against `getpartsizes[]`, so an untracked partition is simply
absent from every batch rather than raising an error. Callers must ensure every partition they mean
to merge has been tracked first. `getpartchunks` logs an info line naming how many requested
partitions had no tracked size whenever it drops any - the filtering behaviour itself is unchanged.

---

## Two deliberate design decisions from adversarial testing

A deliberate adversarial pass beyond the k4unit happy-path suite surfaced two behaviours that needed
a conscious decision rather than either a silent fix or a silently-shipped gap. Both are resolved:

**`init` preserves tracked-but-unmerged partition sizes across a re-init.** Calling `init` again with
valid deps (e.g. a live config reload via `di.torq`) does **not** wipe `.z.m.partsizes` - any segments
`trackpartition`'d since the last `clearpartsizes[]` survive. `partsizes` is orthogonal to the
`log`/`mergebybytelimit`/`partlimit` deps a re-init is typically changing, and silently discarding
tracked-but-unmerged segment sizes is a worse failure mode than leaving them alone - a re-init that
happens to land between `trackpartition` calls and the next merge should not cause data to go
unmerged with no trace. When `init` finds pre-existing tracked partitions it says so explicitly:
`` "di.merge initialised, N segment(s) already tracked, preserved" `` - so the decision is visible in
the log rather than something a future debugger has to discover by reading source. A fresh, first-ever
`init` (nothing tracked yet) logs the plain `"di.merge initialised"` with no such claim.

**`mergebycol` deliberately keeps failing uncaught on a missing/corrupt segment column; `mergebypart`
does not.** These are not equivalent failure modes, so making them match would not obviously be the
safer choice - it might be the wrong one. `mergebypart` fails per whole partition: if one partition's
upsert fails, `dest` simply doesn't get that partition's data yet, which is incomplete but still
internally consistent. `mergebycol` merges one column at a time into the *same* `dest`; if a swallowed
failure let it carry on past a bad column, `dest` would end up with some columns reflecting the new
data and others silently stale - a genuinely worse, silently-inconsistent partition, not just a
delayed merge. So `mergebycol`'s column read is intentionally left unprotected: a missing or
unreadable segment column throws straight out of `mergebycol`/`mergehybrid`'s column-by-column path,
by design, rather than risking a half-updated destination. (This also happens to match the legacy
TorQ source and Olly's draft, both of which have the same unprotected-read structure - but the reason
to keep it here is the partial-column-write risk above, not merely that it matches prior behaviour.)

---

## Cross-process partition-size sync

Legacy `wdb.q` fans `.merge.partsizes` out to sort workers via raw async IPC in two places -
`endofdaymerge` (targeting `.z.pd[]`, the process's own worker handles) and `informsortandreload`
(targeting discovered peer sort/reload processes) - both conditionally guarded on the merge method
being `part` or `hybrid`. There was no symmetric receive-side function: a receiving process
evaluated the raw `(upsert;`.merge.partsizes;y)` tuple directly, which only worked if it had
already loaded `merge.q` so the table existed with the right schema - an undocumented, load-order-
dependent contract.

`syncpartsizes[t]` gives the receive side a real function to go through instead. This is a genuine
improvement over the legacy pattern, not just a faithfulness gap-fill: because `syncpartsizes` is
guarded by `requireinit`, the receiving process must now have called `di.merge.init` first - the
"must have already loaded merge.q" precondition becomes explicit and checked rather than implicit.

```q
/ sender side (e.g. di.wdb, once merge functionality lands there)
(neg h) (`.merge.syncpartsizes; merge.getpartsizes[])

/ receiver side
merge.syncpartsizes[t]   / upserts wholesale into local tracked state
```

---

## Usage Example

```q
logging:use`di.log
merge:use`di.merge
merge.init[logging.logdict]

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

The test suite injects a no-op binary mock logger (and a capturing logger for the log-path assertions). It covers: dependency validation (non-dict deps / missing / non-dict / incomplete `log` all throw, with the `di.merge` error prefix); the `requireinit` guard rejecting every exported function before `init` has run; config application via row-count vs byte-size batching, defaults and overrides; `trackpartition`/`getpartsizes`/`clearpartsizes`/`syncpartsizes`; the `getpartchunks` batching and `partlimit` splitting logic; `version`/`getapimeta` shape; and end-to-end `mergebypart`, `mergebycol` and `mergehybrid` against real on-disk segments written to a scratch directory (cleaned up afterwards).

---

## Notes

- Extracted from TorQ `code/common/merge.q`. The one behavioural change on extraction is the removal of the `.sort.params`/`sort.csv` lookup (`getextrapartitiontype`): the parted column(s) are now a parameter (`extrapartitiontype`) supplied by the caller, keeping the module standalone. All error/info messages that referenced `sort.csv` in the legacy source have been reworded accordingly.
- `init` must be called before any other function - enforced by the `requireinit` guard on every other exported function, not just documented convention.
- The `VERSION`-file read pattern (fail loud on missing/unreadable/empty, `trim` against trailing whitespace) follows `di.servers`, not `di.eodtime` (which has no `VERSION` handling at all).
- The merge functions operate on on-disk paths (`get`/`set`/`upsert` against file symbols); they do not manage the segment or destination directory lifecycle - that remains the caller's responsibility.
