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
- End of day follows the rdb/wdb convention: `endofday[d]` in, `` (`endofday;d) `` out.
- A corrupt own log is reported and opened anyway.
- `.u.icounts` values are one-item lists after an all-syms subscribe.
- `pubinterval` must be a whole number of seconds (the timer runs in seconds); anything else fails `init`.

## Compatibility layer (temporary)

Between `/ compat begin` and `/ compat end` in `chainedtp.q`, plus the `/ compat` line in `init`.
It lets chainedtp sit between a di tickerplant and di rdb/wdb, which speak `di.subscriptions`'
`.u.subdetails` protocol.

- Upstream: `init` subscribes with `.ctp.subscribedi[]` in place of `.ctp.subscribe[]`: same handle
  lookup and `refreshtp`, then `di.subscriptions` `subscribe`, then `.u.d` from the reply.
- Downstream: root `.u.subdetails[tabs;syms]` subscribes the caller through `.ctp.sub` and returns
  `tables`, `schemas`, `logfile`, `rowcount`, `date`.

Limits:
- `logfile` is always `` ` `` and `rowcount` 0, so subscribers never replay from chainedtp.
- The upstream reply carries no per-table counts; `.u.icounts` starts empty.
- `.sub.SUBSCRIPTIONS` is not filled on this path, so `.ctp.notpconnected` reads empty.
- An unknown table comes back as a `(table;message)` pair, unfiltered.

To remove:
1. Delete the block between `/ compat begin` and `/ compat end`.
2. In `init`, put back `.ctp.subscribe[];` for `.ctp.subscribedi[]; / compat`.
3. Delete the `compat:` rows in `test.csv`, and the `compat:` lines in `test.q` (the fixture's
   `.u.subdetails`, the `dsub.q` peer, `DSPORT`/`sh`); put the `.sub.SUBSCRIPTIONS` check back in
   the init group.
4. Delete this section.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.chainedtp
```

`test.q`/`test.csv` run a real upstream (segmented tickerplant surface, found through
`di.torq.servers`) and a real downstream subscriber: subscribe and schema, tick-by-tick delivery,
`subdetails`, `tablelist`, end of day, the own log, batch publish, `clearlogonsubscription`, and a
corrupt log.
