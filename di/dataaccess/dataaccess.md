# dataaccess

`di.dataaccess` is the data access query layer in the TorQ gateway decomposition. It accepts a client query with a time range, **routes** it across partitions (one shard per servertype/sub-range), **rewrites** each shard's query string with its time filter, **scatters** the shards via `di.asyncdispatch`, then **gathers** the shard results and **reduces** them back to the client with a user-supplied join function.

**Standalone value:** any gateway-style process that needs to fan a time-ranged query across time-partitioned backends (rdb, hdb, …) can load this module for routing, query splitting, scatter-gather and map-reduce aggregation.

**Out of scope:**
- **Execution / handle selection** — dispatching a shard to a concrete backend handle is `di.asyncdispatch`'s job; this module calls `asyncdispatch.execqueryto` with a *servertype*.
- **Server registry / pool selection** — `di.serverselect` owns it; this module only asks it which servertypes are currently reachable.
- **Permissions** — belong in `di.gateway` / `di.permissions`.

---

## Loading

```q
da:use`di.dataaccess
```

Loading pulls in the two **hard dependencies** (`di.asyncdispatch`, `di.serverselect`) via `use`, so both must be resolvable on `QPATH`. Both must also be `init`-ed by the start-up script before dataaccess dispatches a query.

---

## Dependencies

### Hard dependencies (resolved via `use` at load)

| Dep | dataaccess uses | Contract relied on |
|---|---|---|
| `di.asyncdispatch` | dispatch each shard | `execqueryto[replyto;query;servertype;join;postback;timeout;sync]`, called with `replyto:0Ni` |
| `di.serverselect` | learn reachable servertypes for routing | `getservers[`servertype;`;()!()]` → active-servers table (reads `servertype` column) |

### ⚠️ Every backend must be registered with **both** modules

Routing and dispatch read **two different server registries**, and nothing keeps them in sync:

- `getrouting` asks **`di.serverselect`** which servertypes are reachable, and drops any partition whose servertype is not among them.
- **`di.asyncdispatch`** then dispatches from its **own** `servers` table, populated only by its own `addserver`.

So a backend registered with only one of the two produces a **silent** failure, not an error. Register it with `di.serverselect` alone and asyncdispatch has no handle to dispatch to, so the shard sits in `queryqueue` un-dispatched and the client eventually gets a generic *"request timed out"* from `checktimeout` — several seconds after the fact, describing a timeout rather than the wiring mistake that caused it. Register it with `di.asyncdispatch` alone and `getrouting` drops the partition, so the request routes to zero shards and returns an **empty result** that reads as "no data".

```q
/ on connect - BOTH, always
ad.addserver[h;`hdb];
srvsel.addserver[h;`hdb];
srvsel.setserveractive[h;1b];
```

The same applies in reverse on disconnect. All four cleanup functions may be called on **every** `.z.pc` without first working out what kind of handle it was — none of them corrupts state for a handle it does not recognise:

```q
/ on .z.pc - safe to call all four unconditionally
ad.removeserverhandle[h];      / early-returns if h is not a registered backend
ad.removeclienthandle[h];      / clauses match nothing; see caveats below
srvsel.setserveractive[h;0b];  / update matches nothing
da.removeclient[h];            / early-returns if h has no in-flight requests
```

Three caveats worth knowing before relying on that, all verified against the source rather than assumed:

- **Two of them are not silent.** `asyncdispatch.removeclienthandle` and `serverselect.setserveractive` each log at **info** on *every* call, including for handles they know nothing about — so wiring all four onto `.z.pc` produces two log lines per disconnect regardless of handle type.
- **`removeclienthandle` also calls `runnextquery[]`.** Harmless (it just attempts a normal dispatch), but it is a side effect, not a pure no-op.
- **All four require their module to be `init`-ed**, and `serverselect.setserveractive` / `dataaccess.removeclient` additionally reject a non-int handle. `.z.w` in a `.z.pc` handler satisfies this.

`test_integration.csv` registers its backend with both modules for exactly this reason.

### Injected via `init` (a single `deps` dict — **`log` and `timer` are required**, no fallback)

| Key | Required | Default | Purpose |
|---|---|---|---|
| `log` | ✅ | — | binary `` `info`warn`error!{[c;m]} `` dict. **No adaptation is performed** — a raw monadic `kx.log` instance will `'rank` at the first call site; wrap it yourself |
| `timer` | ✅ | — | `di.timer` instance; `init` schedules `removerequests` via `addjob` |
| `resultcallback` | ✅ | — | **mount-qualified** postback symbol, e.g. `` `da.shardresult ``. Must *resolve to a function* at `init` — a bare or misspelt symbol is rejected there rather than hanging every request. See below |
| `cp` | — | `{.z.p}` | current-time function (override for sim / backtesting) |
| `errorprefix` | — | `"error: "` | client-error prefix, **must be a non-empty string**; **must match the prefix `di.asyncdispatch` is configured with** — `shardresult` detects backend errors by comparing against it |
| `timeoutcheckperiod` | — | `10i` | seconds between `checktimeout` sweeps |
| `synccallsallowed` | — | `0b` | whether `execquery[...;1b]` (deferred sync) is permitted |
| `requestkeeptime` | — | `0D00:30` | how long completed `requests` rows are retained before purge |
| `partitions` | — | one `hdb` covering all time | partition coverage table — see Routing |
| `timecolumn` | — | `` `time `` | column rewritten into each shard query |

