# di.tickerplant

Core tick-capture for the modular TorQ world: receive updates from feeds, stamp them, write them to a
tickerplant log for recovery, and publish them to subscribers, rolling the log at end of day. It is
the modular replacement for TorQ's `code/processes/tickerplant.q`.

It orchestrates three hard dependencies — `di.pubsub` (subscribe/publish), `di.eodtime` (roll timing)
and `di.tplog` (log check/repair) — with an injected logger and timer.

## Import and init

```q
tp:use`di.tickerplant

trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$())
tp.init[`log`timer`schemas!(logdep;timerdep;enlist[`trade]!enlist trade)]
```

`init` takes a single deps dict:

| Key | Required | Description |
|---|---|---|
| `log` | yes | `` `info`warn`error `` dict of `{[ctx;msg]}` functions |
| `timer` | yes | `di.timer`'s exports (must expose `addjob`) |
| `schemas` | yes | `tablename!schema` dict; the tables to capture |
| `batch` | no | `1b` (default) buffers and publishes on a timer; `0b` publishes each update immediately |
| `batchperiod` | no | batch publish interval (timespan, whole seconds; default `0D00:00:01`) |
| `logdir` | no | directory for the tp log; `""` (default) disables logging |
| `logname` | no | log filename prefix (default `"tp"`; file is `<logdir>/<logname><date>`) |
| `subtables` | no | tables offered for subscription (default: all captured tables) |
| `rolltimezone` / `datatimezone` / `rolltimeoffset` | no | forwarded to `di.eodtime` |

`init` initialises the dependency modules (`di.eodtime`, `di.tplog`, `di.pubsub`), materialises the
schemas as root tables (applying `` `g# `` to any `sym` column), opens today's log, and schedules a
single timer job that flushes the buffer (batch mode) and checks for the end-of-day roll. It is
idempotent — a re-init does not re-add the timer job.

## Root tables and the upd contract

The captured tables live at **root**, not in `.z.m`: a tickerplant owns its tables, feeds insert into
them, and `di.pubsub` reads them by name, so they cannot be module-local. This is the one deliberate
root-state exception; all other mutable state is module-local. `di.torq` wires the process's root
`upd` to `tickerplant.upd` so feeds can publish to it.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `upd` | `[table;data]` | Feed entry point: stamp the update, then buffer+log (batch) or publish+log (zero-latency). |
| `subscribe` | `[tables;filters]` | Register a subscriber (delegates to `di.pubsub`); called by downstream processes over IPC. |
| `endofday` | `[]` | Flush the buffer, notify subscribers, roll the tp log, and advance the end-of-day state. |
| `getcounts` | `[]` | `` `i`j`d `` — messages published (`i`), messages logged (`j`), and the trading date. |
| `gettables` | `[]` | The tables this tickerplant captures. |

`getapimeta[]` and `version` are also exported, as metadata for `di.torq` / `di.depcheck`.

## Dependencies

Hard (imported via `use` in `init.q`, declared in `deps.q`): `di.pubsub`, `di.eodtime`, `di.tplog`.
Injected via `init`: `log` and `timer` (both required; validated by `di.depcheck`'s contract check,
not declared in `deps.q`).

`di.tplog` is used only for check/repair on recovery — when `openlog` finds a pre-existing log it runs
it through `tplog.check`, repairing a corrupt one. The tickerplant appends to and rolls the log itself
(opening for append, not replaying), since `di.tplog`'s `open`/`roll` replay through `upd`, which a
tickerplant must not do to its own log.

## Design notes

- **Batch vs zero-latency.** In batch mode `upd` inserts into the root table and the timer job
  publishes the accumulated rows every `batchperiod`, then clears them. In zero-latency mode `upd`
  publishes each update immediately and does not buffer. Both modes log every message.
- **End of day.** The roll fires when the current time passes `di.eodtime`'s next roll timestamp,
  checked on every `upd` and on every timer tick. `endofday` flushes, notifies subscribers, rolls the
  log to the next day, and refreshes the roll time and data-timestamp offset from `di.eodtime`.
- **No `di.handlers` dependency.** Subscriber-disconnect cleanup is handled by `di.pubsub`'s own
  `.z.pc`. (`di.pubsub` should migrate to `di.handlers` so `.z.*` is not assigned outside the central
  registry — tracked separately, out of scope here.)

## Testing

`test.csv` / `test.q` (k4unit) run against the **real** `di.pubsub`, `di.eodtime`, `di.tplog` and
`di.timer` — no dependencies are mocked (the timer is used without `init`, so no live `.z.ts`, and its
job is exercised through `endofday`). A capturing logger is shared across the modules so their output
is assertable.

Coverage: the metadata/version contract; strict `init` dependency validation (a `fail` row per guard);
init materialising the root tables and scheduling the timer job; batch and zero-latency `upd`;
`endofday` flushing and rolling; `upd` input validation; and the two `di.tplog` integration points — a
tickerplant-written log replaying through `di.tplog`, and rolling into a corrupt log repairing it via
`tplog.check`.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.tickerplant
```
