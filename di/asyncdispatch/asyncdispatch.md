# di.asyncdispatch

Async scatter-gather query coordinator for kdb-x gateway processes. Queues client queries, dispatches them to available backend processes by servertype, collects per-server results, applies a join function, and replies to the client — with timeout management and correct error propagation if a backend disconnects mid-query.

Routing (deciding which servertypes satisfy a query) is `di.serverselect`'s responsibility. This module receives a resolved servertype list and dispatches to whatever idle backends of each type are registered.

---

## Features

- Queue and dispatch async client queries to multiple backend process types simultaneously (scatter-gather)
- Collect per-server results and apply a caller-supplied join function once all slots are filled
- Timeout expired queries with configurable per-query timespan via `checktimeout`
- Handle backend disconnects mid-query — errors in-flight queries and queued queries that can no longer be satisfied
- Track connected clients and clean up orphaned queries on client disconnect
- Support synchronous deferred response mode (`-30!`) alongside the default async mode
- Accept fully pluggable scheduler (`setgetnextqueryid`), routing (`setavailableservers`), reply formatter (`setformatresponse`), and callback symbols (`setcallbacks`) — swap without touching core dispatch logic
- Detect and normalise `kx.log` instances automatically so callers can pass a logger directly without manual wrapping

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn`, `error` — each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

The `log` dependency must be passed to `init` inside the `deps` dict. The module throws immediately if it is absent or missing any of the three required keys. All three are required since the module calls `info`, `warn`, and `error`.

A `kx.log` instance can be passed directly — the module normalises monadic functions to the binary `{[c;m]}` contract automatically via `normlog`. Context is embedded in the output as `"context: message"`:

```q
kxlog:use`kx.log
ad:use`di.asyncdispatch

