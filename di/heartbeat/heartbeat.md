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

All runtime dependencies are **injected** via `init` as dictionaries of functions,
so the module has no hard dependencies on any other module and runs standalone with
minimal built-in fallbacks (logging to stdout, no-op timer/handlers/pubsub). Inject
real implementations to get full functionality.

| Dependency | Keys | Default fallback | Purpose |
|------------|------|------------------|---------|
| `log` | `info` `warn` `error` (each `{[ctx;msg]}`) | writes to stdout | logging |
| `timer` | `addjob` `deletejobs` `enablejobs` `disablejobs` `getactivejobs` `cp` | no-op (`cp` returns `.z.p`) | scheduling publish/check/subscribe and the current-time source |
| `handlers` | `register` `remove` `list` | no-op | registering the connection-close (`.z.pc`) cleanup |
| `pubsub` | `publish` (`{[table;data]}`) `subscribe` (`{[handle]}`) | no-op | publishing heartbeats / subscribing to publishers |
| `servers` | `getservers` (`{[proctype]}` returning handles) | returns empty | discovering heartbeat publishers by process type |

`log`, `timer` and `handlers` follow the standard kdb-x core dependency contracts;
`pubsub` and `servers` are heartbeat-specific.

## Configuration

`init[config;deps]` takes a configuration dictionary as its first argument. Any
recognised key may be supplied; unset keys keep their defaults.

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
| `init[config;deps]` | wire dependencies and configuration, and schedule the timer jobs |
| `publishheartbeat[]` | publish a single heartbeat row and increment the counter |
| `checkheartbeat[]` | flag processes that have not heartbeated in time |
| `storeheartbeat[batch]` | store incoming heartbeat(s); call from `upd` on the monitor |
| `addprocs[proctypes;procnames]` | seed expected processes so a never-seen process is flagged |
| `subscribe[handles]` | subscribe to heartbeats on the given remote handle(s) |
| `hbsubscriptions[]` | subscribe to all configured publishers (by `connections` process type) |
| `gethb[]` | return the heartbeat store |

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

// build dependency dictionaries (here using di.log and di.timer)
log: use `di.log
log.init[()!()]
logdep: `info`warn`error!(log.info;log.warn;log.error)

timer: use `di.timer
timer.init[()!()]
timerdep: `addjob`deletejobs`enablejobs`disablejobs`getactivejobs`cp!(
  timer.addjob;timer.deletejobs;timer.enablejobs;timer.disablejobs;timer.getactivejobs;timer.cp)

// initialise as a publishing RDB
heartbeat.init[`proctype`procname!(`rdb;`rdb1); `log`timer!(logdep;timerdep)]

// publish a heartbeat immediately (normally the timer does this)
heartbeat.publishheartbeat[]
```

On the monitoring side, route received heartbeats into the store from `upd` and let
the scheduled `checkheartbeat` raise warnings / errors:

```q
upd: {[t;x] if[t~`heartbeat; heartbeat.storeheartbeat[x]]; }
heartbeat.gethb[]
```
