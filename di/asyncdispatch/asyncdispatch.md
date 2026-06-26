# asyncdispatch

`asyncdispatch.q` is the async multi-process query coordinator extracted from the TorQ gateway's core engine (`.gw.*`). It queues client queries, dispatches them to available backend ("server") processes, collects the per-server results, applies a join function, and replies to the client — with timeout management and error propagation if a backend disconnects mid-query.

**Standalone value:** any process that needs scatter-gather across multiple backend processes (not just a "gateway") can load this module to get queueing, dispatch, join and timeout handling for free.

**Out of scope** (left to other modules in the gateway decomposition):
- **Routing** — deciding *which* servers satisfy a query is `di.serverselect`'s job. This module is handed a resolved list of servertypes and dispatches to whatever of those is currently idle.
- **Permissions** — `.pm.*`/`execas`/`valp`-style checks belong in `di.gateway`/`di.permissions`.
- **EOD / discovery / dashboard & REST handlers** — `di.gateway` concerns.

---

## Loading

```q
ad:use`di.asyncdispatch
```

Returns a handle (`ad`) exposing the exported API, e.g. `ad.execquery[...]`.

---

## Configuration & pluggable hooks

| Variable | Default | Setter | Purpose |
|---|---|---|---|
| `errorprefix` | `"error: "` | — | Prefix added to error strings sent back to clients |
| `querykeeptime` | `0D00:30` | — | How long `removequeries` keeps finished queries in `queryqueue` |
| `clearinactivetime` | `0D01:00` | — | How long `removeinactive` keeps records for disconnected servers |
| `synccallsallowed` | `0b` | — | Whether `execquery[...;1b]` (sync mode) is permitted |
| `cp` | `{.z.p}` | `setcp` | Current-time function. Override for simulation/backtesting |
| `formatresponse` | see below | `setformatresponse` | Final transform applied to a result/error before it is sent to the client |
| `availableservers` | built-in | `setavailableservers` | How "which servers are free" is computed |
| `getnextqueryid` | `fifo` | `setgetnextqueryid` | Scheduler — picks the next query to dispatch |
| `resultcallback` / `errorcallback` | `` `addserverresult `` / `` `addservererror `` | `setcallbacks` | Symbols backend servers call back into to report results/errors |

### `formatresponse[status;sync;result]`
- `status` — `1b` success, `0b` error.
- `sync` — `1b` if the client used a deferred-sync call (`execquery[...;1b]`), `0b` for async.
- Default: on a synchronous error (`not status` and `sync`), **signals** `result` as an error back up the `-30!` deferred response so the client's sync call raises. Otherwise passes `result` through unchanged.

### `availableservers[excludeinuse]`
- `excludeinuse=1b` → only **idle, active** servers.
- `excludeinuse=0b` → all **active** servers.
- Override for custom load-balancing.

### `getnextqueryid[]` (scheduler)
- Default: oldest runnable query first (FIFO) — a runnable query is one where all required servertypes have an idle server available.
- Override `getnextqueryid` for priority queues. The override receives no arguments and must return a 1-row (or empty) table with the `queryqueue` schema.

### `resultcallback` / `errorcallback`
`serverexecute` (the function sent to backend servers) posts its outcome back via `(resultcallback;queryid;result)` / `(errorcallback;queryid;error)` over `neg .z.w`. Since this module has no fixed namespace path when used standalone, the consumer must point these symbols at wherever it mounted this module on the **backend** processes, e.g.:

```q
ad.setcallbacks[`.gw.dispatch.addserverresult;`.gw.dispatch.addservererror]
```

---

## Core data structures

### `servers` (keyed table, key: `handle`)

| Column | Type | Description |
|---|---|---|
| `handle` | `int` | Connection handle to the backend process |
| `servertype` | `symbol` | e.g. `` `rdb ``, `` `hdb `` |
| `inuse` | `boolean` | Currently running a query |
| `active` | `boolean` | Connected (`0b` once disconnected) |
| `disconnecttime` | `timestamp` | When the server was marked inactive; null while active |

### `queryqueue` (keyed table, key: `queryid`)

| Column | Type | Description |
|---|---|---|
| `queryid` | `long` | Allocated by `addquery` |
| `time` | `timestamp` | When the query was queued |
| `clienth` | `int` | `.z.w` of the requesting client |
| `query` | `()` | The query payload — whatever `value` can execute |
| `servertype` | `()` | List of servertype symbols the query must run on |
| `join` | `()` | Function applied to the collected per-server results |
| `postback` | `()` | `()` for a plain reply, else `(function;extra args...)` to wrap the reply |
| `timeout` | `timespan` | `0Wn` for none |
| `returntime` | `timestamp` | Set by `finishquery` once complete |
| `error` | `boolean` | `1b` if the query ended in error |
| `sync` | `boolean` | `1b` if the client is waiting on a deferred (`-30!`) response |

### `clients` (table)

| Column | Type | Description |
|---|---|---|
| `time` | `timestamp` | Connection time |
| `clienth` | `int` | `.z.w` of the client |
| `user` | `symbol` | `.z.u` |
| `ip` | `int` | `.z.a` |
| `host` | `symbol` | `.z.h` |

### `results` (dict)

`queryid -> (clienth; servertype!(handle;result;received))`

- Keys are the servertype symbols passed to `addquery`.
- Each value is a 3-list: `(handle assigned; result once it arrives; received flag)`.
- A query is complete once every `received` flag is `1b`.
- Entries are removed by `finishquery` once the query completes.

---

## Functions

### Server registry
- **`addserver[handle;servertype]`** — register a backend connection.
- **`availableservers[excludeinuse]`** — query which servers can take work now (see Pluggable hooks).

### Client tracking
- **`addclientdetails[h]`** — call from `.z.po` to record a new client connection in `clients`.
- **`removeclienthandle[h]`** — call from `.z.pc`. Stamps any of that client's unfinished queries as returned/errored and drops their `results` entries.

### Queueing
- **`addquery[query;servertype;join;postback;timeout;sync]`** — low-level: insert a row into `queryqueue`. Does **not** dispatch — call `runnextquery[]` afterwards (or use `execquery` which does both).
- **`removequeries[age]`** — purge `queryqueue` rows with `returntime` older than `age`.

### Scheduling
- **`getnextqueryid[]`** — returns the next runnable query (FIFO by default: oldest query for which all required servertypes have an idle server). Override via `setgetnextqueryid` for priority queues.

### Result collection & joining
- **`addserverresult[qid;data]`** — called when a backend posts back success. Fills slot, frees server, tries to run the next query; once all slots are received applies `join`, sends the reply, and finishes the query.
- **`addservererror[qid;err]`** — called when a backend posts back an error. Sends the error to the client and finishes the query.

### Dispatch
- **`serverexecute[qid;query]`** — **runs on the backend**. Executes `value query`, trapping errors, and posts the outcome back to the dispatcher via `resultcallback`/`errorcallback`.
- **`runnextquery[]`** — picks the next runnable query via `getnextqueryid`, resolves idle servers, and dispatches.

### Timeouts & disconnects
- **`checktimeout[]`** — finds queries past their `timeout` with no `returntime`, sends a timeout error, and finishes them.
- **`removeserverhandle[serverh]`** — call from `.z.pc` for **backend** handles. Errors any in-flight or queued queries that depended on this server, marks the server `active:0b`, and calls `runnextquery[]`.
- **`removeinactive[age]`** — purge `servers` rows that have been inactive for longer than `age`.

### Public API
- **`execquery[query;servertype;join;postback;timeout;sync]`** — queue + dispatch. `sync=0b` for async (uses `postback`); `sync=1b` for deferred sync via `-30!` (`postback` ignored, errors if `synccallsallowed` is `0b`).

### Housekeeping
- **`init[timerrepeat]`** — optionally wires `removequeries`, `checktimeout` and `removeinactive` into a recurring timer. `timerrepeat` should have the signature `.timer.repeat[starttime;endtime;period;(func;params);description]`, or pass `(::)` to skip.

---

## Example usage

```q
/ -- dispatcher process --
ad:use`di.asyncdispatch

/ point backends' callbacks at this module's mount point on this process
ad.setcallbacks[`ad.addserverresult;`ad.addservererror]

/ register backend connections as they connect
h:hopen`:backend1:5001
ad.addserver[h;`rdb]

/ track gateway clients
.z.po:{ad.addclientdetails[.z.w]}
.z.pc:{ad.removeclienthandle[.z.w]; ad.removeserverhandle[.z.w]}

/ a client calls this asynchronously:
ad.execquery["select count i by sym from trade";enlist`rdb;raze;();0Wn;0b]
/ -> queues the query, dispatches it to the rdb, and (once the rdb replies)
/    razes the single result and sends it back to the calling client

/ housekeeping - run periodically (e.g. via di.timer)
ad.checktimeout[]
ad.removequeries[ad.querykeeptime]
ad.removeinactive[ad.clearinactivetime]
```

```q
/ -- backend process --
ad:use`di.asyncdispatch
/ nothing else required: when the dispatcher sends (serverexecute;qid;query),
/ this process runs value query and posts the result/error back via
/ ad.addserverresult / ad.addservererror on the dispatcher
```

---

## Notes

- `.z.M.<name>` is used for in-place mutation of tables (`upsert`/`insert`/`update from`/`delete from`), and `.z.m.<name>:value` for whole-variable reassignment — the same convention used by `di.cache`.
- Module globals referenced inside q-sql expressions (WHERE conditions, UPDATE SET values) must use `.z.m.varname` form, since q-sql evaluates globals in the calling context rather than the module namespace.
- `servertype` on `queryqueue`/`addquery` is deliberately generic: it is a list of servertype symbols used to look up idle servers of each type. Pass the same servertype list to `addserver` and `addquery` to wire them together.
- This module does not open or accept any connections itself — `addserver` and the `.z.po`/`.z.pc` wiring are the consumer's responsibility, by design (keeps this module dependency-free and testable in-process).
