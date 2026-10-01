# di.torq.proc.tickerlogreplay

Replays tickerplant log files into a date-, month- or year-partitioned HDB. It reads either one plain
tickerplant log or a directory of segmented tickerplant logs (`di.torq.proc.segmentedtp` output, picked through
its `stpmeta` table). It can replay all messages or a range of them, save in chunks, sort and apply attributes
at the end, or partition to a temporary directory and merge on disk.

## Files

`init.q` loads `tickerlogreplay.q`: the module `init`, then the `.os` directory helpers and the `.save` hooks
(`savedownmanipulation`, `manipulate`, `postreplay`), each defined if absent, `.merge.getextrapartitiontype`, and
`.replay`. `sort.csv` is the default sort config.

## Surface

| Name | What |
|---|---|
| `init[config;deps]` | applies the settings, checks them, loads the schema, and replays if `autoreplay` |
| `.replay.initandrun[]` | replays every log, sorts or merges, runs `postreplay`, and exits if `exitwhencomplete` |
| `.replay.replaylog[logfile]` | replays one log and saves its tables |
| `.replay.upd[t;x]` | inserts a replayed message; set it before `use` to change how messages are applied |
| `.save.savedownmanipulation` / `.save.postreplay[d;p]` | table!function applied before saving / called after each log is saved; set `.replay.savedownmanipulation` / `.replay.postreplay` before `use` |
| `.merge.getextrapartitiontype[t]` | the `p#` column(s) for a table from the sort config |

## Settings

A `replay` section, set onto `.replay.<name>`:

| Key | Default |
|---|---|
| `schemafile` | `` ` `` — required |
| `hdbdir` | `` ` `` — required |
| `tplogfile` / `tplogdir` | `` ` `` — one of them is required |
| `segmentedmode` | `1b` — `tplogdir` is a segmented tickerplant log directory |
| `tablelist` | `` enlist`all `` |
| `firstmessage` / `lastmessage` | `0` / `0W` — inclusive message indices |
| `messagechunks` | `0W` — messages per save; negative only logs progress |
| `partitiontype` | `` `date `` — `date`, `month` or `year` |
| `emptytables` | `1b` — create each table empty in the partition first |
| `sortafterreplay` | `1b` |
| `sortcsv` | `` ` `` — null uses `sort.csv` (`sym` then `time`, `p#` on `sym`) |
| `basicmode` | `0b` — replay everything, then save with `.Q.hdpf` |
| `checklogfiles` | `0b` — replay a good copy of a corrupt log |
| `clean` | `1b` — delete the date's existing data first |
| `compression` | `()` — `.z.zd` when three values |
| `partandmerge` / `tempdir` / `mergemethod` | `0b` / `` `:tempmergedir `` / `` `part `` (`part`, `col` or `hybrid`) |
| `mergenumrows` / `mergenumtab` / `mergenumbytes` | `10000000` / `` `quote`trade!10000 50000 `` / `500000000` |
| `exitwhencomplete` / `autoreplay` / `gc` | `1b` / `1b` / `1b` |

A `merge` section (`mergebybytelimit`, `partlimit`) is set onto `.merge.<name>` and passed to di.merge's `init`.

## init[config;deps]

Requires `log`. It:

1. initialises di.dbwrite and di.merge, and applies the settings;
2. exits on a bad setting:
   - code 1 for a null `schemafile`/`hdbdir`/log, an unknown `partitiontype`, `basicmode` with
     `messagechunks`, or `partandmerge` into `hdbdir`;
   - code 2 for zero `messagechunks` or a schema file that fails to load;
3. loads the schema file at root;
4. wraps `.replay.realupd` to filter on `tablelist` (plain logs) and to save every `messagechunks` messages;
5. loads `sortcsv`, or `sort.csv`, into di.dbwrite;
6. replays when `autoreplay`.

## Behaviour to know

- The replay process exits when complete unless `exitwhencomplete` is `0b`; call `init` once per process.
- Plain log dates come from the last ten characters of the file name (`YYYY.MM.DD`), segmented log dates from
  their `_YYYYMMDDhhmmss` suffix. Segmented logs from more than one date are refused.
- With `checklogfiles` on a plain log, the repaired copy is named `<log>.good`, so it has no date and its tables
  are saved at the HDB root.
- In segmented mode, a non-default `firstmessage` or `lastmessage` doesn't stop the replay.
- `clean` deletes the whole date partition when `tablelist` is `all`, otherwise only the replayed tables.
- A table with no rows is still saved empty when `emptytables` is on.
- `partandmerge` turns `sortafterreplay` off and applies `p#` through the merge.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.tickerlogreplay
```

`test.q`/`test.csv` write a plain log, run a segmentedtp process to write a segmented log directory, and run
each replay in a fresh q. The tests cover the settings, the init checks, full and table-filtered replays,
message ranges, chunked and track-only saves, basic mode, a custom sort csv, compression, clean, `upd`,
`savedownmanipulation` and `postreplay` overrides, all three merge methods, segmented replays (picking logs from
`stpmeta`, mixed dates refused), and `checklogfiles` on segmented and plain logs.