---

## Routing & query rewriting

These are dataaccess's **own** domain logic (not delegated — `di.serverselect` does server *selection*, not time-range routing).

> **Open question for whoever scopes `di.gateway`: end-of-day suspension does not cover this module.**
>
> `di.asyncdispatch.seteod[1b]` holds a query only when it spans **more than one servertype** (`checkeod`). Every shard this module dispatches is single-servertype by construction — `submitshards` passes `enlist stype` — so **no dataaccess-originated query is ever held by that suspension**, whatever `seteod` is set to.
>
> This module has no hold or suspend mechanism of its own. Its only protection against a request straddling a live rollover is `setpartitions` being called at the right moment, which is timing, not interlocking.
>
> So: should `di.dataaccess` grow its own eod equivalent, or should `di.gateway` hold requests upstream of it entirely? Is the race even reachable in practice, given how `setpartitions` is driven? Recorded here as an unresolved design question — **not** decided, and not implied by anything currently in the code.

### `getrouting[starttime;endtime]` → shard table
Asks `serverselect.getservers` which servertypes are reachable, then clips `[starttime;endtime]` against the `partitions` coverage table. Each surviving partition becomes one shard:

```
partitions:  ([] servertype; coverfrom; coverto)   / coverfrom/coverto are timestamps; use -0Wp / 0Wp for open ends
result:      ([] servertype; rangestart; rangeend)  / rangestart=coverfrom|starttime, rangeend=coverto&endtime, kept where rangestart<rangeend
```

> Partition coverage is validated by **value** as well as by column: `init` and `setpartitions` both reject a null `coverfrom`/`coverto` and any range where `coverfrom` is not strictly earlier than `coverto`. Such a range passes every column check and then silently covers nothing — the request routes to zero shards and the caller gets an empty result rather than any hint the config is dead. An empty coverage table is still accepted: nothing routable is a legitimate state.
>
> Partition coverage should be **non-overlapping** — overlapping ranges produce multiple shards for the same slice and double-count. **`init` and `setpartitions` both detect this and log a warning**; it is a warning rather than an error because a caller may intend it. Ranges that merely *touch* (hdb `coverto` = rdb `coverfrom`, the documented rollover shape) are not treated as an overlap. For "now"-relative boundaries the caller moves the boundary at rollover with `setpartitions`.

### `buildshardquery[query;rangestart;rangeend]` → rewritten query string
Appends a `within` filter on `timecolumn` as the **last** clause, so it is valid whether or not `query` already has a `where`:

```q
"select from t"          -> "select from t where time within (<rangestart>;<rangeend>)"
"select from t where a=1" -> "select from t where a=1 , time within (<rangestart>;<rangeend>)"
```

