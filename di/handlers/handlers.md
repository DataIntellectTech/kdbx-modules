# di.handlers

The single sanctioned place to hook kdb+ `.z.*` connection-lifecycle callbacks. It replaces the per-file, hand-rolled closure-wrapping that TorQ processes use (where load order silently decides who wins) with one explicit, testable registry. Once this module is in use, nothing else should assign `.z.*` directly.

---

## The core distinction: observer vs decider

A `.z.*` callback can only ever hold one function, so two things wanting to hook the same event conflict. How that conflict is resolved depends entirely on **what kdb+ does with the callback's return value**:

- **Observer events** — kdb+ **discards** the return value. The callback runs purely for side effects (record a connection, drop a session on close). Because nobody reads the result, any number of registrants can coexist safely. `di.handlers` runs them all (fan-out).
- **Decider events** — kdb+ **uses** the return value as the outcome delivered to the caller (the query result, allow/deny). A return value is singular, so only one function can coherently own the decision. `di.handlers` enforces exactly one owner and rejects a competing claim.

| Event | Mode | Meaning |
|---|---|---|
| `.z.pc` | observer | connection closed |
| `.z.po` | observer | connection opened |
| `.z.exit` | observer | process exit |
| `.z.wo` | observer | websocket opened |
| `.z.wc` | observer | websocket closed |
| `.z.pg` | decider | sync message (query) |
| `.z.ps` | decider | async message |
| `.z.pi` | decider | console input |
| `.z.pp` | decider | HTTP POST |
| `.z.pw` | decider | password / connection check |
| `.z.ws` | decider | websocket message |

`.z.ts` is **not** managed here — it belongs to `di.timer`. `.z.ph` is **out of scope** — see below.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

`di.handlers` has **no hard dependencies** on other `di.*` modules and works standalone.

All three log keys are required: `info` (register/remove confirmations), `warn` (an isolated observer or original that threw during dispatch), and `error` (domain errors, logged before they are signalled). `init` throws immediately if `log` is absent, is not a dict, or is missing any of the three keys. The module performs no adaptation — pass a dict that already conforms to the `{[c;m]}` contract (e.g. built from `di.log`).

---

## Initialisation

```q
handlers:use`di.handlers

/ build a conforming log dict (or take one from di.log)
logdep:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});

