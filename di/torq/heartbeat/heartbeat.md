# di.torq.heartbeat

Publishes a heartbeat from a process, and on a subscriber, flags processes whose heartbeats stop
arriving in time. A port of TorQ's `code/common/heartbeat.q`. di.torq wires it into every process.

## Surface

| Name | What |
|---|---|
| `heartbeat` (root) | the published table: `time sym procname counter pid host port`; `sym` is the proctype |
| `upd` (root) | wrapped when `heartbeatsubscribeenabled`: heartbeat rows go to `storeheartbeat`, then every table to the previous `upd` |
| `.servers.connectcustom` (root) | wrapped when `heartbeatsubscribeenabled`: subscribes to newly connected processes |

Exports only `init` and `version`. The rest is module-private and reached as `.m.di.0torq.0heartbeat.*`:

| Name | What |
|---|---|
| `hb` | received heartbeats keyed on `sym procname`, plus `warning` and `error` flags |
| `publishheartbeat[]` | publishes one heartbeat via `.ps.publish` once `.ps.initialised`, and counts it in `hbcounter` |
| `storeheartbeat[t]` | upserts the last heartbeat per process into `hb` and clears its flags |
| `addprocs[types;names]` | seeds `hb` with processes expected to heartbeat |
| `checkheartbeat[]` | flags processes past `warningperiod`/`errorperiod`, calls `warn`/`err` with the newly flagged rows |
| `warningperiod`/`errorperiod` | `heartbeatwarningtolerance`/`heartbeaterrortolerance` times `heartbeatpublishinterval` |
| `subscribe[h]` | subscribes to heartbeats on a handle via `.ps.subscribe` |
| `getheartbeats[types]` | subscribes to every not-yet-subscribed handle of the types (`` `ALL `` for all) |
| `hbsubscriptions[]` | `getheartbeats heartbeatsubscribetypes` |

## Settings

Required in `config`, with `proctype` and `procname`; `di/torq/settings/default.q` declares them all:

| Key | Default | Meaning |
|---|---|---|
| `heartbeatenabled` | `1b` | publish and check heartbeats |
| `heartbeatsubscribeenabled` | `0b` | subscribe to heartbeats |
| `heartbeatdebug` | `1b` | log warnings and errors |
| `heartbeatpublishinterval` | `0D00:00:30` | how often heartbeats are published |
| `heartbeatcheckinterval` | `0D00:00:10` | how often heartbeats are checked |
| `heartbeatwarningtolerance` | `1.5` | warning after this many publish intervals without a heartbeat |
| `heartbeaterrortolerance` | `2f` | error after this many publish intervals without a heartbeat |
| `heartbeatsubscribetypes` | `()` | proctypes to subscribe to heartbeats from; `` `ALL `` for all |

The intervals may be a timespan, string, symbol or number of seconds; init errors if one does not convert.
`heartbeatsubscribetypes` may be symbols or strings.

Optional, defaulting to `{[x]}`:

| Key | Meaning |
|---|---|
| `processwarning` | called with the rows newly in warning, every check |
| `processerror` | called with the rows newly in error, every check |

## init[config;deps]

Requires `log`, `timer` and `handlers`. Subscribing calls root `.servers.getservers` and wraps root
`.servers.connectcustom`, both from di.torq.servers. It:

1. signals if a dep or setting is missing or an interval does not convert, then applies the settings;
2. loads di.pubsub, sets the root `heartbeat` table and registers `.stpps.closesub` on `.z.pc`;
3. when `heartbeatenabled` and not `.proc.lowpowermode`, adds `publishheartbeat` and `checkheartbeat` timer jobs
   at their intervals, scheduled from the end of the previous run;
4. when `heartbeatsubscribeenabled`, independently of `heartbeatenabled`: wraps root `upd`, registers a `.z.pc` handler that
   drops closed handles from `subscribedhandles`, adds a 1-minute `hbsubscriptions` job and wraps
   `.servers.connectcustom`.

Call `init` once; di.torq does, before `.ps.initialise`.

## Behaviour to know

- A process in error that was never in warning keeps `warning` false.
- `processwarning` and `processerror` are called every check, with an empty table when nothing is new.
- The `connectcustom` wrap passes only the filtered, unsubscribed rows on to the previous `connectcustom`.
- A handle is recorded as subscribed when `.ps.subscribe` returns, even if the publisher refused the table.
- `addprocs` seeds `pid` and `port` as longs.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.heartbeat
```

One test spawns a publisher on an OS-assigned port and checks its heartbeat reaches this process.
