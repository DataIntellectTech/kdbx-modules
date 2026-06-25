# Heartbeat

This module lets every process publish a periodic heartbeat over pub/sub, and lets
monitoring processes detect when a process has stopped beating - i.e. it is stalled
or blocked - even when the underlying connection is still valid.

It covers both sides:

* **Publishing** - a process periodically publishes a heartbeat row over pub/sub.
* **Monitoring** - a process subscribes to other processes' heartbeats, stores the
  latest beat per process, and raises a *warning* then an *error* when a process
  stops heartbeating within the configured grace periods.

## Dependencies

Config and dependencies are passed together in a **single dictionary** to `init` (see
Configuration). The dependencies below are **required** - `init` errors immediately with a
clear message if `deps` is not a dictionary or a required dependency is missing or malformed.
There is no hard dependency on any other module: any module exporting the contracted function
signatures can be supplied.

| Dependency | Keys | Required | Purpose |
|------------|------|----------|---------|
| `log` | a logger providing `info` `warn` `error`; a `kx.log` instance is accepted directly | always | logging |
| `timer` | `addjob` `deletejobs` (the full `di.timer` dict may be passed) | always | scheduling the publish / check / subscribe jobs (`deletejobs` lets `init` be re-run safely) |
| `pubsub` | `publish` (`{[table;data]}`) `subscribe` (`{[handle]}`) | always | publishing heartbeats / subscribing to publishers |
| `servers` | `getservers` (`{[proctype]}` returning handles) | when `subenabled` | discovering heartbeat publishers by process type |
| `handlers` | `register` `remove` `list` | when `subenabled` | registering the connection-close (`.z.pc`) cleanup |

**Logging contract.** Internally the module calls the logger as **binary** `.z.m.log[\`info][\`heartbeat;"msg"]`
(`{[c;m]}` - context symbol + message). Only `info`/`warn`/`error` are mandated (heartbeat uses all
three). You may pass either:
- a **`kx.log` instance** (`(use\`kx.log).createLog[]`) - its unary `{[msg]}` functions are detected
  (by the `getlvl`/`sinks`/`fmts` keys) and auto-wrapped to the binary contract by the internal
  `normlog`, folding the context tag into the message (`"heartbeat: ..."`); or
- a **custom binary logger** - an `` `info`warn`error `` dict of `{[c;m]}` functions, used as-is
  (extra keys are passed through untouched).

`timer` and `handlers` follow the standard kdb-x core dependency contracts; `pubsub` and
`servers` are heartbeat-specific. `servers` and `handlers` are only required when `subenabled`
is set (i.e. this process monitors other heartbeats); a pure publisher needs `log`, `timer`
and `pubsub`.

Only the functions the module actually calls are accessed (`timer`'s `addjob` and
`deletejobs`, `handlers`' `register`), but supplying the full contracted dictionary
keeps the dependency interchangeable with the real `di.*` modules.

The module keeps its **own** current-time function rather than taking it from the
timer dependency (so it doesn't rely on the timer exporting a clock getter). It
defaults to `.z.p`; override it with `setcp` for deterministic tests or simulation,
e.g. `heartbeat.setcp[{2025.01.01D00:00:00.000}]`.

## Configuration

`init[deps]` takes a **single dictionary** carrying both config overrides and the injected
dependencies. The recognised config keys below are all optional - omit any and the module
falls back to the default; unrecognised keys are ignored. The dependency keys (`log`, `timer`,
`pubsub`, and `servers`/`handlers` when monitoring) live in the same dictionary.

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `1b` | publish and check heartbeats |
| `subenabled` | `0b` | act as a monitor: subscribe to other heartbeats and register the disconnect handler |
| `debug` | `1b` | log warning / error transitions |
| `publishinterval` | `0D00:00:30` | how often heartbeats are published |
| `checkinterval` | `0D00:00:10` | how often received heartbeats are checked |
| `warningtolerance` | `1.5` | warning after `warningtolerance*publishinterval` without a beat |
| `errortolerance` | `2f` | error after `errortolerance*publishinterval` without a beat |
| `proctype` | `` `unknown `` | this process's type (published as `sym`) |
| `procname` | `.z.h` | this process's name |
| `pid` `host` `port` | from `.z` | this process's identity |
| `connections` | `` `$() `` | process types this monitor subscribes to (used by `hbsubscriptions`) |
| `onwarning` | no-op | callback invoked with the rows entering warning state |
| `onerror` | no-op | callback invoked with the rows entering error state |

## Public API

| Function | Description |
|----------|-------------|
| `init[deps]` | wire config + dependencies (one dict) and schedule the timer jobs |
| `publishheartbeat[]` | publish a single heartbeat row and increment the counter |
| `checkheartbeat[]` | flag processes that have not heartbeated in time |
| `storeheartbeat[batch]` | store incoming heartbeat(s); call from `upd` on the monitor |
| `addprocs[proctypes;procnames]` | seed expected processes so a never-seen process is flagged |
| `subscribe[handles]` | subscribe to heartbeats on the given remote handle(s) |
| `gethb[]` | return the heartbeat store |
| `setcp[f]` | replace the current-time function (for tests / simulation) |

## Heartbeat store schema

`gethb[]` returns the store, keyed on `sym`,`procname`:

| Column | Type | Description |
|--------|------|-------------|
| sym | `symbol` | process type |
| procname | `symbol` | process name |
| time | `timestamp` | time of the last received heartbeat |
| counter | `long` | counter from the last heartbeat |
| pid | `int` | publisher process id |
| host | `symbol` | publisher host |
| port | `int` | publisher port |
| warning | `boolean` | process is in warning state |
| error | `boolean` | process is in error state |

## Example

```q
// load the module
heartbeat: use `di.heartbeat

// log is a required kx.log logger instance (its info/warn/error are unary)
// bound as kxlog, not log, since log is a reserved q word
logger: use `kx.log
kxlog: logger.createLog[]

timer: use `di.timer
timer.init[()!()]
// heartbeat needs addjob and deletejobs from the timer - it keeps its own clock (see setcp)
// note: di.timer's addjob is a namespace; addjob.custom has the [id;func;params;period;mode;opts] signature heartbeat calls
timerdep: `addjob`deletejobs!(timer.addjob.custom; timer.deletejobs)

// a pubsub dependency must provide publish[table;data] and subscribe[handle]
pubsub: use `di.pubsub
psdep: `publish`subscribe!(pubsub.publish; {[h] h(`.m.di.0pubsub.subscribe;`heartbeat;`)})

// initialise from a single dict - config keys + the (required) log/timer/pubsub dependencies
// the kx.log instance is passed straight through; normlog wraps it to the binary contract
heartbeat.init[`proctype`procname`log`timer`pubsub!(`rdb;`rdb1;kxlog;timerdep;psdep)]

// publish a heartbeat immediately (normally the timer does this)
heartbeat.publishheartbeat[]
```

On the monitoring side, route received heartbeats into the store from `upd` and let
the scheduled `checkheartbeat` raise warnings / errors:

```q
upd: {[t;x] if[t~`heartbeat; heartbeat.storeheartbeat[x]]; }
heartbeat.gethb[]
```
