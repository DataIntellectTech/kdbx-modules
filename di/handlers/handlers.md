# di.handlers

Central registry for a KDB-X process's `.z.*` connection-lifecycle callbacks — connection open and close, websocket open and close, process exit, and the message, auth and console handlers. It lets multiple independent components hook the same event without silently overwriting one another, and is the single place in a process that assigns `.z.*` directly.

---

## Features

- Register any number of **observer** handlers on an event whose return value KDB-X discards (connection open/close, websocket open/close, process exit). Every handler runs, in registration order, and each call is isolated — one handler throwing is logged and does not stop the rest.
- Register a single **owner** for a **decider** event whose return value KDB-X uses as the outcome (query, async, console, HTTP POST, auth, websocket message). A second registrant under a different name is rejected rather than silently replacing the first.
- Whatever was bound to an observer event before the first registration is preserved and still runs, last, after every registered handler.
- Remove a handler by name; removing a decider restores the KDB-X built-in default.
- Inspect what is registered on any event with `list`.

Managed events, by whether KDB-X consumes the callback's return value:

| Event | Mode | Meaning |
|---|---|---|
| `.z.pc` | observer | connection closed |
| `.z.po` | observer | connection opened |
| `.z.exit` | observer | process exit |
| `.z.wo` | observer | websocket opened |
| `.z.wc` | observer | websocket closed |
| `.z.pg` | decider | synchronous message (query) |
| `.z.ps` | decider | asynchronous message |
| `.z.pi` | decider | console input |
| `.z.pp` | decider | HTTP POST |
| `.z.pw` | decider | password / connection check |
| `.z.ws` | decider | websocket message |

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

### `register[event;name;func]`
Register `func` under `name` for a `.z.*` `event`.

For an **observer** event, `func` is added to the fan-out in registration order; re-registering the same `[event;name]` replaces that entry in place. For a **decider** event, `func` becomes the single owner; re-registering under the same `name` replaces it, while a different `name` on an already-owned event throws.
```q
handlers.register[`.z.pc;`mytracker;{[w] .track.onclose w}]   / observer
handlers.register[`.z.pw;`myauth;{[u;p] .auth.check[u;p]}]     / decider
```

### `remove[event;name]`
Remove a previously registered handler. Removing an observer deletes its entry from the fan-out; removing a decider relinquishes ownership and restores the KDB-X built-in default.
```q
handlers.remove[`.z.pc;`mytracker]
```

### `list[event]`
Return the registrations for a single `event`: observers as a `name`/`func` table in registration order, a decider as a one-row table naming its owner (empty if unowned).
```q
exec name from handlers.list[`.z.pc]
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

/ observer event - two independent close handlers, both run in order
handlers.register[`.z.pc;`audit;  {[w] }]
handlers.register[`.z.pc;`metrics;{[w] }]
exec name from handlers.list[`.z.pc]        / `audit`metrics

/ decider event - a single owner for the connection auth check
handlers.register[`.z.pw;`auth;{[u;p] 1b}]
exec name from handlers.list[`.z.pw]        / ,`auth

/ a different owner on an already-owned decider is rejected
handlers.register[`.z.pw;`other;{[u;p] 1b}] / signals: already owned by auth

/ remove them again - decider remove restores the built-in default
handlers.remove[`.z.pc;`audit]
handlers.remove[`.z.pc;`metrics]
handlers.remove[`.z.pw;`auth]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.handlers
```

The unit suite needs no sockets — it drives dispatch by invoking the function bound to each `.z.*` event with synthetic arguments. A separate integration suite (`test_integration.csv`) stands up a real child q process, opens and closes a connection, and confirms a registered observer actually fired. It needs no configuration and skips cleanly when no usable q binary is available; the unit suite needs neither.

---

## Notes

- `init` must be called before any other function, and is idempotent.
- `register` on `.z.ph` throws — HTTP GET permissioning uses `.h.val`, not `.z.*`, and is not managed by this module.
- Decider events have exactly one owner; there is currently no way to also observe one without owning it.
- `.z.ts` is not managed here — it belongs to `di.timer`.
- The handler bound to an observer event before its first registration is captured once and always runs last, after every registered handler.
- Removing a decider restores the KDB-X built-in default, not any handler that happened to be bound before the module took ownership.
- All errors raised after `init` are logged at `error` before being signalled.
