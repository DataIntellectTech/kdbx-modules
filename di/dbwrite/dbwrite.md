# di.dbwrite

Sort, attribute application, save-down manipulation, and garbage-collection utilities for kdb+ processes that persist data to disk (RDB, WDB, TickerLogReplay).

---

## Features

- Sort on-disk table partitions by configured columns using `xasc`
- Apply kdb+ attributes (`p`, `s`, `g`, `u`) to on-disk columns after sort
- Register per-table pre-write manipulation functions applied before save-down
- Run `.Q.gc[]` with before/after memory logging
- Sort and attribute behaviour driven by a CSV config file; a `default` row acts as a fallback
- Built-in `defaultparams` provides an out-of-the-box fallback (sort by `time` ascending) when no config file is loaded
- All errors from sort, attribute application, and manipulation are caught and logged — they do not propagate

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
| `column` | symbol | Column to sort or attribute; empty means attribute-only (no sort contribution) |
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
| `loadconfig[file]` | Load and validate the sort config CSV into module state |
| `sort[d]` | Sort an on-disk partition and apply attributes per config |
| `applyattr[dloc;colname;att]` | Apply a single kdb+ attribute to an on-disk column |
| `manipulate[t;x]` | Apply a registered pre-write manipulation to a table |
| `postreplay[d;p]` | Post-EOD stub; override to add custom logic |
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

### `loadconfig[file]`

Loads and validates the sort configuration CSV, storing the result in module state for use by `sort`.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `file` | hsym | Path to the sort config CSV. Passing a null symbol (`` ` ``) uses the module-level `defaultfile` value |

**Returns** — generic null on success; throws on failure.

Validation checks that all four required columns (`tabname`, `att`, `column`, `sort`) are present and that all `att` values are within `` ``p`s`g`u ``. Throws a descriptive error for invalid files or unreadable paths.

```q
dbwrite.loadconfig[`:config/sort.csv]
```

> **Note:** `defaultfile` is a module-level variable (default: null symbol). Set it in `init.q` to configure a path that `sort` will auto-load on first use. If no explicit `loadconfig` call is made and `defaultfile` is not set, `sort` falls back to `defaultparams` automatically.

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

If `params` is empty when `sort` is called, it is auto-populated before the lookup:
1. If `defaultfile` is set, `loadconfig[defaultfile]` is attempted (errors are swallowed).
2. If `params` is still empty after that, the built-in `defaultparams` is used — a single `default` row that sorts by `time` ascending with no attribute.

Config lookup order within `params`:
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

### `manipulate[t;x]`

Applies a registered pre-write manipulation to table `x` of type `t`.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `t` | symbol | Table name used to look up the registered manipulation function |
| `x` | table | Table data to transform |

**Returns** — modified table, or original table unmodified if no manipulation is registered or the function throws.

Manipulations are registered in the module-internal `savedownmanipulation` dictionary (`` tabname → unary function ``). This dictionary is module-bound and populated by process initialisation code before EOD.

```q
data:dbwrite.manipulate[`trade;data]
```

---

### `postreplay[d;p]`

Post-EOD stub called after all tables have been written and sorted.

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `d` | hsym | HDB directory |
| `p` | date | Partition value |

**Returns** — generic null.

This is a no-op by default. Override at the call site to add custom post-replay logic.

```q
dbwrite.postreplay[`:hdb;2024.01.02]
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

Tests cover: dependency injection, `loadconfig` validation, `applyattr` on valid and missing paths, `sort` with explicit config / `defaultparams` fallback when no config is loaded / `default` row fallback / no-config skip, `manipulate` pass-through, and `postreplay` stub.

---

## Exported symbols

```q
export:([init;sort;applyattr;loadconfig;manipulate;postreplay;gc])
```