> **String-based by design** (per the chosen query representation). It assumes a flat `select … from … [where …]` string and is **not** robust to subqueries or `fby`. If queries become structured/functional, swap this one function.
>
> Trailing whitespace and statement separators are stripped before the clause is appended. `"select from t;"` would otherwise become `"select from t; where time within (…)"`, which is not valid q — the `;` ends the statement and the backend fails with `'a`.
>
> Where-detection **is** whole-word and literal-aware: `where` is matched only as a complete token and only outside double-quoted string literals. A bare `query like "*where*"` used to fire on any identifier merely *containing* the substring — a column named `wherever`, a symbol `` `nowhere `` — and then emitted `"select wherever from t , time within (…)"`, which is invalid q.

---

## asyncdispatch integration

Each shard is submitted as an independent async query:

```q
asyncdispatch.execqueryto[0Ni; shardquery; enlist servertype; first; (resultcallback;reqid); timeout; 0b]
```

Four behaviours of the real `asyncdispatch` that dataaccess accommodates:

1. **Postback arity.** asyncdispatch replies `(postback…, query, result)`, so the callback arrives as **`shardresult[reqid;query;result]`** (the `query` arg is echoed and unused).
2. **`errorprefix` must match `di.asyncdispatch`'s.** This is a contract between two modules, not local config: `shardresult` compares the leading characters of a shard result against this module's copy, while `di.asyncdispatch` is what actually prepends the prefix. Both modules reject an empty prefix at `init` (an empty one matches *every* string result), and `test_integration.csv` asserts the two defaults agree. **A deployment that overrides one and not the other is now detected too:** `di.asyncdispatch` exposes its live value through `status[]`, and this module holds a hard handle to it, so `init` compares the two and **logs a warning** naming both values. It warns rather than signals because `di.asyncdispatch` may legitimately not be `init`-ed yet when this module is wired, in which case `status[]` signals and the check is skipped. Measured: with the prefixes mismatched and no check, a genuine backend failure is joined into the client's result as ordinary data and the request completes with `error:0b`.
3. **A failed local postback is logged, not raised.** `resultcallback` must be mount-qualified because `di.asyncdispatch` resolves it with `value` inside its own namespace. If it does not resolve, `sendclientreply`'s local branch traps and logs `local postback failed: …` at error, then finishes the query with `error:0b` — so the request is recorded as successful and this module never learns the reply was lost. Confirmed by measurement, not inferred. The trap is correct (a throwing postback must not kill the dispatch loop). **This module now closes the common case at `init`:** `resultcallback` must not merely be a symbol, it must *resolve to a function* — `value` on a bare or misspelt symbol throws, so a typo is rejected loudly at startup instead of hanging every request forever with no diagnostic. What remains open on `di.asyncdispatch`'s side is only the case where the symbol resolves at `init` and stops resolving later.
4. **Errors share the postback.** A backend error is delivered through the *same* postback as an `"error: …"` result string (asyncdispatch has no separate client error-callback). So `shardresult` detects an `errorprefix`-prefixed string result and short-circuits via `sharderror`. A genuine string result beginning `"error: "` would be misclassified — acceptable given the string contract.

3. **Reply routing — RESOLVED.** This was previously documented here as an open asyncdispatch-side concern; it is fixed and closed. `asyncdispatch.execquery` captures `clienth:.z.w` at call time and posts the reply there — and because dataaccess calls it **in-process**, `.z.w` is the *end client's* handle inherited through the synchronous call chain. Every shard reply therefore went to the client, which has no `shardresult`, and the join never ran.

   `di.asyncdispatch` shipped `execqueryto[replyto;…]` for exactly this, and **dataaccess now calls it with `replyto:0Ni`**, which makes asyncdispatch invoke the postback locally via `value` instead of sending it to a handle. Nothing further is outstanding on either side.

   Two consequences worth knowing:

   - **`resultcallback` must be mount-qualified** (`` `da.shardresult ``, not `` `shardresult ``). `value` runs inside asyncdispatch's own namespace, where a bare export name does not resolve. This is why the key is required rather than defaulted — a wrong value fails *silently*, swallowed by asyncdispatch's local-postback trap.
   - **The request row must exist before dispatch.** `execquery` files the request row and its `shardresults` slot, and consumes the request id, *before* calling `submitshards`. The postback itself is invoked synchronously by asyncdispatch's local branch (`value tosend`, inside `addserverresult`), so whether `shardresult` re-enters this module before `submitshards` returns depends on when the backend's reply is processed: against an **in-process backend on handle `0`** — which this build executes locally — it re-enters immediately, which is what makes the ordering load-bearing. Against a **real remote backend** the reply arrives later, which is why `test_integration.csv` needs an explicit round-trip (`h "1b"`) to force it through before asserting.

---

## Core data structures

### `requests` (keyed table, key `requestid`) — `.z.m.requests`

| Column | Type | Description |
|---|---|---|
| `requestid` | `long` | Auto-incremented per `execquery` |
| `time` | `timestamp` | Submission time |
| `clienth` | `int` | `.z.w` of the requesting client |
| `remaining` | `long` | Shard results still outstanding |
| `joinfn` | `()` | Map-reduce join applied across shard results |
| `postback` | `()` | `()` for a plain reply; `(fn;args…)` to wrap before sending |
| `timeout` | `timespan` | `0Wn` for none |
| `returntime` | `timestamp` | Set on completion; null while in-flight |
| `error` | `boolean` | `1b` if the request ended in error |
| `sync` | `boolean` | `1b` if the client awaits a deferred (`-30!`) response |

### `shardresults` (dict) — `.z.m.shardresults`
`requestid -> list of shard results`; removed by `finishrequest` once the join is sent.

---

## Functions (export)

- **`init[deps]`** — wire injectables + optional config, then schedule `removerequests` and `checktimeout` on the timer. **Must be called before any other function** — every public entry point guards on it and signals `di.dataaccess: <fn>: init must be called first` rather than leaking a raw error naming module internals.

  `init` is re-callable, and a re-init resets `requests`, `shardresults` and `requestid` wholesale. If that discards live work it **logs a warning naming the count** — those clients are never replied to and would otherwise never find out. Optional config is **type-checked at `init`**, so a misconfiguration fails at startup rather than silently at first use (an int `requestkeeptime`, for instance, used to be accepted and then read as nanoseconds).
- **`execquery[query;starttime;endtime;joinfn;postback;timeout;sync]`** — main entry point: route → rewrite → scatter → (on completion) reduce → reply. **Returns the `requestid` the call was filed under** (a long), so a caller can correlate a postback reply with the request that produced it. Both exits — including the no-shard early return — consume exactly one id and return *that* id, not the next one.

  **Every argument is validated up front** and routed through the log-then-signal helper, so a caller mistake is logged and named rather than surfacing later as a raw `'type` from a downstream `upsert`. `query` must be a non-empty string; `starttime`/`endtime` non-null timestamps with **`starttime` strictly earlier than `endtime`**; `joinfn` a function; `postback` `()`, a symbol, or a list; `timeout` a timespan; `sync` a boolean.

  > The strict range check is deliberate. An inverted or zero-width range previously routed to zero shards and returned an *empty result with no error*, which a caller reads as "no data" rather than "bad request". A genuine point-in-time query should be expressed as a range that contains the instant.
