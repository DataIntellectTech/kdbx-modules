# `grafana.q` – Grafana JSON datasource adaptor for kdb-x

A library that lets a [Grafana](https://grafana.com/) server query a kdb+
process directly, using the
[SimPod JSON datasource](https://github.com/simPod/GrafanaJsonDatasource) API.

Once initialised, the module installs HTTP handlers on the process so that
requests carrying the `X-Grafana-Org-Id` header are intercepted and answered
with Grafana-shaped JSON, while all other HTTP requests fall through to any
existing handler. Point a SimPod JSON datasource at the process's HTTP port and
its tables become available as Grafana panels.

---

## :sparkles: Features

- Serves the `/search` endpoint – populates Grafana's metric dropdowns from the
  tables in the process.
- Serves the `/query` endpoint – returns either **timeseries** or **table**
  panel data.
- Answers the Grafana test-connection `GET` with a `200 OK`.
- Wraps any pre-existing `.z.pp`/`.z.ph` handlers rather than overwriting them.
- No connection to other modules required – loads standalone with an injected
  logger.

---

## :inbox_tray: Import

```q
q)grafana:use`di.grafana
```

Only `init` is exported; everything else runs automatically via the installed
HTTP handlers.

---

## :electric_plug: Dependencies

| Dependency | Required | Description |
|---|---|---|
| `log` | yes | A dictionary of `` `info`warn`error `` logging functions, each with the `{[c;m]}` signature (context symbol; message string). |

The logger is **mandatory** – `init` errors immediately if it is not supplied.
A ready-made logger can be taken from `di.log`, or you can pass your own:

```q
/ custom logger
mylog:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});
```

### Handler wiring

`init` installs the adaptor by closure-wrapping the process's `.z.pp` (POST) and
`.z.ph` (GET) callbacks: it captures any pre-existing handler, then installs a
wrapper that routes Grafana requests (those carrying the `X-Grafana-Org-Id`
header) to the adaptor and **falls through to the captured handler for
everything else** — so adding the module to a process that already serves HTTP
does not break existing endpoints. This follows the `di.timer` precedent of a
module owning a `.z.*` callback as its core mechanism.

The intended end-state under the modularisation guide is to register these
through the injected `di.handlers` dependency rather than assigning `.z.*`
directly. That migration is deferred until `di.handlers` exists and supports
**return-yielding** handler chains — `.z.pp`/`.z.ph` must *return* the HTTP
response and conditionally defer, which a side-effect-only chain cannot express.
`di.handlers` is not implemented on any branch yet.

---

## :gear: Configuration

Configuration is optional and passed to `init` under the `config` key. Any
omitted value keeps its default.

| Key | Type | Default | Description |
|---|---|---|---|
| `timecol` | symbol | `` `time `` | Name of the time column used for timeseries queries. |
| `sym` | symbol | `` `sym `` | Name of the column used to split data by instrument. |
| `timebackdate` | timespan | `2D` | How far back to look when finding distinct syms for the dropdowns. |
| `ticks` | long | `1000` | Number of rows returned for a table request. |
| `del` | char | `"."` | Delimiter separating the arguments within a query target. |

---

## :memo: Initialisation

`init` takes a single dictionary of dependencies (and optional config), then
installs the HTTP handlers. The handlers are installed only once, so `init` may
be called again to update the logger or configuration without re-wrapping.

```q
/ logger only, defaults for everything else
q)grafana.init[enlist[`log]!enlist mylog]

/ logger plus configuration overrides
q)grafana.init[`log`config!(mylog;`timecol`ticks!(`ts;500))]
```

---

## :wrench: Exported functions

### `init`

```
init[deps]
```

- `deps` – a dictionary, one of:
  - `` enlist[`log]!enlist logdict `` – inject the logger, use config defaults.
  - `` `log`config!(logdict;configdict) `` – inject the logger and override config.
- `logdict` – `` `info`warn`error `` ! three `{[c;m]}` functions (required).
- `configdict` – any subset of the keys in the [configuration](#gear-configuration) table.

Errors if no logger is supplied. Returns nothing; its effect is wiring the
logger, applying configuration, and installing the `.z.pp`/`.z.ph` handlers.

---

## :mag: Query target syntax

The Grafana metric strings produced by `/search` encode the table, panel type
and arguments, separated by `del` (default `"."`):

| Prefix | Meaning |
|---|---|
| `t.<table>` | table panel for the whole table |
| `t.<table>.<sym>` | table panel filtered to one sym |
| `g.<table>` | graph panel, one series per numeric column |
| `g.<table>.<col>` | graph panel, one series per sym for a column |
| `o.<table>...` | "other" panels (single-stat, gauge, etc.) |
| `f.<...>` | the target is a function call rather than a table |

---

## :rocket: Example usage

```q
q)grafana:use`di.grafana
q)log:use`di.log                       / or define your own logger
q)grafana.init[enlist[`log]!enlist `info`warn`error!(log.info;log.warn;log.error)]

q)trade:([]time:.z.p-0D00:00:01*til 100;sym:100#`a`b`c;price:100?100f)
```

Add a SimPod JSON datasource in Grafana pointing at this process's HTTP port,
then build panels using the metrics offered in the dropdowns (`t.trade`,
`g.trade.price`, …).

---

## :test_tube: Tests

Tests are written for k4unit and run with:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.grafana
```
