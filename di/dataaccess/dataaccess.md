# dataaccess

`dataaccess.q` is the data access query layer in the TorQ gateway decomposition. It accepts a client query with a time range, routes it to the appropriate process types based on which partitions they cover, splits the query across those shards to avoid time-range overlap, and reduces the results back to the client via a user-supplied join function.

**Standalone value:** any gateway-style process that needs to fan queries across time-partitioned backends (rdb, hdb, etc.) can load this module to get routing, query splitting, scatter-gather, and map-reduce aggregation without reimplementing them.

**Out of scope:**
- **Execution** — dispatching to backend processes is `di.asyncdispatch`'s job; this module calls `dispatch.execquery`.
- **Routing** — deciding which server types cover which date ranges is `di.serverselect`'s job; this module calls `getrouting` (currently a stub, see below).
- **Permissions** — belong in `di.gateway`/`di.permissions`.

---

## Loading

```q
da:use`di.dataaccess
```

---

## Dependencies

| Dep | How to wire |
|---|---|
| `di.asyncdispatch` | `da.setdispatch[ad]` where `ad:use\`di.asyncdispatch` |
| `di.serverselect` | `da.setgetrouting[ss.getrouting]` and `da.setbuildshardquery[ss.buildshardquery]` *(once available)* |

---

## Configuration & pluggable hooks

| Variable | Default | Setter | Purpose |
|---|---|---|---|
| `requestkeeptime` | `0D00:30` | — | How long `removerequests` retains completed rows in `requests` |
| `synccallsallowed` | `0b` | — | Whether `execquery[...;1b]` (deferred sync) is permitted |
| `cp` | `{.z.p}` | `setcp` | Current-time function — override for simulation/backtesting |
| `dispatch` | `(::)` | `setdispatch` | Handle to a loaded `di.asyncdispatch` instance |
| `logfn` | stderr | `setlogfn` | Logging function `{[lvl;msg]}` |
| `shardresultcallback` | `` `shardresult `` | `setshardcallbacks` | Symbol asyncdispatch postbacks resolve to for shard success |
| `sharderrorcallback` | `` `sharderror `` | `setshardcallbacks` | Symbol asyncdispatch postbacks resolve to for shard errors |
| `getrouting` | stub | `setgetrouting` | `{[starttime;endtime]}` — returns routing table (see below) |
| `buildshardquery` | stub | `setbuildshardquery` | `{[query;starttime;endtime]}` — injects time range into query |

### `getrouting[starttime;endtime]` (di.serverselect stub)
Returns a table `([] servertype:`symbol$(); starttime:`timestamp$(); endtime:`timestamp$())`. Each row is one shard: the process type to dispatch to, and the time range it covers. Multiple rows with the same `servertype` produce multiple dispatches to that type (useful when several hdb processes each cover a different date range).

**Stub behaviour:** returns a single row `(hdb; starttime; endtime)` — i.e. routes everything to a single hdb without splitting.

Replace via `setgetrouting` once `di.serverselect` is available:
```q
da.setgetrouting[ss.getrouting]
```

### `buildshardquery[query;starttime;endtime]`
Given the user query and a shard's time range, returns the modified sub-query with appropriate date/time filters applied. The real implementation (in `di.serverselect`) will modify the functional form's where clause.

**Stub behaviour:** returns `query` unchanged.

Replace via `setbuildshardquery`:
```q
da.setbuildshardquery[ss.buildshardquery]
```

### `shardresultcallback` / `sharderrorcallback`
`submitshards` passes these symbols as the `postback` to `dispatch.execquery`. When asyncdispatch delivers a shard result, it sends `(shardresultcallback;reqid;result)` to this process's local handle, which evaluates to `shardresult[reqid;result]`.

After mounting, update these to match the module's path on the gateway process:
```q
da.setshardcallbacks[`da.shardresult;`da.sharderror]
```

---

## Core data structures

### `requests` (keyed table, key: `requestid`)

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

### `shardresults` (dict)

`requestid -> list of shard results`

Populated one entry at a time by `shardresult`. Removed immediately by `finishrequest` once all shards are joined and the reply is sent. The `requests` table row is retained for `requestkeeptime` for audit purposes.

---

## Functions

### Public
- **`execquery[query;starttime;endtime;joinfn;postback;timeout;sync]`** — main entry point. Routes the query, builds per-shard sub-queries, submits each to `dispatch.execquery`, and (when all shards reply) reduces with `joinfn` and replies to the client.
- **`shardresult[reqid;result]`** — shard success callback. Called by asyncdispatch via postback when a shard completes. Accumulates the result and triggers join once all shards are in.
- **`sharderror[reqid;err]`** — shard error callback. Short-circuits the request, sends the error to the client, and stamps the request as errored.

### Routing stubs (replace with di.serverselect)
- **`getrouting[starttime;endtime]`** — see above.
- **`buildshardquery[query;starttime;endtime]`** — see above.

### Housekeeping
- **`removerequests[age]`** — purge `requests` rows with `returntime` older than `age`.
- **`init[timerrepeat]`** — wire `removerequests` into a recurring timer. Pass `(::)` to skip. `timerrepeat` signature: `.timer.repeat[starttime;endtime;period;(func;params);description]`.

---

## Example usage

```q
/ -- gateway process --
ad:use`di.asyncdispatch
da:use`di.dataaccess

/ wire dependencies
da.setdispatch[ad]
da.setshardcallbacks[`da.shardresult;`da.sharderror]
ad.setcallbacks[`ad.addserverresult;`ad.addservererror]

/ register backend connections
ad.addserver[hopen`:hdb1:5001;`hdb]
ad.addserver[hopen`:rdb1:5002;`rdb]

/ wire connection handlers
.z.po:{ad.addclientdetails[.z.w]}
.z.pc:{ad.removeclienthandle[.z.w]; ad.removeserverhandle[.z.w]}

/ a client query spanning rdb and hdb - once di.serverselect is wired,
/ getrouting will split this into two shards automatically
da.execquery["select count i by sym from trade";
             2000.01.01D00:00:00.000000000;
             .z.p;
             raze;    / join: raze the two result tables together
             ();      / no postback wrapping
             0Wn;     / no timeout
             0b]      / async

/ housekeeping (e.g. via di.timer)
da.removerequests[da.requestkeeptime]
```

---

## Notes

- Each shard is submitted to `dispatch.execquery` as an independent async query (`sync:0b`). The per-shard asyncdispatch join is `first` (unwraps the single-element result list). The user-supplied `joinfn` is applied by dataaccess across the full list of shard results.
- `shardresult` and `sharderror` guard against late or duplicate deliveries via the `returntime` null check. Once a request is finished, further callbacks for that `requestid` are silently dropped.
- The first shard error short-circuits the whole request. Any subsequently-delivered shard results are ignored.
- `getrouting` and `buildshardquery` are thin stubs that will be replaced by `di.serverselect`. All other module logic (accumulation, join, dispatch wiring) is independent of the routing implementation.