- **`setpartitions[parts]`** — replace the live partition coverage table at runtime, e.g. from a gateway's end-of-day `reloadend` handler. Shares **exactly** the validation `init` uses (both reject a keyed table and a missing column), and warns if the new coverage overlaps. Without this the rdb/hdb boundary goes stale at every roll.
- **`removeclient[h]`** — error and clean up any in-flight request belonging to a disconnected client handle. **Exported, not self-registered**: wiring it to `.z.pc` through `di.handlers` is `di.torq`'s job, exactly as `di.asyncdispatch` exports `removeclienthandle` rather than registering it itself.
- **`getapimeta[]`** — this module's api metadata, one row per callable export, for `di.torq` to collect and register with `di.api`. `init` and `getapimeta` are omitted as framework plumbing.
- **`version`** — the module version string, read from the `VERSION` file.
- **`shardresult[reqid;query;result]`** — asyncdispatch success-postback callback; accumulates, and triggers the join when all shards are in. Detects `"error:"` results and routes them to `sharderror`.
- **`sharderror[reqid;err]`** — short-circuits the request, logs, replies the error.
- **`removerequests[age]`** — purge completed `requests` rows older than `age` (timer-driven; also callable manually). Note it only purges rows that already have a `returntime`, so an *abandoned* in-flight request is invisible to it — that is `checktimeout`'s and `removeclient`'s job.
- **`checktimeout[]`** — error any in-flight request that has passed the `timeout` `execquery` recorded for it, routing it through `sharderror` so the client is told and the row becomes purgeable. `init` schedules this on the injected timer every `timeoutcheckperiod` seconds. Without it a shard that never returns leaves its request in flight forever: `removerequests` only touches rows that already have a `returntime`. `di.asyncdispatch` runs an equivalent sweep over its *own* queue, but only if the caller scheduled it, and it cannot see this module's `requests` table — so the timeout recorded here is enforced here. **Caveat:** this errors *this* module's request and replies to the client, but it cannot reach into `di.asyncdispatch`'s `queryqueue`/`results` to cancel the shard query underneath. The backend slot that shard was dispatched to therefore stays `inuse:1b` until asyncdispatch's own `checktimeout` fires (only if the caller scheduled it) or the backend disconnects. Size the backend pool accordingly, and schedule *both* sweeps — see the matching pool-starvation note in `asyncdispatch.md`.

> **Why `removeclient` is necessary.** Every shard is now dispatched with `replyto:0Ni`, so `di.asyncdispatch.removeclienthandle` can never match a dataaccess-originated shard query for a real client handle — its own comment says local queries "are not matched here — the in-process caller owns cleanup for its own requests". The real client handle exists only in this module's `requests` table. Without `removeclient`, a client that disconnects mid-flight leaves its row in `requests` and its accumulator in `shardresults` forever.

