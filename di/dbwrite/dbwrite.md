# di.dbwrite

Write, sort, and attribute utilities for kdb+ processes that persist data to disk (rdb, wdb, tickerlogreplay).

A **config table** (`tabname`,`att`,`column`,`sort`) drives which columns are sorted and which attributes are applied per table. Load it once with `readcsv` (from a CSV) or `setconfig` (from an in-memory table); `sort` and `savedown` read from module state automatically. A table with no explicit entry falls back to a `default` row; if no config has been loaded, the built-in default (sort every table by `time` ascending) applies.

---

## Features

- Write an in-memory table to a date-partitioned HDB with `savedown` — enumerates syms, writes, sorts per stored config, then runs `.Q.gc[]`
- Append rows to an existing partition with `appenddown` — enumerates syms and appends; sort separately when the partition is complete
- Sort on-disk table partitions by configured columns using `xasc`, then apply kdb+ attributes (`p`,`s`,`g`,`u`)
- Config loaded once via `readcsv` (from a CSV) or `setconfig` (from a table); inspectable at any time with `getconfig`
- Sort and attribute errors are caught-and-logged (a single partition failure does not halt the run); config and write errors are raised to the caller with a `di.dbwrite:` prefix

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | Functions `info`,`warn`,`error` — each binary `{[c;m] ...}` (context symbol, message string) |

The `log` dependency must be passed to `init`. The module throws if it is absent, `(::)`, or missing any of the three keys. The `log` value must **already** be a binary `` `info`warn`error!{[c;m]} `` dict — each function takes a context symbol `c` (the calling function) and a message string `m`. `init` performs **no** adaptation and fans the dict out into `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`. Build it from `di.log` (which exports binary `info`/`warn`/`error`) or hand-roll one; a raw monadic [`kx.log`](https://github.com/KxSystems/logging) instance must be wrapped by the caller first — the module will not do it.

```q
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)
dbwrite:use`di.dbwrite
dbwrite.init[enlist[`log]!enlist logdep]

