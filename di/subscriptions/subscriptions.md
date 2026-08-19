# di.subscriptions

Tickerplant subscription management for kdb+ subscriber processes (RDB, WDB, chained TP). Fetches table schemas and log details from a tickerplant in a single call, defines the subscribed tables at root, replays the pre-subscription tickerplant log exactly once, and records the subscription in an inspectable registry. Live updates then flow through the root `upd` as normal.

---

## Features

- Subscribe over an already-open tickerplant handle - the caller owns the connection, so this module never opens, retries or closes one
- Subscribe to all tables and syms, or to any subset, with sym filtering applied to the log replay as well as to the live feed
- Define subscribed tables at root from the schemas the tickerplant returns, preserving their attributes (e.g. `` `g# `` on `sym`)
- Replay exactly the messages the tickerplant had logged at the instant of subscription, so messages that also arrive on the live feed are not applied twice - exact in every case except a *shared* log, where it is best-effort with a bounded duplicate window (see Notes)
- Verify every log before defining a single table, so a truncated or unreadable log fails with the process untouched (see Notes for the limit of that guarantee)
- Handle every payload shape a tickerplant may log - a list of columns, a table, a dict, or a single atom row - by resolving the `sym` column by name rather than position
- Replay across several log files, as a segmented tickerplant writes one log per table - and across a *shared* log, which the same tickerplant writes in its `singular` and `periodic` modes, driving only the subscribed tables even when the shared file carries others (see Notes)
- Resolve `` ` `` (all tables) to a concrete list with a `tablelist` round trip before calling `subdetails`, because a segmented tickerplant cannot accept the sentinel
- Track live subscriptions in a registry whose `active` flag is maintained from `.z.pc`, cross-checked against `.z.W`, and released explicitly by `unsubscribe` before the caller closes a handle
- Refuse to re-subscribe a table that already has a live subscription, rather than silently redefining it and replaying into it again
- Run every guard that does not need the tickerplant's reply *before* asking for it, because asking is itself a subscription (see Notes)
- Speaks TorQ's real `subdetails` protocol rather than a new one, and the remote entry point name is configurable

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn` and `error` - each binary `{[c;m]}` where `c` is a symbol context and `m` is a string. All three are called by this module |
| handlers | `` `handlers `` | yes | `register` and `remove`, per the `di.handlers` contract. Used to install a `.z.pc` observer that marks a dropped connection's subscriptions dead |

**Hard dependencies.** The modularisation plan places `di.subscriptions` in the **FRAMEWORK** tier with `-> di.servers, di.pubsub`. Both are genuine module imports, `use`d in `init.q` before the implementation loads (the shape `di.eodtime` uses for `di.tz`), declared in `deps.q` and enforced by `di.depcheck` (`di.servers` ≥ `0.1.0`, `di.pubsub` ≥ **`0.2.0`** — that release adds `getsubtables` and, critically, makes `di.pubsub` *chain* `.z.pc` instead of replacing it; a `0.1.0` `di.pubsub` would silently destroy this module's own dropped-connection observer). The module will not load without them.

| Import | Used for |
|---|---|
| `di.servers` | `getsubscriptionhandles` resolves tickerplant handles off `di.servers.SERVERS`, calling only `getservers` |
| `di.pubsub` | the **local** publisher this process republishes through — see `republish` below |

`log` and `handlers` must be passed to `init` inside the `deps` dict. The module throws immediately if either is absent or malformed - there is no fallback logger and no degraded no-handlers mode. The `log` dict must already match the binary `{[c;m]}` contract; the module does not detect or adapt other shapes (e.g. a raw `kx.log` instance, which is monadic). To use `di.log`, pass its `logdict``log`.

**`republish` (default `0b`) turns on the `di.pubsub` half.** A chained or segmented tickerplant subscribes upstream and serves the *same* tables downstream — TorQ splits that across `chainedtp.q:71-82` and `sctp.q:15-25`, which subscribe, then publish through `.ps.publish` and serve their own table list straight out of the pubsub registry (`chainedtp.q:7`, `tablelist:{.stpps.t}`). With `republish` set, a successful `subscribe` hands the tables it defined at root to the local `di.pubsub` (`setsubtables` then `init`), so it extracts their schemas and can fan out to this process's own subscribers.

It is **off by default**: a plain RDB or WDB consumes a feed and must not silently start publishing one.

The handoff is **additive** — it unions the registry's tables with what `di.pubsub` already serves (read back via `getsubtables`), so the published set only ever grows within a process. Two measured reasons:

- `di.pubsub`'s `setsubtables` **replaces** its list (`pubsub.q:119`), and `unsubscribe` deletes its registry rows. A union computed purely from the registry therefore dropped an unsubscribed table at the next *unrelated* `subscribe` — downstream subscribers silently stopped receiving it, at a moment disconnected from the `unsubscribe` that caused it.
- Shrinking toward empty is worse than useless: `setsubtables` with an empty list does **not** mean "publish nothing". `di.pubsub` then falls back to publishing **every** table at root (`pubsub.q:125`).

**What `republish` does and does not do.** It makes the local publisher *able to serve* the subscribed tables — schemas extracted, ready for a downstream `subscribe`. It does **not** forward the data: that is the process's own `upd`, exactly as in TorQ, where `chainedtp.q`'s `tickpub` (`:96-99`) is chainedtp's code, not `.sub`'s. A chained tickerplant built on this module therefore wires one line:

```q
upd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]]; pubsub.publish[t;x]}
```

That split is deliberate: this module owns the *subscription*, the caller owns what it does with each message. The integration suite proves the whole chain across three real processes — an upstream tickerplant, a middle process using this module with `republish` on, and a downstream subscriber.

Legacy's chained tickerplants also seed `.u.d`/`.u.icounts` from the subscribe result. Those are tickerplant sequence-and-date state, which `di.pubsub` does not own (it has no `i`, `j`, `icounts` or `d`); the values are returned to the caller in `subscribe`'s result as `d` and `icounts` so whatever owns a tickerplant log can apply them.

**A handoff failure does not fail the subscribe.** By the time the handoff runs, the subscribe has fully succeeded — schemas defined, log replayed, registry row committed. If `di.pubsub` then refuses the tables, the module logs a **warning** naming the reason and stating plainly that the subscription stands, and `subscribe` returns its normal result. It does not throw: discarding completed work over an optional secondary step would be wrong, and appending the usual post-`subdetails` remedy ("close the handle before retrying") would be worse — the connection is healthy, and a retry would hit the duplicate-subscription guard against the row that call just committed. This matches how `unsubscribe` handles the same shape when its optional `unsubscribefunc` call fails.

A table that is unsubscribed stays advertised and simply stops receiving data — a visible, inert condition rather than a silent disappearance. Tables not defined at root are filtered out first, since `di.pubsub.init` calls `value` on each name (`pubsub.q:84`).

Note the module still speaks the publisher's **wire** protocol separately: `subdetailsfunc` and `tablelistfunc` name functions evaluated on the *remote* tickerplant, so they resolve in that process. Legacy is the same shape — its `.u.sub`/`.u.i`/`.u.L`/`.u.icounts`/`.u.d` references (`subscriptions.q:100-101`) sit inside lambdas sent to the tickerplant handle. The integration suite's peer runs the real `di.pubsub`, so that half is exercised across a genuine process boundary.

**⚠️ Import order is load-bearing.** `di.pubsub` assigns `.z.pc` at load (`pubsub.q:75`). It now *chains* onto whatever already owns the event, but the `use` in `init.q` runs at module load and `init` registers this module's `.z.pc` observer afterwards — that ordering is what keeps the observer alive, and it is asserted in `test.csv` rather than left to comment.

The configuration keys `subdetailsfunc` and `tablelistfunc` are optional - omit them and the module calls the tickerplant's `subdetails` and `tablelist`. See Initialisation.

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` and `handlers` dependencies with any configuration overrides.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep - `info`, `warn` and `error`, each `{[c;m]}` |
| `` `handlers `` | yes | Handlers dep - at minimum `register` and `remove` |
| `` `subdetailsfunc `` | no | Symbol naming the tickerplant-side function to call. Default: `` `subdetails `` |
| `` `tablelistfunc `` | no | Symbol naming the tickerplant-side function that lists the available tables, used to resolve a `` ` `` request into a concrete list. Default: `` `tablelist `` |
| `` `unsubscribefunc `` | no | Symbol naming a tickerplant-side function that releases this connection's subscriptions, called by `unsubscribe`. Default: `` ` `` (none) — see Notes |
| `` `republish `` | no | Boolean. Hand the subscribed tables to the local `di.pubsub` so this process can serve them downstream — the chained/segmented tickerplant role. Default: `0b` |

`init` must be called before any operational function - `subscribe`, `unsubscribe`, `subscribed`, `getsubscriptions` and `teardown` each throw a clear error if it has not been. `getapimeta` and `version` are metadata and deliberately work without it, so `di.torq` can collect api rows and `di.depcheck` can read the version before anything is initialised. `init` registers a `.z.pc` observer through `di.handlers` and is idempotent - a second call refreshes the dependencies and replaces the registration in place rather than duplicating it, and leaves the registry intact.

Build `deps` as one multi-key dictionary. Do not join `di.log`'s `logdict` to another single-key dict: `` enlist[`k]!enlist somedict `` puts a table on the value side, and joining two of them throws `` 'mismatch `` at the call site before `init` runs.

```q
`log`handlers!(logging.logdict`log;handlerdep)                  / correct
logging.logdict,`handlers`subdetailsfunc!(handlerdep;`subdetails)   / also correct
logging.logdict,enlist[`handlers]!enlist handlerdep             / 'mismatch
```

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log and handlers dependencies, applies config, and registers the `.z.pc` observer.
```q
sub.init[`log`handlers!(logging.logdict`log;`register`remove!(handlers.register;handlers.remove))]
```

### `subscribe[tph;tabs;syms;setschema;replay]`
Subscribe over an already-open tickerplant handle. `tph` is an int handle (or a function standing in for one). `tabs` and `syms` are `` ` `` for all, or one or more symbols - a bare symbol atom names a single table or sym and is normalised to a list. `syms` may also be a **filter dictionary** keyed by table (TorQ's own shape - `rdb.q` loads it from a csv as `.sub.filterparams` and passes it through as `instruments`); it is handed to the tickerplant for the live feed, and the replay runs unfiltered, exactly as legacy's `replayupd` does. `setschema` defines the returned schemas at root; `replay` replays the pre-subscription log and requires a root-level `upd`. If it throws, check whether the error mentions the handle having already been registered — see Notes for the one case where that can happen and what to do about it.

Returns a dictionary of `subtables`, `tplogdate`, `rowcounts` and `date`, plus `logdir` when the tickerplant supplies one. It also carries `icounts` and `d`, which are legacy's names for `rowcounts` and `date` and hold the same values — see Notes for why both are emitted.
```q
sub.subscribe[tph;`;`;1b;1b]                        / all tables, all syms, define schemas, replay
sub.subscribe[tph;`trade`quote;enlist`AAPL;1b;1b]   / two tables, one sym
sub.subscribe[tph;`;`;0b;0b]                        / subscribe only - keep my schemas, skip the replay
/ `subtables`tplogdate`rowcounts`date`icounts`d!(`trade`quote;2025.06.01;`trade`quote!(1042;3311);2025.06.01;`trade`quote!(1042;3311);2025.06.01)
```

### `resubscribe[tph]`
Re-establish every subscription that has since dropped, over a **new** handle to the same tickerplant. This is legacy's `retrysubscription` (`subscriptions.q:155`), split so the module keeps the knowledge of what was subscribed while the caller keeps ownership of the connection — `di.rdb`/`di.servers` decide *when* to call it. Uses `setschema:0b` and `replay:0b` exactly as legacy does, so a reconnect restores the live feed without re-applying history. Best-effort per subscription and never fatal; returns the tables re-established.
```q
sub.resubscribe[newtph]     / -> `trade`quote
```

It reports what `subscribe` **actually** established, not what the dead row asked for. The two differ: if the tickerplant has since retired one table of a multi-table subscription, `narrowtabs` drops it with a warning and the call still succeeds for the rest. Taking the request as the outcome would mark the retired table re-established and retire its row, losing the only record that it was ever subscribed.

A dead row is therefore **narrowed** rather than deleted whole — the tables that came back are removed from it, and the row is dropped only once nothing is left. Deleting whole would discard the tables that did *not* come back; keeping whole would retry them alongside the ones that did, which now hold a live subscription, so the duplicate guard would reject the retry and warn about it on every call. A narrowed row is retried only while this tickerplant still publishes what remains in it, so a table retired upstream goes quiet instead of warning on every timer tick, and is picked up again automatically if the tickerplant starts publishing it once more.

Only the rows a given call actually attempted are rewritten, so a same-named table belonging to a *different* tickerplant's dead row is left alone.

### `unsubscribe[tph]`
Release the subscriptions held on a tickerplant handle and return the tables released. **Call this before `hclose`.** It never closes the handle — the caller owns the connection — and never messages the tickerplant, because the `subdetails` protocol has no unsubscribe verb.

It exists for the one liveness signal kdb+ cannot supply: a handle the *caller* closes fires no `.z.pc`, and the freed descriptor is then reissued to the next connection. Without this call, that stale registry row goes on reporting live and the duplicate guard refuses a legitimate re-subscribe. Idempotent — a second call logs at `warn` and returns an empty list rather than throwing, so a shutdown path is safe to run twice.

A deliberate release **deletes** its registry rows rather than flagging them dead: the caller already knows it closed the handle, so the row carries nothing it does not have. A `.z.pc` drop is the opposite case and **keeps** its row, because an unexpected disconnect is worth being able to see afterwards. It selects on the *stored* flag, not the live/dead one, so calling it after `hclose` still removes the row — which is the case that matters most.
```q
sub.unsubscribe[tph]
/ `trade`quote
hclose tph;
```

### `subscribed[]`
Return whether any subscription is currently live. The connectivity check a subscriber process needs before declaring itself ready.
```q
sub.subscribed[]
/ 1b
```

### `getsubscriptions[]`
Return the subscription registry: the handle, subscribed tables, syms, subscription timestamp, and a live/dead `active` flag.
```q
sub.getsubscriptions[]
/ handle tabs        syms subtime                       active
/ ------------------------------------------------------------
/ 4      trade quote      2025.06.01D08:00:00.000000000 1
```
`tabs` and `syms` are general columns, so symbols display without backticks and an all-syms subscription shows an empty `syms`.

### `getsubscriptionhandles[proctype;procname]`
Resolve live tickerplant handles by proctype and/or procname, projected to the `procname`, `proctype`, `w` triple a caller needs before it can subscribe. Reads `di.servers`, this module's one hard dependency. Ported from legacy `.sub.getsubscriptionhandles` (`code/common/subscriptions.q:11`), which is registered public api there (`apidetails.q:67`) and called by `rdb.q:163`, `wdb.q:540`, `chainedtp.q:71` and `sctp.q:15`.

```q
sub.getsubscriptionhandles[`tickerplant;()]      / rdb / wdb shape - by proctype
/ procname proctype    w
/ ----------------------
/ tp1      tickerplant 4

sub.getsubscriptionhandles[`;`tp1]               / chained / segmented tp shape - by procname
```

The two arguments are **not interchangeable**, and this is the whole of the function's behaviour:

| Argument value | Meaning |
|---|---|
| `` ` `` | match **every** row |
| `()` | match **nothing**, and switch the combine from intersection to union |
| symbol or symbol list | match those values |

So `[`tickerplant;()]` unions the proctype matches with nothing and yields the tickerplants, while `` [`;`tp1] `` intersects every row with the named one and yields just that process. Only live connections are ever returned — `di.servers` excludes null handles.

**Two deliberate differences from legacy**, both forced by `di.servers`' contract:

- Legacy took a third `attributes` argument and filtered on `.servers.SERVERS`'s `attributes` column. `di.servers`' `SERVERS` carries no such column, so the parameter is **dropped** rather than accepted and silently ignored — a filter that quietly does nothing hands back handles the caller believes were filtered. All four legacy call sites pass `()!()`.
- Legacy passed `autoopen:1b` to retry dead connections on demand. `di.servers` returns live rows only and runs its own retry job, so reconnection is its concern now.

**`di.servers` must be initialised first.** Every `di.servers` accessor refuses to run before that module's own `init` — deliberately, because a pre-`init` `getservers` used to return an empty table, which is indistinguishable from "nothing is connected". That refusal signals under the `di.servers` context and through the `di.servers` logger, so left alone it would travel straight past this module: the caller would see a `di.servers` error from a `di.subscriptions` call, and nothing would reach *this* module's log. So it is caught and re-raised through `raiseerror`, naming both modules:

```
di.subscriptions: getsubscriptionhandles: could not read the di.servers server list
(di.servers: getservers: init must be called before any other function) - di.servers
must be initialised before subscription handles can be resolved
```

Returning an empty table instead would be the wrong call: "I cannot tell you" is not the same answer as "no handles", and a caller that treats them alike waits for a tickerplant that was never going to appear. This is the only place the module reaches into another module's failure and rewrites it, and it does so only to add context, never to change the outcome.

### `teardown[]`
Remove the `.z.pc` registration installed by `init`, leaving no process-global residue. Afterwards `subscribe` is refused until `init` is called again — see Notes. `getsubscriptions`, `subscribed` and `unsubscribe` keep working, so a shutdown path can still inspect and release what it holds, and the registry is left intact.
```q
sub.teardown[]
```
**Liveness degrades while torn down.** With the observer gone, `markdead` no longer fires, so `active` rests on the `.z.W` check alone and the handle-recycling protection is lost until `init` runs again. `init` is idempotent and reinstalls the observer, so the exposure is narrow — but do not treat a torn-down module as merely "quiet".

### `getapimeta[]`
Return this module's api metadata, one row per callable export, for `di.torq` to register with `di.api`.
```q
sub.getapimeta[]
```

### `version`
The module version string, read from the `VERSION` file.
```q
sub.version
/ "0.1.0"
```

---

## Usage Example

```q
/ log and handlers deps must already match their contracts - use di.log and di.handlers:
logging:use`di.log
handlers:use`di.handlers
handlers.init[logging.logdict]
handlerdep:`register`remove!(handlers.register;handlers.remove)

/ load and initialise
sub:use`di.subscriptions
sub.init[`log`handlers!(logging.logdict`log;handlerdep)]

