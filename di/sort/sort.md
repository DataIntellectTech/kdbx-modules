# di.sort

Module for sorting and applying attributes to on-disk kdb+ tables. Driven by a configuration CSV (`sort.csv`) that specifies which columns to sort by and which attributes to apply per table. If a table has no explicit entry, `di.sort` falls back to a `default` row. Extracted from the `.sort` namespace in TorQ's `dbwriteutils.q`.

## Usage

```q
srt:use`di.sort

/ inject dependencies — log is required, savedir defaults to `:sort.csv
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[`log`savedir!(logdep;`:config/sort.csv)]

/ load sort configuration
srt.getsortcsv[`:config/sort.csv]

/ sort all partitions for a table
srt.sorttab[(`trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade)]

/ inspect loaded config
srt.getparams[]
```

### Typical HDB sort loop

```q
srt:use`di.sort
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[`log`savedir!(logdep;`:config/sort.csv)]

/ collect partitions per table then sort each
tables:`trade`quote
dirs:raze {[t;hdb] ([] t:t; d:hdb,/:t) } [;`:/hdb] each tables
srt.sorttab each {(first x;exec d from x)} each value tables!dirs
```

## sort.csv format

```
tabname,att,column,sort
trade,p,sym,1
trade,s,time,1
trade,,price,0
quote,p,sym,1
default,p,sym,1
```

| Column | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name, or `default` to apply to all unlisted tables |
| `att` | symbol | Attribute to apply after sort: `p` `s` `g` `u` or empty for none |
| `column` | symbol | Column to sort/attribute |
| `sort` | boolean | `1` to use this column as a sort key; `0` to apply attribute only |

**Attributes:**

| Value | Description |
|---|---|
| `p` | Parted — all rows with the same value are contiguous. Requires the column to be sorted first (`sort=1`). |
| `s` | Sorted — values are in ascending order. Applied automatically by `xasc`; set explicitly here if wanted after the sort step. |
| `g` | Grouped — inverse index stored on disk. Suitable for low-to-medium cardinality unsorted columns. |
| `u` | Unique — all values are distinct. |
| ` ` (empty) | No attribute applied. Column may still participate in the sort if `sort=1`. |

Multiple rows for the same table are supported. All rows with `sort=1` for a table are used as the compound sort key in the order they appear. Attribute rows with `sort=0` are applied independently after sorting.

## API

### `init[deps]`

Wire injectable dependencies and optional configuration. Must be called before any other function.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | Functions keyed `` `info`warn`error ``, each with signature `{[ctx;msg]}` |
| `` `savedir `` | no | hsym | Path to sort.csv used as fallback when `sorttab` is called with an empty `params` table. Defaults to `` `:sort.csv ``. |

Errors with prefix `di.sort:` if `log` is missing or does not contain all three required keys.

```q
/ minimal — savedir defaults to `:sort.csv
srt.init[enlist[`log]!enlist logdep]

/ with explicit sort.csv path
srt.init[`log`savedir!(logdep;`:config/sort.csv)]
```

---

### `getsortcsv[file]`

Load and validate sort configuration from a CSV file. Populates the internal `params` table used by `sorttab`.

| Parameter | Type | Description |
|---|---|---|
| `file` | hsym | Path to sort.csv |

Validates that:
- All four required columns (`tabname`, `att`, `column`, `sort`) are present
- No unrecognised column names exist
- All `att` values are one of `` ` `p`s`g`u ``

Logs an info message on successful load and an error message on file-read failure (then rethrows).

```q
srt.getsortcsv[`:config/sort.csv]
```

---

### `sorttab[d]`

Sort and apply attributes to on-disk partitions for a single table.

| Parameter | Type | Description |
|---|---|---|
| `d` | 2-element list | `(tablename; partition_dirs)` where `partition_dirs` is an hsym or list of hsyms |

Lookup order for sort parameters:
1. Rows where `tabname` matches the supplied table name
2. Rows where `tabname = \`default`
3. If neither found — logs a warn and returns `()` without error

Each partition directory is processed independently. A failure on one partition is logged (as an error) and does not halt remaining partitions.

If `params` is empty when `sorttab` is called, it auto-loads from the `savedir` set during `init`.

```q
/ single partition
srt.sorttab[(`trade; enlist `:/hdb/2000.01.01/trade)]

/ multiple partitions
srt.sorttab[(`trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade)]
```

---

### `getparams[]`

Return the current sort configuration table loaded by `getsortcsv`.

```q
srt.getparams[]
```

Returns a table with schema `([] tabname:\`symbol$(); att:\`symbol$(); column:\`symbol$(); sort:\`boolean$())`.

## Log dependency contract

`di.sort` requires a log dependency dictionary with keys `` `info`warn`error ``, each a function with signature `{[ctx;msg]}`:

```q
`info`warn`error!({[ctx;msg] ...};{[ctx;msg] ...};{[ctx;msg] ...})
```

`di.log` satisfies this contract out of the box:

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[enlist[`log]!enlist logdep]
```

You can supply any custom implementation with the same signatures.

Context symbols used by `di.sort` in log calls:

| Context | Level | When |
|---|---|---|
| `` `getsortcsv `` | info | CSV retrieval start and row count on successful load |
| `` `getsortcsv `` | error | File read failure (rethrown after logging) |
| `` `sorttab `` | info | Sort start, params lookup result, column list, sort completion |
| `` `sorttab `` | warn | Table has no matching params and no default row |
| `` `sorttab `` | error | `xasc` failure on a partition (non-fatal — remaining partitions continue) |
| `` `applyattr `` | info | Attribute applied to a column |
| `` `applyattr `` | error | Attribute application failure (non-fatal) |