Internal helpers (`getrouting`, `buildshardquery`, `checkresults`, `sendreply`, `finishrequest`, `submitshards`, `raiseerror`, `getopt`) are **not** exported.

> `normlog` has been **removed**. It was the retired auto-detect-and-wrap helper for a raw `kx.log` instance; the module now validates that the injected `log` is already a binary `` `info`warn`error `` dict and stores it as `.z.m.loginfo` / `.z.m.logwarn` / `.z.m.logerr`, matching every other module in the repo.

---

## Example usage

```q
/ -- gateway process --
/ NB the module handle must be a ROOT global named to match resultcallback below - asyncdispatch
/ resolves `da.shardresult with value, so `da` has to exist here by that name
da:use`di.dataaccess

/ the log dep must ALREADY be a binary `info`warn`error!{[c;m]} dict - this module performs no
/ adaptation, so a raw monadic kx.log instance would 'rank at the first call site.
/ di.log's logdict is a ready-made dep; hand-rolled shown here so the shape is explicit
logdep:`info`warn`error!(
  {[c;m] / your info sink};
  {[c;m] / your warn sink};
  {[c;m] / your error sink})

tmr:use`di.timer
tmr.init[(::)]

/ rdb holds today, hdb holds history (boundary updated at rollover via setpartitions)
parts:([] servertype:`rdb`hdb; coverfrom:(.z.d;-0Wp); coverto:(0Wp;.z.d))

/ resultcallback is REQUIRED and must be mount-qualified to match the `da` handle above
da.init[`log`timer`resultcallback`partitions!(logdep;tmr;`da.shardresult;parts)]

reqid:da.execquery["select count i by sym from trade";
                   2000.01.01D00:00:00.000000000;
                   .z.p;
                   raze;    / join the shard result tables together
                   ();      / no postback wrapping
                   0Wn;     / no timeout
                   0b]      / async

/ at the end-of-day roll, move the rdb/hdb boundary
da.setpartitions[([] servertype:`rdb`hdb; coverfrom:(.z.d;-0Wp); coverto:(0Wp;.z.d))]

/ on client disconnect (di.torq wires this to .z.pc via di.handlers)
da.removeclient[disconnectedhandle]
```

---

## Testing

Two suites. The unit suite runs the normal way:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.dataaccess
```

**`test_integration.csv` is the one that matters for the dispatch path.** Every row in `test.csv` stubs `submitshards` outright, so `di.asyncdispatch` is never reached and the dispatch call has no coverage there at all. The integration suite stands up a **real child q process** as an hdb backend on an OS-assigned ephemeral port, registers it with both `di.asyncdispatch` and `di.serverselect`, and drives a real shard round-trip. `moduletest` only ever loads `test.csv`, so load and run this suite directly:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.dataaccess;`test_integration.csv]
.m.di.0k4unit.KUrt[]
```

> **Why it asserts on `asyncdispatch.queryqueue` and not only on the outcome.** The outcome assertions (the join ran, the child's real rows came back) cannot on their own distinguish the fix from the bug. In-process `.z.w` is `0i`, and this q build **executes** a message sent to handle `0` locally rather than writing it anywhere — measured, not assumed — so broken handle-routing and correct local invocation produce identical results. The suite therefore also asserts what asyncdispatch *recorded*: `local` is `1b` and `clienth` is null for the shard query. Reverting `submitshards` to the old `execquery` call fails exactly those two assertions and no others, which is how the suite was confirmed to discriminate at all.

---

## Notes

- All mutable state lives on `.z.m`; the module declares no namespaces and never assigns `.z.M`.
- The injected logger is fanned out in `init` to `.z.m.loginfo` / `.z.m.logwarn` / `.z.m.logerr` and called as `.z.m.loginfo[`ctx;"msg"]`, matching the rest of the repo. The module performs no shape adaptation on it. All three levels are used: `warn` covers a re-init that discarded live work, overlapping partition coverage, and a timeout sweep that expired requests.
- A `joinfn` of the wrong arity does **not** throw — q returns a projection — so `checkresults` treats a callable join result as a join failure rather than delivering a function object to the client as its "result".
- Domain errors route through an internal log-then-signal helper, so failures appear in the injected log as well as being thrown — except `init`'s own dependency validation, which signals plainly because the logger is not yet wired.
- `shardresult`/`sharderror` guard against late/duplicate deliveries via the `returntime` null check; once a request is finished, further callbacks for that `requestid` are dropped.
