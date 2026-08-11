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
| `servers` | when `subenabled` | `getservers` | `di.servers`; returns a **table**, handles are its `w` column. `procname` and `proctype` are used for the never-beaten warning, and skipped if absent |

Nothing is silently defaulted. A missing or malformed dependency throws from `init` with a message
naming the module that supplies it.

> **No `handlers` dependency.** This module used to register a `.z.pc` observer, purely to prune a
> cache of already-subscribed handles. That cache is gone (see *How a monitor subscribes*), and the
> observer went with it. A `handlers` key passed anyway is **silently accepted and ignored**, so
> `di.torq` can keep wiring every module with one uniform dict — it is deliberately still listed in
> the module's `depkeys` so it is never mistaken for a stray config key and warned about on every
> publisher-only boot.

## Initialisation

`init` takes exactly **one** dict, carrying dependencies and config side by side.

```q
logging:use`di.log
timer:use`di.timer
ps:use`di.pubsub
hb:use`di.heartbeat

timer.init[]
hb.init[logging.logdict,`timer`pubsub`proctype`procname!(timer;ps;`rdb;`rdb1)]
ps.init[]                              / MUST run after hb.init - see Ordering below
```

The module export dicts (`timer`, `ps`) are passed straight through - `di.heartbeat` reads the keys it
needs off them.

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
| `subscribeinterval` | `0D00:01:00` | legacy value, now configurable | how often to sweep for newly connected publishers |
| `warningtolerance` | `2f` | **shipped** | warning after `tolerance * publishinterval` |
| `errortolerance` | `3f` | **shipped** | error after `tolerance * publishinterval` |
| `subscribewarnsweeps` | `3` | new | consecutive-sweep threshold for both monitor warnings: a subscribed peer sending nothing, and discovering no peer at all |
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

### How `` `ALL `` resolves, and why the sweep still iterates

`` `ALL `` converts to a null symbol, which `di.servers.getservers` treats as match-all — the same
contract legacy TorQ's `.servers.getservers` (`trackservers.q:75`) and `di.serverselect.getservers`
both implement (`` ` `` → every server, otherwise `proctype in lookups`).

The sweep nonetheless calls `getservers` **once per proctype** rather than passing the whole list.
That is deliberate: it is the one shape every version of the contract accepts, so this module works
against a `di.servers` that predates the list/null support as well as one that has it. The cost is
one call per configured proctype per sweep, which is not worth optimising away for the coupling it
would add.

> **Requires `di.servers` with the null/list contract.** An older build accepting only a symbol atom
> returns nothing for `` `ALL `` and *throws* on a list — and because the sweep runs in a `di.timer`
> job with `disableonfail:1b`, that throw would permanently disable monitor discovery. If a monitor
> discovers nothing, the discovered-nothing warning below is what surfaces it.

**`connections` is not the same key as `di.servers.connections`.** They share a name and mean
different things: `di.servers.connections` decides which process types this process *connects to at
all*; `di.heartbeat.connections` filters which of those already-connected types get *heartbeat
subscribed*. A type named here but absent there is silently inert - `getservers` simply has no rows
for it. A config that looks complete can therefore monitor nothing.

**Discovery is gradual on a cold start.** `hbsubscriptions` only finds what `di.servers.startup` /
`retry` has actually connected to by the time it sweeps, so a freshly started monitor picks peers up
over the first few sweeps rather than all at once. Not a bug, but worth expecting.

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
All three timer jobs are scheduled through `di.timer`, whose `addjob.opts` defaults `disableonfail:1b` — so
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

**Flipping a flag off on re-`init` cleans up after the previous one.** `registertimers` and the
root-name sync both *reconcile* rather than only add. Re-initialising with `subenabled:0b` removes the
subscription sweep job; with `publishroot:0b` it removes the published root names. Both leaks were
real and both were permanent: `teardown` used to key off the *current* config, so once a flag was off
nothing could remove what the earlier init had installed. A lingering
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

Legacy solved this with an IPC call (`heartbeat.q:92`), and so does this module: the monitor calls the
publisher's root ``.heartbeat.subscribe`` over the handle. During that inbound call the publisher's
`.z.w` *is* the connection back to the monitor, so the subscription lands correctly.

```q
hb.subscribe[handle]        / monitor side; sends `.heartbeat.subscribe to the publisher
```

