# di.dbwrite

Write, sort, and attribute utilities for kdb+ processes that persist data to disk.

---

## Features

- Write in-memory tables to a date-partitioned HDB with `savedown` — enumerates syms, applies `p#` to `sym`, writes, then sorts
- Append rows to an existing partition with `upsert` — enumerates syms, appends, then re-sorts
- Sort on-disk table partitions by configured columns using `xasc`
- Apply kdb+ attributes (`p`, `s`, `g`, `u`) to on-disk columns after sort
- Sort and attribute behaviour driven by a CSV config file; a `default` row acts as a fallback
- A built-in `default` row in `params` provides an out-of-the-box fallback (sort by `time` ascending) when no config file is loaded
- Run `.Q.gc[]` with before/after memory logging
- All errors from sort, attribute application, and write operations are either caught-and-logged (sort, applyattr) or propagated to the caller (savedown, upsert)

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| `di.log` | `` `log `` | yes | Logging functions `info`, `warn`, `error` — each `{[ctx;msg] ...}` |

The `log` dependency must be passed to `init`. The module throws if it is absent or `(::)`.

---

## Sort config CSV

`loadconfig` reads a CSV with four columns:

| Column | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name, or `` `default `` as a catch-all fallback |
| `att` | symbol | kdb+ attribute to apply: `p`, `s`, `g`, `u`, or empty for none |
| `column` | symbol | Column to sort or attribute |
| `sort` | boolean | `1b` — include in `xasc` sort key; `0b` — attribute only |

Example `sort.csv`:

```
tabname,att,column,sort
trade,p,sym,1
trade,,price,0
quote,p,sym,1
default,,time,1
```

Sorts `trade` by `sym`, applies `p` to `sym`. Tables not listed fall back to `default` and sort by `time`.

---

## Functions

### Summary

| Function | Description |
|---|---|
| `init[config;deps]` | Wire injected dependencies; must be called first |
| `savedown[dir;part;tabname;data]` | Write in-memory table to HDB partition, enumerate syms, apply `p#sym`, then sort |
| `upsert[dir;part;tabname;data]` | Append rows to existing partition, enumerate syms, then re-sort |
| `loadconfig[file]` | Load and validate the sort config CSV into module state |
| `sort[d]` | Sort an on-disk partition and apply attributes per config |
| `applyattr[dloc;colname;att]` | Apply a single kdb+ attribute to an on-disk column |
| `gc[]` | Run `.Q.gc[]` and log before/after memory stats |

---

### `init[config;deps]`

Wires injected dependencies into the module. Must be called before any other function.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `config` | any | Accepted but unused; pass `(::)` |
| `deps` | dict | Must contain `` `log `` → `` `info`warn`error!(infofunc;warnfunc;errfunc) `` |

**Returns** — generic null.

Throws with a descriptive message if the `log` dependency is missing or set to `(::)`.

