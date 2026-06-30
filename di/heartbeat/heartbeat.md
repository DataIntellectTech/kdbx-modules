# di.heartbeat

Periodic process-liveness signalling over pub/sub for kdb-x. Every process can publish a regular heartbeat so that downstream monitors detect when a process has stopped beating - i.e. it is stalled or blocked - even when the underlying connection is still valid. The module covers both sides: publishing heartbeats, and on the monitoring side storing received beats and raising a warning then an error when a process stops within configurable grace periods.

--- 

## Features

- Publish a periodic heartbeat row over pub/sub so downstream monitors can detect a stalled or blocked process even while its connection is still open
- Monitor side: subscribe to other processes' heartbeats and store the latest beat per process as inspectable module state
- Escalate from healthy to *warning* to *error* when a process stops heartbeating, using per-process-type grace periods (`warningtolerance`/`errortolerance` x `publishinterval`)
- Fire user-supplied `onwarning`/`onerror` callbacks with the rows entering each state
- Seed expected processes with `addprocs` so a never-seen process is flagged immediately
- Owns its own clock (`cp`, default `.z.p`), overridable via `setcp` for deterministic tests or simulation
- Idempotent `init` - re-running clears and re-registers its timer jobs safely
- No hard module dependencies - log, timer, pubsub (and servers/handlers when monitoring) are all injected via `init`

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`/`warn`/`error` - binary `{[c;m]}` where `c` is a symbol context and `m` is a string. Heartbeat uses all three. A `kx.log` instance is accepted directly |
| timer | `` `timer `` | yes | `addjob`, `deletejobs` - schedules the publish / check / subscribe jobs (`deletejobs` lets `init` be re-run safely). The full `di.timer` dict may be passed |
| pubsub | `` `pubsub `` | yes | `publish` (`{[table;data]}`), `subscribe` (`{[handle]}`) - publishing heartbeats / subscribing to publishers |
| servers | `` `servers `` | when `subenabled` | `getservers` (`{[proctype]}` returning handles) - discovering heartbeat publishers by process type |
| handlers | `` `handlers `` | when `subenabled` | `register` - wiring the connection-close (`.z.pc`) cleanup |

**Hard dependency:** none - all runtime dependencies are injected via `init`, so any module exporting the contracted signatures can be supplied.

The dependencies are passed to `init` inside the single `deps` dict alongside any configuration. They are **required**: `init` throws immediately if `deps` is not a dictionary or a required dependency is missing or malformed. `servers` and `handlers` are only required when `subenabled` is set (i.e. this process monitors others); a pure publisher needs only `log`, `timer` and `pubsub`.

**Logging contract.** Internally the module calls the logger as binary `.z.m.log[\`info][\`heartbeat;"msg"]` (`{[c;m]}` - context symbol + message). `info`/`warn`/`error` are all mandated because heartbeat uses all three. You may pass either a `kx.log` instance (`(use\`kx.log).createLog[]`) - its monadic `{[msg]}` functions are detected and auto-wrapped to the binary contract by the internal `normlog`, folding the context tag into the message (`"heartbeat: ..."`) - or a custom `` `info`warn`error `` dict of `{[c;m]}` functions, used as-is.

The module keeps its **own** current-time function rather than taking it from the timer dependency. It defaults to `.z.p`; override it with `setcp` for deterministic tests or simulation, e.g. `heartbeat.setcp[{2025.01.01D00:00:00.000}]`.

---

## Initialisation

`init[deps]` takes a single dictionary combining the injected dependencies (above) with any configuration overrides. All config keys are optional - omit any and the module falls back to the default; unrecognised keys are ignored.

| Key | Default | Description |
|---|---|---|
| `` `enabled `` | `1b` | publish and check heartbeats |
| `` `subenabled `` | `0b` | act as a monitor: subscribe to other heartbeats and register the disconnect handler |
| `` `debug `` | `1b` | log warning / error transitions (callbacks still fire when off) |
| `` `publishinterval `` | `0D00:00:30` | how often heartbeats are published |
| `` `checkinterval `` | `0D00:00:10` | how often received heartbeats are checked |
| `` `warningtolerance `` | `1.5` | warning after `warningtolerance*publishinterval` without a beat |
| `` `errortolerance `` | `2f` | error after `errortolerance*publishinterval` without a beat |
| `` `proctype `` | `` `unknown `` | this process's type (published as `sym`) |
| `` `procname `` | `.z.h` | this process's name |
| `` `pid `` `` `host `` `` `port `` | from `.z` | this process's identity |
| `` `connections `` | `` `$() `` | process types this monitor subscribes to (used by the subscribe job) |
| `` `onwarning `` | no-op | callback invoked with the rows entering warning state |
| `` `onerror `` | no-op | callback invoked with the rows entering error state |

`init` must be called before any other function. It applies config, wires dependencies, and schedules the timer jobs. Re-running `init` resets unset config keys to their defaults and re-registers the timer jobs.

---

## Exported Functions

### `init[deps]`
Wire config + dependencies (one dict) and schedule the timer jobs. Must be called before anything else.
```q
heartbeat.init[`proctype`procname`log`timer`pubsub!(`rdb;`rdb1;kxlog;timerdep;psdep)]
/ or as a monitor:
heartbeat.init[`subenabled`connections`log`timer`pubsub`servers`handlers!(1b;`rdb`hdb;kxlog;timerdep;psdep;serversdep;handlersdep)]
```

### `publishheartbeat[]`
Publish a single heartbeat row over pub/sub and increment the counter. Normally driven by the timer; a no-op when `enabled` is `0b`.
```q
heartbeat.publishheartbeat[]
```

### `checkheartbeat[]`
Flag processes that have not heartbeated within the warning / error grace periods, firing `onwarning`/`onerror` on transitions. Driven by the timer on the monitor.
```q
heartbeat.checkheartbeat[]
```

### `storeheartbeat[batch]`
Store one or more incoming heartbeats, keeping the latest per process and clearing warning / error state. Call from `upd` on the monitor.
```q
upd:{[t;x] if[t~`heartbeat; heartbeat.storeheartbeat[x]]; }
```

### `addprocs[proctypes;procnames]`
Seed the store with expected processes so a never-seen process is flagged. Real heartbeats arriving later override the seeded rows.
```q
heartbeat.addprocs[`rdb`hdb; `rdb1`hdb1]
```

### `subscribe[handles]`
Subscribe to heartbeats on the given remote handle(s), tracking successful subscriptions and skipping any that fail.
```q
heartbeat.subscribe hopen `:remotehost:5050
```

