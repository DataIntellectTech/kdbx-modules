# di.dbwrite

Write, sort, and attribute utilities for kdb+ processes that persist data to disk (rdb, wdb, tickerlogreplay).

The sorting/attribute engine is `di.sort` baked in directly: a **config table** (`tabname`,`att`,`column`,`sort`) drives which columns are sorted and which attributes are applied per table. You pass that config straight to `sort`/`savedown`; if it lives in a CSV, `readcsv` reads it into the right shape. A table with no explicit entry falls back to a `default` row, and `(::)` selects a built-in default (sort every table by `time` ascending).

`di.dbwrite` holds no sort state of its own — each call takes the config it should use, so you can build that config by hand, from a query, or from a CSV and reuse or vary it freely.

---

## Features

- Write an in-memory table to a date-partitioned HDB with `savedown` — enumerates syms, applies `p#` to `sym`, writes, then sorts per config
- Append rows to an existing partition with `appenddown` — enumerates syms and appends; sort separately when the partition is complete
- Sort on-disk table partitions by configured columns using `xasc`, then apply kdb+ attributes (`p`,`s`,`g`,`u`)
- Config supplied as an in-memory table or read from a CSV (`readcsv`); a `default` row or `(::)` provides a fallback
- Run `.Q.gc[]` with before/after memory logging
- Sort and attribute errors are caught-and-logged (a single partition failure does not halt the run); config and write errors are raised to the caller with a `di.dbwrite:` prefix

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | Functions `info`,`warn`,`error` — each `{[ctx;msg] ...}` |

