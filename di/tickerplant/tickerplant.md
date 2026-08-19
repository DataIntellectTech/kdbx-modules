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
| `timer` | yes | `di.timer`'s exports; must expose `addjob` (with the `custom` variant) and `deletejobs` |
| `schemas` | yes | `tablename!schema` dict; the tables to capture |
| `batch` | no | `1b` (default) buffers and publishes on a timer; `0b` publishes each update immediately |
| `batchperiod` | no | batch publish interval (timespan, whole seconds; default `0D00:00:01`) |
| `logdir` | no | directory for the tp log; `""` (default) disables logging |
| `logname` | no | log filename prefix (default `"tp"`; file is `<logdir>/<logname><date>`) |
| `subtables` | no | tables offered for subscription (default: all captured tables) |
| `rolltimezone` / `datatimezone` / `rolltimeoffset` | no | forwarded to `di.eodtime` |

`init` initialises the dependency modules (`di.eodtime`, `di.tplog`, `di.pubsub`), materialises the
schemas as root tables (applying `` `g# `` to any `sym` column), opens today's log, **publishes
`subdetails` and `tablelist` at root**, and schedules a single timer job that flushes the buffer
(batch mode) and checks for the end-of-day roll.

`deletejobs` is required even though only `teardown` calls it: a dict-valued dependency returns a
null-shaped value for an absent key rather than erroring, so a missing `deletejobs` would fail
silently inside `teardown` rather than at wiring time.

## Root state: the tables and the subscription protocol

Two things this module owns live at **root**, not in `.z.m`:

- **The captured tables.** A tickerplant owns its tables, feeds insert into them, and `di.pubsub`
  reads them by name, so they cannot be module-local.
- **`subdetails` and `tablelist`.** A subscriber reaches these over IPC through the default
  `.z.pg`/`.z.ps`, which resolve names at root. A bare assignment in module code lands in the
  module's private namespace and would never be found, so `init` publishes them explicitly with
  ``@[`.;nm;:;f]`` and `teardown` gives them back — the same install/uninstall pair `di.rdb` uses.
  Installing over a name that holds something neither this module nor the caller installed logs a
  warning first; `teardown` removes a name only while it still holds this module's function.

All other mutable state is module-local. The process's root `upd` is **not** published here —
`di.torq` wires the feed entry point, which may legitimately be a caller-supplied wrapper around
this module's `upd`.

## The subdetails / tablelist contract

This is the seam every downstream process depends on. `di.subscriptions` drives both.

### `tablelist[x]` → symbol list