```q
log:use`di.log
log.init[logconfig]
logdep:`info`warn`error!(log.info;log.warn;log.error)

dbwrite:use`di.dbwrite
dbwrite.init[(::);(enlist`log)!enlist logdep]
```

---

### `savedown[dir;part;tabname;data]`

Writes an in-memory table to a date-partitioned HDB. Enumerates symbol columns against the HDB sym file, applies `p#` to `sym` if present, writes the partition, then calls `sort` to sort and apply attributes per the loaded config.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `dir` | hsym | HDB root directory (e.g. `` `:hdb ``) |
| `part` | date/month/int | Partition value |
| `tabname` | symbol | Table name — determines the partition subdirectory |
| `data` | table | In-memory table to write |

**Returns** — generic null on success; throws on write failure.

If `loadconfig` has not been called, the built-in default row applies (sort by `time` ascending). If the table has no `sym` column, enumeration and `p#` are skipped.

```q
dbwrite.savedown[`:hdb;2024.01.02;`trade;data]
```

---

### `upsert[dir;part;tabname;data]`

Appends rows to an existing on-disk partition then re-sorts. Enumerates symbol columns before appending. The partition must already exist — use `savedown` for the initial write.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `dir` | hsym | HDB root directory |
| `part` | date/month/int | Partition value |
| `tabname` | symbol | Table name |
| `data` | table | Rows to append |

**Returns** — generic null on success; throws if the partition does not exist or on write failure.

```q
dbwrite.upsert[`:hdb;2024.01.02;`trade;latedata]
```

---

### `loadconfig[file]`

Loads and validates the sort configuration CSV, storing the result in module state for use by `sort`.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `file` | hsym | Path to the sort config CSV; pass null (`` ` ``) to warn and reset `params` to the default row |

**Returns** — generic null on success; throws on file/validation failure.

Validation checks that all four required columns (`tabname`, `att`, `column`, `sort`) are present and that all `att` values are within `` ``p`s`g`u ``. Throws a descriptive error for invalid files or unreadable paths.

Passing null warns at `warn` level and resets `params` to the default row — it does not throw.

```q
dbwrite.loadconfig[`:config/sort.csv]
```

---

### `sort[d]`

Sorts an on-disk table partition and applies configured attributes.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `d` | symbol or list | Table name alone, or `(tabname;dir)`, or `(tabname;list of dirs)` — see below |

`d` forms:

| Form | Example |
|---|---|
| Symbol | `` `trade `` |
| Tabname + single dir | `` (`trade;`:hdb/2024.01.02/trade/) `` |
| Tabname + dir list | `` (`trade;`:hdb/2024.01.02/trade/ `:hdb/2024.01.03/trade/) `` |

**Returns** — generic null on success; `()` if no sort config is found for the table.

Config lookup order within the loaded params:
1. Rows where `tabname` matches — used directly.
2. Rows where `tabname = \`default` — used with a `warn` log.
3. No match — warns and returns `()`.

Sort and attribute errors are caught, logged, and swallowed.

```q
dbwrite.sort[(`trade;`:hdb/2024.01.02/trade/)]
```

---

### `applyattr[dloc;colname;att]`

Applies a single kdb+ attribute to an on-disk column.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `dloc` | hsym | On-disk partition directory (e.g. `` `:hdb/2024.01.02/trade/ ``) |
| `colname` | symbol | Column name |
| `att` | symbol | Attribute to apply: `` `p ``, `` `s ``, `` `g ``, or `` `u `` |

**Returns** — generic null on success.

Logs the attempt before applying. On failure, logs the error and continues — does not throw.

```q
dbwrite.applyattr[`:hdb/2024.01.02/trade/;`sym;`p]
```

---

### `gc[]`

Runs `.Q.gc[]` and logs before/after memory statistics.

**Returns** — generic null.

Emits two `info`-level log lines: memory stats before collection, and bytes recovered plus memory stats after.

```q
dbwrite.gc[]
```

---

## Running tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.dbwrite
```

The test suite uses mock logging (no `di.log` dependency required). The mock wires up three no-op counters so log call counts can be asserted:

```q
dbwrite:use`di.dbwrite
logcount:0
loginfo:{[c;m] logcount::logcount+1}
logwarn:{[c;m] logcount::logcount+1}
logerr:{[c;m] logcount::logcount+1}
logdep:`info`warn`error!(loginfo;logwarn;logerr)
deps:(enlist`log)!enlist logdep
dbwrite.init[(::);deps]
```

Tests cover: dependency injection, `init` error on missing log dep, `savedown` write and sort, `savedown` without sym column, `upsert` append and re-sort, `upsert` error on non-existent partition, `sort` with default row fallback / explicit config / `default` row fallback / no-match skip / empty input / wrong type, `loadconfig` with null file / valid file / unrecognised columns / unrecognised attributes / missing file / header-only file, `applyattr` on missing path / null column / invalid attribute / valid path, `gc` log count.

---

## Exported symbols

```q
export:([init;savedown;upsert;sort;applyattr;loadconfig;gc])
```