### The send is asynchronous, and why that matters

Legacy sent this **synchronously**. That is an availability hazard in a module whose entire job is
detecting unresponsive processes: a sync call waits as long as the peer takes to answer, and a peer
that is *alive but stalled* — a GC pause, a heavy query, exactly the condition heartbeats exist to
surface — never answers promptly. Because the sweep runs inside a `di.timer` job on a single thread,
that wait stalled `publishheartbeat` and `checkheartbeat` along with it, so **the monitor fell silent
to its own monitors at precisely the moment a peer was misbehaving.** A failed attempt was never
recorded either, so it was retried — and re-blocked — on every sweep. Measured: 10s of blocking
against a peer hung for 10s, versus 36µs for the async send. (`hopen`'s timeout does not help; it
bounds connection *establishment*, not later requests on an established handle.)

The async send costs nothing in correctness — `.z.w` resolves to the monitor's connection during an
async inbound call just as it does for a sync one — but it does change what failures are visible:

| Failure | Reported |
|---|---|
| dead handle, null handle | **yes**, immediately, at `error` — the send itself throws |
| the remote throws, or has no `.heartbeat.subscribe` | **no** — an async send gets no answer |

That second row is covered indirectly instead. See *The never-beaten warning* below.

### There is no cache of subscribed handles

An earlier version tracked which handles it had already subscribed, to skip them on later sweeps.
That was removed rather than repaired, because **a handle number is not an identity**: kdb+ reissues
the lowest free descriptor immediately (measured: handle `4` → close → reopen → handle `4`), and
`hclose` does not fire `.z.pc` at all (also measured). A stale entry therefore made the monitor skip a
live peer *forever*, with nothing in any log to explain it — and no cheap liveness probe fixes it,
because after a close-and-reopen the recycled number is back in `.z.W` and looks perfectly valid.

Nothing is lost by dropping the cache: `di.pubsub` already dedupes subscribers by handle
(`pubsub.q:11`), so a repeat subscribe is a no-op on the publisher, and an async send is far too cheap
to be worth caching around. Removing it also removed this module's only reason to register a `.z.pc`
handler, and with it the `handlers` dependency.

**What cleans up, then?** The publisher does. `di.pubsub` registers its own `.z.pc` (`pubsub.q:75`)
which calls `closesub` to drop a dead subscriber's handle from `reqalldict` and `reqfilteredtbl`.
Subscriber lifetime is the publisher's concern, not the monitor's — which is why losing the
monitor-side cache costs nothing. A monitor that dies is forgotten by every publisher it was watching,
without this module tracking anything. (`di.pubsub` assigns `.z.pc` flatly rather than through
`di.handlers`, so on a shared process it can clobber other modules' cleanup — but not its own: it is
the last assignment to win, so subscriber cleanup stays reliable regardless.)

### The never-beaten warning

Since an async send cannot report a *remote* failure, the sweep watches for the consequence instead:
a peer it has subscribed to that never produces a heartbeat. After `subscribewarnsweeps` consecutive
sweeps (default 3) in which a discovered, attempted peer has no observed beat in the store, it warns
once — naming the peers.

Three details are deliberate:

- **Only peers actually attempted are counted.** A row with a null handle or handle `0` was skipped on
  purpose, so warning that it never beat would be a false alarm about a peer nobody asked.
- **An `addprocs` seed does not count as an observation.** Those rows carry a null `counter`, the same
  discriminator `evictstale` uses to tell operator *intent* from a real observation.
- **The count restarts if a peer leaves the discovered set and returns.** A connectivity blip is not
  the continuously-stuck subscribe this warning exists to catch; only an uninterrupted run trips it.

It warns at exactly the threshold sweep, not past it, so a permanently broken peer does not log
forever.

### The discovered-nothing warning