The tables offered for subscription (`di.pubsub`'s subscribable list). `di.subscriptions` resolves a
`` ` `` (all tables) request by sending `` (`tablelist;`) `` — so this is **unary**, and the argument
is accepted and ignored. TorQ's own `` tablelist:{.stpps.t} `` is unary for the same reason. A
niladic `{[] …}` would throw `'rank`, which `di.subscriptions` catches and silently downgrades to
asking for `` ` `` — which a segmented tickerplant cannot answer.

### `subdetails[tabs;syms]` → dict

Subscribes the calling handle **and** returns everything a subscriber needs to recover. Asking for
the schemas *is* the subscription: `di.pubsub` registers the handle for live delivery as a side
effect, and there is no unsubscribe verb to undo it.

| Key | Shape | Meaning |
|---|---|---|
| `schemalist` | list of `(tablename;schema)` pairs | the table name and its empty schema, attributes included |
| `logfilelist` | list of `(messagecount;logfile)` pairs | at most one entry — this tickerplant writes a single log. Empty when logging is disabled |
| `rowcounts` | dict keyed by table name | rows **published** for each subscribed table so far today |
| `date` | date | the tickerplant's current trading date |

Behaviour on a partial or empty match, driven by `di.pubsub.subscribe`'s three reply shapes:

- every requested table exists → the dict above;
- **some** exist → the dict for those, plus a `warn` naming the ones that do not. It must still
  succeed: those tables really were subscribed, and signalling would report failure to a caller that
  is now registered;
- **none** exist → signals. `di.pubsub` registered nothing in that case, so failing leaves no half
  subscription behind, and `di.subscriptions` reports the message verbatim.

### `logfilelist`'s message count is `i`, the published watermark — not `j`

This is the one part of the contract that is easy to get backwards, so the reasoning is recorded
here.

`getcounts` reports two counters: `i`, messages **published** to subscribers, and `j`, messages
**written to the log**. In zero-latency mode they move together. In batch mode `j` runs ahead: a row
is logged by `upd` but stays in the buffer until the next timer tick.

`subdetails` reports **`i`**. In batch mode a row that is logged but not yet flushed is still in the
buffer, and `di.pubsub.pubclear` publishes the *whole table* to every registered handle — including
one that registered after that row was buffered. So a subscriber told to replay `j` messages would
replay those rows from the log **and** receive them again at the next tick:

| t | event | i | j | buffered | subscriber told `i=0` | subscriber told `j=1` |
|---|---|---|---|---|---|---|
| 0.1 | `upd` A | 0 | 1 | A | — | — |
| 0.2 | subscriber calls `subdetails` | 0 | 1 | A | replays nothing | replays A |
| 1.0 | tick publishes the buffer | 1 | 1 | — | receives A | receives A **again** |

TorQ reports the same field for the same reason — `chainedtp.q`'s `.ctp.sub` puts `.u.i` in the
reply, and kdb+tick's `r.q` replays with `` .u`i ``.

`rowcounts` is the per-table counterpart (TorQ's `.u.icounts`) and is bumped on the same events, so
the two numbers in one reply always agree about what has been published.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `upd` | `[table;data]` | Feed entry point: stamp the update, then buffer+log (batch) or log+publish (zero-latency). |
| `subscribe` | `[tables;filters]` | The kdb+tick `.u.sub` entry point (delegates to `di.pubsub`), for a caller that wants the raw `(tables;schemas)` reply. |
| `subdetails` | `[tables;syms]` | Subscribe and return the schemas, log details and counts `di.subscriptions` needs. Published at root. |
| `tablelist` | `[ignored]` | The tables offered for subscription. Published at root; unary. |
| `endofday` | `[]` | Flush the buffer, notify subscribers, roll the tp log, and advance the end-of-day state. |
| `teardown` | `[]` | Remove the root protocol and the timer job `init` installed. |
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
  logs and then publishes each update immediately and does not buffer. Both modes log every message.
  The log-then-publish order matches TorQ's `chainedtp.q` and means a message that fails to publish
  is still recoverable from the log.
- **The log handle and the log path are separate names.** `.z.m.logfile` holds the handle (`writelog`
  tests it with `>0i`); `.z.m.logpath` holds the path, which `logfilelist` reports. `openlog` sets
  the path and returns the handle for the caller to store. They were one name, and the path never
  survived — every caller overwrote it with the handle.
- **End of day.** The roll fires when the current time passes `di.eodtime`'s next roll timestamp,
  checked on every `upd` and on every timer tick. `endofday` flushes, notifies subscribers, rolls the
  log to the next day, resets the message and row counts, and refreshes the roll time and
  data-timestamp offset from `di.eodtime`.
- **A re-init preserves runtime state.** Dependencies and config are refreshed on every `init`, but
  the trading date, the message and row counts, and the open log are seeded only on the first. A
  re-init — `di.torq` re-applying config, a config reload, a second wiring — must not rewind the date,
  zero the counts a subscriber replays against, or reopen (and so leak) the log already being written
  to. Table materialisation follows the same rule: a fresh `init` defines every captured table from
  its schema, attributes included, while a re-init defines only names not already at root, because
  re-running `nm set schema` over a live tickerplant discards every buffered row that has been logged
  but not yet published — leaving the counts describing data that had just been thrown away. Same
  precedent as `di.rdb` and `di.subscriptions`, which seed their runtime state only when fresh.
  **Consequence:** a `logdir` or `logname` change on a re-init takes effect at the next roll, not
  immediately.
- **`init` must be called first, and every callable export says so — except `upd`.** `teardown`,
  `subscribe`, `subdetails`, `tablelist`, `endofday`, `getcounts` and `gettables` each guard with
  `requireinit` and report `di.tickerplant: <fn>: init must be called before any other function`.
  `upd` deliberately does not: it runs once per feed message, and the `initialised[]` probe is a
  protected apply costing ~0.7µs a call (measured) — a permanent per-message tax to catch a wiring
  mistake that can only happen at startup and surfaces immediately when it does. Called before `init`
  it throws a bare `'.m.di.0tickerplant.tabs` instead. `di.rdb`'s `updfn` is unguarded for the same
  reason. A test pins which functions are on each side of that line, so the split cannot drift.
- **The `VERSION` read fails loud.** `init.q` signals `di.tickerplant: VERSION file missing or
  unreadable` / `... is empty` rather than doing a bare `first read0`. `di.depcheck` compares versions
  as **strings**, so a whitespace-padded value silently breaks every dependent's check and an empty
  one reads to it as "exports no version" — both failing far from the real cause. The value is
  trimmed. Same shape as `di.rdb`, `di.dbwrite` and `di.eodtime`.
- **`teardown` is idempotent and narrow.** It withdraws the process-global bindings — the root
  protocol and the timer job — and deliberately leaves module state and the captured tables intact,
  so a shutdown path can still inspect or save what is buffered. A re-init after a teardown
  re-publishes the protocol and re-schedules the job.
- **No `di.handlers` dependency.** Subscriber-disconnect cleanup is handled by `di.pubsub`'s own
  `.z.pc`. (`di.pubsub` should migrate to `di.handlers` so `.z.*` is not assigned outside the central
  registry — tracked separately, out of scope here.)

## Design divergences from TorQ

- **The `subdetails` protocol is a deliberate capability addition, not restored parity.** TorQ's
  standard `code/processes/tickerplant.q` defines **no** `subdetails` — a grep over the TorQ tree
  finds it only in `code/processes/chainedtp.q` and `code/processes/segmentedtickerplant.q`, which
  `di.subscriptions`' own source comment also attributes it to. A standard TorQ tickerplant never
  spoke this protocol.

  It is implemented here anyway because there is no `di.chainedtp` or `di.segmentedtp` for `di.rdb`
  to subscribe to instead, so without it no modular subscriber can attach to a modular tickerplant at
  all. Both existing integration harnesses (`di/rdb/test_integration.csv`,
  `di/subscriptions/test_integration.csv`) already hand-roll exactly this adapter in their spawned
  peer, and both label it *"the subdetails adapter a modular tickerplant would own"*. This module now
  owns it. Nobody should read its presence as evidence that a standard TorQ tickerplant had one.
- **One log, not one per table.** `logfilelist` is a list because the protocol also serves a
  segmented tickerplant, which writes one log per table. This module writes a single log, so it
  reports at most one entry.
- **Removed entirely:** all `.finspace.*` / `.aws.*` code. FinSpace is end-of-life.

## Testing

`test.csv` / `test.q` (k4unit) run against the **real** `di.pubsub`, `di.eodtime`, `di.tplog` and
`di.timer` — no dependencies are mocked (the timer is used without `init`, so no live `.z.ts`, and its
job is exercised through `endofday`). A capturing logger is shared across the modules so their output
is assertable.

Coverage: the metadata/version contract; strict `init` dependency validation (a `fail` row per guard,
plus a message assertion so a guard cannot pass on an unrelated throw); init materialising the root
tables and scheduling the timer job; batch and zero-latency `upd`, including that `i` lags `j` while
rows are buffered and tracks it when they are not; a re-init preserving the counts, the buffer and the
log handle; `endofday` flushing and rolling; the `subdetails`/`tablelist` shapes, the published-not-
logged message count, an empty `logfilelist` when logging is off, and the error naming an unpublished
table; root publication and `teardown`; `upd` input validation; and the two `di.tplog` integration
points.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.tickerplant
```

It also carries the **`VERSION` guard** checks. Those fire at *load* time, so they can only be
observed in a child process: the suite builds a temp `QPATH` tree that symlinks every other module
and copies `di/tickerplant`, mutates only its `VERSION`, and loads the module in a child q — covering
an untouched file, a missing one, an empty one, and a whitespace-padded one.

`test_integration.csv` drives a **real `di.subscriptions`** against a **real `di.tickerplant`** over
genuine IPC — the only test that actually proves the protocol gap is closed. The tickerplant is the
spawned peer and `di.subscriptions` runs in the test process, not the other way round: a q process
blocked in a sync call does not accept a new inbound connection, so the side that *dials* has to be
the side that drives. Two scenarios, on OS-assigned ports with no port number anywhere in the file:

- **batch mode** — subscribe with four rows already published and two still buffered, then flush.
  The subscriber must replay 4 and end with 6 rows in order. Reporting `j` gives 8.
- **zero-latency mode** — subscribe with three rows published-and-logged, then two more live. The
  subscriber must replay 3 and end with 5. With `i` not advancing it replays 0.

`moduletest` only ever loads `test.csv`, so load and run this suite directly, in a fresh session:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.tickerplant;`test_integration.csv]
.m.di.0k4unit.KUrt[]
```
