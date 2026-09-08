# di.asyncdispatch

Async scatter-gather query coordinator for kdb-x gateway processes. Queues client queries, dispatches them to available backend processes by servertype, collects per-server results, applies a join function, and replies to the client — with timeout management and correct error propagation if a backend disconnects mid-query.

Routing (deciding which servertypes satisfy a query) is `di.serverselect`'s responsibility, but **`di.serverselect` is not a dependency** — this module dispatches a resolved servertype list to whatever backends its *server source* reports. That source is pluggable with a default: by default it is asyncdispatch's own registry (populate it with `addserver`), or you point it at `di.serverselect`'s output via `setavailableservers`. Either works standalone; neither is required.

---

## Features

- Queue and dispatch async client queries to multiple backend process types simultaneously (scatter-gather)
- Collect per-server results and apply a caller-supplied join function once all slots are filled
- Timeout expired queries with configurable per-query timespan via `checktimeout`
- Handle backend disconnects mid-query — errors in-flight queries and queued queries that can no longer be satisfied
- Track connected clients and clean up orphaned queries on client disconnect
- Support synchronous deferred response mode (`-30!`) alongside the default async mode
- Pluggable server source with a default — dispatch against the built-in registry (`addserver`) by default, or point it at `di.serverselect`'s output (or any source) via `setavailableservers`; `di.serverselect` is a composable option, never a dependency
- Accept fully pluggable scheduler (`setgetnextqueryid`), routing (`setavailableservers`), reply formatter (`setformatresponse`), and callback symbols (`setcallbacks`) — swap without touching core dispatch logic

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn`, `error` — each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

The `log` dependency must be passed to `init` inside the `deps` dict. The module throws immediately if it is absent or missing any of the three required keys. All three are required since the module calls `info`, `warn`, and `error`. The dict passed in must already match the binary `{[c;m]}` contract — the module does not detect or adapt other shapes (e.g. a raw `kx.log` instance, which is monadic). If you want to use `kx.log`, load it and write your own `{[c;m]}` wrapper around it before passing it in.

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
| `` `cp `` | no | `{.z.p}` | Current-time function. Override for simulation or backtest; `setcp` does the same after `init` |

**Every optional key is type-checked at `init`**, so a misconfiguration fails loudly at startup rather than silently at first use. A `querykeeptime` or `clearinactivetime` passed as an int, for instance, would otherwise be accepted and then read as nanoseconds by the purge jobs. An **empty** `errorprefix` is rejected outright, not merely defaulted: `di.dataaccess.shardresult` detects a backend error with `prefix~(count prefix) sublist result`, and an empty prefix matches *every* string result, so every ordinary string a shard returned would be misread as an error. Validation runs before any state is written, so a rejected `init` leaves a previously wired module intact.

**`init` must be called before any other function.** There is no default logger, so every public entry point guards on it and signals `di.asyncdispatch: <fn>: init must be called first` rather than surfacing a raw `.m.di.0asyncdispatch.<name>` error that names module internals.

Housekeeping — `checktimeout`, `removequeries`, `removeinactive`, and `removeclients` — is the caller's responsibility. Wire them into your gateway's timer after `init`. The configured default age parameters are accessible as `querykeeptime` and `clearinactivetime` via module state.

> Both TorQ (`gateway.q:590-593`, three `.timer.repeat` calls inline at load) and `di.dataaccess` (which takes a required `timer` dep and schedules its own jobs in `init`) self-schedule this housekeeping instead. This module deliberately does not, keeping it timer-agnostic and leaving the wiring to `di.gateway`. Noted so the divergence is a recorded decision rather than an oversight.

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log dependency and applies config overrides.
```q
ad.init[enlist[`log]!enlist logdep]
```

### `addserver[handle;servertype]`
Register a backend connection into the **built-in (default) server source**. `handle`: open int handle. `servertype`: symbol identifying the process type (e.g. `` `rdb ``, `` `hdb ``). Use this when asyncdispatch owns the server list; to source servers from `di.serverselect` instead, leave `addserver` unused and inject via `setavailableservers`.
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
Replace the **server source** — the function dispatch uses to find backends. `f` is `{[excludeinuse]}` and must return a table with `handle` and `servertype` columns. This is the seam for running against `di.serverselect` (or any external source) **without a dependency and without copying its registry**: by default the source reads asyncdispatch's own registry (`addserver`), and you override it to read serverselect instead.
```q
// default (built-in registry) — equivalent to not calling this at all
ad.setavailableservers[{[eu] $[eu; select from servers where active, not inuse; select from servers where active]}]

// compose with di.serverselect (not a dependency — just its output as the source)
srvsel:use`di.serverselect
ad.setavailableservers[{[eu] select handle, servertype from srvsel.getservers[`servertype;`;()!()]}]
```
Result routing does **not** depend on the source — a returning handle is matched to its servertype from the query's own dispatch record — so an injected source needs no registration in asyncdispatch. Note `inuse` throttling applies only to the built-in registry; an external source is expected to do its own idle/selection (e.g. serverselect's `roundrobin`), and the `excludeinuse` flag is a hint such a source may ignore.

