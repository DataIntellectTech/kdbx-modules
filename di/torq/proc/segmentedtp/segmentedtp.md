# di.torq.proc.segmentedtp

The segmented tickerplant: receives updates from feeds, timestamps them, writes them to a
configurable **layout of log files** (per table or shared, rolled per period or per day, or a
per-table mix), publishes them to subscribers in one of three **batch modes**, and rolls its
logs at end of period and end of day. It is the TorqX process type for TorQ's
`segmentedtickerplant` proctype.

Built from the real TorQ source — `code/processes/segmentedtickerplant.q`,
`code/segmentedtickerplant/{stplog,stpmeta,pubsub}.q` and `config/settings/segmentedtickerplant.q`
— onto the `di.torq` process-module conventions, mirroring `di.torq.proc.tickerplant` wherever
segmented TP's own requirements don't force a divergence. **Standalone configuration only:**
TorQ's chained variant (`sctp.q`, which subscribes *to* a parent TP) is out of scope.

| Dependency | Kind | Role |
| --- | --- | --- |
| `log` | injected | `` `info`warn`error ``, each `{[ctx;msg]}` — required |
| `timer` | injected | `` `addjob`deletejobs`enablejobs`disablejobs `` (di.timer contract) — required |
| `handlers` | injected | `` `register`remove `` (di.torq.handlers contract) — required |
| `servers` | injected | passed by `di.torq`, deliberately unread (no connection needs), as in `di.torq.proc.tickerplant` |
| `di.pubsub` | `use` | subscribe / publish / end-of-period and end-of-day broadcast; its `closesub` is registered on `.z.pc` through `handlers` (di.pubsub no longer binds `.z.pc` at load) |
| `di.eodtime` | `use` | roll date, next roll time, data-timezone adjustment |
| `di.tplogmgr` | `use` | `write` only — see "Why log handling is self-implemented" |

`deps.toml` declares all three `use`d modules at `0.1.0`.

---

## Config

> **Boolean settings.** Values may be booleans, symbols (a `.q` settings file), strings (`.toml` or
> a command-line override) or numbers: `1b`, `` `true ``, `"true"`, `"t"`, `"yes"`, `"on"`, `1` and
> their negatives all work, in any case. An **unrecognised** value fails `init` rather than silently
> defaulting to false — a typo in a setting is a configuration error, and reading it as "off" is how
> a safety setting gets disabled unnoticed. Every boolean in every deployed settings file was checked
> before this change: all canonical `true`/`false`.

`init[config;deps]` — the merged settings dict from `di.torq`'s cascade. Values may be symbols
(`.q` settings) or strings (`.toml`); each is coerced where it is read.

| Key | Default | Notes |
| --- | --- | --- |
| `kdbtplog` | **required** | root directory for the logs; relative to `TORQXDATAHOME` (falls back to `TORQXAPPHOME`) or absolute. TorQ read `KDBTPLOG`; there is no TorqX equivalent, and TorQ never allowed "no directory" — only `createlogs:0b` |
| `schemafile` | `<TORQXAPPHOME>/database.q` | as `di.torq.proc.tickerplant`: publishable tables are the unkeyed ones with `time`,`sym` first; `` `g# `` applied to `sym` |
| `multilog` | `` `tabperiod `` | naming mode — `tabperiod`, `singular`, `periodic`, `tabular` or `custom` |
| `multilogperiod` | `0D01` | period length (timespan, or a `"0D01:00:00"` string). **Forced to `1D` when the top-level mode is `singular` or `tabular`** — never inside `custom` |
| `batchmode` | `` `defaultbatch `` | `memorybatch`, `defaultbatch` or `immediate` |
| `replayperiod` | `` `day `` | `period` or `day` — what `subdetails` offers for replay |
| `errmode` | `1b` | divert updates that fail to a per-day error log |
| `errorlogname` | `` `segmentederrorlogfile `` | name part of the error log file |
| `createlogs` | `1b` | `0b` publishes without writing any log |
| `logprefix` | the process name | prefix for file and directory names — TorQ used `.proc.procname`, and `di.torq` stamps `procname` into every config, so two segmented tickerplants sharing a `kdbtplog` cannot write the same files or clobber each other's metatable. `"stp"` only when no `procname` is in the config (a hand-wired `init`). An explicit `logprefix` always wins; an empty one is rejected |
| `tickinterval` | `1` | **seconds** — di.timer's unit for modes 1-3. Not TorQ's `system"t 1000"` milliseconds; `1000` here would tick every ~16 minutes (a value of 60 or more is logged at `warn`). di.timer's period is a whole number of seconds, so a sub-second flush is not possible |
| `customcsv` | none | `table,mode` csv for `custom` mode, relative to `TORQXAPPHOME` or absolute |
| `rolltimezone` / `datatimezone` / `rolltimeoffset` | GMT / GMT / `0D` | passed to di.eodtime. `rolltimeoffset` accepts a timespan, a `"0D10:00:00"` string or seconds (like `multilogperiod`); a value that cannot be parsed is dropped with a `warn`, never silently — `di.torq.proc.tickerplant` drops a non-timespan silently |
| `proctype` / `procname` | stamped by `di.torq` | carried in the end-of-period data dict |

`multilog`, `batchmode` and `replayperiod` are dispatch keys, so an unrecognised value **fails
`init`** with a message naming the setting; so do a non-positive `multilogperiod` or
`tickinterval`. TorQ's settings comment lists `prior` for `replayperiod`, but `stplog.q` never
implemented it — it is rejected. A `multilogperiod` shorter than the tick interval is logged at
`warn` (the past-period guard would trip on every roll).

Type coercion: booleans accept `1b`/`0b`, `"true"`/`"false"`, `"1"`/`"0"` and numbers; integers
accept numbers or numeric strings; `multilogperiod` accepts a timespan, a `"0D01:00:00"` string, or a
number of seconds. Strings are *parsed*, never cast — `` `boolean$"true" `` is a boolean **list**,
which would throw `'type` in `if`/`$` on every update, and `"j"$"5"` is the character code 53.