// minimal
ad.init[enlist[`log]!enlist kxlog.createLog[]]

// with config overrides
ad.init[`log`querykeeptime`synccallsallowed!(kxlog.createLog[];0D01:00;1b)]
```

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` dependency with any configuration overrides.

| Key | Required | Default | Description |
|---|---|---|---|
| `` `log `` | yes | — | Binary log dep — `info`, `warn`, `error` functions each `{[c;m]}` |
| `` `errorprefix `` | no | `"error: "` | String prepended to all error messages sent back to clients |
| `` `querykeeptime `` | no | `0D00:30` | How long `removequeries` retains finished query rows |
| `` `clearinactivetime `` | no | `0D01:00` | How long `removeinactive` retains disconnected server rows |
| `` `synccallsallowed `` | no | `0b` | Whether `execquery[...;1b]` (deferred sync mode) is permitted |

Housekeeping — `checktimeout`, `removequeries`, `removeinactive`, and `removeclients` — is the caller's responsibility. Wire them into your gateway's timer after `init`. The configured default age parameters are accessible as `querykeeptime` and `clearinactivetime` via module state.

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log dependency and applies config overrides.
```q
ad.init[enlist[`log]!enlist logdep]
```

### `addserver[handle;servertype]`
Register a backend connection. `handle`: open int handle. `servertype`: symbol identifying the process type (e.g. `` `rdb ``, `` `hdb ``).
```q
ad.addserver[hopen`:backend1:5001;`rdb]
```

### `removeserverhandle[handle]`
Call from `.z.pc` for **backend** handles. Errors any in-flight or queued queries that depended on this server, marks the server `active:0b`, and triggers `runnextquery`.
```q
.z.pc:{ad.removeserverhandle[.z.w];ad.removeclienthandle[.z.w]}
```

### `addclientdetails[handle]`
Record client identity on connect. Call from `.z.po`.
```q
.z.po:{ad.addclientdetails[.z.w]}
```

### `removeclienthandle[handle]`
On client disconnect, mark their pending queries errored so result slots are not leaked. Call from `.z.pc`.
```q
.z.pc:{ad.removeserverhandle[.z.w];ad.removeclienthandle[.z.w]}
```

### `addserverresult[qid;data]`
Called when a backend posts back a successful result. Fills the result slot, frees the server, triggers `runnextquery`, and — once all slots for the query are received — applies the join function and replies to the client.
```q
// called by serverexecute on the backend; not typically called directly
```

### `addservererror[qid;err]`
Called when a backend posts back an error. Sends the error to the client and finishes the query.
```q
// called by serverexecute on the backend; not typically called directly
```

### `execquery[query;servertype;join;postback;timeout;sync]`
Public entry point. Validates sync constraints, enqueues the query, and triggers dispatch.

| Argument | Type | Description |
|---|---|---|
| `query` | any | Payload passed to `value` on the backend |
| `servertype` | symbol list | One symbol per required backend type, e.g. `` enlist`rdb `` |
| `join` | function | Applied to the list of per-server results once all are received |
| `postback` | list or `()` | `()` for a plain reply; `(function;extra_args...)` to wrap the reply |
| `timeout` | timespan | `0Wn` for no timeout |
| `sync` | boolean | `1b` for deferred sync via `-30!`; `0b` for async |

```q
ad.execquery["select count i by sym from trade";enlist`rdb;raze;();0Wn;0b]
```

### `execqueryto[replyto;query;servertype;join;postback;timeout;sync]`
Variant of `execquery` with an explicit reply target. Pass `replyto:0Ni` to invoke the postback locally via `value` instead of IPC-sending to a handle. Pass any valid int handle to route the reply to a specific process regardless of `.z.w`. Used when the caller is in the same process as the gateway (e.g. `di.dataaccess` dispatching shards).

| Argument | Type | Description |
|---|---|---|
| `replyto` | int | `0Ni` for local in-process invocation; any int handle to IPC-send to a specific target |
| `query` | any | Payload passed to `value` on the backend |
| `servertype` | symbol list | One symbol per required backend type |
| `join` | function | Applied to the list of per-server results once all are received |
| `postback` | list | Required when `replyto` is `0Ni` — `(function;extra_args...)` invoked locally; `()` permitted for non-local targets |
| `timeout` | timespan | `0Wn` for no timeout |
| `sync` | boolean | Must be `0b` when `replyto` is `0Ni`; sync not supported for local invocation |

```q
// di.dataaccess wiring: shard result delivered locally to da.shardresult
ad.execqueryto[0Ni;shardquery;servertypes;raze;(`da.shardresult;reqid);0Wn;0b]
```

### `checktimeout[]`
Scan the queue for queries past their timeout, send a timeout error to each client, and mark them complete. Wire into your gateway's timer — every few seconds is typical.
```q
// in gateway timer
timer.addjob.default[`asyncdispatch.checktimeout;{ad.checktimeout[]};();5i;1]
```

### `removequeries[age]`
Purge completed `queryqueue` rows older than `age`. Prevents unbounded growth.
```q
// default age is querykeeptime (0D00:30)
timer.addjob.default[`asyncdispatch.removequeries;{ad.removequeries[0D00:30]};();300i;1]
```

### `removeinactive[age]`
Purge `servers` rows for backends that have been disconnected longer than `age`. Prevents unbounded growth.
```q
// default age is clearinactivetime (0D01:00)
timer.addjob.default[`asyncdispatch.removeinactive;{ad.removeinactive[0D01:00]};();300i;1]
```

### `removeclients[age]`
Purge `clients` rows older than `age`. The `clients` table is appended to on every client connect (`addclientdetails`) for audit and is not otherwise pruned, so wire this into the timer to prevent unbounded growth. Choose `age` to match your audit retention requirements.
```q
// retain one day of client audit history
timer.addjob.default[`asyncdispatch.removeclients;{ad.removeclients[1D]};();300i;1]
```

### `setformatresponse[f]`
Override the reply formatter applied before a result or error is sent to the client. `f` must be `{[status;sync;result]}`. Note: `formatresponse` is only applied on the remote IPC path — queries dispatched via `execqueryto` with `replyto:0Ni` invoke the postback directly and bypass this formatter.
```q
ad.setformatresponse[{[status;sync;result]result}]
```

### `setcallbacks[resfn;errfn]`
Update the callback symbols used by `serverexecute`. Required when the module is mounted under a non-default namespace — point these at wherever `addserverresult` and `addservererror` are visible on the backend processes.
```q
ad.setcallbacks[`.gw.dispatch.addserverresult;`.gw.dispatch.addservererror]
```

### `setavailableservers[f]`
Swap in a custom routing strategy. `f` must be `{[excludeinuse]}` returning a table with a `servertype` column.
```q
ad.setavailableservers[{[excl]select from servers where active}]
```

### `setgetnextqueryid[f]`
Inject a custom scheduling strategy. `f` must be niladic and return a 0- or 1-row table with the `queryqueue` schema.
```q
// priority queue example - highest-priority query first
ad.setgetnextqueryid[{1 sublist `priority xdesc 0!select from .z.m.queryqueue where null returntime}]
```

---

## Usage Example

```q
kxlog:use`kx.log
timer:use`di.timer
timer.init[()!()]

ad:use`di.asyncdispatch
ad.init[enlist[`log]!enlist kxlog.createLog[]]

// point backends' callbacks at this module's mount point on this process
ad.setcallbacks[`ad.addserverresult;`ad.addservererror]

// register backend connections as they connect
ad.addserver[hopen`:backend1:5001;`rdb]
ad.addserver[hopen`:backend2:5002;`hdb]

// wire client and server connection/disconnection handlers
.z.po:{ad.addclientdetails[.z.w]}
.z.pc:{ad.removeserverhandle[.z.w];ad.removeclienthandle[.z.w]}

// wire housekeeping into the gateway timer
timer.addjob.default[`asyncdispatch.checktimeout;{ad.checktimeout[]};();5i;1]
timer.addjob.default[`asyncdispatch.removequeries;{ad.removequeries[0D00:30]};();300i;1]
timer.addjob.default[`asyncdispatch.removeinactive;{ad.removeinactive[0D01:00]};();300i;1]
timer.addjob.default[`asyncdispatch.removeclients;{ad.removeclients[1D]};();300i;1]

// a client calls this asynchronously:
// execquery dispatches to rdb and hdb in parallel, razes results, replies to client
ad.execquery[("select count i by sym from trade";"select count i by sym from trade");`rdb`hdb;raze;();0Wn;0b]

// synchronous deferred mode (requires synccallsallowed:1b in deps)
ad.execquery["select count i by sym from trade";enlist`rdb;raze;();0Wn;1b]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.asyncdispatch
```

116 tests. Requires a `q` binary in `PATH` — the test suite starts two real backend processes on dynamically selected free ports and exercises the full dispatch lifecycle over live IPC connections. No TorQ installation or special libraries required. Covers: server registry, FIFO scheduling, full IPC round-trip with join and reply, backend error path via real IPC callback (`addservererror`), join-failure path (throwing join function flagged as error), postback wrapping (`tosend` tuple construction), multi-servertype scatter-gather with two backends dispatched in parallel and results joined, checktimeout, removequeries, removeinactive, removeclients audit-row purge, removeserverhandle with orphaned query cleanup, client tracking, in-flight server release on client disconnect, all pluggable hook setters, and local in-process reply path via `execqueryto` (success, backend error, timeout, and non-null explicit replyto variants).

---

## Notes

- Housekeeping (`checktimeout`, `removequeries`, `removeinactive`, `removeclients`) is the caller's responsibility — the gateway process already has a timer running and is better placed to decide intervals. Wire all four after `init`; see the usage example above
- When `checktimeout` fires for a query that is already in-flight (dispatched to a backend but not yet answered), the client receives the timeout error and the query is marked done, but the backend that received the dispatch remains `inuse:1b` until it eventually replies. A slow-but-alive backend holds its dispatch slot until `addserverresult` or `addservererror` fires; a permanently hung backend holds it until `removeserverhandle` fires on disconnect. Size backend pools and timeouts with this in mind — a run of timeouts against a stuck backend will not free its slot on timeout alone
- `.z.M.<name>` is used for in-place mutation of tables (`upsert`, `insert`, `update from`, `delete from`) and `.z.m.<name>:value` for whole-variable reassignment — the same convention used by `di.cache`
- Module globals referenced inside q-sql expressions (WHERE conditions, UPDATE SET values) must use the `.z.m.varname` form since q-sql evaluates column expressions in the calling context rather than the module namespace
- `servertype` in `queryqueue` and `addquery` is a list of servertype symbols — one per required backend type. Pass `` enlist`rdb `` for single-server queries, `` `rdb`hdb `` for scatter-gather across two types
- `setcallbacks` must be called before any queries are dispatched if the module is mounted under a non-default path — `serverexecute` reads `resultcallback` and `errorcallback` by bare name on the backend process and posts back to whatever symbols they resolve to
- This module opens and accepts no connections itself — `addserver` and the `.z.po`/`.z.pc` wiring are the consumer's responsibility, keeping the module dependency-free and testable in-process
- All three log keys (`info`, `warn`, `error`) are required — the module calls `info` on server/client connect and init, `warn` on disconnect and timeout, and `error` on backend error and join failure
- `execqueryto` with `replyto:0Ni` invokes the postback locally via `value` — the postback head symbol must be mount-qualified (e.g. `` `da.shardresult ``) since bare exported names are not globals. This is the same resolution mechanism used by `setcallbacks`
- Local queries store `clienth:0Ni` and are not matched by `removeclienthandle` — the in-process caller owns disconnect cleanup for its own requests
- `setformatresponse` overrides only apply to the remote IPC path — local invocation via `execqueryto[0Ni;...]` calls the postback directly without applying `formatresponse`. The default `formatresponse` is a pass-through for async, so this is transparent by default; consumers that override it should not combine that with local invocation
