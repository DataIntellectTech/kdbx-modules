# dataaccess

`di.dataaccess` is the data access query layer in the TorQ gateway decomposition. It accepts a client query with a time range, routes it to the appropriate process types based on which partitions they cover, splits the query across those shards to avoid time-range overlap, and reduces the results back to the client via a user-supplied join function.

**Standalone value:** any gateway-style process that needs to fan queries across time-partitioned backends (rdb, hdb, etc.) can load this module to get query splitting, scatter-gather and map-reduce aggregation without reimplementing them.

**Out of scope:**
- **Execution** — dispatching to backend processes is `di.asyncdispatch`'s job; this module calls `asyncdispatch.execquery`.
- **Routing** — deciding which server types cover which date ranges is `di.serverselect`'s job; this module calls `serverselect.getrouting` / `serverselect.buildshardquery`.
- **Permissions** — belong in `di.gateway` / `di.permissions`.

---

## Loading

```q
da:use`di.dataaccess
```

Loading the module pulls in its two **hard dependencies** (`di.asyncdispatch`, `di.serverselect`) via `use`, so both must be resolvable on `QPATH`.

---

## Dependencies

### Hard dependencies (resolved via `use` at load)

| Dep | Used for | Assumed contract |
|---|---|---|
| `di.asyncdispatch` | dispatching each shard query | `execquery[query;servertypes;joinfn;postback;timeout;sync]` |
| `di.serverselect` | routing + per-shard query rewriting | `getrouting[starttime;endtime]` → routing table; `buildshardquery[query;starttime;endtime]` → rewritten sub-query |

> The exact `execquery` / `getrouting` / `buildshardquery` signatures above are this module's **assumed** contract and should be reconciled once `di.asyncdispatch` / `di.serverselect` land.

### Injected dependencies (passed to `init`)

All injectables are passed in a single `deps` dictionary. **`log` and `timer` are required** — `init` errors immediately if either is missing or malformed. There is no silent fallback.

| Key | Required | Default | Purpose |
|---|---|---|---|
| `log` | ✅ | — | `kx.log` instance, or a binary `` `info`warn`error!{[c;m]} `` dict |
| `timer` | ✅ | — | `di.timer` instance; `init` uses `addjob` to schedule housekeeping |
| `cp` | — | `{.z.p}` | current-time function (override for simulation / backtesting) |
| `synccallsallowed` | — | `0b` | whether `execquery[...;1b]` (deferred sync) is permitted |
| `requestkeeptime` | — | `0D00:30` | how long completed `requests` rows are retained before purge |
| `resultcallback` | — | `` `shardresult `` | postback symbol that `asyncdispatch` resolves to for shard success |
| `errorcallback` | — | `` `sharderror `` | postback symbol that `asyncdispatch` resolves to for shard errors |

After mounting the module under a path (e.g. `da`), set `resultcallback` / `errorcallback` to that path's exported callbacks so async postbacks resolve correctly, e.g. `` `da.shardresult `` / `` `da.sharderror ``.

---

## Core data structures

### `requests` (keyed table, key: `requestid`) — `.z.m.requests`

| Column | Type | Description |
|---|---|---|
| `requestid` | `long` | Auto-incremented per `execquery` call |
| `time` | `timestamp` | When the request was submitted |
| `clienth` | `int` | `.z.w` of the requesting client |
| `remaining` | `long` | Number of shard results still outstanding |
| `joinfn` | `()` | Map-reduce join function applied to the list of shard results |
| `postback` | `()` | `()` for a plain reply; `(fn;args...)` to wrap before sending |
| `timeout` | `timespan` | `0Wn` for none (passed to asyncdispatch per shard) |
| `returntime` | `timestamp` | Set by `finishrequest` once complete; null while in-flight |
| `error` | `boolean` | `1b` if the request ended in error |
| `sync` | `boolean` | `1b` if the client is waiting on a deferred (`-30!`) response |

### `shardresults` (dict) — `.z.m.shardresults`

`requestid -> list of shard results`. Populated one entry at a time by `shardresult`, removed by `finishrequest` once all shards are joined and the reply is sent. The `requests` row is retained for `requestkeeptime` for audit.

---

## Functions (export)

- **`init[deps]`** — wire injectables and optional config (see table above), then schedule recurring request housekeeping on the injected timer. **Must be called before any other function.**
- **`execquery[query;starttime;endtime;joinfn;postback;timeout;sync]`** — main entry point. Routes the query, builds per-shard sub-queries, submits each to `asyncdispatch.execquery`, and (when all shards reply) reduces with `joinfn` and replies to the client.
- **`shardresult[reqid;result]`** — shard success callback. Invoked by asyncdispatch via postback when a shard completes; accumulates the result and triggers the join once all shards are in.
- **`sharderror[reqid;err]`** — shard error callback. Short-circuits the request, logs the error, sends it to the client, and stamps the request as errored.
- **`removerequests[age]`** — purge `requests` rows whose `returntime` is older than `age`. Wired onto the injected timer by `init`; also callable manually.

Internal helpers (`checkresults`, `sendreply`, `finishrequest`, `submitshards`, `normlog`, `raiseerror`, `getopt`) are **not** exported.

---

## Example usage

```q
/ -- gateway process --
da:use`di.dataaccess

/ build the required log dependency from kx.log (pass the WHOLE instance)
logger:use`kx.log
loginst:logger.createLog[]

/ the injected timer
tmr:use`di.timer
tmr.init[(::)]

/ init: log + timer required; point the callbacks at the mounted path
da.init[`log`timer`resultcallback`errorcallback!(loginst;tmr;`da.shardresult;`da.sharderror)]

/ a client query spanning rdb and hdb - di.serverselect splits it into shards automatically
da.execquery["select count i by sym from trade";
             2000.01.01D00:00:00.000000000;
             .z.p;
             raze;    / join: raze the shard result tables together
             ();      / no postback wrapping
             0Wn;     / no timeout
             0b]      / async
```

---

## Notes

- Each shard is submitted to `asyncdispatch.execquery` as an independent async query (`sync:0b`). The per-shard asyncdispatch join is `first` (unwraps the single-element result list); the user-supplied `joinfn` is applied by dataaccess across the full list of shard results.
- `shardresult` and `sharderror` guard against late or duplicate deliveries via the `returntime` null check. Once a request is finished, further callbacks for that `requestid` are silently dropped.
- The first shard error short-circuits the whole request; any subsequently-delivered shard results are ignored.
- All mutable state lives on `.z.m` (`.z.m.requests`, `.z.m.shardresults`, `.z.m.requestid`, etc.); the module declares no namespaces and never assigns `.z.M`.
- Domain errors are routed through an internal log-then-signal helper, so failures appear in the injected log as well as being thrown. The only exception is `init`'s own dependency validation, which signals plainly because the logger is not yet wired.
