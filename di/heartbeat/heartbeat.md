# di.heartbeat

Periodic liveness signalling over pub/sub, and monitoring of other processes' beats.

A process publishes a heartbeat row on a timer so downstream monitors can detect that it has stalled
or blocked, even when the underlying TCP connection is still perfectly valid. The same module carries
the monitor role: subscribing to other processes' heartbeats, tracking the last beat seen per process,
and raising warning and error transitions when they stop arriving.

Consolidates TorQ's `code/common/heartbeat.q` (the `.hb` namespace), covering both roles.

## Features

- **Publisher** (`enabled`, default on) - publishes one row per `publishinterval` over `di.pubsub`.
- **Monitor** (`subenabled`, default off) - subscribes to configured process types, stores incoming
  beats, and flags `warning` then `error` as processes go quiet.
- **Pluggable transitions** - `onwarning` and `onerror` callbacks receive the affected rows. No
  dashboard dependency is baked in.
- **Local-only mode** (`publishroot:0b`) - track own heartbeats without touching root namespace at all.
- **Own clock** - `setcp` overrides the module's time source for testing and simulation, independently
  of `di.timer`'s clock.

## Dependencies

All injected via `init`; there are no hard module dependencies (`deps.q` is empty).

| Key | Required | Must expose | Notes |
|---|---|---|---|
| `log` | always | `info`, `warn`, `error` | binary `{[ctx;msg]}` - `di.log`'s `logdict` fits directly |
| `timer` | always | `addjob`, `deletejobs` | `addjob` must be the variant dict exposing `custom` |
| `pubsub` | always | `publish`, `subscribe` | `di.pubsub` |
| `servers` | when `subenabled` | `getservers` | `di.servers`; returns a **table**, handles are its `w` column |
| `handlers` | when `subenabled` | `register`, `remove` | `di.handlers`; 5-arg `register[event;phase;nm;pri;func]` |

Nothing is silently defaulted. A missing or malformed dependency throws from `init` with a message
naming the module that supplies it.

## Initialisation

`init` takes exactly **one** dict, carrying dependencies and config side by side.

```q
logging:use`di.log
timer:use`di.timer
ps:use`di.pubsub
hb:use`di.heartbeat

timer.init[]
hb.init[logging.logdict,`timer`pubsub`proctype`procname!(timerdep;psdep;`rdb;`rdb1)]
ps.init[]                              / MUST run after hb.init - see Ordering below
```

`proctype` and `procname` are **required**. They are published as the heartbeat's `sym` and `procname`
and have no sensible default. (Legacy took them from `.proc.*`; a module cannot.)

> **Dict-building gotcha.** `!` and `,` are both right-to-left with no precedence, so
> ``` `a`b!(x;y),moredeps ``` parses as ``` `a`b!((x;y),moredeps) ``` - the comma binds to the *value
> list*, not the dict, and you get a `'type`. Build the base dict first, or keep an inline `k!v` last.

### Ordering: `di.pubsub.init[]` must run *after* `di.heartbeat.init[]`

`di.pubsub` decides which tables it will serve by scanning **root** `tables[]` when its own `init`
runs, and resolves each name with `value`. `di.heartbeat.init` is what puts the `heartbeat` schema
table at root. Reverse the order and `di.pubsub` never sees the table: `subscribe` is refused and
`publish` silently discards every row. Nothing errors. The integration suite asserts this path
end-to-end for exactly that reason.

> **Known gap - the wider discovery surface is LIVE, not fixed.** Because nothing currently calls
> `di.pubsub.setsubtables`, `di.pubsub` still auto-discovers *every* root table present when its
> `init` runs - not just `heartbeat`. `di.heartbeat` deliberately does **not** call `setsubtables`
> itself: that function replaces the list wholesale and `di.pubsub` exposes no getter, so a consumer
> cannot add itself without silently removing everyone else. Closing this belongs to **`di.torq`**,
> the only component that knows the full table set - the same reasoning that puts `getapimeta`
> collection there. Until `di.torq` does it, this remains a known, temporary gap.

## Configuration

