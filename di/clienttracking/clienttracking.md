# di.clienttracking

Tracks the client sessions connected to a KDB-X process in an in-memory session table — who
connected, when they opened and closed, and (once a query owner exists) how many requests and how
many result-bytes each client has been served. It is the modular replacement for TorQ's
`code/handlers/trackclients.q` (`.clients` namespace).

It never assigns `.z.*` directly: all connection-lifecycle and query hooks are registered through an
injected **di.handlers** instance, so it coexists with any other component hooking the same events.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, `error`, each binary `{[c;m]}` (context symbol, message string) |
| handlers | `` `handlers `` | yes | dict with `register`, `remove`, `list` — a di.handlers instance's exported functions |

Both are **injected via `init`**. `di.clienttracking` has **no hard `use` dependency** on another
`di.*` module.

> **Note on the tier classification.** The modularisation plan's dependency tree lists
> `di.clienttracking → di.handlers`. That is a *role/coupling* grouping (client-tracking is
> meaningless without a handler registry), **not** a hard `use` import. Principle 4 and the injectable
> contract table both class handler management as an *injected* dependency, so — consistent with the
> rest of the framework — di.handlers is passed in as `deps[`handlers]`, and this module loads and
> tests standalone. `di.torq` wires the shared, already-`init`-ed di.handlers instance into this
> module's `init` at startup.

`init` throws immediately if either dependency is missing, is not a dict, or is missing a required
key. No adaptation is performed — pass dicts that already conform.

---

## Initialisation

```q
handlers:use`di.handlers
ct:use`di.clienttracking
logger:use`di.log

/ di.log supplies the log dependency - `logdict`log is an info..fatal level dict
/ (a superset of the required info/warn/error); it is passed straight through, no adaptation
logdep:logger.logdict`log

/ di.handlers must be initialised before it is handed on
handlers.init[enlist[`log]!enlist logdep]
hdep:`register`remove`list!(handlers.register;handlers.remove;handlers.list)

ct.init[`log`handlers!(logdep;hdep)]
```

Any dict with binary `` `info`warn`error `` `{[c;m]}` functions works — a hand-rolled one for a quick
test, or `di.log`'s `logdict`log` in a real process.

`init` must be called before any other function (there is no default logger). It is idempotent —
re-calling re-wires the dependencies, re-registers the lifecycle handlers in place, and preserves the
existing session table. Re-calling with `trackusage:0b` also *removes* any usage handlers a previous
`init`/`enableusage` had wired, so the flag is authoritative on every call.

### Config keys (optional)

Each is type-checked by `init` (a wrong type is rejected up front, not deferred to a runtime failure):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxidle` | timespan | `0D00:15:00` | force-close a live handle idle longer than this; `0D` disables idle reaping |
| `retain` | timespan | `0D00:05:00` | purge a closed session this long after it ended |
| `trackusage` | boolean | `1b` | wire usage counting during `init` (`0b` also tears down any already-wired usage handlers) |

---

## The session table

`getclients[]` returns the table; one row per session, an open session has a null `endp`:

| Column | Type | Meaning |
|---|---|---|
| `w` | `` `g#int `` | connection handle (`.z.w` at open) |
| `ipa` | symbol | client ip address, dotted-decimal |
| `u` | symbol | client user (`.z.u` at open) |
| `a` | int | client ip address, raw int (`.z.a` at open) |
| `startp` | timestamp | session start — connection open time |
| `endp` | timestamp | session end — connection close time; null while open |
| `lastp` | timestamp | time of the last request seen from this client |
| `hits` | long | number of requests served for this client |
| `sz` | long | total (approximate, via `-22!`) bytes of results returned |

Current connections are `select from ct.getclients[] where null endp`.

---

## Exported functions

### `init[deps]`
Wire dependencies + config, create the session table, register the lifecycle handlers, and (if
`trackusage`) attempt to wire usage counting. Idempotent.

### `getclients[]`
Return the session table.

### `addclient[handle]`
Manually record a client `handle` (an int) as an open session, using the current `.z` context — the
equivalent of TorQ's `addw`. Signals if `handle` is not an int.

### `cleanup[]`
Run a cleanup sweep now: stamp `endp` on open rows whose handle is no longer live, force-close live
handles idle past `maxidle`, and delete closed rows older than `retain`. Cleanup also runs
automatically on every connection open and close; export it so a host can also drive it from a
`di.timer` job.

### `enableusage[]`
(Re)wire usage counting onto each of `.z.pg` / `.z.ps` / `.z.ws` that currently has an `exec` owner.
Idempotent. Call it after the process's query owner (e.g. a gateway or `di.permissions`) has been
registered — see the design note below on why usage counting is deferred.

### `version`
The module version string (`"0.1.0"`).

---

## Events managed

| Event | di.handlers model | Role here |
|---|---|---|
| `.z.po` | simple (observer) | open a session row |
| `.z.pc` | simple (observer) | stamp `endp` on the session |
| `.z.wo` | simple (observer) | open a session row (websocket) |
| `.z.wc` | simple (observer) | stamp `endp` on the session (websocket) |
| `.z.pg` | phased — `post` | count a served request (hits, bytes, lastp) |
| `.z.ps` | phased — `post` | count a served request |
| `.z.ws` | phased — `post` | count a served request |