---

## Initialisation

```q
sp:use`di.torq.proc.segmentedtp
sp.init[`kdbtplog`multilog`batchmode!("tplog";`singular;`immediate);`log`timer`handlers!(logdep;timerdep;handlersdep)]
```

`di.torq` does this for a `segmentedtp` proctype (`di.torq.builtin`). `init`:

1. validates the deps (plain signals — nothing is wired yet), tears down a previous successful
   `init`, and releases anything a previous *failed* `init` left open (handles, the timer job,
   the `.z.exit` registration — removals are no-ops when absent);
2. reads and validates every setting, loads the schema file, initialises di.pubsub and di.eodtime;
3. publishes the root IPC surface: `upd`, `.u.upd`, `.u.sub`, `tablelist`, `subdetails`, and
   `tptype:`segmented` (what TorQ's `.sub.subscribe` reads to choose its protocol);
4. opens the day's directory `<kdbtplog>/<logprefix>_<date>`, its logs, error log and metatable;
5. schedules the timer job `` `segmentedtp `` every `tickinterval` seconds and registers
   `.z.exit` (name `` `segmentedtp ``) and di.pubsub's `closesub` on `.z.pc` (name `` `pubsub ``) through
   `handlers` as simple events;
6. sets its initialised flag as the **literal last statement**, so a throw anywhere above leaves
   the module uninitialised and a retry runs a full `init`.

Every exported function except `init`, `readcustomcsv`, `getapimeta` and `version` signals if
called before `init`. All post-`init` errors are logged at `error` before being signalled.

---

## Exported functions

| Function | Description |
| --- | --- |
| `init[config;deps]` | see above |
| `upd[t;x]` | feed entry point (also root `upd` / `.u.upd`). `t` a table symbol, or a symbol list with `x` a matching list of payloads; `x` a list of columns or a table |
| `tablelist[]` | the publishable tables — TorQ `.sub.subscribe`'s `tablesfunc` for a segmented TP |
| `subdetails[tabs;instruments]` | TorQ `.sub.subscribe`'s `subfunc`: registers the caller with di.pubsub and returns `` `schemalist`logfilelist`rowcounts`date`logdir `` |
| `readcustomcsv[path]` | reads a `table,mode` csv into a `table!mode` dict; touches no state, callable before `init` |
| `setcustommode[dict]` | replaces the custom assignment at runtime (custom mode only) |
| `getcounts[]` | `` `seqnum`tables `` — per-table `msgcount`/`rowcount` (logged and published) and `pendingmsgcount`/`pendingrowcount` (in the unflushed batch) |
| `teardown[]` | flush, close every segment and file, remove the timer job and the `.z.exit` and `.z.pc` handlers |
| `getapimeta[]` | api metadata for `di.torq` to register with `di.api` (callable functions only) |
| `version` | the `VERSION` file's contents |