/ a raw kx.log instance is monadic - wrap it to binary {[c;m]} before passing:
/   loginst:(use`kx.log)[`createLog][]
/   `info`warn`error!({[c;m]loginst[`info][string[c],": ",m]};…)
```

---

## The config table

| Column | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name, or `` `default `` as a catch-all fallback |
| `att` | symbol | Attribute applied after sort: `p`,`s`,`g`,`u`, or empty (`` ` ``) for none |
| `column` | symbol | Column to sort and/or attribute |
| `sort` | boolean | `1b` — include in the `xasc` sort key; `0b` — attribute only |

Build it directly and load with `setconfig`, or read it from a CSV with `readcsv`. A CSV must have exactly the four columns `tabname,att,column,sort` in **any** order (the result is normalised to canonical order); a missing, extra, or misnamed column raises a clear `di.dbwrite:` error rather than silently mis-parsing.

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
| `readcsv[file]` | Read a config CSV and store it in module state |
| `setconfig[t]` | Store a hand-built config table in module state |
| `getconfig[]` | Return the currently stored config (`::` if not yet set) |
| `sort[tabname;dirs]` | Sort on-disk partition(s) for a table and apply attributes per stored config |
| `savedown[dir;part;tabname;data]` | Write an in-memory table to an HDB partition, sort it, then run gc |
| `appenddown[dir;part;tabname;data]` | Append rows to an existing partition (no sort) |
| `applyattr[dloc;colname;att]` | Apply a single kdb+ attribute to an on-disk column |

---

### `init[deps]`

Wire injected dependencies. Must be called before any other function. Also resets the stored sort config to `(::)`.

| Arg | Type | Description |
|---|---|---|
| `deps` | dict | Must contain `` `log `` → `` `info`warn`error!(infofn;warnfn;errfn) `` |

Throws (prefixed `di.dbwrite:`) if `deps` is not a dict, `log` is missing, or the log dict lacks any required key.

---

### `readcsv[file]`

Read a config CSV and store it in module state (equivalent to calling `setconfig` with the parsed result). The stored config is used by subsequent calls to `sort` and `savedown`.

| Parameter | Type | Description |
|---|---|---|
| `file` | symbol/hsym/string | Path to the CSV. Symbols are coerced with `hsym`; strings are converted via `hsym `$`. Errors (`di.dbwrite:`) if not a symbol or string. |

The CSV is parsed field-by-field and fully validated before storing — it does **not** silently pad, truncate, or coerce malformed rows. A clear `di.dbwrite:` error is raised if: the header is not exactly `tabname,att,column,sort` (any order); any data row does not have exactly four fields; any `sort` value is not `0` or `1`; or any `att` value is not in `` ` `p`s`g`u ``. Column order is normalised to canonical.

```q
dbwrite.readcsv `:config/sort.csv
dbwrite.readcsv "config/sort.csv"
```

---

### `setconfig[t]`

Store a hand-built config table in module state. Alternative to `readcsv` when the config is constructed in-session rather than read from a file. Validates the table before storing — throws (`di.dbwrite:`) on any schema or content error.

| Parameter | Type | Description |
|---|---|---|
| `t` | table | Config table with columns `tabname`,`att`,`column`,`sort` |

```q
dbwrite.setconfig ([] tabname:`trade`default; att:`p`; column:`sym`time; sort:11b)
```

---

### `getconfig[]`

Return the currently stored sort config. Returns `(::)` if `init` has been called but neither `readcsv` nor `setconfig` has been called yet.

```q
dbwrite.getconfig[]
```

---

### `sort[tabname;dirs]`

Sort and apply attributes to the on-disk partition(s) for one table, using the config stored by `readcsv` or `setconfig`. Falls back to the built-in default (sort by `time` ascending) if no config has been loaded.

| Parameter | Type | Description |
|---|---|---|
| `tabname` | symbol | Table name. Errors (`di.dbwrite:`) if not a symbol. |
| `dirs` | hsym, or list of hsyms | Partition directory or directories. |

Row lookup: the table's own rows → the `default` row → otherwise a warn is logged and `()` returned. Each partition is processed independently; a failure on one is logged and does not halt the rest.

```q
dbwrite.sort[`trade; (`:hdb/2024.01.02/trade; `:hdb/2024.01.03/trade)]
```

---

### `savedown[dir;part;tabname;data]`

Write an in-memory table to a date-partitioned HDB partition, sort it per the stored config, then run `.Q.gc[]`. Enumerates symbol columns against the HDB sym file before writing. Sorting and attributes are applied by `sort` *after* the write — so an attribute like `p#` is only applied once its column is correctly grouped.

| Parameter | Type | Description |
|---|---|---|
| `dir` | hsym | HDB root directory (e.g. `` `:hdb ``). |
| `part` | date/month/int | Partition value. |
| `tabname` | symbol | Table name — determines the partition subdirectory. |
| `data` | table | In-memory table to write. |

Throws on write failure.

```q
dbwrite.savedown[`:hdb; 2024.01.02; `trade; data]
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
dbwrite.sort[`trade; .Q.par[`:hdb; 2024.01.02; `trade]]
```

---

### `applyattr[dloc;colname;att]`

Apply a single kdb+ attribute to one on-disk column (best-effort: logs and swallows errors so a run continues). A non-attribute `att` (the empty sentinel or any value outside `` `p`s`g`u ``) is a silent no-op.

```q
dbwrite.applyattr[`:hdb/2024.01.02/trade; `sym; `p]
```

---

## Running tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.dbwrite
```

The suite injects binary mock loggers (`{[c;m] ...}`): a no-op logger, and a capturing logger that records `(level;context;msg)` so log behaviour can be asserted. It also wires a real `kx.log` instance (wrapped caller-side into the binary `{[c;m]}` contract) through `init` to confirm the module works end-to-end against the system logger. On-disk behaviour (sort, attributes, `savedown`/`appenddown`) is exercised against real splayed partitions and cleaned up afterwards. It covers: dependency-injection validation; `readcsv` stores-and-verifies / column-order independence / header-validation failures; `setconfig` happy path and validation failures; `sort` edge cases / resolution / on-disk results / multi-dir / non-fatal partition failure; `savedown` write+sort (default and explicit config, and a table without `sym`); `appenddown` append-without-sort then explicit sort, and the non-existent-partition error; `applyattr`; the binary `{[c;m]}` context-tagged logging contract; and the real `kx.log` integration.

---

## Exported symbols

```q
export:([init;readcsv;setconfig;getconfig;sort;applyattr;savedown;appenddown])
```
