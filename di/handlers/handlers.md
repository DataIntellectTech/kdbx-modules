# di.handlers

Central registry for a KDB-X process's `.z.*` connection-lifecycle callbacks — connection open and close, websocket open and close, process exit, and the message, auth and HTTP handlers. It lets multiple independent components hook the same event without silently overwriting one another, and is the single place in a process that assigns `.z.*` directly.

---

## Features

- Register any number of **simple** handlers on an event whose return value KDB-X discards (connection open/close, websocket open/close, process exit). Every handler runs, in ascending **priority** order, and each call is isolated — one handler throwing is logged and does not stop the rest.
- Register handlers on a **phased** event whose return value KDB-X uses as the outcome (query, async, console input, HTTP POST/GET, auth, websocket message). A phased event threads its request through three phases: **`pre`** (any number, priority order — each reshapes the request), **`exec`** (exactly one owner — produces the outcome), and **`post`** (any number, priority order — side-effect-only watchers of the result).
- A phased event has a single `exec` owner: a second `exec` under a different name is rejected rather than silently replacing the first. `pre` and `post` cannot attach until an `exec` owner exists.
- **Fault-isolation is asymmetric.** `pre` and `exec` run **unprotected** — a `pre` that throws vetoes the request and propagates to the caller (this is a deliberate channel, e.g. an auth rejection). `post` and simple handlers run **protected/isolated** — a throw is logged at `warn` and changes neither the outcome nor the other handlers.
- Whatever was bound to a simple event before the first registration is preserved and still runs, last, after every registered handler.
- Remove a handler by `event`, `phase` and `name`; removing an `exec` owner restores the KDB-X built-in default and clears the event's phased state.
- Inspect what is registered on any event with `list`.

Managed events, by dispatch model:

| Event | Model | Meaning |
|---|---|---|
| `.z.pc` | simple | connection closed |
| `.z.po` | simple | connection opened |
| `.z.exit` | simple | process exit |
| `.z.wo` | simple | websocket opened |
| `.z.wc` | simple | websocket closed |
| `.z.pg` | phased | synchronous message (query) |
| `.z.ps` | phased | asynchronous message |
| `.z.pi` | phased | console input |
| `.z.pp` | phased | HTTP POST |
| `.z.ph` | phased | HTTP GET (see notes) |
| `.z.ws` | phased | websocket message |
| `.z.pw` | phased | password / connection check (binary, `exec`+`post` only — no `pre`) |

