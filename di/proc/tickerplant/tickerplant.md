# di.proc.tickerplant

The real-time capture root: receives updates from feeds, timestamps and logs them,
publishes to subscribers, and rolls the log at end of day. It depends on no other
process type, so it's the base of the RT stack (and what `di.subscriptions` / the RDB
will subscribe to).

Classic TorQ splits kdb+tick's `u.q` into pure pubsub (`code/common/u.q`) and the
tick/log/EOD logic (inline in `code/processes/tickerplant.q`). This module is the
latter, orchestrating three hard dependencies — none of which use the
`init[config;deps]` convention, so di.proc.tickerplant initialises each in its own idiom:

| Dependency | Source | Role | Init idiom |
| --- | --- | --- | --- |
| `di.pubsub` | kdbx-modules | subscribe / publish / EOD broadcast | `setsubtables[tabs]` then `init[]` |
| `di.tplogmgr` | TorqX | log open / replay / append / roll | `open[dir;date]` (no init) |
| `di.eodtime` | vendored (feature-eodtime) | roll timing, data-tz stamping | `init[merged dict]` |

Injected deps (from `di.torq`): `log`, `timer`. (`handlers` is passed but unused —
`di.pubsub` installs its own `.z.pc` for subscriber cleanup; see Notes.)

## Config

```toml
publishmode = "immediate"   # "immediate" (publish each update) or "batched" (buffer, flush on a timer)
pubperiod = 1               # batched only: flush period in SECONDS (di.timer granularity)
tplogdir = "tplog"          # relative to TORQXDATAHOME, or absolute; empty/absent = no logging
schemafile = "database.q"   # defaults to <TORQXAPPHOME>/database.q (schema is code, not data)
# rolltimezone / datatimezone / rolltimeoffset -> passed to di.eodtime (default GMT/GMT/0)
```

## Behaviour

- **Schema**: loads `schemafile` at root; the publishable tables are the **unkeyed**
  ones with `time`,`sym` as their first two columns (so ambient/system root tables are
  ignored — a clean di.torq process has only the schema tables at root anyway). `` `g# ``
  is applied to each `sym`. A schema yielding no publishable table is an error.
- **Feed entry** (`upd`, also `.u.upd`, published at root for IPC): timestamps the
  data with `.z.p + di.eodtime.getdailyadj[]` unless the first column is already a
  timestamp (so replay is idempotent); writes `(`upd;t;x)` to the log; then **immediate**
  → `di.pubsub.publish` straight away, or **batched** → `t insert` into the buffer for
  the flush job.
- **Subscriber entry** (`.u.sub[tabs;syms]`, published at root): delegates to
  `di.pubsub.subscribe` (syms=` → all data; a sym list → sym-filtered).
- **Timer jobs** (via injected `di.timer`): an EOD-roll check every second; plus, in
  batched mode, a flush every `pubperiod` seconds (`di.pubsub.pubclear`).
- **End of day** (`endofday`, published at root; fired by the roll-check job or via
  IPC): flush any buffer, `di.pubsub.callendofday`, roll the log
  (`di.tplogmgr.roll`), and advance di.eodtime's date / next-roll / daily-adjustment.
- **Restart**: `di.tplogmgr.open` replays the day's log through the root `upd`, restoring
  in-memory state (batched) and the message count.

## Startup order note

The root `upd`/`.u.sub`/`endofday` names are published **before** the log is opened,
because `di.tplogmgr.open` replays via `-11!`, which executes the root-level `upd`.

## Notes / known gaps

- `di.pubsub` sets its own global `.z.pc` for subscriber cleanup, bypassing `di.torq.handlers`.
  Fine in a TP process (nothing else claims `.z.pc` there); if client tracking is ever
  added to a TP, `di.pubsub` should register through `di.handlers` upstream instead.
- A single malformed schema table (missing `time`/`sym`) is silently skipped rather
  than erroring (shape-filtering trade-off vs TorQ's strict assertion, chosen for
  robustness against ambient root tables).
- Batched flush granularity is whole seconds (di.timer's period unit); TorQ's `system"t"`
  allows sub-second. Fine for v1.
- `di.eodtime` is vendored from an unmerged PR and `rolltimeoffset` can't be expressed
  in TOML (no timespan type) — GMT-midnight rolls need no offset; a non-default offset
  needs a `.q` settings file for now.

## Testing

`test.csv`/`test.q` (k4unit) use the **real** pubsub/tplog/eodtime with a mock
log/timer, covering: schema shape-validation (a no-time/sym schema fails init),
immediate mode (no local retention + log write), batched mode (buffer then flush
clears), the scheduled timer jobs, log replay restoring the buffer on restart, feeding
with logging disabled, and an EOD roll opening the next day's log. Real
feed→TP→subscriber **delivery** and the forced roll are proven in the TorqX-POC
end-to-end (a synchronous k4unit test can't flush pubsub's async `-25!` sends). Run:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.proc.tickerplant
```

End-to-end (TorqX-POC): `torqx.sh start tickerplant1`, then a subscriber
(`hopen`, `.u.sub[`;`]`) and a feed (`.u.upd`) — verified: 3 fed trades reach the
subscriber, the tp log holds 3 messages and replays 3 on restart, and a forced
`endofday` rolls to the next day's log.