/ define the root upd the replay will drive, exactly as the subscriber process does.
/ NB it must handle BOTH payload shapes - see Notes. simplifying this to the flip alone throws
/ part way through a sym-filtered replay
upd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]];}

/ the caller resolves the tickerplant handle. the usual route is di.servers directly:
servers:use`di.servers
tph:servers.gethandlebytype[`tickerplant;`any]

/ or, having passed di.servers in as the `servers dep, through this module - the legacy
/ .sub.getsubscriptionhandles route the TorQ rdb and wdb take:
/   tph:first exec w from sub.getsubscriptionhandles[`tickerplant;()]

/ subscribe to everything and replay the log
r:sub.subscribe[tph;`;`;1b;1b]
r`subtables      / the tables now defined at root and receiving live updates
r`tplogdate      / the tickerplant log date, for setting the partition

/ check connectivity
sub.subscribed[]
sub.getsubscriptions[]

/ on shutdown - declare the handle finished BEFORE closing it, so a reissued
/ descriptor cannot revive the registry row
sub.unsubscribe[tph]
hclose tph
```

---

## Running Tests

Two suites, following the convention `di.handlers` and `di.permissions` use. Both define their
fixtures inline as `before` rows; there is no separate fixture file, so neither depends on the
working directory.

**Unit suite** (`test.csv`) - 570 assertions, no child processes, no ports, no `QHOME`. It does need `di.servers` on `QPATH`, since the module imports it, and it drives the **real** `di.servers` rather than a mock: the fixtures seed its `SERVERS` registry directly, so the whole selection matrix runs against the genuine `getservers` without opening a socket:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.subscriptions
```

**Integration suite** (`test_integration.csv`) - 131 assertions. It stands up a real q process as a
tickerplant and drives it over genuine IPC, so it needs a q binary reachable via `QHOME`, plus
`di.pubsub` and `di.servers` on `QPATH` - the two modules the dependency tree names, both exercised
here as real modules rather than mocks.

It runs up to **three** processes at once for the `republish` block: an upstream tickerplant, a
middle process that subscribes through this module with `republish` on, and this test process acting
as the downstream subscriber. That is the only way to prove the chained-tickerplant role - a
subscriber that serves its own subscribers has to be at its own main loop, so it cannot be tested
in-process. It does NOT need `di.timer`: `di.servers` validates a timer
dict and schedules one retry job through it, which a stub satisfies, and this suite asserts nothing
about that job.

The peer is built on **`di.pubsub`** — it loads the real publisher, registers subscriptions through
`di.pubsub.subscribe` and fans out through `di.pubsub.publish`, with only a thin `subdetails`
adapter on top of the kind a modular tickerplant process would own. So the publisher half of the
wire protocol is exercised by the actual module rather than a hand-rolled stand-in, including
sym-filtered delivery, which `di.pubsub` decides. Assertions read `di.pubsub`'s own registry on the
peer (`reqalldict`, `reqfilteredtbl`) so this cannot silently regress into a fake.
`moduletest` only ever loads `test.csv` (`di/k4unit/init.q`), which is why these rows live in their
own file - otherwise every unit run would spawn a process and bind a port. Load it explicitly:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.subscriptions;`test_integration.csv]
.m.di.0k4unit.KUrt[]
select from .m.di.0k4unit.KUTR where not ok
```

`KUrt` prints the results table but, unlike `moduletest`, no pass/fail summary - the last line is the
verdict, and an empty result means everything passed.

Run the integration suite in a **fresh** q session - after `moduletest` the unit tests are still
loaded and would re-run against dirty module state, reporting spurious failures. It is fully
self-contained: it inits `di.handlers` and `di.subscriptions` itself rather than inheriting setup
from the unit rows.

Together the two suites are 701 assertions (`true`, `fail` and `run` rows, excluding the fixture `before`/`after` rows) and wire the real merged `di.log` and `di.handlers` rather than mocks, so both injected contracts are proven end to end. Between them they cover: pre-`init` guards on every export; dependency validation (non-dict deps, each missing key, each malformed value); `init` arity asserted by observable effect rather than by "it did not throw"; idempotent re-init; the `VERSION` file and exported `version`; `getapimeta`; all-tables and sym-filtered replay; all four payload shapes a tickerplant may log; symbol-atom table and sym selectors; a multi-table log where only the requested table is defined; replay across two log files; requested-but-absent and offered-but-unrequested tables; a configured `subdetailsfunc`; partial, unreadable, absent and empty logs; a replay requested with no root `upd`; malformed `schemalist` **and** `logfilelist` shapes, including a non-table schema, a column-less table, a duplicated table name, and a keyed schema that must still be accepted; a negative message count, asserted with `replay:0b` as well so the guard cannot drift behind the replay branch; every `setschema`/`replay` combination, including `setschema:0b` with `replay:1b` on both the narrowed and all-syms paths; empty `tabs` and `syms` selectors; the double-subscribe guard and its release by `unsubscribe`; `unsubscribe` deleting rather than flagging, its idempotency, and its `warn` on an unheld handle; malformed tickerplant responses; `setschema:0b` preserving a populated table; `logdir` passthrough; a `setschema:0b` replay whose request names a table that is absent at root *and* unpublished, proving the tables-exist check follows the narrowing rather than the raw request; the full life cycle of a partially re-established subscription — narrowed on the way back, skipped silently while the tickerplant no longer publishes what remains, and retired only once the remainder returns; `getsubscriptionhandles` called before `di.servers` is initialised, asserted on all three counts that matter — the error carries *this* module's context, it names `di.servers` as the module needing wiring, and it lands in this module's log rather than bypassing it; and input validation on every argument.

It also covers the TorQ-protocol cases this module is built to survive: a `0W` message count replaying a whole log, and the same count over a **truncated** log being refused with nothing replayed and no table defined; a **shared** log reported once per table being collapsed to one full replay, with the per-table row counts asserted individually so a regression to the old per-entry replay is caught rather than merely the total; an unshared file in the same response keeping its own count and raising no warn; a corrupt shared log refused, proving the corruption guard covers the collapse trigger and not only the `0W` sentinel; an exact duplicate entry rejected; `` ` `` resolved through `tablelist` with the *resolved* list asserted to be what `subdetails` actually received; the fallback to `` ` `` when a tickerplant offers no `tablelist`; a configured `tablelistfunc` asserted to be called **first**, ahead of `subdetails`; and the two legitimate `rowcounts` shapes accepted with atoms and tables rejected.

One fixture is modelled on the **real** producers rather than on convenience: `subdetails` as `.ps.subscribe` each-left, answering an unpublished name with the error pair instead of omitting it. That distinction matters more than it looks — the forgiving mocks omit, real tickerplants error, and a suite built only on the forgiving shape went green over a subscribe that a single mistyped table name would have taken down entirely. Rows assert that one bad name no longer sinks the call, that the drop is reported with the real reason, that a wholly unpublishable request is refused before `subdetails` runs, and — as an explicit regression guard — that the schema-shape error no longer fires on this path.

The whole-file narrowing is asserted on a shared log that carries a table the tickerplant does not offer: the offered tables replay in full, the unoffered one is never driven into `upd` and so is never created at root, and the `upd` call count distinguishes the two. The same is asserted for the `0W` sentinel, and a per-table log is asserted to still take the unfiltered path.

Guard **ordering** is asserted directly rather than inferred, using a fixture that records every remote function name `subscribe` asks for. Each guard that was moved ahead of the `subdetails` call has a row proving the tickerplant was never asked at all when it fires — including the case whose semantics changed, a requested table that is already held *and* no longer offered, which now throws where it previously warned and continued. The residual cases have rows too: an all-tables subscribe to a tickerplant with no `tablelist` reaches the post-reply copy of the duplicate guard, and a short log is caught only after `subdetails` has run, with assertions on both halves of the error text that tells the caller to close the handle.

Everything above is in the **unit** suite except where it needs a live publisher. The **integration**
suite owns what cannot be faked in process: the replay-then-live exactly-once boundary, a real `.z.pc`
firing when the peer is killed, the `` ` `` round trip over the wire, `unsubscribe` closing the
local-close liveness gap against a genuinely reissued descriptor, and the `di.handlers` isolation
contract below.

