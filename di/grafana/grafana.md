# di.grafana

Grafana JSON datasource adaptor for kdb+. Implements the
[SimPod JSON datasource](https://github.com/simPod/GrafanaJsonDatasource) API so
a Grafana server can query a kdb+ process directly: the module installs HTTP
handlers that answer Grafana's `/search` and `/query` requests with the JSON it
expects, serving the process's tables as timeseries and table panels.

---

## Features

- Serves the `/search` endpoint - populates Grafana's metric dropdowns from the tables in the process
- Serves the `/query` endpoint - returns either timeseries or table panel data
- Answers the Grafana test-connection `GET` with a `200 OK`
- Wraps any pre-existing `.z.pp`/`.z.ph` handlers rather than overwriting them, so other HTTP endpoints keep working
- Accepts a `kx.log` instance directly, or a plain `info`warn`error` dict
- Loads standalone - no hard dependencies on other modules

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn`, and `error` - each a binary `{[c;m]}` where `c` is a symbol context and `m` is a string. All three are required because this module calls all three. |

**Hard dependency:** none - the module loads standalone.

The `log` dependency must be passed to `init` inside the `deps` dict keyed on
`` `log ``. The module throws immediately if `log` is absent, is not a
dictionary, or is missing any of `info`/`warn`/`error`.

A `kx.log` instance can be passed directly - the module normalises its monadic
functions to the binary `{[c;m]}` contract automatically (detected by the
`getlvl`/`sinks`/`fmts` keys). Plain `info`warn`error` dicts pass through
unchanged.

```q
/ plain custom logger
mylog:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});
grafana:use`di.grafana
grafana.init[enlist[`log]!enlist mylog]

/ or a kx.log instance directly
kxlog:use`kx.log
grafana.init[enlist[`log]!enlist kxlog.createLog[]]
```

Configuration keys `timecol`, `sym`, `timebackdate`, `ticks`, `del`, and
`allowfunctions` are all optional - omit any or all of them and the module falls
back to sensible defaults. See Initialisation for full details.

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` dependency with any
configuration overrides.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep - `info`/`warn`/`error` `{[c;m]}` functions, or a `kx.log` instance |
| `` `timecol `` | no | Name of the time column used for timeseries queries. Default: `` `time `` |
| `` `sym `` | no | Name of the column used to split data by instrument. Default: `` `sym `` |
| `` `timebackdate `` | no | How far back to look when finding distinct syms for the dropdowns. Default: `2D` |
| `` `ticks `` | no | Number of rows returned for a table request. Default: `1000` |
| `` `del `` | no | Delimiter separating the arguments within a query target. Default: `"."` |
| `` `allowfunctions `` | no | Enable `f.` function targets, which evaluate arbitrary q (see Security note). Default: `0b` (disabled) |

`init` must be called before the module will serve any requests. It validates
the logger, applies config, and installs the `.z.pp`/`.z.ph` handlers - once;
re-calling `init` updates the logger/config without re-wrapping the handlers.

```q
/ defaults only
grafana.init[enlist[`log]!enlist logdep]

/ with config overrides (config keys sit alongside `log)
grafana.init[`log`timecol`ticks!(logdep;`ts;500)]
```

---

## Exported Functions

### `init[deps]`
Initialise the module: validate the log dependency, apply config, and install the HTTP handlers. Errors immediately if `log` is missing, is not a dict, or lacks `info`/`warn`/`error`.
```q
grafana.init[enlist[`log]!enlist logdep]
/ or with config:
grafana.init[`log`ticks!(logdep;500)]
```

### `getconfig[]`
Return the currently active configuration as a dictionary - useful for confirming how the running module is tuned.
```q
grafana.getconfig[]
/ `timecol`sym`timebackdate`ticks`del!(`time;`sym;2D;1000;".")
```

---

## Query target syntax

The Grafana metric strings produced by `/search` encode the table, panel type,
and arguments, separated by `del` (default `"."`):

| Target | Meaning |
|---|---|
| `t.<table>` | table panel for the whole table |
| `t.<table>.<sym>` | table panel filtered to one sym |
| `g.<table>` | graph panel, one series per numeric column |
| `g.<table>.<col>` | graph panel, one series per sym for a column |
| `o.<table>...` | "other" panels (single-stat, gauge, etc.) |
| `f.<...>` | the target is a q expression to evaluate rather than a table - **disabled unless `allowfunctions` is set** (see Security) |

---

## Usage Example

```q
/ load and initialise with a printing logger
mylog:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});

grafana:use`di.grafana
grafana.init[enlist[`log]!enlist mylog]

/ open an HTTP port and create some data with time + sym columns
\p 5000
trade:([]time:.z.p-0D00:00:01*til 100;sym:100?`AAPL`MSFT`GOOG;price:100?100f)
```

Add a SimPod JSON datasource in Grafana pointing at the process's HTTP port,
then build panels using the metrics offered in the dropdowns (`t.trade`,
`g.trade.price`, ...).

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.grafana
```

The suite injects a no-op mock logger and covers: the export surface; dependency
validation (non-dict deps, missing `log` key, null log value, missing log keys);
handler wiring and the install-once `wired` guard; config defaults and overrides
via `getconfig`; the target-parsing helpers (`isfunc`/`istab`/`istype`/`prefix`);
`finddistinctsyms`/`memvals`/`catchvals`; the `/query` table and timeseries
builders (`tbfunc`, and `tsfunc` including the per-column and per-sym graph
paths); the live `.z.pp`/`.z.ph` routes including non-Grafana fall-through; and a
`kx.log` integration test confirming the `normlog` wrapping works end-to-end.

---

## Security

The module answers any HTTP request carrying the `X-Grafana-Org-Id` header, so
treat its port as a trust boundary - put it behind Grafana's authentication and
firewall it from untrusted networks.

- **Table targets are resolved by name, never evaluated.** `t.`/`g.`/`o.` and
  bare targets are looked up as symbols against `tables[]`; an unknown name is
  rejected. A target string can therefore never be executed as q code through
  these paths.
- **`f.` function targets evaluate arbitrary q and are disabled by default.**
  They run only when `allowfunctions` is set to `1b` in `init`. Enable it solely
  on processes where every client able to reach the port is trusted, since an
  `f.` target is, by design, remote code execution.

---

## Notes

- The module installs `.z.pp`/`.z.ph` by closure-wrapping any pre-existing handler: Grafana requests (those carrying the `X-Grafana-Org-Id` header) are routed to the adaptor, and every other request falls through to the captured handler - so adding the module to a process that already serves HTTP does not break existing endpoints. This follows the `di.timer` precedent of a module owning a `.z.*` callback.
- The intended end-state is to register the handlers through an injected `di.handlers` dependency rather than assigning `.z.*` directly. That is deferred until `di.handlers` exists and supports return-yielding `.z.pp`/`.z.ph` chains - a side-effect-only chain cannot return the HTTP response. `di.handlers` is not implemented yet.
- A panel with multiple queries works: each target in the request is dispatched by its own type and the per-target results are merged into one JSON array
- Table panels return the last `ticks` rows (default 1000); raise `ticks` via config if a panel needs more
- Sym dropdowns list only syms seen within `timebackdate` (default 2 days)
- Data tables must expose the configured `timecol` and `sym` columns (defaults `` `time ``/`` `sym ``)
- The `/annotations` endpoint returns a "not yet implemented" marker, matching the TorQ original