Simple events take a null phase (`` ` ``); phased events take one of `` `pre`exec`post ``.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

**No hard dependencies** on other `di.*` modules — the module works standalone.

The `log` dependency is passed to `init` keyed on `` `log ``. It must be a dict containing all three of `info`, `warn`, and `error`: `info` records register/remove activity, `warn` reports an isolated handler that threw during dispatch, and `error` reports a rejected call before it is signalled. `init` throws immediately if `log` is absent, is not a dict, or is missing any key. No adaptation is performed — pass a dict that already conforms to the `{[c;m]}` contract (for example one built from `di.log`).

---

## Initialisation

```q
handlers:use`di.handlers

/ a conforming log dict (or one supplied by di.log)
logdep:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});

handlers.init[enlist[`log]!enlist logdep]
```

`init` must be called before any other function — there is no default logger. It is idempotent: calling it again re-wires the log dependency and leaves existing registrations and installed dispatchers intact.

---

## Exported Functions

### `init[deps]`
Validate the required `log` dependency and set up the registries. `deps` is a dict with a `` `log `` key. Idempotent.
```q
handlers.init[enlist[`log]!enlist logdep]
```

### `register[event;phase;name;priority;func]`
Register `func` under `name` for a `.z.*` `event`. `phase` is `` ` `` (null) for a simple event, one of `` `pre`exec`post `` for a phased event. `priority` is an integer — **lower runs first**, and ties break by registration order.

- **Simple event** (`phase` `` ` ``): `func` is added to the fan-out. Re-registering the same `[event;name]` replaces that entry in place.
- **`exec`**: `func` becomes the single owner and produces the outcome. Re-registering under the same `name` replaces it; a different `name` on an already-owned event throws. Registering the `exec` is what installs the event's dispatcher.
- **`pre` / `post`**: added to the pre- or post-chain (priority order). Both are rejected if the event has no `exec` owner yet. A `pre` receives the request and returns the (possibly reshaped) request; a `post` is called `post[result;args]` and its return is discarded. `args` is the argument list `exec` was invoked with, **with one deliberate exception — `.z.pw`'s password is redacted**. For the six unary phased events `args` is `enlist request`, exactly what `exec` ran on: the request *after* any `pre` reshaped it, not the original caller's input. For the binary `.z.pw`, `exec` sees the real `(user;password)` but `post` sees `(user;"***")`, so a `post` handler can never read a real password. `result` is what that request produced.
```q
handlers.register[`.z.pc;`;`mytracker;0;{[w] .track.onclose w}]         / simple
handlers.register[`.z.pg;`exec;`gw;0;{[q] .gw.run q}]                    / exec owner
handlers.register[`.z.pg;`pre;`auth;10;{[q] .auth.check q; q}]           / pre - reshape/veto
handlers.register[`.z.pg;`post;`querylog;0;{[result;args] .log.q args}]  / post - observe
```

### `remove[event;phase;name]`
Remove a previously registered handler; `phase` mirrors `register`. Removing a simple handler or a `pre`/`post` deletes its entry (the dispatcher stays installed). Removing the `exec` owner relinquishes ownership, restores the KDB-X built-in default, and clears the event's `pre`/`post` state. Removing a name that is not currently registered is a harmless no-op, logged at `info` — except removing an `exec` under a name that does *not* own it, which is an error (the event has a single owner).
```q
handlers.remove[`.z.pc;`;`mytracker]
handlers.remove[`.z.pg;`exec;`gw]
```

### `list[event]`
Return the registrations for a single `event` as a `phase`/`name`/`priority` table. A simple event lists its handlers (null phase) in priority order; a phased event lists its `pre` rows, then the `exec` owner, then its `post` rows (empty if unowned).
```q
select name,priority from handlers.list[`.z.pg] where phase=`pre
```

### `version`
The module version string.
```q
handlers.version   / "0.1.0"
```

---

## Usage Example

```q
handlers:use`di.handlers

/ a no-op log dep for illustration (di.log would supply a real one)
logdep:`info`warn`error!(3#{[c;m]});
handlers.init[enlist[`log]!enlist logdep]

/ simple event - two independent close handlers, priority orders them, both run
handlers.register[`.z.pc;`;`audit;  10;{[w] }]
handlers.register[`.z.pc;`;`metrics; 0;{[w] }]
exec name from handlers.list[`.z.pc]                 / `metrics`audit  (priority 0 before 10)

/ phased event - one exec owner produces the outcome
handlers.register[`.z.pg;`exec;`gw;0;{[q] value q}]
select name from handlers.list[`.z.pg] where phase=`exec   / ,`gw

/ a pre reshapes or vetoes the request (runs unprotected - a throw rejects the query)
handlers.register[`.z.pg;`pre;`auth;0;{[q] q}]

/ a post observes the result after the owner (side-effect only, cannot change it)
handlers.register[`.z.pg;`post;`querylog;0;{[result;args] }]

/ a different exec owner on an already-owned event is rejected
handlers.register[`.z.pg;`exec;`other;0;{[q] q}]     / signals: already owned by gw

/ remove them again - removing the exec owner restores the built-in default and clears pre/post
handlers.remove[`.z.pg;`pre;`auth]
handlers.remove[`.z.pg;`exec;`gw]
handlers.remove[`.z.pc;`;`audit]
handlers.remove[`.z.pc;`;`metrics]
```

---

## Running Tests

**Unit suite** (`test.csv`) — needs no sockets; it drives dispatch by invoking the function bound to each `.z.*` event with synthetic arguments. It covers dependency validation, simple fan-out ordering and per-handler isolation, phased `pre`/`exec`/`post` dispatch, single-owner claim/reclaim/reject, `pre` veto and `post` isolation, `.z.pw` password redaction, `.z.ph` register/dispatch and default restoration, priority ordering, and state teardown on removal. `moduletest` loads and runs it:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.handlers
```