Passed in the same dict as the dependencies. Every key is optional.

| Key | Default | Source of default | Description |
|---|---|---|---|
| `enabled` | `1b` | both agree | publish and check heartbeats |
| `subenabled` | `0b` | both agree | monitor other processes |
| `debug` | `1b` | both agree | log warning/error transitions |
| `publishroot` | `1b` | new | publish at root; see below |
| `publishinterval` | `0D00:00:30` | both agree | how often to publish |
| `checkinterval` | `0D00:00:10` | both agree | how often to check |
| `warningtolerance` | `2f` | **shipped** | warning after `tolerance * publishinterval` |
| `errortolerance` | `3f` | **shipped** | error after `tolerance * publishinterval` |
| `maxage` | `0D24:00:00` | new | forget a process silent this long; `0Wn` to keep forever |
| `connections` | `` `ALL `` | **shipped** | process types to monitor; `` `ALL `` means every one |
| `onwarning` | no-op | new | unary callback given the rows entering warning |
| `onerror` | no-op | new | unary callback given the rows entering error |
| `pid` / `host` / `port` | `.z.i` / `.z.h` / `system"p"` | legacy | captured once at load, as legacy did |

**On "shipped" vs in-file defaults.** Legacy carried two different sets: the `@[value;...]` fallbacks
inside `heartbeat.q` (`1.5f`, `2f`, `()`) and the values actually shipped in
`config/settings/default.q` (`2f`, `3f`, `` `ALL ``). This module takes the **shipped** values - they
reflect what really ran. The in-file `connections:()` could not be used at all: with it, `` `ALL in () ``
is false and every subscription lookup returns nothing, so the whole monitor path silently does nothing.

### Config that `init` refuses

Every one of these would otherwise produce a module that runs happily and does the wrong thing
silently, so each is rejected up front rather than left to be discovered in production:

| Rejected | Why |
|---|---|
| `errortolerance <= warningtolerance` | a process reaches error before warning, so the warning transition can never fire |
| tolerance `<= 0` (including `0n`) | the grace period is zero or negative, so every process is flagged immediately and permanently |
| interval `< 1 second` | `di.timer` schedules in whole seconds; `tosecs` **rounds**, so anything under 500ms becomes a period of `0` and the job would run on every timer cycle |
| null `proctype` or `procname` | they key the monitor's store, so nulls collapse every publisher into a single row |

Setting `subenabled:1b` with an **empty** `connections` list is legal but warns: it is the same shape
as legacy's in-file `connections:()` default, where the entire monitor path silently did nothing. Use
`` `ALL ``, or name the process types to watch.

Setting `subenabled:1b` with an **empty** `connections` list is legal but warns: it is the same shape
as legacy's in-file `connections:()` default, where the entire monitor path silently did nothing. Use
`` `ALL ``, or name the process types to watch.

## Robustness

Three properties worth knowing about, because each one exists to stop a *local* failure becoming a
*permanent* one.

**Two silent-projection traps are closed at `init`.** A callback of the wrong arity is *not* an error
in q — applying a two-argument function to one argument yields a projection, so it would never run and
never log. `init` therefore checks callback **arity**, not just type. Likewise `setcp` calls the clock
function once and checks it returns a timestamp: a clock returning anything else does not throw inside
`checkheartbeat`, it just makes every staleness comparison evaluate false, silently switching
monitoring off. (Consequence: the clock's state must exist when `setcp` is called.)

**A broken callback cannot stop heartbeating.** `onwarning`, `onerror` and the `pubsub.publish` call
all run isolated: a throw is logged at error and execution continues. This matters more than it looks.
Both timer jobs are scheduled through `di.timer`, whose `addjob.opts` defaults `disableonfail:1b` — so
an unprotected throw would not merely skip one beat, it would **permanently disable** the job. A single
bug in a client's `onwarning`, or one transient pub/sub outage, would silently end the monitoring this
module exists to provide. State is always updated *before* a callback fires, so isolation never leaves
the store inconsistent. Same reasoning `di.handlers` applies to its `post` phase.

**A misbehaving publisher cannot corrupt or blind the monitor.** `storeheartbeat` validates what
arrives over the wire:

- a batch missing `sym`, `procname` or `time` is rejected with a named error (not a raw `'rank`);
- rows with a **null time** are dropped with a warning — such a row is permanently invisible to
  `checkheartbeat`, since `now > time + period` is never true against a null, so the process could
  never be flagged however long it stayed silent;
- **unknown columns are ignored, not rejected.** A publisher on a newer schema would otherwise have
  every heartbeat refused and be reported *dead* by this monitor — a far worse failure than dropping a
  column we have no use for. Version skew is warned about once per distinct column set, so it stays
  visible without a log line per beat.

**The store is bounded.** `hb` is keyed on `sym`+`procname`, so anything that churns identities —
containers with generated names, a process restarting under a new `procname` — would otherwise add a
row per incarnation that lives for the life of the monitor. `checkheartbeat` evicts processes silent
for longer than `maxage` (default one day), and logs what it dropped.

Two properties of that policy are deliberate and worth stating, because the obvious implementations
get both wrong:

- **Eviction is by age, never by row count.** A dead process has an *old* timestamp by definition, so
  a "keep the newest N rows" cap would discard exactly the rows worth keeping.
- **A row that has never heartbeated is never evicted.** Those come from `addprocs` and represent
  operator *intent* rather than an observation — silently forgetting a process you declared you were
  expecting would stop it being reported missing, which is the whole point of seeding it. They are
  cleared only by `removeprocs`.

**Only a row already flagged `error` is ever evicted.** Validating `maxage > errorperiod` is *not*
sufficient on its own — it only guarantees the transition would have fired had a check run in the
window. A monitor that was paused or restarted, or one handed a heartbeat carrying an old timestamp,
gets its first check when the row is already past `maxage`; gating solely on age evicted it without
anyone ever being told the process had stopped. Gating on `error` makes "forgotten only after being
reported" structurally true rather than dependent on check cadence — the row simply survives one extra
check cycle. Set `maxage:0Wn` to disable eviction entirely.

**Flipping a flag off on re-`init` cleans up after the previous one.** `registertimers`,
`registerhandlers` and the root-name sync all *reconcile* rather than only add. Re-initialising with
`subenabled:0b` deregisters the `.z.pc` observer; with `publishroot:0b` it removes the published root
names. Both leaks were real and both were permanent: `teardown` used to key off the *current* config,
so once a flag was off nothing could remove what the earlier init had installed. A lingering
`.heartbeat.subscribe` is the worse of the two — a remote monitor can still subscribe *successfully*
and then receive nothing for the life of the process, while believing it is watching you.

The root-name sync runs **before** any timer is scheduled, since it is the only step that can fail on
external state — so a failure leaves the process untouched rather than half-configured.

### `publishroot` - and what `publishroot:0b` actually means

With `publishroot:1b` (the default) the module publishes two names at root, both removed by `teardown`:

- `heartbeat` - the empty schema table `di.pubsub` discovers and resolves.
- `.heartbeat.subscribe` - the entry point a monitor calls to subscribe itself (see below).

(A root table `heartbeat` and a root namespace `.heartbeat` do not collide in q — verified in both
creation orders.)

**A pre-existing `heartbeat` table is never taken over — not even a column-identical one.** If the
name is already occupied at root by a table this module did not create, `init` **errors**. This is a
real case, not a hypothetical: `di.subscriptions` installs subscribed schemas at root, so a monitor
watching a tickerplant that carries `heartbeat` already has one.

There is deliberately **no adoption path**, and column compatibility is deliberately *not* used as a
signal. "Identifier plus timestamp plus a few status fields" is a common table shape, so matching
columns are no evidence that a table means the same thing — adopting on that basis would silently
co-mingle liveness rows with whatever the real owner stores there, leaving only a log line to explain
it afterwards. Nothing is lost by refusing, either: the publish table is *only ever an empty schema
holder* (rows go out over pub/sub, never into it), so a stale one from an earlier load costs nothing
to remove. The error says exactly that, and names both remedies (remove it, or run `publishroot:0b`).

Re-`init` over the module's **own** table is fine — ownership persists across re-init, and `teardown`
removes only a table this module created.

**`publishroot:0b` means "do not publish at all, track locally" - not "publish, but privately".**
This is a real behavioural difference, not just a doc note. Without the root schema table `di.pubsub`
can never serve this topic, so a version that merely skipped the root call would build and discard a
row on every tick, forever, with no subscriber possible. Instead, with `publishroot:0b`:

- no root names are created;
- `publishheartbeat` does **not** call `pubsub.publish` at all;
- the row is retained in module-private state, readable via `getownhb[]` (last row only, so memory
  stays bounded).

So `enabled:1b, publishroot:0b` is a valid, meaningful combination: this process keeps beating for
local introspection, and nothing it produces is visible to anyone else or written to root namespace.
Legacy had no equivalent - every heartbeat was always globally visible - so this is a deliberate
addition, not a port.

## How a monitor subscribes

`di.pubsub.subscribe` registers **the caller's own `.z.w`**. A monitor therefore cannot subscribe
itself to a remote publisher by calling it locally - it would only ever subscribe itself to itself.

Legacy solved this with a synchronous IPC call (`heartbeat.q:92`), and so does this module: the monitor
calls the publisher's root ``.heartbeat.subscribe`` over the handle. During that inbound call the
publisher's `.z.w` *is* the connection back to the monitor, so the subscription lands correctly.

```q
hb.subscribe[handle]        / monitor side; sends `.heartbeat.subscribe to the publisher
```

A failed subscribe is logged and **not** recorded, so the next `hbsubscribe` tick retries it.

**Handle 0 and null handles are refused.** A "remote" call on handle `0i` evaluates *locally*, so
subscribing it would register this process as a subscriber to its own heartbeats and then publish to
handle 0; a null handle is a disconnected server row. Both are dropped from `subscribe` and from the
`getservers` sweep, with a warning. Legacy guarded the same case by seeding
`subscribedhandles:0 0Ni` (`heartbeat.q:21`) — the guard is deliberate, not incidental.

> **Security note.** `.heartbeat.subscribe` is callable by anyone holding a handle to this process,
> exactly as legacy's `.ps.subscribe` was. It takes no arguments and only subscribes the caller to the
> heartbeat table, so the exposure is small — but it is a root-published remote entry point, and a
> deployment running `di.permissions` will want it in scope of whatever gates `.z.pg`.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `[dict]` | wire dependencies and config; idempotent |
| `teardown` | `[]` | release timer jobs, the `.z.pc` registration and the root names |
| `version` | - | module version string, read from `VERSION` |
| `getapimeta` | `[]` | api metadata rows for `di.torq` to register with `di.api` |
| `publishheartbeat` | `[]` | publish one row and bump the counter (timer job) |
| `checkheartbeat` | `[]` | flag processes past their grace periods (timer job) |
| `storeheartbeat` | `[table]` | store incoming beats, latest per process, clearing state |
| `addprocs` | `[proctypes;procnames]` | seed expected processes so a silent one is still flagged |
| `removeprocs` | `[proctypes;procnames]` | forget the named processes entirely; the counterpart to `addprocs` |
| `subscribe` | `[handles]` | subscribe to heartbeats on the given remote handle(s) |
| `gethb` | `[]` | the store of heartbeats **received** from others |
| `getownhb` | `[]` | the last heartbeat **this** process produced (populated when `publishroot:0b`) |
| `setcp` | `[func]` | replace the module's clock, for tests and simulation |

Every function except `init` requires `init` to have run first, and says so if it has not.

**Input validation.** Every public function validates its arguments and routes failures through the
log before signalling, so a bad call names itself rather than surfacing as a raw `'type` / `'length`
from somewhere downstream:

| Call | Behaviour |
|---|---|
| `storeheartbeat` on a non-table, or missing `sym`/`procname`/`time` | errors, naming the columns it got |
| `storeheartbeat` with a non-timestamp `time` column | errors, naming the type it got |
| `onwarning`/`onerror` of the wrong arity | rejected at `init` — see below |
| `setcp` with a function not returning a timestamp | rejected, the function is called once to check |
| `subscribe` with a negative handle | accepted, skipped, warned |
| `storeheartbeat` rows with a null `time` | dropped, warned (see Robustness) |
| `storeheartbeat` with unknown columns | ignored, warned once (see Robustness) |
| `addprocs` with mismatched lengths or non-symbols | errors, naming the two lengths |
| `subscribe` with a non-integer | errors |
| `subscribe` with `0i` or a null handle | accepted, skipped, warned |
| `setcp` with a non-function | errors |

## Store schema

`gethb[]` returns a table keyed on `sym` (the publishing process **type**) and `procname`:

```
sym procname | time counter pid host port warning error
```

`addprocs` seeds rows with null `counter`/`pid`/`port`, so a process that never beats at all still
appears and still transitions to warning and error. A real beat arriving later wins.

**A *gradually* escalated process carries `warning:1b` and `error:1b` together.** Both statements are
literally true — it is past both thresholds — and it matches legacy, which sets each flag
independently and never clears either (`heartbeat.q:71,77`). Only a fresh heartbeat clears them, in
`storeheartbeat`. (Queried on PR #109; legacy semantics kept.)

But a process that crosses **both** thresholds between two checks — a long `checkinterval`, or a
monitor that was paused — gets `error:1b` with `warning` still `0b`, because it was never observed in
the warning state and that transition never fired. So do not treat `warning` as implied by `error`. A
consumer rendering both columns should key off `error` first and treat `warning` as independent.

The null `counter` is load-bearing beyond that: it is what marks a row as operator intent rather than
an observation, and so what exempts it from age-based eviction (see Robustness). Use `removeprocs` to
clear one.

## Deliberate departures from legacy

Three places where this module intentionally does not look like `heartbeat.q`. Each is a considered
choice, not a missed port.

- **No `upd` hook.** Legacy composed `upd` at load time
  (`upd:{[f;t;x] ...}@[value;`upd;...]`), which is load-order dependent and was silently overridden
  by `monitor.q` in the one process that most needed it. Instead, `storeheartbeat` is exported and the
  consuming process calls it from its own `upd`:
  ```q
  upd:{[t;x] if[t=`heartbeat;hb.storeheartbeat x]; ... }
  ```
- **No `.servers.connectcustom` wrapper.** Legacy wrapped it to filter auto-connections by
  `.hb.CONNECTIONS`, mutating the table handed to whatever had registered before it - a cross-feature
  side effect. `di.servers` owns its own connection strategy now; this module resolves handles through
  `getservers` instead.
- **No `.html.pub`.** Legacy's `processwarning`/`processerror` published straight to a dashboard.
  Those are now the `onwarning`/`onerror` callbacks. `di.html` is `di.monitor`'s dependency, not this
  module's.

## Running tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.heartbeat
```

The integration suite needs a real child process and is a separate file, so `moduletest` (which is
hardcoded to `test.csv`) does not pick it up:

```q
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.heartbeat;`test_integration.csv]
.m.di.0k4unit.KUrt[]
```

It spawns a genuine second q process as a publisher and exercises the paths a mock cannot reach: the
root schema table, the remote-subscribe handshake, and a published row actually crossing the wire into
the monitor's store.

## Notes

- `warningperiod` and `errorperiod` take a process type so a deployment can vary grace periods per
  type. The default implementations ignore it, as legacy's did.
- Both timer jobs use **mode 2** (period after the previous *actual* start). A heartbeat asserts
  "alive now", so missed beats must not be replayed as a catch-up storm, which mode 1 would do.
  Periods are converted to whole seconds, which is what `di.timer` expects.
- `pid`, `host` and `port` are captured once at load, matching legacy. A runtime port change is not
  picked up.
- Re-running `init` is safe: it clears its own timer jobs before re-registering, and deliberately
  **preserves** already-received heartbeats.
- `host` shares its name with a q error message, which `qlint` flags as `VAR_Q_ERROR`. The column name
  is fixed by the published row shape and legacy wire compatibility, so it is kept.
