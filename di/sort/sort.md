# di.sort

Module for sorting and applying attributes to on-disk kdb+ tables. Driven by a **config table** that specifies which columns to sort by and which attributes to apply per table. You pass that table straight to `sorttab`; if you keep your config in a CSV file, `readcsv` reads one into the right shape for you. If a table has no explicit entry, `di.sort` falls back to a `default` row. Extracted from the `.sort` namespace in TorQ's `dbwriteutils.q`.

## Usage

```q
srt:use`di.sort

/ inject dependencies — log is required
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[enlist[`log]!enlist logdep]

/ build a config table directly ...
config:([] tabname:`trade`trade`default; att:`p``p; column:`sym`time`sym; sort:101b)
srt.sorttab[config; `trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade]

/ ... or read the config from a csv and pass it straight in
srt.sorttab[srt.readcsv `:config/sort.csv; `trade; `:/hdb/2000.01.01/trade]
```

`di.sort` holds no state of its own: every `sorttab` call takes the config it should use, so you can build that config however you like (by hand, from a query, or from a CSV) and reuse or vary it freely.

### Typical HDB sort loop

```q
srt:use`di.sort
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[enlist[`log]!enlist logdep]

config:srt.readcsv `:config/sort.csv

/ .Q.par[root;date;table] builds the on-disk partition path
hdb:`:/hdb
dates:2000.01.01 2000.01.02
tabs:`trade`quote
/ for each table, build its partition paths, then sort every table with the same config
pdirs:{[hdb;dates;t] .Q.par[hdb;;t] each dates}[hdb;dates] each tabs
srt.sorttab[config]'[tabs; pdirs]
```

## The config table

`di.sort` is configured with a table of this shape:

| Column | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name, or `default` to apply to all unlisted tables |
| `att` | symbol | Attribute to apply after sort: `p` `s` `g` `u` or empty (`` ` ``) for none |
| `column` | symbol | Column to sort/attribute |
| `sort` | boolean | `1b` to use this column as a sort key; `0b` to apply an attribute only |

Build it any way you like — in code, from a query, or from a CSV via `readcsv`:

```q
([] tabname:`trade`trade`default; att:`p``p; column:`sym`time`sym; sort:101b)
```

Multiple rows for the same table are supported. All rows with `sort=1b` for a table form the compound sort key, in the order they appear. Attribute rows with `sort=0b` are applied independently after sorting.

**Attributes:**

| Value | Description |
|---|---|
| `p` | Parted — all rows with the same value are contiguous. Requires the column to be sorted first (`sort=1b`). |
| `s` | Sorted — values are in ascending order. Applied automatically by `xasc`; set explicitly here if wanted after the sort step. |
| `g` | Grouped — inverse index stored on disk. Suitable for low-to-medium cardinality unsorted columns. |
| `u` | Unique — all values are distinct. |
| ` ` (empty) | No attribute applied. Column may still participate in the sort if `sort=1b`. |

### sort.csv format (for `readcsv`)

A CSV consumed by `readcsv` must have these four columns, in this order:

```
tabname,att,column,sort
trade,p,sym,1
trade,,time,0
quote,p,sym,1
default,p,sym,1
```

## API

### `init[deps]`

Wire injectable dependencies. Must be called before any other function.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | Functions keyed `` `info`warn`error ``, each with signature `{[ctx;msg]}` |

Errors with prefix `di.sort:` if `deps` is not a dict, if `log` is missing, or if the log dict does not contain all three required keys.

```q
srt.init[enlist[`log]!enlist logdep]
```

---

### `readcsv[file]`

Read a config CSV and **return** it as a table. Does not store it — pass the result to `sorttab`. Use this only when your config lives in a CSV; a hand-built table goes straight to `sorttab`.

| Parameter | Type | Description |
|---|---|---|
| `file` | hsym (or symbol) | Path to the CSV. Coerced with `hsym`, so `` `:config/sort.csv `` and `` `config/sort.csv `` both work. |

The CSV must have exactly the four columns `tabname`, `att`, `column`, `sort` — in **any** order (the result is normalised to canonical column order). The header is validated as it is read: a missing, extra, or misnamed column raises a clear `di.sort:` error rather than silently mis-parsing or dropping data. Logs info messages while reading (the read start and the row count) and an error message on file-read failure (then rethrows). Attribute-value validation (e.g. an unknown `att`) happens later in `sorttab`.

```q
config:srt.readcsv `:config/sort.csv
srt.sorttab[config; `trade; dirs]

/ or in one line
srt.sorttab[srt.readcsv `:config/sort.csv; `trade; dirs]
```

---

### `sorttab[config;tabname;dirs]`

Sort and apply attributes to on-disk partitions for a single table, using the supplied config table.

| Parameter | Type | Description |
|---|---|---|
| `config` | table | A config table with columns `` `tabname`att`column`sort `` (see [The config table](#the-config-table)) |
| `tabname` | symbol | Table name |
| `dirs` | hsym, or list of hsyms | Partition directory (or directories) for that table |

`config` is validated first; `sorttab` errors (prefixed `di.sort:`) if it is not a table, has unknown or missing columns, has a non-boolean `sort` column, or has an `att` value outside `` ` `p`s`g`u ``. It also errors (prefixed `di.sort:`) if `tabname` is not a symbol.

Lookup order for sort parameters within `config`:
1. Rows where `tabname` matches the supplied table name
2. Rows where `tabname = \`default`
3. If neither found — logs a warn and returns `()` without error

Each partition directory is processed independently: a failure on one partition is logged (as an error) and does not halt remaining partitions.

```q
/ single partition
srt.sorttab[config; `trade; enlist `:/hdb/2000.01.01/trade]

/ multiple partitions
srt.sorttab[config; `trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade]
```

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
| `` `readcsv `` | info | CSV read start and row count on successful read |
| `` `readcsv `` | error | File read failure (rethrown after logging) |
| `` `sorttab `` | info | Sort start, params lookup result, column list, sort completion |
| `` `sorttab `` | warn | Table has no matching params and no default row |
| `` `sorttab `` | error | `xasc` failure on a partition (non-fatal — remaining partitions continue) |
| `` `applyattr `` | info | Attribute applied to a column |
| `` `applyattr `` | error | Attribute application failure (non-fatal) |
