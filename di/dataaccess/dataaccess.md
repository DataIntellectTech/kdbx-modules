# dataaccess

`di.dataaccess` is the data access query layer in the TorQ gateway decomposition. It accepts a client query with a time range, **routes** it across partitions (one shard per servertype/sub-range), **rewrites** each shard's query string with its time filter, **scatters** the shards via `di.asyncdispatch`, then **gathers** the shard results and **reduces** them back to the client with a user-supplied join function.

**Standalone value:** any gateway-style process that needs to fan a time-ranged query across time-partitioned backends (rdb, hdb, …) can load this module for routing, query splitting, scatter-gather and map-reduce aggregation.

**Out of scope:**
- **Execution / handle selection** — dispatching a shard to a concrete backend handle is `di.asyncdispatch`'s job; this module calls `asyncdispatch.execquery` with a *servertype*.
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
| `di.asyncdispatch` | dispatch each shard | `execquery[query;servertype;join;postback;timeout;sync]` |
| `di.serverselect` | learn reachable servertypes for routing | `getservers[`servertype;`;()!()]` → active-servers table (reads `servertype` column) |

### Injected via `init` (a single `deps` dict — **`log` and `timer` are required**, no fallback)

| Key | Required | Default | Purpose |
|---|---|---|---|
| `log` | ✅ | — | `kx.log` instance, or a binary `` `info`warn`error!{[c;m]} `` dict |
| `timer` | ✅ | — | `di.timer` instance; `init` schedules `removerequests` via `addjob` |
| `cp` | — | `{.z.p}` | current-time function (override for sim / backtesting) |
| `synccallsallowed` | — | `0b` | whether `execquery[...;1b]` (deferred sync) is permitted |
| `requestkeeptime` | — | `0D00:30` | how long completed `requests` rows are retained before purge |
| `resultcallback` | — | `` `shardresult `` | postback symbol asyncdispatch resolves to (set to the mounted path, e.g. `` `da.shardresult ``) |
| `partitions` | — | one `hdb` covering all time | partition coverage table — see Routing |
| `timecolumn` | — | `` `time `` | column rewritten into each shard query |

---

## Routing & query rewriting

These are dataaccess's **own** domain logic (not delegated — `di.serverselect` does server *selection*, not time-range routing).

### `getrouting[starttime;endtime]` → shard table
Asks `serverselect.getservers` which servertypes are reachable, then clips `[starttime;endtime]` against the `partitions` coverage table. Each surviving partition becomes one shard:

```
partitions:  ([] servertype; coverfrom; coverto)   / coverfrom/coverto are timestamps; use -0Wp / 0Wp for open ends
result:      ([] servertype; rangestart; rangeend)  / rangestart=coverfrom|starttime, rangeend=coverto&endtime, kept where rangestart<rangeend
```

> Partition coverage should be **non-overlapping** — overlapping ranges produce multiple shards for the same slice and double-count. For "now"-relative boundaries (e.g. rdb = start-of-day…now), the caller updates the `partitions` config at rollover.

### `buildshardquery[query;rangestart;rangeend]` → rewritten query string
Appends a `within` filter on `timecolumn` as the **last** clause, so it is valid whether or not `query` already has a `where`:

```q
"select from t"          -> "select from t where time within (<rangestart>;<rangeend>)"
"select from t where a=1" -> "select from t where a=1 , time within (<rangestart>;<rangeend>)"
```

> **String-based by design** (per the chosen query representation). It assumes a flat `select … from … [where …]` string; it is **not** robust to subqueries, `fby`, or the literal text `where` appearing inside a string constant. If queries become structured/functional, swap this one function.

---

## asyncdispatch integration

Each shard is submitted as an independent async query:

```q
asyncdispatch.execquery[shardquery; enlist servertype; first; (resultcallback;reqid); timeout; 0b]
```

Two behaviours of the real `asyncdispatch` that dataaccess accommodates:

1. **Postback arity.** asyncdispatch replies `(postback…, query, result)`, so the callback arrives as **`shardresult[reqid;query;result]`** (the `query` arg is echoed and unused).
2. **Errors share the postback.** A backend error is delivered through the *same* postback as an `"error: …"` result string (asyncdispatch has no separate client error-callback). So `shardresult` detects an `errorprefix`-prefixed string result and short-circuits via `sharderror`. A genuine string result beginning `"error: "` would be misclassified — acceptable given the string contract.

> ⚠️ **Integration concern (needs an asyncdispatch change, not fixable here).** `asyncdispatch.execquery` captures `clienth:.z.w` at call time and posts the reply there. Because dataaccess calls it **in-process**, `.z.w` is the *end client's* handle — so as-is asyncdispatch would reply to the client, not back to dataaccess, and the client has no `shardresult`. For dataaccess to interpose its shard-join, asyncdispatch needs to reply to dataaccess (e.g. an execquery reply-handle / local-callback option). Tracked as an asyncdispatch follow-up.

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

- **`init[deps]`** — wire injectables + optional config, then schedule `removerequests` on the timer. **Must be called before any other function.**
- **`execquery[query;starttime;endtime;joinfn;postback;timeout;sync]`** — main entry point: route → rewrite → scatter → (on completion) reduce → reply.
- **`shardresult[reqid;query;result]`** — asyncdispatch success-postback callback; accumulates, and triggers the join when all shards are in. Detects `"error:"` results and routes them to `sharderror`.
- **`sharderror[reqid;err]`** — short-circuits the request, logs, replies the error.
- **`removerequests[age]`** — purge completed `requests` rows older than `age` (timer-driven; also callable manually).

Internal helpers (`getrouting`, `buildshardquery`, `checkresults`, `sendreply`, `finishrequest`, `submitshards`, `normlog`, `raiseerror`, `getopt`) are **not** exported.

---

## Example usage

```q
/ -- gateway process --
da:use`di.dataaccess

logger:use`kx.log
loginst:logger.createLog[]
tmr:use`di.timer
tmr.init[(::)]

/ rdb holds today, hdb holds history (boundary updated at rollover)
parts:([] servertype:`rdb`hdb; coverfrom:(.z.d;-0Wp); coverto:(0Wp;.z.d))

da.init[`log`timer`partitions`resultcallback!(loginst;tmr;parts;`da.shardresult)]

da.execquery["select count i by sym from trade";
             2000.01.01D00:00:00.000000000;
             .z.p;
             raze;    / join the shard result tables together
             ();      / no postback wrapping
             0Wn;     / no timeout
             0b]      / async
```

---

## Notes

- All mutable state lives on `.z.m`; the module declares no namespaces and never assigns `.z.M`.
- Domain errors route through an internal log-then-signal helper, so failures appear in the injected log as well as being thrown — except `init`'s own dependency validation, which signals plainly because the logger is not yet wired.
- `shardresult`/`sharderror` guard against late/duplicate deliveries via the `returntime` null check; once a request is finished, further callbacks for that `requestid` are dropped.