**Integration suite** (`test_integration.csv`) — stands up a real child q process on an OS-assigned ephemeral port, opens and closes a connection, and confirms a registered `.z.pc` handler actually fired. It needs a q/kdb-x binary reachable via `QHOME`, needs no other configuration, and skips cleanly when no usable binary is available. `moduletest` only ever loads `test.csv`, so load and run this suite directly:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.handlers;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]                / one row per assertion; ok=1 is a pass
```

Run the integration suite in a fresh q session — running it after `moduletest` in the same session re-runs the still-loaded unit tests against dirty module state and reports spurious failures.

---

## Notes

- `init` must be called before any other function, and is idempotent.
- **Fault isolation is asymmetric.** `pre` and `exec` run unprotected: a throw propagates to the caller, and a `pre` throw is the sanctioned way to veto a request (e.g. an auth rejection). `post` and simple handlers run isolated: a throw is logged at `warn` and cannot change the outcome or stop the other handlers. A broken `pre` blocking its event is an accepted tradeoff — q cannot tell a deliberate veto from a bug, both being a throw.
- Priority is an integer, **lower runs first**; handlers at equal priority run in registration order.
- `.z.ph` is a normal phased event, but an `exec` owner on it **replaces the KDB-X built-in HTTP GET handler wholesale** — including the `.h`-namespace response formatting — so the owner becomes fully responsible for the GET response. GET **permissioning** is done via `.h.val` (a `.h` hook, not a `.z.*` callback) and is **not managed by this module**; a `pre` veto on `.z.ph` works but does not substitute for `.h.val`-based permissioning of the default handler. `.z.ph` is the only phased event KDB-X ships a default handler for, and `\x` expunges rather than restores it, so di.handlers captures that shipped handler when the `exec` is claimed and puts it back on `remove` (the other phased events have no shipped default and `\x`-restore correctly).
- `.z.pw` is binary and supports `exec` and `post` only — there is no `pre` phase. The `exec` owner sees the real `(user;password)`; `post` handlers see `(user;"***")`, so only the owner ever sees the password.
- A `post` handler's `args` is the argument list `exec` was invoked with, **except that `.z.pw`'s password is deliberately redacted** — `exec` sees the real `(user;password)`, `post` sees `(user;"***")`, so a `post` handler can never read a real password. That asymmetry is intentional, not an oversight: it is what lets an audit-log `post` handler exist on `.z.pw` at all. For the six unary phased events `args` is `enlist request` — the request *after* any `pre` reshaped it, not the original caller's input — paired with the `result` that request produced. `.z.pw` has no `pre` phase, so its request is never transformed.
- A `post` handler runs synchronously after the owner and before its result is returned, so it adds to that event's response time — unlike simple-event handlers, where nothing awaits the return.
- A `post` handler runs in the event's own execution context; under multithreaded input (a negative `\p` port) that is not the main thread, so a `post` that writes a global hits kdb's `'noupdate` restriction, as any `.z.pg` code would. di.handlers' own dispatch only reads its registries and is unaffected.
- `.z.ts` is not managed here — it belongs to `di.timer`.
- The handler bound to a simple event before its first registration is captured once and always runs last, after every registered handler.
- Removing the `exec` owner restores the KDB-X built-in default (via `\x` for every phased event except `.z.ph`, whose shipped handler is captured and put back — see the `.z.ph` note above), not any handler that happened to be bound before the module took ownership.
- Removing a simple handler drops it from the fan-out, but the event's dispatcher — installed once on first registration — stays installed permanently; removing the last handler does not revert the event, which keeps running an empty fan-out plus the captured original. Unlike a phased event (whose `exec` `remove` restores the KDB-X built-in default — see the removal bullet above), a simple event has no path back to its pre-di.handlers binding.
- All errors raised after `init` are logged at `error` before being signalled.