### `gethb[]`
Return the current heartbeat store (keyed on `sym`,`procname`) for inspection.
```q
heartbeat.gethb[]
```

### `setcp[f]`
Replace the current-time function (for deterministic tests / simulation). Defaults to `.z.p`.
```q
heartbeat.setcp[{2025.01.01D00:00:00.000}]
```

---

## Heartbeat store schema

`gethb[]` returns the store, keyed on `sym`,`procname`:

| Column | Type | Description |
|---|---|---|
| sym | `symbol` | process type |
| procname | `symbol` | process name |
| time | `timestamp` | time of the last received heartbeat |
| counter | `long` | counter from the last heartbeat |
| pid | `int` | publisher process id |
| host | `symbol` | publisher host |
| port | `int` | publisher port |
| warning | `boolean` | process is in warning state |
| error | `boolean` | process is in error state |

---

## Usage Example

```q
/ --- publisher ---
kxlog:use`kx.log

heartbeat:use`di.heartbeat

timer:use`di.timer
timer.init[()!()]
/ heartbeat needs addjob and deletejobs - it keeps its own clock (see setcp)
/ note: di.timer's addjob is a namespace; addjob.custom has the [id;func;params;period;mode;opts] signature heartbeat calls
timerdep:`addjob`deletejobs!(timer.addjob.custom; timer.deletejobs)

/ pubsub must provide publish[table;data] and subscribe[handle]
pubsub:use`di.pubsub
psdep:`publish`subscribe!(pubsub.publish; {[h] h(`.m.di.0pubsub.subscribe;`heartbeat;`)})

/ initialise from a single dict - config keys + the (required) log/timer/pubsub dependencies
/ the kx.log instance is passed straight through; normlog wraps it to the binary contract
heartbeat.init[`proctype`procname`log`timer`pubsub!(`rdb;`rdb1;kxlog.createLog[];timerdep;psdep)]

/ publish a heartbeat immediately (normally the timer does this)
heartbeat.publishheartbeat[]
```

On the monitoring side, route received heartbeats into the store from `upd` and let the scheduled `checkheartbeat` raise warnings / errors:

```q
upd:{[t;x] if[t~`heartbeat; heartbeat.storeheartbeat[x]]; }
heartbeat.gethb[]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.heartbeat
```

The test suite injects no-op binary mock loggers and a capturing logger that records messages for assertion. It covers: dependency validation (non-dict deps throws; missing/non-dict `log` throws; `log` missing a level throws; missing `timer`/`pubsub` throws; missing monitor `servers`/`handlers` throws); the capturing-logger test confirming `init` logs `"di.heartbeat initialised"`; `normlog` wrapping a fake `kx.log` instance end-to-end (and extra log levels passing through untouched); idempotency of re-running `init`; and a real-process integration test driving a background publisher over a live handle.

---

## Notes

- The module keeps its own clock (`cp`, default `.z.p`) rather than taking one from the timer dependency - override it with `setcp` for deterministic tests or simulation
- Timer jobs use mode 2 (period after the previous actual start) so missed beats are not replayed as a catch-up storm
- `init` is idempotent: it deletes its jobs (`hbpublish`/`hbcheck`/`hbsubscribe`) before re-registering, so it is safe to call again
- `servers` and `handlers` are only required when `subenabled` is set; a pure publisher needs only `log`, `timer` and `pubsub`
- A `kx.log` instance is accepted directly - `normlog` wraps its monadic functions to the binary `{[c;m]}` contract and folds the context tag into the message
- `debug` toggles whether warning / error transitions are logged; the `onwarning`/`onerror` callbacks still fire either way