All registrations use the name `` `clienttracking `` at priority `0`.

---

## Design decisions & rationale

The extraction turned on how di.handlers classifies events, and several deliberate departures from
TorQ's `trackclients.q` follow from it.

- **Lifecycle vs usage are two different di.handlers models.** Connection open/close (`.z.po`/`.z.pc`
  /`.z.wo`/`.z.wc`) are *simple* events: di.handlers fans them out to every registrant and discards
  the return, so client-tracking is just one more observer. Per-request counting hangs off
  `.z.pg`/`.z.ps`/`.z.ws`, which are *phased* — their return value is the query answer. Counting is a
  side-effect watcher of a result, i.e. a **`post`** handler, never an owner or a `pre`.

- **Usage counting is deferred, by necessity.** di.handlers refuses a `post` registration until an
  `exec` owner exists on that event (the dispatcher isn't installed until then). So `init` wires the
  four lifecycle observers unconditionally, then *attempts* usage counting: for each query event that
  already has an owner it registers the `post` handler; for the rest it logs a `warn` and skips.
  `enableusage[]` re-attempts and is meant to be called once the query owner is up. This ordering
  dependency is inherent to the observer/decider split — it is surfaced, not hidden.

- **`errs` is not tracked (deliberate omission).** TorQ counted per-client errors via a wrapper that
  saw the failure. In di.handlers a `post` handler runs **only after a successful `exec`** — a throwing
  query propagates before any `post` fires — so a `post` watcher structurally cannot observe errors.
  Rather than carry a column that would always be zero, the `errs` column is dropped. Error attribution
  would need a different mechanism (e.g. an owner/`pre` that traps) and is out of scope here.

- **INTRUSIVE mode dropped.** TorQ optionally sent an async `eval` back to each connecting client to
  self-report its `.z.k`/`.z.c`/os/pid/port. It only works for a cooperating q client and is
  security-questionable; it is removed, and with it the `k`/`K`/`c`/`s`/`o`/`f`/`pid`/`port` columns
  it populated. The retained schema is what this module can populate truthfully from `.z.*` at
  connect time.

- **Unkeyed session table.** TorQ keyed `CLIENTS` on the handle and nulled the key on close, which
  collides when handles are reused or several closed rows coexist. This module keeps an unkeyed table
  with `` `g# `` on `w`; the current session for a handle is the row with that `w` and a null `endp`.
  Handle reuse simply produces a new row.

- **Cleanup is inline, no timer injected.** Cleanup runs on every open/close (as in TorQ) and is also
  exported for a host to schedule. That keeps the injectable surface to `log` + `handlers` only; a
  host wanting periodic sweeps wires `cleanup[]` to `di.timer` rather than this module pulling timer
  in.

## Known limitations

- **Usage counting needs a single-threaded query port.** A `post` handler on `.z.pg`/`.z.ps`/`.z.ws`
  runs in the query's own execution context. On a multithreaded process (a negative `\p` port) that is
  not the main thread, so the global write inside the counter hits kdb's `'noupdate` restriction — the
  same constraint any `.z.pg` code faces. di.handlers isolates the `post`, so the query still succeeds;
  the count is simply skipped and a `warn` is logged. Lifecycle tracking (open/close) is unaffected —
  those run on the main thread.
- **Usage counting is order-dependent.** It only attaches to query events that already have an `exec`
  owner. If a query owner is registered *after* `di.clienttracking`, call `enableusage[]` again. If the
  owner is later removed, di.handlers clears the event's `post` state with it — re-run `enableusage[]`
  after re-registering an owner.
- **`ipa` is a plain dotted-decimal format** of `.z.a`; unlike TorQ it does not do a reverse-hostname
  lookup or cache.

---

## Running tests

Needs KDB-X (the `use` module system + k4unit).

**Unit suite** (`test.csv`, 41 checks) — hermetic, no sockets. Runs against the **real, merged
di.handlers and di.log** (nothing is mocked); drives di.handlers' actual dispatcher by invoking the
function bound to each `.z.*` event with synthetic handles. `moduletest` loads and runs it:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.clienttracking      / "All tests passed"
```

It covers dependency + config-type validation, the four lifecycle registrations, open/close through
real di.handlers dispatch (which also proves the registered callbacks resolve this module's own `.z.m`
state), `addclient`, cleanup of dead handles, usage-counting deferral without an owner and activation
with one, teardown on `trackusage:0b` re-init, and the api-metadata/version contract.

**Integration suite** (`test_integration.csv`, 6 checks) — stands up a real child q process, tracks the
outgoing handle to it, then reaps it as idle. This is the one path the unit suite cannot reach: the
idle-reap branch force-closes a handle that must genuinely be in `.z.W`. It needs a q/kdb-x binary via
`QHOME`, needs no other configuration, and skips cleanly if none is available. `moduletest` only loads
`test.csv`, so run this suite directly, in a fresh session:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.clienttracking;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]                / one row per assertion; ok=1 is a pass
```

The *incoming*-connection (`.z.po`) direction is deliberately not integration-tested: a process only
accepts an inbound connection at its top-level event loop, which a k4unit script never reaches. That
di.handlers binds `.z.*` to the socket layer at all is covered by di.handlers' own integration suite;
here the `.z.po`/`.z.pc` dispatch is exercised via the unit suite's synthetic-handle drives.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.clienttracking      / prints the results; "All tests passed" on success
```