### `setgetnextqueryid[f]`
Inject a custom scheduling strategy. `f` must be niladic and return a 0- or 1-row table with the `queryqueue` schema.
```q
// priority queue example - highest-priority query first
ad.setgetnextqueryid[{1 sublist `priority xdesc 0!select from .z.m.queryqueue where null returntime}]
```

### `asyncexec[query;servertype]`
The raze / no-postback / no-timeout / async convenience form — a projection of `execquery`, and the entry point most TorQ gateway clients actually call. Exactly TorQ's `asyncexec` (`gateway.q:419`, `asyncexecjpt[;;raze;();0Wn]`).
```q
ad.asyncexec["select from trade";`rdb`hdb]      // equivalent to execquery[...;raze;();0Wn;0b]
```

### `status[]`
A snapshot of live dispatch state. Returns a dictionary:

| Key | Meaning |
|---|---|
| `queued` | Queries accepted but not yet dispatched (null `submittime`) |
| `running` | Queries dispatched and awaiting a backend reply |
| `servers` | Rows in the server registry, active or not |
| `activeservers` | Active server count broken down by servertype |
| `clients` | Rows in the client audit table |
| `errorprefix`, `querykeeptime`, `clearinactivetime`, `synccallsallowed` | The live config values |

This exists because **`.z.m` is invisible over IPC** — a remote query runs in the root context, whose `.z.m` is not this module's, so `h".z.m.servers"` throws. An export is the only way `di.gateway` or a monitoring process can read this module's state at all.

The `queued`/`running` split is what the `submittime` column on `queryqueue` is for: it is null until `runnextquery` dispatches the query, then stamped fill-if-null so a redispatch never restamps. That is TorQ's own mechanism (`gateway.q:180` stamps it in `getnextquery`, `:194` derives `?[null submittime;\`pending;\`running]` in `getqueue`).

### `teardown[]`
Clears all dispatch state — `queryqueue`, `servers`, `clients`, `results` — and resets the query-id counter, so a re-init or a test starts clean.

> This is deliberately **not** the `di.servers` teardown contract, which withdraws process-global registrations while leaving module state intact. This module installs no process-global bindings to withdraw: it registers no handler and schedules no timer job, both being the caller's responsibility. What it does own is four tables and a counter, so a state reset is the only shape that means anything here.

If any query is still in flight (null `returntime`) it **warns** rather than dropping it silently — those clients are never replied to and never find out, the same hazard `di.dataaccess.init` warns about on re-init.

### `seteod[b]`
Start (`1b`) or end (`0b`) an end-of-day reload suspension.

While set, a query needing **more than one servertype** is held in the queue rather than dispatched — during a roll, data is moving between (say) the rdb and the hdb, so a query straddling both can double-count or miss rows. Single-servertype queries are unaffected and keep running. Held queries are **not errored**; they dispatch once the suspension clears.

This is TorQ's `eod`/`seteod`/`checkeod` (`gateway.q:91-93`), and the rule is deliberately narrow: the suspension alone blocks nothing, it is the multi-servertype span that does.

**Who calls it.** `di.gateway`. TorQ drives this from the **wdb**, which sends `reloadstart`/`reloadend` to the gateway process (`wdb.q:261,274` → `gateway.q:560,570`). Those two live at TorQ's **root** namespace rather than in `.gw`, because they also refresh `.servers` attributes — so the orchestration belongs to the process module and only the suspension itself belongs here.

**Enforced at two points**, matching TorQ: the scheduler excludes held queries (`canberun`, `gateway.q:147`), and `runnextquery` refuses them as a backstop (`runquery`, `gateway.q:486`). The backstop is not redundant — `getnextqueryid` is pluggable via `setgetnextqueryid`, and an injected scheduler need not implement the eod rule. TorQ keeps both checks for the same reason.

> TorQ has a third eod check at `gateway.q:438`, but it sits inside `syncexecjpre36` — the pre-3.6 path, which is dead on kdb-x and deliberately not ported. `asyncexecjpts` has no eod check at all, so on any modern kdb+ there are only the two gates above.

> **Divergence:** clearing the suspension flushes the held queue here, where TorQ's `reloadend` does it as a separate explicit `runnextquery[]` (`gateway.q:577`). Doing it inside `seteod` means the module guarantees the flush rather than depending on every caller remembering; without it a held query waits for whatever unrelated dispatch happens next.

### `setcp[f]`
Replace the clock function after `init`, to control time in tests without sleeping. `f` is niladic and returns a timestamp. The same thing can be passed as the `` `cp `` key to `init`; use this when a test needs to swap the clock mid-run.

### `version`
The module version string, read at load time from the module's `VERSION` file (bare `major.minor.patch`,
no trailing newline). `init.q` fails loudly if the file is missing, unreadable or empty. This is not a
convenience export: `di.depcheck.checkdepversion` resolves a dependency's version from the export
dictionary and classes a missing one as a **failure**, which makes `di.depcheck.init` throw for every
process that loads a module declaring `di.asyncdispatch` as a hard dependency — `di.gateway` and
`di.dataaccess` both do. It must stay exported.

### `getapimeta[]`
Niladic. Returns an unkeyed table of `` `name`public`descrip`params`return `` rows, one per **callable**
export. The module only *declares* this metadata — it never calls `di.api.add` itself; `di.torq` collects
each module's `getapimeta[]` at startup and registers the rows centrally with `di.api`. Names are bare;
`di.torq` applies the process-wide qualification.

