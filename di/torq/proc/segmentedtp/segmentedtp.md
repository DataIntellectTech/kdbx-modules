# di.torq.proc.segmentedtp

A segmented tickerplant. It stamps and logs incoming updates, per table and per period, and publishes them to
subscribers, filtered or not, immediately or in batches. With `sctp.chainedtp` on, it runs as a chained segmented
tickerplant: it subscribes to another one and republishes what it receives.

## Files

`init.q` loads, in order: `stpps.q` (`.stpps.upd`/`.stpps.zts`), `sctp.q` (`.sctp`, the chained mode), `stplog.q`
(`.stplg`, logging and batching, and the `.os` directory helpers if absent), `stpmeta.q` (`.stpm`, log metadata) and `segmentedtp.q` (the process and `init`).

## Surface

| Name | What |
|---|---|
| `tptype` | `` `segmented `` |
| `tablelist[]` | the published tables (`.stpps.t`) |
| `subdetails[tabs;instruments]` | subscribes the caller; returns `schemalist`, `logfilelist`, `rowcounts`, `date`, `logdir` |
| `.u.upd[t;x]` | the update entry point; `x` is a list of columns without `time` |
| `upd[t;x]` | chained: a table from the upstream, passed to `.u.upd` |
| `endofday[date;data]` / `endofperiod[cur;next;data]` | chained: set at root by `.sctp.init` |
| `currlog` / `loghandles` | open logs per table, and a view of their handles |
| `.stplg.*` | settings, `init`, `upd`/`zts` per batch mode, `replaylog`, `openlog`, `closelog`, `rolllog`, `endofday`, `endofperiod`, `checkends` |
| `.sctp.*` | settings, `subscribe`, `init` |
| `.stpm.metatable` | one row per opened log: `seq`, `logname`, `start`, `end`, `tbls`, `msgcount`, `schema`; saved as `stpmeta` in the log directory |

Subscribers get `(`upd;t;x)`, `(`endofperiod;cur;next;data)` and `(`endofday;date;data)`, where `data` is
`proctype`, `procname`, `tables` and `p`.

## Settings

A `stplg` section, set onto `.stplg.<name>`:

| Key | Default |
|---|---|
| `multilog` | `` `tabperiod `` — `tabperiod`, `periodic`, `tabular`, `singular` or `custom` |
| `multilogperiod` | `0D01` |
| `errmode` | `1b` — failed updates go to an error log |
| `batchmode` | `` `defaultbatch `` — `immediate`, `defaultbatch` or `memorybatch` |
| `replayperiod` | `` `day `` — `day` or `period` |
| `customcsv` | `` ` `` — `table,mode` csv for `custom` |
| `kdbtplog` | `KDBTPLOG` — the log root; logs go in `<kdbtplog>/<procname>_<date>` |
| `errorlogname` | `` `segmentederrorlogfile `` |

A `sctp` section, set onto `.sctp.<name>`: `chainedtp` (`0b`), `loggingmode` (`` `none ``: `none`, `create` or
`parent`), `tickerplantname` (`` `stp1 ``), `tpconnsleep` (`10`), `tpcheckcycles` (`0W`), `subscribeto` and
`subscribesyms` (`` ` ``), `replay` (`0b`), `schema` (`1b`).

An `eodtime` section, passed to di.eodtime's `init`: `rolltimezone`, `datatimezone`, `rolltimeoffset`.

Flat: `schemafile` (required unless chained), `createlogs` (`1b`).

## init[config;deps]

Requires `log`, `timer` and `handlers`. It:

1. initialises di.pubsub and di.eodtime, and registers `.stpps.closesub` on `.z.pc`;
2. applies the settings; `singular` and `tabular` set `multilogperiod` to `1D`; `custom` loads `customcsv`;
   `parent` makes `replaylog` ask the upstream;
3. registers a `.z.pc` observer (chained: exit 1 when the upstream closes) and a `.z.exit` observer (flush
   `memorybatch`, close the logs);
4. sets `.u.upd` from `batchmode`, wraps `.z.ts` (the existing handler, then the batch timer and the end checks),
   and sets `\t` to 1000 if it is off;
5. chained: initialises di.subscriptions, waits for the upstream and subscribes; otherwise loads `schemafile`;
6. strips attributes from the published tables and opens the logs.

Under di.torq, `generateschemas` is queued with `.proc.addinitlist`, so it runs again after di.torq's
`.ps.initialise[]` and the published tables stay the schema tables.

## Behaviour to know

- End of period and end of day are checked on each update and each timer tick.
- The first logs of a day have `seq` 0, and each period roll adds 1.
- After an end of period, `currperiod` becomes the old `nextperiod`.
- `period` replay returns `distinct` count and log pairs for the tables asked for; `day` replay returns every log of
  the day, closed ones with count `0W`.
- In `custom` mode a table missing from the csv is not logged.
- Chained without `create`, `loghandles` becomes a dictionary of `::`, and `.z.exit` leaves the logs alone.
- The `.z.exit` flush runs only in `memorybatch`.
- `subdetails` and `.stplg.replaylog` take a list of tables.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.segmentedtp
```

`test.q`/`test.csv` start five peers: `defaultbatch` with `tabperiod`, `immediate` with `singular`, `memorybatch`
with `tabular`, and two chained peers (`create`, `parent`) on the first. The test process subscribes through
`.sub.subscribe`. The tests cover the settings, the handshake, each batch mode and log naming, error mode, sym and
filtered subscriptions, both replay periods, end of period, end of day (including through the chained peer), the
`.z.exit` flush and the chained exit when the upstream is lost.