A companion to the above, one level further out. The never-beaten warning covers *"we found a peer and
subscribed to it, but nothing arrives"*. This one covers *"we never found a peer at all"* — a monitor
with `subenabled:1b` that discovers no usable handle for `subscribewarnsweeps` consecutive sweeps
warns once.

It is deliberately **cause-agnostic**, watching the consequence rather than any single mechanism, so
one check covers all of:

- a `connections` list naming a process type `di.servers` is not configured to connect to — the
  name-collision trap described earlier;
- a `di.servers` too old for the null/list `getservers` contract, so `` `ALL `` matches nothing;
- an injected `servers` dependency that returns nothing for the configured types;
- every watched peer being genuinely down.

Two deliberate exclusions. An **explicitly empty** `connections` list does not trip it — that is a
considered "monitor nothing" choice, already warned about at `init`, and repeating it every sweep
would be noise. And it fires **once**, at the threshold, not on every subsequent sweep.

**Cold start and peer loss are reported differently**, because they have nothing in common but the
symptom:

| Situation | Message |
|---|---|
| no peer has been discovered **yet** | *"no peer discovered yet, after N consecutive sweeps — on a cold start the peers may simply still be coming up, in which case this resolves itself and a recovery line follows…"* |
| peers were discovered, and are now **all gone** | *"every previously-discovered peer has gone — N consecutive sweeps found none. the peers may be down, or di.servers may have dropped their connections"* |

**A cold-start warning is always closed out.** When peers become visible again after a warning, the
module logs `peer discovery recovered - now watching N connection(s)` — gated on whether a warning was
actually emitted, so it can never claim to resolve an outage nobody was told about.

It is logged at **`warn`**, not `info`, even though recovery is good news. The alert fires exactly
once, so a resolution at a lower level would be invisible to anyone whose pipeline filters to warn and
above — they would see a dangling alert and nothing else. Matching the alert's level is what makes a
once-only warning safe to act on. This matters more than it
looks: a staggered rollout that starts the monitor before its peers will legitimately trip the
warning, and an alert that fires once and then goes quiet is indistinguishable from an alert that
fired and was ignored. The recovery line is what makes the warning safe to act on. It is logged once
per outage, not on every healthy sweep.

**`teardown` forgets everything this check learned.** A monitor re-`init`ed after a teardown is
usually watching a different set of process types, and is cold starting in every sense that matters to
whoever reads the log — so it gets the cold-start wording rather than a claim about peers it never
watched. All three pieces of discovery state reset together; resetting only "have we ever seen a peer"
would be worse than resetting none, because a carried-over sweep count already past a new, lower
threshold never equals it again and the warning would then *silently never fire* for the new
configuration.

This is the one place `teardown` discards state. The heartbeat store, its counter and the never-beaten
counters are all deliberately preserved — the store by design, and the never-beaten counters because
they are rebuilt from the current discovered set on every sweep and so self-heal anyway.

If your deployments routinely start monitors well ahead of their peers and you would rather not see
the warning at all, raise `subscribewarnsweeps` — the threshold is in sweeps, so the wall-clock grace
is `subscribewarnsweeps × subscribeinterval` (3 minutes on the defaults).

Because the check never names a mechanism in its logic, it needs no maintenance as the causes it
catches come and go — which is why it survived the `di.servers` `getservers` fix unchanged.

**Only the sweep feeds this check, not `subscribe[]`.** The manual entry point takes bare handles with
no identity attached, so there is nothing to key a pending row on — a handle number alone cannot be
matched against the store. An operator subscribing by hand should check `gethb[]` directly. This is
structural, not an oversight: giving `subscribe[]` the same coverage would mean asking the caller for
a `proctype`/`procname` it does not currently have to supply.

> **Known coupling.** This matches `di.servers`' `procname`/`proctype` against the `sym`/`procname` a
> publisher puts in its own heartbeats. If `process.csv` disagrees with a process's own identity
> config, the warning fires spuriously — which is itself a deployment bug nothing else currently
> catches. If the injected `getservers` returns rows without those columns, the check is skipped
> entirely rather than guessing.

**Handle 0 and null handles are refused.** A "remote" call on handle `0i` evaluates *locally*, so
subscribing it would register this process as a subscriber to its own heartbeats and then publish to
handle 0; a null handle is a disconnected server row. Both are dropped from `subscribe` and from the
`getservers` sweep, with a warning. Legacy guarded the same case by seeding its own
`subscribedhandles:0 0Ni` (`heartbeat.q:21`) — the guard is deliberate, not incidental.

A **negative** handle is dropped for a sharper reason now that the send is async: `neg` of an
already-negative handle is *positive*, so a negative handle reaching `subscribeone` would silently
become the blocking synchronous call the async switch exists to remove.

> **Security note.** `.heartbeat.subscribe` is callable by anyone holding a handle to this process,
> exactly as legacy's `.ps.subscribe` was. It takes no arguments and only subscribes the caller to the
> heartbeat table, so the exposure is small — but it is a root-published remote entry point, and a
> deployment running `di.permissions` will want it in scope of whatever gates `.z.pg`.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `[dict]` | wire dependencies and config; idempotent |
| `teardown` | `[]` | release the timer jobs and the published root names, and reset the discovery-warning state (the heartbeat store is preserved) |
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
  > **Use `:` here, not `::`.** At the top level of a script, `upd::{…}` defines a **view**, not a
  > global assignment — `type upd` is then `101h`, and every published row throws `'rank` before your
  > handler is reached. Nothing logs, and the publisher looks dead to this monitor. Inside a function
  > `::` *is* the correct global assign, which is why `test.q` sets `upd` from within `installupd`.