`init` and `getapimeta` are omitted from the table rather than listed as `public:0b` rows. Both are
framework plumbing that `di.torq` invokes by convention, not by discovering them in the registry, so
registering them would describe startup wiring as though it were callable API. `test.csv` asserts both
directions — that every callable export has a row, and that neither plumbing name appears.

`setcp` is deliberately absent: it is an internal test hook for controlling the clock without sleeping,
is not in the export dictionary, and so is not part of the callable API.

---

## Usage Example

```q
// log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
//   logging:use`di.log
//   ad.init[logging.logdict]
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

timer:use`di.timer
timer.init[()!()]

ad:use`di.asyncdispatch
ad.init[enlist[`log]!enlist logdep]

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
- **Finishing a query releases its backends.** `finishquery` frees any server still holding a slot for the query before dropping the result accumulator, so a timed-out in-flight query returns its backend to the pool. This is a **deliberate divergence from TorQ**, which leaks the slot: TorQ's `finishquery` takes a `serverh` and frees it via `setserverstate` (`gateway.q:187`), but `checktimeout` calls it as `finishquery[qids;1b;0Ni]` (`gateway.q:314`), and `where handle in 0Ni` matches no real handle. Left faithful, a run of timeouts against one stuck backend would progressively starve the dispatch pool with no recovery short of a disconnect — the same shape of reasoning as `di.rdb`'s partition guard, where the module also diverged from legacy to avoid a silent, unrecoverable failure. The behaviour is pinned by a test that fails against the unfixed module and passes against this one
- `.z.M.<name>` is used for in-place mutation of tables (`upsert`, `insert`, `update from`, `delete from`) and `.z.m.<name>:value` for whole-variable reassignment — the same convention used by `di.cache`
- Module globals referenced inside q-sql expressions (WHERE conditions, UPDATE SET values) must use the `.z.m.varname` form since q-sql evaluates column expressions in the calling context rather than the module namespace
- `servertype` in `queryqueue` and `addquery` is a list of servertype symbols — one per required backend type. Pass `` enlist`rdb `` for single-server queries, `` `rdb`hdb `` for scatter-gather across two types
- `setcallbacks` must be called before any queries are dispatched if the module is mounted under a non-default path — `serverexecute` reads `resultcallback` and `errorcallback` by bare name on the backend process and posts back to whatever symbols they resolve to
- This module opens and accepts no connections itself — `addserver` and the `.z.po`/`.z.pc` wiring are the consumer's responsibility, keeping the module dependency-free and testable in-process
- All three log keys (`info`, `warn`, `error`) are required — the module calls `info` on server/client connect and init, `warn` on disconnect and timeout, and `error` on backend error and join failure
- **`errorprefix` is a two-module contract, not local config.** `di.dataaccess.shardresult` detects a backend error by comparing the leading characters of a shard result against *its own* copy of the prefix, so the two modules must be configured identically or ordinary string results get misread as errors. Both now reject an empty prefix at `init`, and `di.dataaccess`'s integration suite asserts the two defaults agree. A deployment that overrides one and not the other **is** detected: this module exposes its live `errorprefix` through `status[]`, and `di.dataaccess` — which holds a hard dependency on this one — compares the two at its own `init` and logs a warning naming both values. The check lives on the `di.dataaccess` side because that is the direction the dependency runs; nothing here needs to know its consumers. It warns rather than signals, since this module may legitimately not be `init`-ed yet when dataaccess is wired, in which case `status[]` signals and the check is skipped
- **A failed *local* postback is logged but not otherwise observable.** Confirmed by measurement: `sendclientreply`'s local branch traps the invocation, logs `local postback failed: <error>` at error level, and returns normally. The query is then finished with `error:0b` — recorded as **successful** even though the reply reached nobody. The trap has to stay (a throwing postback must not kill the dispatch loop), so the open question is only how the failure becomes visible to the requester; the log is currently the sole signal. See the note in `dataaccess.md` for the matching side
- `execqueryto` with `replyto:0Ni` invokes the postback locally via `value` — the postback head symbol must be mount-qualified (e.g. `` `da.shardresult ``) since bare exported names are not globals. This is the same resolution mechanism used by `setcallbacks`
- Local queries store `clienth:0Ni` and are not matched by `removeclienthandle` — the in-process caller owns disconnect cleanup for its own requests
- `setformatresponse` overrides only apply to the remote IPC path — local invocation via `execqueryto[0Ni;...]` calls the postback directly without applying `formatresponse`. The default `formatresponse` is a pass-through for async, so this is transparent by default; consumers that override it should not combine that with local invocation