The integration suite also covers teardown/re-init lifecycle cycles, and asserts the `di.handlers` isolation contract: a co-registrant that throws at a priority ahead of this module's observer must not suppress `markdead`. That assertion is made through `unsubscribe`, which matches on the stored flag - checking `active` alone would be vacuous, since the closed handle reads dead through `.z.W` either way.

The integration block subscribes to a genuinely separate tickerplant process over IPC, kills it, confirms `.z.pc` marks the subscription dead, reconnects onto a recycled handle number, confirms the stale row stays dead and the re-subscribe succeeds, then drives live updates through the replayed tables to prove the exactly-once boundary. It finishes on the two cases only a real handle can reach: releasing a handle and `hclose`ing it while the tickerplant is still alive (so nothing fires `.z.pc`), reopening onto the same reissued descriptor and confirming no revival; and the reverse order — `hclose` *first*, then `unsubscribe` — which proves the release matches on the stored flag rather than the computed one, and so still finds a row `.z.W` has already given up on.

---

## Notes

- Replay uses kdb+'s native `-11!` directly rather than `di.tplog`. This module replays the first *n* messages; `di.tplog.check` is built for the replay-everything caller and would rewrite an entire log to a `.good` file when corruption lies beyond the messages actually needed, and cannot report the good-message count the preflight requires
- Every log is verified with the non-executing `-11!(-2;logfile)` streaming count *before* any table is defined. This matters: `-11!(n;logfile)` past a corruption point replays the good messages and only then throws, leaving tables half populated
- **That guarantee covers log corruption, not every replay failure.** Preflight cannot vet the root `upd` itself. If `upd` throws part-way through a replay — bad data, or a bug in the caller's own handler — the tables are already defined and partially populated, and no registry row exists, because the row is appended after the replay completes. `subscribe` signals, but the process is *not* untouched. Do not read the preflight guarantee more broadly than it is stated
- The registry retains a row for every subscription that ended via `.z.pc` (tickerplant death) for the life of the process; only `unsubscribe` removes rows. This is deliberate for v1 rather than merely unfixed: the case that would make it matter — a flapping tickerplant generating dead rows continuously — **is not reachable without auto-reconnect**, which this module does not implement. Today a dead handle is only replaced by a human or an external supervisor calling `subscribe` again, which is inherently rate-limited. Bounding this belongs with the auto-reconnect design, where the reconnect cadence will be known rather than guessed at now. `activesubscriptions` recomputes liveness across the whole registry on every accessor call, so the bound on rows is also the bound on that cost
- The subscribed set is what was requested intersected with what the tickerplant offered. A requested table the tickerplant does not return is logged at `warn` and skipped; a table it volunteers unasked is logged at `warn` and ignored - neither defined nor replayed
- **`unsubscribe` releases at the tickerplant when a release verb is configured.** Set `unsubscribefunc` at `init` to the name of a tickerplant-side function that drops this connection's registrations, and `unsubscribe` calls it — the release is then real, not local bookkeeping. This matters because shipped TorQ has a gap: `suball` and `subfiltered` each clear only their **own** registry (`pubsub.q:34,41`), so moving from an all-syms to a filtered subscription on one connection leaves the all-syms entry behind and the wider feed keeps arriving. Measured against a live segmented tickerplant, and measured again with `unsubscribefunc` wired: the same sequence then delivers only the narrowed syms, with no all-syms entry left at the tickerplant. The verb needs `.z.w` — the caller's handle as the tickerplant sees it — so only the tickerplant can offer it; `di.tickerplant` should expose one, e.g. `` {[tabs] .stpps.delhandle[;.z.w] each (),tabs; .stpps.delhandlef[;.z.w] each (),tabs} ``. Left unset, `unsubscribe` drops local rows only and says so at `warn`, naming the reason
- **The return dictionary carries both this module's key names and legacy's, because a real consumer reads legacy's and reads them silently.** `rdb.q:171` takes `subtables` and `tplogdate`, and `wdb.q:546` takes `tplogdate` — those names match. But `chainedtp.q:81-84` and `sctp.q:22-25` both read `` `d `` and `` `icounts ``, *through* `` if[`d in key r] `` / `` if[`icounts in key r] `` guards. A missing key there does not fail: the chained tickerplant simply never sets its own `.u.d` and never seeds `.u.icounts`/`.u.jcounts`, and every downstream subscriber of *that* process then gets wrong counts, with nothing logged anywhere. So `icounts` and `d` are emitted alongside `rowcounts` and `date`, holding the same values, and the suite runs `chainedtp.q`'s own seeding expression verbatim against the return as a compatibility test. `rowcounts`/`date` remain canonical — they are the tickerplant's own key names, carried through from the `subdetails` reply unchanged, where `subtables`/`tplogdate` are names legacy invented and so keep legacy's spelling. Legacy's `i` is deliberately **not** emitted: no shipped consumer reads it, and legacy gives it two different meanings by tickerplant type (the whole `logfilelist` for segmented, the message count for standard and chained) that this module has no `tptype` to disambiguate between
- **A requested table the tickerplant does not publish is dropped from the request before it is sent, not passed through.** This is not tidiness. `subdetails` is `.ps.subscribe` **each-left** over the table list, and every shipped producer fails on a name it does not publish: the standard one *signals* `'x` (`u.q`, `sub`), while segmented and chained answer with the pair `` (name;"Table … not in list of stp pub/sub tables") `` (`pubsub.q`), which the schema guard then rejects. Either way **one** bad name sinks the **whole** call — and because the each-left runs left to right, every valid table ahead of it has already been registered by `suball` before the failure, leaving a partial subscription live at the tickerplant that nothing on this side records. A typo, a stale process config, or a table retired at the tickerplant would otherwise take down an entire subscription. The request is therefore narrowed against the `tablelist` round trip first, exactly as legacy's `reducesubs` does (`subtabs:subtabs inter utabs`), and each dropped table is logged at `warn` with the real reason. A request the tickerplant publishes *none* of is refused outright, before `subdetails` is called and so before anything is registered
- **One `tablelist` round trip serves both jobs**, and it runs before every guard because it is *pure* — `tablelist` is `{.stpps.t}` on both shipped producers and registers nothing, unlike `subdetails`. When the tickerplant cannot answer it, `` ` `` is sent onward and an explicit request goes unnarrowed, exactly as before; that is reported at `warn` only when the `` ` `` sentinel genuinely had to be resolved, and at `info` on the explicit path where the round trip is a safety net rather than a requirement
- Liveness needs three signals, and the measured behaviour of each is what dictates the design. On KDB-X 5f: a handle the process `hclose`s itself fires **no** `.z.pc` and leaves `.z.W`; a remote death fires `.z.pc` with the handle; and a closed descriptor **is** reissued to the next connection (`4` → `4`). So `.z.pc` covers tickerplant death, `.z.W` covers a local close *until the number is reused*, and `unsubscribe` covers the reuse case by clearing the stored flag outright. `.z.pc` is why `handlers` is a required dependency; `.z.W` alone is not sufficient, because a recycled number would revive a stale registry row
- The double-subscribe guard compares the **requested** table list — the caller's list, or the concrete list `` ` `` was resolved to — against what is already held, and it runs *before* the tickerplant is asked for anything. Re-subscribing to a table you already hold is a caller mistake whatever the tickerplant happens to offer that round; comparing against the *offered* set instead let the same mistake through with only a `warn` whenever the tickerplant had also stopped offering the table, which was an accident of ordering rather than a considered exception. The guard runs a second time against the offered set, for the one request that cannot be resolved up front (see below). An all-tables subscribe is still refused only where it genuinely overlaps a live subscription, not merely because some other subscription exists
- **Asking a tickerplant for its schemas subscribes you to it.** `subdetails` calls `.ps.subscribe`, which *is* `.u.sub`, so the one call that returns the schemas also registers the handle for live delivery — and the protocol has no unsubscribe verb to undo it. `unsubscribe` here is local bookkeeping only; tickerplant-side release is driven by `.z.pc`, which nothing but closing the handle triggers. Every guard that does not need the reply therefore runs **ahead** of that call: the duplicate guard, the root-`upd` check, and the tables-exist check for `setschema:0b`. That is legacy's own ordering — `reducesubs` runs against a `tablelist` round trip before `subfunc` — restored rather than invented, and it is what makes the `tablelist` round trip load-bearing for a second reason beyond the `` ` `` sentinel. The tables-exist check runs after the request has been narrowed but still ahead of `subdetails`, which costs nothing — the `tablelist` round trip behind the narrowing is pure and registers nothing — and avoids demanding a table at root that the narrowing was about to drop anyway
- **What is left of that window, precisely.** With `replay:0b` it is closed for every subscribe that names its tables, and for an all-tables subscribe whenever the tickerplant answers `tablelistfunc` — which both shipped producers do. It stays open only for an all-tables subscribe against a tickerplant offering no usable `tablelist`, where the request cannot be resolved before the call. With `replay:1b` one case is **irreducible**: the log preflight. The log file names exist only in the reply and their integrity can only be established by reading them, so a log that is short, corrupt or unreadable is necessarily discovered *after* the handle is registered. `subscribe` then throws and records no registry row, while the tickerplant goes on publishing into the caller's root `upd` — so the module's own view and reality diverge. The error raised in that case says so explicitly and names the only remedy the protocol leaves: close the handle before retrying. No extra registry state is kept for it; the case is narrow and a third liveness state would cost every reader of `getsubscriptions[]` more than it would buy
- Tables are created at root with `@[`.;name;:;schema]`, and `-11!` resolves `upd` at root even when invoked from module context. A root-level `upd` must therefore be defined before calling `subscribe` with `replay` set - this is **enforced**, not merely expected: without it every replayed message would be silently discarded and the narrowed path would leave its no-op stand-in bound at root, so the live feed would vanish into it too
- A malformed `subdetails` response is rejected before anything is defined, including a `schemalist` that is not a list or whose entries are not `(tablename;schema)` pairs. An empty entry is tolerated, as legacy does
- The *schema* half of each entry must actually be a table. This is not pedantry: `createtables` uses `@[`.;name;:;schema]`, which succeeds for **any** value, so without the check a tickerplant sending a dict or an atom would have it planted at root under the caller's table name and `subscribe` would report success over a root name that is not a table. The test is `.Q.qt` rather than `98h=type`, deliberately — a **keyed** table is `99h` and must still be accepted, while a column-less `([])` is also `99h` and must not be, since it has no columns to replay into. The guard also catches a shape that is not a garbled schema at all: TorQ's `.u.sub` answers a table it does not publish with `` (name;"Table … not in list of stp pub/sub tables") ``, so a **string** in the schema position is the tickerplant declining the table, and the error message says so
- A `schemalist` naming the same table more than once is rejected rather than deduplicated. The duplicate would otherwise flow straight into `subtables` — which `di.rdb` and `di.wdb` iterate over — and into the registry's `tabs`. Deduplicating would hide a tickerplant bug; every other malformed response here fails loud, so this does too
- `setschema:0b` skips table definition entirely, so a subscriber that pre-loads its own schema keeps it. With `setschema:1b` the returned schema replaces whatever is at root, which is why re-subscribing a live table is refused. Combining `setschema:0b` with `replay:1b` requires the tables to exist at root already, and that is **checked** — otherwise the replay fails inside the caller's own `upd` on the all-syms path, or from `cols get t` on the narrowed one, neither of which reaches the log. The check is against the tables actually being subscribed to, not the caller's raw list: a table the tickerplant does not publish is dropped with a warning and never becomes part of the subscription, so it is not required at root. The check runs twice — once on the narrowed request before the tickerplant is asked, and once on the confirmed set after it replies, which still catches a table the `tablelist` advertised but `schemalist` then declined
- **After `teardown`, a new `subscribe` is refused — reading and releasing still work.** `teardown` removes the `.z.pc` observer, and without it a dropped tickerplant's registry row keeps reporting live for as long as `.z.W` still holds the handle number, and *indefinitely* once kdb+ reissues that number to another connection. That is exactly the failure the `handlers` dependency exists to prevent, so taking a **new** subscription in that state now throws and names the recovery (`call init again`) rather than degrading silently into the `.z.W`-only mode this module documents as insufficient. `getsubscriptions`, `subscribed` and `unsubscribe` deliberately keep working, because a shutdown path needs to inspect and release what it already holds. `init` is idempotent and restores the observer. This reverses an earlier deliberate choice — the previous behaviour let the subscribe through and accepted degraded liveness tracking — because silent degradation is inconsistent with how every other guard in this module behaves
- **The root `upd` must accept two payload shapes, and which one it gets depends on the subscription.** An unfiltered replay hands `upd` the logged payload exactly as the tickerplant wrote it — normally a list of columns. A **sym-filtered** replay hands it a **table**, because `replayfilter` has to materialise one to filter by column name rather than by position. Legacy's `replayupd` behaves the same way, so this is inherited rather than introduced, but it is a real contract: an `upd` written only for the column-list shape throws part-way through a filtered replay, after earlier messages have already been applied. Write it as `` {[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]]} ``, which is what the usage example and the test fixtures use. The live feed is unaffected — it never passes through `replayfilter`
- **Live-feed filtering is the tickerplant's job, not this module's.** `replayfilter` is installed only for the duration of a narrowed replay and torn down the moment it ends; live messages after that reach the caller's `upd` unfiltered by anything here. That is correct, not a leak: the `subdetails` call itself registers the handle for tickerplant-side filtered delivery as a *side effect*. In shipped TorQ, `subdetails` calls `.ps.subscribe`, which **is** `.u.sub`, which routes through `suball`/`subfiltered` to `selfiltered` - and that records `(tbl;handle;filts;columns)` with `filts` built as `` (in;`sym;syms) ``, which `pub` then evaluates per subscriber. Replay needs its own filter only because it bypasses the publish layer entirely and reads the log file directly. Without this note a reader seeing `replayfilter` removed right after the replay would reasonably read it as a bug
- **That delegation is verified end to end.** Measured against a live TorQ v1.0 segmented tickerplant (`singular` multilog, `replayperiod day`) at the time the delegation was written — that instance is long gone, so treat it as a recorded measurement of the subscribe/filter path, not of later additions such as `getsubscriptionhandles` or `republish`, which are covered by the suites instead: a sym-filtered subscribe on a fresh connection registers `` filts: ,,,(in;`sym;,,`S1) `` in the tickerplant's `.stpps.subrequestfiltered`, leaves `subrequestall` empty for that table, and delivers only the matching rows live — two of three published. So the filtering really is the tickerplant's, not an assumption about it
- **The `0W` message count means "replay everything", not "more than I have".** A segmented tickerplant reports `0Wj` for every **closed** log under `replayperiod` `` `day ``. It is resolved to the log's own readable total rather than forwarded to `-11!`, because `-11!(0W;log)` over a corrupt log replays the good prefix and only *then* throws - precisely the half-populated state the preflight exists to prevent. A corrupt log is **refused** on this path, even though its readable prefix could be replayed: the whole log was asked for, so a prefix would be a silently incomplete history. On the ordinary finite-count path, damage lying *beyond* the messages actually needed is still tolerated
- **A shared log is replayed once, in full.** In `singular` and `periodic` multilog modes a segmented tickerplant writes every table to **one** file, and reports that file once *per table* with a different count each time. Replaying it once per entry re-applies the head of the file - measured, `(4;LF)` then `(2;LF)` over a six-message log applies messages 0 and 1 twice and never reaches 4 and 5. Duplicate entries for one file are therefore collapsed to a single replay of the whole file, with the table filter discarding the rest, and the condition is logged at `warn`. **The trade-off is trailing duplicates, not missing rows:** messages logged between the `subdetails` call and the replay arrive twice, once from the log and once on the live feed. That is deliberate - the alternative (summing the per-table counts) never duplicates but silently *drops* rows whenever the shared log also carries tables you did not subscribe to, and a missing row is invisible and permanent where a duplicate is visible and diagnosable. An **exact** duplicate entry - same file *and* same count - is rejected instead, because no shipped tickerplant can emit one: the segmented producer applies `distinct` to these pairs itself, and the chained and standard producers emit at most one entry each
- **A whole-file replay is narrowed to the offered tables; a per-table one is not.** An all-tables, all-syms subscribe normally replays the log raw, with no filter wrapper — correct for a per-table log, because the tickerplant returned that file *because* it belongs to a table it offered. It is not correct for a file read to its end, and the difference is structural rather than hypothetical: a segmented tickerplant opens logs for `` tables[`.] except `currlog `` (`stplog.q`, `logtabs`) but publishes only `` tables[] except `currlog`heartbeat`logmsg`svrstoload `` (`segmentedtickerplant.q`, `.stpps.init`), and `.stpps.upd` applies **no** membership check before logging. So in `singular` and `periodic` multilog modes the one shared file can legitimately carry tables the tickerplant declined to offer a schema for, and replaying it raw would drive the caller's `upd` with a table it never subscribed to — throwing part-way through a replay, or silently creating a wrongly-shaped table at root. Both whole-file triggers are narrowed to the subscribed set: the shared-log collapse and the `0W` `` `day `` sentinel, which has the same exposure. The sym filter still passes straight through when `syms` is `` ` ``, so the cost is one table-membership test per message on that path and nothing else. This was found by adversarial probe rather than by the suite, and it pre-dated the shared-log collapse — the collapse widened it from a leaked prefix to a leaked whole file rather than introducing it
- **Upstream requirement for `di.tickerplant`: do not `distinct` the per-table log pairs.** `getlogs` applies `distinct` to its `(messagecount;logname)` pairs (`stplog.q`), so when every table in a shared log happens to have the *same* count, the per-table entries are collapsed **at the tickerplant** and the reply that arrives is byte-identical to a legitimate single-log one. No subscriber can distinguish the two, because the distinguishing information was discarded before it was sent. The shared-log collapse here handles every case the protocol still carries — differing counts, and the `0W` sentinel — and this one is closed by the producer either not applying `distinct` or reporting per-table log offsets. Raised against `di.tickerplant` rather than worked around here, because a subscriber-side guess would have to be a heuristic and this module does not ship heuristics
- **`subdetails` is never sent the `` ` `` sentinel if it can be avoided.** A segmented tickerplant cannot accept it: its `subdetails` hands `tabs` straight to `.stplg.replaylog`, whose `where tbl in t` matches nothing for an atom and then signals `` 'rank ``. Legacy never hit this because it resolved a concrete table list with a `tablelist` round trip *first* and passed that onward; dropping that round trip for a single bundled call turned out to remove something load-bearing. `` ` `` is therefore resolved via `tablelist` before `subscribe` calls `subdetails`. If the tickerplant has no `tablelist`, or answers with something that is not a symbol list, the module logs at `warn` and sends `` ` `` anyway - a chained tickerplant handles the sentinel correctly, and a tickerplant with no `tablelist` is not a segmented one. The caller's *intent* is tracked separately from the resolved list, so resolving `` ` `` does not switch an all-tables subscription onto the narrowed replay path or raise spurious missing/unrequested warnings
- **`rowcounts` is validated for shape only, and two shapes are legitimate.** A dictionary keyed by table is the usual one; an **empty list** is equally real, because a chained tickerplant builds its response as `` (`schema`icounts`i`logfile`d)!() `` - which broadcasts `()` to every value - and only overwrites `icounts` when its *own* `subscribesyms` is `` ` ``. TorQ's own consumer guards for exactly that. Anything else - an atom, a table - is rejected. The *contents* are not checked against anything, because there is no `di.tickerplant` contract to check them against yet; they are passed through to the caller as received. The shape check earns its place because the field is load-bearing downstream: a chained subscriber seeds its `.u.icounts`/`.u.jcounts` straight off it, so a wrong shape would otherwise fail far from its cause
- A malformed `logfilelist` is rejected on the same terms as `schemalist` — a non-list, an entry that is not a `(messagecount;logfile)` pair, a non-integer count or a non-symbol log file. A **negative** count is rejected too, which no shape check catches, since `-1` is a perfectly good integer; that guard lives in the response validation rather than the replay preflight so it also fires when `replay` is `0b`
- `subdetails` is TorQ's real protocol, defined at root by `chainedtp.q` and `segmentedtickerplant.q`, returning `` `schemalist`logfilelist`rowcounts`date `` and optionally `` `logdir ``. Both also define `tablelist` at root, which is how `` ` `` is resolved. The key names and shapes here were taken from that source and are exercised against a tickerplant process built to the same protocol in the integration tests; the module has **not** yet been run against a live TorQ chained or segmented tickerplant. `di.tickerplant` is not built yet - when it lands, point `subdetailsfunc` at its entry point if the name differs
- Not implemented: remote-log streaming. The subscriber is assumed to share the tickerplant's filesystem and replays from the log path the tickerplant reports — the classic tick assumption, and what legacy `.sub` does. This is a capability TorQ does not have either, rather than a port omission
- The modularisation plan places this module in the FRAMEWORK tier with `-> di.servers, di.pubsub`. Both are real module imports, `use`d in `init.q` and declared in `deps.q`. `di.servers` backs `getsubscriptionhandles`; `di.pubsub` is the **local** publisher a chained or segmented tickerplant republishes through, wired by the `republish` config key. The module also speaks the *remote* publisher's wire protocol over IPC, which is a separate thing from the local import and is exercised by the integration suite's peer. See Dependencies
- `unsubscribe` is the supported way to close the local-close liveness gap, but it is a **cooperative** mechanism, not a structural one: kdb+ exposes no way to detect an *unannounced* `hclose`, and no way to tell whether a reissued descriptor is still the same remote. A caller that closes a tickerplant handle without calling `unsubscribe` first, and whose descriptor is then reissued, can still leave a stale row appearing live. Tickerplant death, and any local close that goes through `unsubscribe`, are both exact. With `unsubscribefunc` configured the tickerplant-side release is exact too