---

## Naming modes

Files live in `<kdbtplog>/<logprefix>_<date>/`; timestamps are `YYYYMMDDHHMMSS` of the period
start (data-timezone adjusted), exactly as `stplog.q` builds them with `logprefix` for `procname`.

| Mode | Files | Rolled |
| --- | --- | --- |
| `tabperiod` | `stp_<table><ts>` — one per table | every `multilogperiod` |
| `singular` | `stp_<ts>` — one shared by all tables | daily (period forced to `1D`) |
| `periodic` | `stp_periodic<ts>` — one shared by all tables | every `multilogperiod` |
| `tabular` | `stp_<table><ts>` — one per table | daily (period forced to `1D`) |
| `custom` | per table, under its own mode from the csv / `setcustommode` | periodic/tabperiod tables per period; singular/tabular tables daily only |

Also in the directory: `stp_<errorlogname><date-start>` (one error log per day, when `errmode`)
and `stpmeta`, the metatable.

In custom mode a table absent from the assignment is published but not logged. Custom mode with
no `customcsv` starts with nothing logged and a warning, until `setcustommode` is called.
`setcustommode` flushes, closes every open segment, and reopens every assigned table under the new
layout: a table whose file name is unchanged reopens the same file and resumes its metatable row.

## Batch modes

| Mode | On `upd` | On the timer flush |
| --- | --- | --- |
| `immediate` | write the log, publish | nothing |
| `defaultbatch` | insert into the root table, write the log; counts held as **pending** | publish and clear every table, then count the pending messages |
| `memorybatch` | insert into the root table only | per table with rows: write the whole buffer as **one** message, count it, publish and clear |

Holding `defaultbatch` counts as pending until they are published is what keeps a subscriber's
replay count exact: a message already written but not yet published is not included in
`subdetails`' counts, because the subscriber will receive it live.

## Timer job, period end and day end

