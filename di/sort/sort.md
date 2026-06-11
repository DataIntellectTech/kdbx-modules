# di.sort

Library for sorting and applying attributes to on-disk kdb+ tables. Driven by a configuration CSV that specifies which columns to sort and which attributes to apply per table.

## Dependencies

**Injectable (required):**
- `log` — `{[c;m]}` functions for `info`, `warn`, `error`

**Hard:** none

## Init

```q
srt:use`di.sort

/ log only - savedir defaults to `:sort.csv
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srt.init[enlist[`log]!enlist logdep]

/ log + custom sort.csv path
srt.init[`log`savedir!(logdep; `:config/sort.csv)]

/ using a custom logger
mylog:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});
srt.init[`log`savedir!(mylog; `:config/sort.csv)]
```

## Exported Functions

### `init[deps]`

Wire injectable dependencies and optional config. Must be called before any other function.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | `info`, `warn`, `error` functions |
| `` `savedir `` | no | hsym | Path to sort.csv; defaults to `` `:sort.csv `` |

If `params` is empty when `sorttab` is called, it auto-loads from `savedir`.

### `getsortcsv[file]`

Load and validate sort configuration from a CSV file.

| Parameter | Type | Description |
|---|---|---|
| `file` | hsym | Path to sort.csv |

**sort.csv format:**
```
tabname,att,column,sort
trade,p,sym,1
trade,s,time,1
quote,p,sym,1
quote,s,time,1
default,p,sym,1
```

| Column | Description |
|---|---|
| `tabname` | Table name, or `` `default `` to apply to all unlisted tables |
| `att` | Attribute to apply: `` `p`s`g`u `` or `` ` `` for none |
| `column` | Column to sort/attribute, or `` ` `` for no sort |
| `sort` | `1b` to sort by this column, `0b` to only apply attribute |

### `sorttab[d]`

Sort and apply attributes to on-disk partitions for a single table.

| Parameter | Type | Description |
|---|---|---|
| `d` | list | 2-element: `` (`tablename; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade) `` |

Looks up `params` by `tablename`, falls back to `default` row, skips if neither found.

```q
srt.getsortcsv[`:config/sort.csv]
srt.sorttab[(`trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade)]
```

### `getparams[]`

Return the current sort configuration table loaded by `getsortcsv`.

```q
srt.getparams[]
```

## Example

```q
srt:use`di.sort
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)

srt.init[enlist[`log]!enlist logdep]
srt.getsortcsv[`:config/sort.csv]
srt.sorttab[(`trade; `:/hdb/2000.01.01/trade`:/hdb/2000.01.02/trade)]
```