The `log` dependency must be passed to `init`. The module throws if it is absent, `(::)`, or missing any of the three keys. `di.log` satisfies the contract:

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
dbwrite:use`di.dbwrite
dbwrite.init[enlist[`log]!enlist logdep]
```

---

## The config table

| Column | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name, or `` `default `` as a catch-all fallback |
| `att` | symbol | Attribute applied after sort: `p`,`s`,`g`,`u`, or empty (`` ` ``) for none |
| `column` | symbol | Column to sort and/or attribute |
| `sort` | boolean | `1b` — include in the `xasc` sort key; `0b` — attribute only |

Build it directly, or read it from a CSV with `readcsv`. A CSV must have exactly the four columns `tabname,att,column,sort`, in **any** order (the result is normalised to canonical order); a missing, extra, or misnamed column raises a clear `di.dbwrite:` error rather than silently mis-parsing.

```
tabname,att,column,sort
trade,p,sym,1
trade,,price,0
default,,time,1
```

---

## Functions

| Function | Description |
|---|---|
| `init[deps]` | Wire injected dependencies; must be called first |
| `readcsv[file]` | Read a config CSV and return it as a table |
| `sort[config;tabname;dirs]` | Sort on-disk partition(s) for a table and apply attributes per config |
| `savedown[config;dir;part;tabname;data]` | Write an in-memory table to an HDB partition, then sort it per config |
| `appenddown[dir;part;tabname;data]` | Append rows to an existing partition (no sort) |
| `applyattr[dloc;colname;att]` | Apply a single kdb+ attribute to an on-disk column |
| `gc[]` | Run `.Q.gc[]` and log before/after memory stats |

---

### `init[deps]`

Wire injected dependencies. Must be called before any other function.

| Arg | Type | Description |
|---|---|---|
| `deps` | dict | Must contain `` `log `` → `` `info`warn`error!(infofn;warnfn;errfn) ``. |

Throws (prefixed `di.dbwrite:`) if `deps` is not a dict, `log` is missing, or the log dict lacks any required key.

---

### `readcsv[file]`

Read a config CSV and **return** it as a table (does not store it) — pass the result to `sort` or `savedown`.

| Parameter | Type | Description |
|---|---|---|
| `file` | symbol/hsym | Path to the CSV; coerced with `hsym`. Errors (`di.dbwrite:`) if not a symbol. |

The CSV is parsed field-by-field and validated as it is read — it does **not** silently pad, truncate, or coerce malformed rows. A clear `di.dbwrite:` error is raised if: the header is not exactly `tabname,att,column,sort` (any order); any data row does not have exactly four fields; or any `sort` value is not `0` or `1`. Column order is normalised to canonical. Attribute-value validation happens later in `sort`.

```q
config:dbwrite.readcsv `:config/sort.csv
```

---

### `sort[config;tabname;dirs]`

Sort and apply attributes to the on-disk partition(s) for one table.

| Parameter | Type | Description |
|---|---|---|
| `config` | table, or `::` | Config table (built directly or via `readcsv`). `::` uses the built-in default config. |
| `tabname` | symbol | Table name. Errors (`di.dbwrite:`) if not a symbol. |
| `dirs` | hsym, or list of hsyms | Partition directory (or directories). |

`config` is validated first (errors `di.dbwrite:` if not a table, has unknown/missing columns, a non-boolean `sort`, or an `att` outside `` ` `p`s`g`u ``). Row lookup: the table's own rows → the `default` row → otherwise a warn is logged and `()` returned. Each partition is processed independently; a failure on one is logged and does not halt the rest.

```q
dbwrite.sort[config; `trade; `:/hdb/2024.01.02/trade`:/hdb/2024.01.03/trade]
```

---

### `savedown[config;dir;part;tabname;data]`

Write an in-memory table to a date-partitioned HDB partition, then sort it per `config`. Enumerates symbol columns against the HDB sym file before writing. Sorting **and** attributes are driven entirely by `config` and applied by `sort` *after* the write — so an attribute like `p#` is only applied once its column is grouped (e.g. a config that sorts by `sym` and parts `sym`), never to unsorted data.

| Parameter | Type | Description |
|---|---|---|
| `config` | table, or `::` | Config passed through to `sort` (`::` for the default). |
| `dir` | hsym | HDB root directory (e.g. `` `:hdb ``). |
| `part` | date/month/int | Partition value. |
| `tabname` | symbol | Table name — determines the partition subdirectory. |
| `data` | table | In-memory table to write. |

Throws on write failure. If the table has no `sym` column, enumeration and `p#` are skipped.

```q
dbwrite.savedown[config; `:hdb; 2024.01.02; `trade; data]
```

---

### `appenddown[dir;part;tabname;data]`

Append rows to an existing on-disk partition (enumerates syms); does **not** sort. Keeping sort separate allows multiple intraday appends without re-sorting a growing partition on each call — sort once when the partition is complete.

| Parameter | Type | Description |
|---|---|---|
| `dir` | hsym | HDB root directory. |
| `part` | date/month/int | Partition value. |
| `tabname` | symbol | Table name. |
| `data` | table | Rows to append. |

Throws (prefixed `di.dbwrite:`) if the partition does not exist, or on write failure.

```q
/ intraday: append each batch as it arrives
dbwrite.appenddown[`:hdb; 2024.01.02; `trade; batch]
/ end-of-day: sort once when done
dbwrite.sort[config; `trade; .Q.par[`:hdb;2024.01.02;`trade]]
```

---

### `applyattr[dloc;colname;att]`

Apply a single kdb+ attribute to one on-disk column (best-effort: logs and swallows errors so a run continues). A non-attribute `att` (the empty sentinel or any value outside `` `p`s`g`u ``) is a silent no-op.

```q
dbwrite.applyattr[`:/hdb/2024.01.02/trade; `sym; `p]
```

---

### `gc[]`

Run `.Q.gc[]`, logging memory stats before and after.

---

## Running tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.dbwrite
```

The suite injects mock loggers: a no-op logger, and a capturing logger that records `(level;ctx;msg)` so log behaviour can be asserted. On-disk behaviour (sort, attributes, `savedown`/`appenddown`) is exercised against real splayed partitions and cleaned up afterwards. It covers: dependency-injection validation; `readcsv` returns / column-order independence / header-validation failures; `sort` validation / edge cases / resolution / on-disk results / multi-dir / non-fatal partition failure; `savedown` write+sort (default and explicit config, and a table without `sym`); `appenddown` append-without-sort then explicit sort, and the non-existent-partition error; `applyattr`; `gc`; and the logging contract.

---

## Exported symbols

```q
export:([init;readcsv;sort;applyattr;savedown;appenddown;gc])
```
