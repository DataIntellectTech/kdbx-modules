# di.torq.proc.chainedtp

A chained tickerplant. It subscribes to an upstream tickerplant through `.sub`, optionally writes
what it receives to a log of its own, and republishes to its own subscribers, tick by tick or in
batches.

## Surface

| Name | What |
|---|---|
| `tptype` | `` `chained `` |
| `tablelist[]` | the published tables (`.stpps.t`) |
| `subdetails[tabs;instruments]` | subscribes the caller and returns `schemalist`, `logfilelist`, `rowcounts`, `date` |
| `.u.end[d]` | publishes and clears the batch, rolls to `d+1`, sends `` (`.u.end;d) `` to subscribers |
| `upd` | set at root to `.ctp.upd` if no `upd` exists |
| `.ctp.*` | settings, `subscribe`, `writetolog`, `tickpub`, `batchpub`, `publishalltables`, `cleartables`, `openlog`, `clearlog`, `refreshtp`, `createlogfilename`, `notpconnected`, `sub` |
| `.u.i`/`.u.j`/`.u.icounts`/`.u.jcounts`/`.u.L`/`.u.l`/`.u.d` | publish and log counts, log file and handle, date |

## Settings

`di/torq/settings/chainedtp.q` (flat config):

| Key | Default |
|---|---|
| `tickerplantname` | `` `tickerplant1 `` — procname(s) of the upstream |
| `pubinterval` | `0D00:00:00` — tick by tick; above 0, batches published on a timer |
| `tpconnsleep` / `tpcheckcycles` | `10` / `0W` — seconds between, and number of, upstream checks |
| `createlogfile` / `logdir` / `clearlogonsubscription` | `0b` / `` `:tplogs `` / `0b` — log file `<logdir>/<procname>_<date>` |
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
5. `.ctp.subscribe[]`;
6. builds `.ctp.tableschemas`;
7. when `pubinterval` is above 0, adds the `publishalltables` job (seconds, timer mode 2).

di.torq runs `.ps.initialise[]` again after the module loads, which publishes the subscribed tables.

## Behaviour to know

- The upstream is found by procname through `di.torq.servers` (with the default settings, through
  discovery). With `tpcheckcycles` `0W` it waits for it indefinitely.
- An upstream that sends `endofday` rather than `.u.end` (a segmented tickerplant) does not end the day here.
- A corrupt own log is reported and opened anyway.
- `.u.icounts` values are one-item lists after an all-syms subscribe.
- `pubinterval` must be a whole number of seconds (the timer runs in seconds); anything else fails `init`.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.chainedtp
```

`test.q`/`test.csv` run a real upstream (segmented tickerplant surface, found through
`di.torq.servers`) and a real downstream subscriber: subscribe and schema, tick-by-tick delivery,
`subdetails`, `tablelist`, `.u.end`, the own log, batch publish, `clearlogonsubscription`, and a
corrupt log.