handlers.init[enlist[`log]!enlist logdep]
```

`init` must be called before any other function — there is no default logger. It is **idempotent**: calling it again re-wires the log dependency but leaves any live registrations and installed dispatchers untouched, so a process can safely re-initialise.

---

## Exported Functions

### `init[deps]`
Validate the required `log` dependency and set up the empty registries. Idempotent. `deps` is a dict with a `` `log `` key.
```q
handlers.init[enlist[`log]!enlist logdep]
```

### `register[event;name;func]`
Register `func` under `name` for a `.z.*` `event`. Behaviour depends on the event's mode.

**Observer** — `func` is added to the fan-out for `event` in registration order. On the first registration for an event, whatever is currently bound to it is captured as the *original* and installed to run **last**, after every registered handler. Re-registering the same `[event;name]` replaces that entry in place. Each handler (and the original) is called under protection: if one throws, the error is logged at `warn` tagged with its `name` and the rest of the chain still runs.
```q
handlers.register[`.z.pc;`mytracker;{[w] .track.onclose w}]
```

**Decider** — the first `register` for an event installs `func` directly as the sole owner. Re-registering under the **same** `name` replaces it (idempotent re-init). Registering under a **different** `name` while the event is already owned **throws**, naming the current owner:
```q
handlers.register[`.z.pw;`myauth;{[u;p] .auth.check[u;p]}]
handlers.register[`.z.pw;`other;{[u;p] 1b}]
/ 'di.handlers: register: .z.pw already owned by myauth - call remove first
```

### `remove[event;name]`
Remove a previously registered handler.

- **Observer** — deletes the named entry from the fan-out. The dispatcher and the captured original keep firing regardless of how many registrants remain.
- **Decider** — if `name` owns the event, relinquishes ownership and restores the kdb+ built-in default via `\x`. Throws if `name` does not own the event.
```q
handlers.remove[`.z.pc;`mytracker]
handlers.remove[`.z.pw;`myauth]
```

### `list[event]`
Return the registrations for a single `event` (monadic only — there is no all-events overload). Observers return a `name`/`func` table in registration order; deciders return a one-row table naming the owner (empty if unowned).
```q
handlers.list[`.z.pc]
/ name       func
/ ---------------
/ mytracker  {[w]..}
```

---

## `.z.ph` / HTTP GET is out of scope

On any current kdb+ (3.5+), HTTP GET permissioning is applied by setting **`.h.val`** — a hook in the `.h` namespace, entirely outside `.z.*`. `.z.ph` itself is not the real gate on a modern deployment. Because `di.handlers` manages `.z.*` events only, `register[`.z.ph;...]` **throws** with a clear message rather than silently installing a handler that would do nothing:

```q
handlers.register[`.z.ph;`x;{[r] r}]
/ 'di.handlers: register: .z.ph is out of scope - HTTP GET permissioning uses .h.val (see di.permissions), not .z.*
```

A module that needs to gate HTTP GET should own `.h.val` directly (this is what a permissions module does). Folding `.h.val` into `di.handlers` was considered and rejected: it would drag the module outside its `.z.*` remit and hide a `.h`-namespace assignment behind a `.z.ph`-shaped call.

---

## Known limitation: observers on decider events

**This is a real, deliberately-deferred gap — not an oversight.** In production TorQ, a decider event such as `.z.pg` is not owned by exactly one thing: it is owned by one *decision-maker* (permissions) **and** wrapped by one or more pure *observers* — query logging and per-client byte-counting both layer themselves around the same `.z.pg`/`.z.ps` and pass the return value through untouched. `di.handlers` currently models decider events as **single-owner only**, so there is no slot for an observer that wants to watch a decider event without owning its outcome.

**Consequence.** A future `di.querylog` or `di.clienttracking` cannot, through `di.handlers` alone, observe `.z.pg`/`.z.ps` while a permissions module owns them. The interim workaround is for the decider owner to invoke the logging/tracking itself — which reintroduces exactly the coupling `di.handlers` exists to remove, so it is a stopgap, not the intended end state.

**Follow-up design task (for whoever builds `di.querylog` / `di.clienttracking`):** extend the decider model so an event keeps exactly one owner for the *outcome* but also supports an unlimited, side-effect-only observer layer around it (return value untouched). This deserves the same dedicated design scrutiny the observer/decider split itself required and should not be improvised at implementation time.

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.handlers
```

The unit suite (`test.csv`) injects no-op and capturing mock loggers and drives dispatch by invoking the function actually bound to each `.z.*` event with synthetic arguments — no sockets required. It covers observer fan-out order, throw-isolation, original-runs-last, and in-place replacement; decider claim / same-name reclaim / different-name rejection and default-restoring removal; the `.z.ph` and unknown-event rejections; and `init` dependency validation.

A separate, environment-gated integration suite (`test_integration.csv`) stands up a second blank q process on a runtime-chosen ephemeral port, opens and closes a real connection, and confirms the registered `.z.po`/`.z.pc` observers actually fired. It skips cleanly when no q binary is available.

---

## Notes

- The captured *original* for an observer is whatever was bound the instant the first handler registers — capture is lazy and per-event, so `di.handlers` never installs a dispatcher on an event that has no registrants.
- Decider `remove` restores the kdb+ built-in default, not whatever happened to be bound before `di.handlers` took ownership — deciders capture no original by design.
- All post-`init` domain errors are logged at `error` before being signalled, so failures are observable in the log and not only as a thrown exception.