- **No `.servers.connectcustom` wrapper.** Legacy wrapped it to filter auto-connections by
  `.hb.CONNECTIONS`, mutating the table handed to whatever had registered before it - a cross-feature
  side effect. `di.servers` owns its own connection strategy now; this module resolves handles through
  `getservers` instead.
- **No `.html.pub`.** Legacy's `processwarning`/`processerror` published straight to a dashboard.
  Those are now the `onwarning`/`onerror` callbacks. `di.html` is `di.monitor`'s dependency, not this
  module's.
- **The subscribe is async, and there is no subscribed-handle cache.** Legacy did both synchronously
  and cached `subscribedhandles`. Both were removed for measured reasons — a stalled peer could block
  the monitor's whole timer thread, and a recycled handle number could make it skip a live peer
  forever. See *How a monitor subscribes*. The confirmation the sync call used to provide is replaced
  by the never-beaten warning.

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

- **Known limitation.** `warningperiod` and `errorperiod` take a process type so a deployment can vary
  grace periods per type, as legacy documented — but `init` exposes no way to *supply* a per-type
  override, so the extensibility point is not reachable without editing the module. Designing that
  config shape is deferred until there is a real requirement to shape it against.
- All three timer jobs use **mode 2** (period after the previous *actual* start). A heartbeat asserts
  "alive now", so missed beats must not be replayed as a catch-up storm, which mode 1 would do.
  Periods are converted to whole seconds, which is what `di.timer` expects.
- **Both timer entry points that can throw are isolated.** `hbsubscriptions` runs its whole sweep
  through `safecall`, because `di.timer`'s `addjob.opts` defaults `disableonfail:1b` — an unprotected
  throw would not skip one sweep, it would end monitor discovery for the life of the process.
  `checkheartbeat`'s `cp[]` call is deliberately *not* wrapped: `setcp` probes the clock once at swap
  time, so a clock with external dependencies could still throw there. That is an accepted, much
  narrower risk than the sweep's — noted in the source so it reads as a decision, not an oversight.
- `test.q`'s `freeport[]` binds a port and immediately releases it, so it carries an inherent
  bind-release-reuse race. Known and accepted as an occasional integration-suite flake source.
- `pid`, `host` and `port` are captured once at load, matching legacy. A runtime port change is not
  picked up.
- Re-running `init` is safe: it clears its own timer jobs before re-registering, and deliberately
  **preserves** already-received heartbeats.
- `host` shares its name with a q error message, which `qlint` flags as `VAR_Q_ERROR`. The column name
  is fixed by the published row shape and legacy wire compatibility, so it is kept.