The `` `segmentedtp `` job flushes the batch and then checks for boundaries (TorQ's
`.stpps.zts.def`). `upd` also checks, so a boundary is not missed between ticks.

The job body is protected and any failure is logged at `error`, and the job is registered with
`disableonfail` off. Both are needed: di.timer swallows a job's error unless its own `debug` flag
is on, and with `disableonfail` (its default) the first transient failure — a full disk on a
memorybatch flush, say — would silently stop this process flushing and rolling for good. A guard
trip still stops the job deliberately (via `disablejobs`); the next successful roll re-enables it.

- **End of period** — flush, `di.pubsub.callendofperiod`, advance the period, then roll the
  period-rolled tables: close their metatable rows, close their files, reset their message counts,
  open the new period's files and rows.
- **End of day** — flush, `di.pubsub.callendofday[date]`, advance di.eodtime (date, next roll,
  daily adjustment), close every segment, file and the error log, then start the new day
  (fresh counts, directory, logs, error log and metatable).

## Metatable

`stpmeta` in the day directory: `seq`, `logname`, `start`, `end`, `tbls`, `msgcount`, `schema`,
`additional` — as TorQ's `stpmeta.q`. Persisted on every open and close. `end`/`msgcount` are set
when a segment closes; a null `end` means open (or never closed).

## Subscriber protocol

`subdetails[tabs;instruments]` returns:

| Key | Value |
| --- | --- |
| `schemalist` | list of `(table;empty schema)` pairs for the tables subscribed |
| `logfilelist` | list of `(message count;log file)` pairs, as `-11!` takes them |
| `rowcounts` | `table!rows` for the day, for the tables subscribed |
| `date` | the roll date |
| `logdir` | `kdbtplog` as a symbol — **carried**: TorQ's `.sub.subscribe` segmented branch returns `details[`logdir]` to its caller (`subscriptions.q:132`), so a consumer of this exact protocol expects it |

`logfilelist` under `replayperiod`:
- `day` — every metatable row naming a subscribed table: closed segments `0W` (replay in full),
  open segments their current message count;
- `period` — the files currently open for the subscribed tables.

Either way there is **one pair per physical file**, counting the messages of *every* table in it —
including tables outside the request, whose messages the file physically holds. A filtered
subscriber (sym list or filter table) therefore replays unfiltered files and must filter during
replay itself, as TorQ's `.sub.replayupd` does. `rowcounts` are the **day's** row totals per table
(as TorQ's `rowcount`), even under `replayperiod=period`.

Verified end to end (a real subscriber process calling `subdetails`, replaying `logfilelist` with
`-11!`, then receiving live): every batch mode, a shared singular file, and a subscription made
across a period roll each delivered every message exactly once.

---

## Design record

### Why log handling is self-implemented

`di.tplogmgr`'s `open`/`roll`/`logname` are fixed at one file per date (`<dir>/tp<date>`).
Segmented TP exists to write several files per day under several naming schemes, so naming,
opening, closing and rolling are implemented here; only `write` is taken from `di.tplogmgr`.

### Defects in the TorQ source, fixed from day one

Each is a confirmed defect in the shipped TorQ code, not hypothetical hardening. Each has a
regression test asserting the corrected behaviour.

1. **Corrupt logs were opened blind.** `openlog` `hopen`ed an existing file with no check. Every
   existing file is now counted with the non-executing `-11!(-2;file)` first. A corrupt file's
   good prefix is copied to `<file>.good` (via a temp file and `mv`), and that copy is opened,
   recorded in `currlog` and renamed in the metatable. The corrupt original is left untouched. A
   later start prefers an existing `.good`, so the recovery is not repeated and appended messages
   are not lost. A file too short to hold a log header, or one `-11!(-2;…)` cannot read at all
   (it throws `'type` on either), holds no recoverable message and is recovered as an empty
   `.good`. A corrupt `.good` is recovered in place (its own good prefix), the one case where the
   file being recovered is overwritten.
   *Decision:* a generic byte-prefix copy rather than `di.tplogmgr.check`/`di.tplog.repair`.
   `di.tplog`'s repair matches the `(`upd;`trade;…)` message header only, so for any other table,
   and for any shared file, it would write an empty `.good` — silent data loss.
2. **A roll-guard trip stopped the whole process timer.** `stpeoperiod`/`dayrollover`/`checkends`
   called `system"t 0"`. The guards now call `timer.disablejobs[enlist`segmentedtp]` — this
   module's job only — and every successful roll calls `enablejobs` for it.
3. **The error log leaked a handle every day.** It is tracked apart from the table logs, and
   `dayrollover` never closed it. Day roll, teardown and clean exit now close it explicitly.
4. **An unclean shutdown left never-closed metatable rows, and TorQ added a row on every open.**
   After the day's logs are opened, still-open rows are reconciled by **logname**. A row for a file
   opened again is resumed (and a file already in the metatable is reopened rather than repeated).
   Any other still-open row is an orphan, closed with a **null** message count and logged at
   `warn`. The count is not reconstructed by replaying the file, which would drive the root `upd`.
5. **Replay lists were built per table.** Under `singular`/`periodic` several tables share one
   file, and a `(count;file)` pair per table double-counts it. Pairs are now built per physical
   file, summing every table writing to it.
6. **Custom mode's metatable split was two-way.** `updmeta[`custom]` sent every non-periodic table
   down the per-table path, so custom `singular` tables got a row each. Metatable rows are now
   grouped by the physical file each table is actually writing. That gives one shared row for a
   shared file and one row for a per-table file, whatever mode assigned it, so the four-way split
   needs no mode dispatch.
7. **A failed `init` could look initialised.** The initialised flag is written only as the last
   statement of `init`. A retry after a part-way failure also releases the leaked handles and the
   job/handler registration, so it registers exactly once.
8. **Unrecognised `multilog`/`batchmode`/`replayperiod` failed late or silently.** Each indexes a
   dispatch dict, where an unknown key gives null — a confusing error somewhere unrelated or, for
   `replayperiod`, a bad `subdetails` answer with no error at all. All three are validated in
   `init`, and each is resolved to its function once there.
9. **`createlogs:0b` made every update throw.** `` `..loghandles[t] enlist … `` applied a null handle.
   TorQ's own chained TP masked this by setting `loghandles` to `(::)`; a standalone TP with
   `createlogs:0b` — or a custom-mode table missing from the csv — threw on every `upd`. A table
   with no open log is now published and counted without a write.

### Further decisions

- **Logs open at the period start, not at `.z.p`.** TorQ opened its first logs at the current
  timestamp, so a restart always created new files. Opening at the aligned period start lets a
  restart within a period resume the same files, which is the case fixes 1 and 4 exist for. Each
  file's message count when opened is kept as its base count, so replay counts for a resumed file
  include the messages already in it.
- **Period and day ends flush the batch mode, not just `pubclear`.** TorQ called `pubclear` at
  period end. Under `memorybatch` that published the buffer without ever logging it, and under
  `defaultbatch` it left pending counts to be added to the next period's file.
- **`upd` survives a failed boundary check.** The check is protected inside `upd`: a guard trip is
  logged and stops the job, but the message that exposed it is still logged and published. In
  TorQ's `errmode` the whole `.u.upd` was trapped, so that message went to the error log instead.
- **The error log is per day** (named with the day start), so a restart appends to it.
- **`.u.sub` and `tptype` are published** — TorQ's segmented TP exposed both; `.sub.subscribe` reads
  `tptype` to pick the `tablelist`/`subdetails` protocol.
- **`logprefix` defaults to `procname`.** The first draft defaulted to a fixed `"stp"`, which dropped a
  property TorQ had by construction: names unique per process. Review caught it; the process name from
  `di.torq`'s config is now the default, `"stp"` the fallback for a hand-wired `init`.
- **A string table name in `upd` is accepted as the symbol.** `$[0h<type t;…]` would otherwise
  iterate a string character by character, one unknown-table error per character.
- **Past-period catch-up is one period per check, not a resync.** After a pause longer than one
  period (a suspended host, a clock jump), the guard trips, the job is stopped, and each subsequent
  `upd` advances one period — subscribers receive one `endofperiod` per missed period, messages
  arriving meanwhile go to the file of the period being caught up, and the roll happens once the
  present is reached, re-enabling the job. With no feed traffic the catch-up waits for the next
  message. This mirrors TorQ's guard rather than jumping straight to the present; a single-step
  resync (`multilogperiod xbar now`, one warning, one roll) would be the alternative.
- **Orphaned metatable rows get a null count**, not one from `-11!(-2;file)`. The streaming count is
  side-effect free, so it *could* fill the count accurately — but it reads the whole file at
  startup, and TorQ documents `end`/`msgcount` as informative only.
- **Stamping mirrors `di.torq.proc.tickerplant`:** the data-timezone-adjusted arrival time is
  prepended unless the first column is already a timestamp.
- **Root tables are written with a bare `t insert x`**, as in `di.torq.proc.tickerplant`. The
  schema file loads the tables at root before `upd` can run, and an insert into an existing root
  table amends that table (verified from inside a `use`d module, including via a root-published
  `upd`).
- **di.eodtime's init dict is built in one `!`**, never by amending keys onto
  `` enlist[`log]!enlist logdep ``. A one-element list of dicts is a table, so each amended timezone
  key produced a table-valued dict, and `di.eodtime.init` threw `'type` for **any**
  `rolltimezone`/`datatimezone`/`rolltimeoffset` setting. Found by the integration suite's day-roll
  child; `tzconfigok` in the unit suite guards it. The construction was copied from
  `di.torq.proc.tickerplant`, whose `eoddeps` has the same defect — outside this module, not changed.
- **`version` is exported but not listed by `getapimeta`**. `di.torq.depcheck` reads `version` from
  the export dict, while `getapimeta` describes the callable API. The contract test excludes
  `version` alongside `init`/`getapimeta`.

---

## Known gaps

- ~~**No `di.subscriptions` consumer.**~~ **Closed** — `di.subscriptions` 0.2.0 speaks both
  protocols, choosing between them by probing a root `tptype` over the handle, exactly as TorQ's own
  `.sub.subscribe` does. A subscriber reaches a segmented TP by naming it as its tickerplant type
  (`tickerplanttypes = "segmentedtp"` for `di.torq.proc.rdb` / `di.torq.proc.wdb`), and
  `di.torq.proc.chainedtp` can chain off one. **Nothing in this module changed for it** — the
  protocol it already published was consumed as-is, `0W` sentinel included.
- **End-of-period payload shape.** `di.pubsub.callendofperiod` is monadic, so subscribers receive
  `endofperiod[(currentperiod;nextperiod;data)]` — one list argument — where TorQ sent three
  arguments. Likewise `callendofday` sends `endofday[date]` without TorQ's data dict.
- **`di.pubsub`'s `.z.pc` binding** — resolved on this branch: di.pubsub no longer binds `.z.pc`
  at load (it replaced the `di.torq.handlers` dispatcher, and di.torq.servers' cleanup with it,
  moments after di.torq installed it). This module registers pubsub's `closesub` on `.z.pc`
  through `handlers` in `init` and removes it in `teardown`.
- **Corrupt-log recovery shells out to `mv`** (as `di.torq.proc.tickerplant` uses `mkdir -p`);
  paths are shell-quoted.
- **`msgcount` in a closed metatable row is informative only.** It counts what this process wrote
  plus what the file held when opened; an orphaned row's count is null by design (fix 4).
- **Only today's metatable is reconciled.** A process that was down across a day roll starts a new
  day directory; yesterday's still-open rows are never closed. Subscribers only read today's
  metatable, so this is an audit gap, not a replay one.
- **Sub-second flushing is not possible** — di.timer's period is a whole number of seconds
  (TorQ's `-t 200` style flush has no equivalent). Affects `defaultbatch`/`memorybatch` latency.
- **`di.eodtime` is process-wide state.** Anything else in the process that calls its `init`
  (another module, app code) changes this module's roll date and next-roll time.
- **A dead subscriber does not throw into this module.** `-25!` to a handle whose peer has gone
  reports `'snd handle … Connection reset by peer` on stderr and q closes it, firing `.z.pc`; the
  publish itself returns normally (verified with a `kill -9`ed subscriber in immediate and
  defaultbatch modes). The tick protection above covers the other failure modes.
- **A failed `init` under `torqx_init.q` leaves a silent, live process.** kdb-x abandons a QINIT
  script at the first error with no message and no exit (verified: a `'type` in a QINIT file
  prints nothing, exit code 0, the console comes up). `torqx_init.q` does not guard `tq.init`, so
  any process type whose `init` throws — this module with no `kdbtplog`, or
  `di.torq.proc.tickerplant` with any `rolltimezone`/`datatimezone`/`rolltimeoffset` setting (its
  `eoddeps` defect) — is left listening on its port with the schema loaded and **no `upd`**,
  dropping every feed message with `'upd`. Reproduced by booting a tickerplant with
  `rolltimezone = "Europe/London"` through `torqx_init.q`. A launcher fix (protect `tq.init`, log,
  `exit 1`) is outside this module. The integration suite's `stackboot` therefore asserts the
  module's observable effects (root `upd`, identity, job, handler), never that the process came up.
- **A full publish failure mid-flush** (defaultbatch) leaves the pending counts unfolded until the
  next successful flush; a `subdetails` in between would omit messages a subscriber will not get
  live. Publish failures are not expected in practice (see above) — noted for completeness.
- **`upd` immediate-mode cost** is ~20µs per single-record message in-process against the
  sibling's ~13µs (errmode's protected apply, the per-message count amends and the handle
  lookup); batched messages match the sibling. No per-message `select`/`exec` is on the path.

---

## Running tests

**Unit suite** (`test.csv` / `test.q`) — real di.pubsub, di.eodtime and di.tplogmgr, with mock
log, timer and handlers that record their calls. The timer never cycles; ticks and rolls are
driven by the tests. Covers dependency and config validation, every naming mode, every batch mode,
stamping and multi-table messages, errmode, each of fixes 1-9, period and day rolls (including the
end-of-period/end-of-day broadcasts to an in-process subscriber), `subdetails`, custom mode, exit
handling and teardown. Scenario helpers return `1b` only when every named check passes, and leave
the per-check dict in `LAST`. Expected errors are asserted by message, not by a bare `fail` row.
File-descriptor assertions read `/proc/<pid>/fd` (Linux).

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.segmentedtp
```

Run from the repository root (the suite loads `di/torq/proc/segmentedtp/test.q` by relative path).
**Put this repository first on `QPATH`** — a shared `mod/di` directory earlier on the path (e.g. a
`/opt/kdbx/mod/di` symlink to another checkout) silently supplies its own `di.eodtime`, `di.pubsub`,
`di.timer` and `di.k4unit`, and the suite then tests someone else's dependencies. Check with
`.Q.m.mp`di.eodtime`.

**Integration suite** (`test_integration.csv`) — spawns real child kdb-x processes
(`test_integration_child.q`, which wires the module to the real di.timer, di.torq.handlers and
di.util.log and takes every `-flag` as a string setting, exercising the config coercions), and one
**real `di.torq` boot**: a throwaway app (schema, `process.csv`, a `segmentedtp.toml`) launched
through `torqx_init.q` exactly as `torqx.sh` does, asserting identity and settings reached the
module, feeding it, and exiting it cleanly. Run it in its own fresh q session, not after `moduletest`:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.torq.proc.segmentedtp;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]
```
