# di.torq.proc.chainedtp

A chained tickerplant. It subscribes to an upstream tickerplant through `di.subscriptions`,
optionally writes what it receives to a log of its own, and republishes to its own subscribers, tick
by tick or in batches.

## Surface

| Name | What |
|---|---|
| `tptype` | `` `chained `` |
| `tablelist[]` | the published tables (`.stpps.t`) |
| `.u.subdetails[tabs;syms]` | root; subscribes the caller and returns `tables`, `schemas`, `logfile`, `rowcount`, `date` |
| `.u.end[d]` | publishes and clears the batch, rolls to `d+1`, sends `` (`endofday;d) `` to subscribers |
| `endofday[d]` | root; calls `.u.end d` (the upstream's end-of-day message) |
| `upd` | set at root to `.ctp.upd` if no `upd` exists |
| `.ctp.*` | settings, `subscribe`, `writetolog`, `tickpub`, `batchpub`, `publishalltables`, `cleartables`, `openlog`, `clearlog`, `refreshtp`, `createlogfilename`, `notpconnected`, `sub` |
| `.u.i`/`.u.j`/`.u.icounts`/`.u.jcounts`/`.u.L`/`.u.l`/`.u.d` | publish and log counts, log file and handle, date |

## Settings

`di/torq/settings/chainedtp.q` (flat config):

| Key | Default |
|---|---|
| `tickerplantname` | `` `tickerplant1 `` — procname(s) of the upstream |
| `pubinterval` | `0D00:00:00` — tick by tick; above 0, batches published on a timer. Also a `"0D00:00:01"` string or seconds |
| `tpconnsleep` / `tpcheckcycles` | `10` / `0W` — seconds between, and number of, upstream checks |
| `createlogfile` / `logdir` / `clearlogonsubscription` | `0b` / `` `:tplogs `` / `0b` — log file `<logdir>/<procname>_<date>`; `logdir` may be a path string |
| `subscribeto` / `subscribesyms` | `` ` `` / `` ` `` — all tables, all syms |
| `replay` / `schema` | `0b` / `1b` |
| `connections` / `startup` | `` `tickerplant `` / `1b` |

## init[config;deps]

Requires `log`, `timer` and `handlers`. It initialises `di.pubsub` (with the log) and
`di.subscriptions`, registers `.stpps.closesub` on `.z.pc`, applies the settings, then:

1. registers a `.z.pc` observer that logs and exits 0 when the upstream handle closes;
2. sets `.ctp.upd` from `createlogfile`/`pubinterval`, and root `upd` if absent;
3. `.ps.initialise[]`;
4. `.servers.startupdepnamecycles[tickerplantname;tpconnsleep;tpcheckcycles]`;
5. `.ctp.subscribe[]`: finds the upstream handle, `refreshtp`, subscribes through `di.subscriptions`, takes
   `.u.d` from the reply;
6. builds `.ctp.tableschemas`;
7. when `pubinterval` is above 0, adds the `publishalltables` job (seconds, timer mode 2).

di.torq runs `.ps.initialise[]` again after the module loads, which publishes the subscribed tables.

## Behaviour to know

- The upstream is found by procname through `di.torq.servers` (with the default settings, through
  discovery). With `tpcheckcycles` `0W` it waits for it indefinitely.
- End of day follows the rdb/wdb convention: `endofday[d]` in, `` (`endofday;d) `` out.
- A corrupt own log is reported and opened anyway.
- `pubinterval` must be a whole number of seconds (the timer runs in seconds); anything else fails `init`.

## Downstream subscribers

`.u.subdetails[tabs;syms]` subscribes the caller through `.ctp.sub`, the protocol `di.subscriptions`
subscribers (di rdb/wdb) use. With `createlogfile` on, `logfile` is `.u.L` and `rowcount` `.u.i`, so
subscribers replay chainedtp's own log; otherwise `` ` `` and 0. Plain `.u.sub` subscribers are served
by `di.pubsub`.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.chainedtp
```

`test.q`/`test.csv` run a real upstream (di tickerplant surface, found through `di.torq.servers`) and
real `.u.sub` and `di.subscriptions` subscribers: subscribe and schema, tick-by-tick delivery,
`.u.subdetails`, `tablelist`, end of day, the own log, batch publish, `clearlogonsubscription`, a
corrupt log, and a subscriber replaying the own log.
