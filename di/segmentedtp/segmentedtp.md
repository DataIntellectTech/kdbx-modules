# di.segmentedtp

Segmented tickerplant (STP): a sibling of `di.tickerplant`, not derived from it. Where
`di.tickerplant` writes one fixed-format log per day, `di.segmentedtp` supports five distinct
log-naming modes, three batch/publish modes, per-table custom logging assignment, and a dedicated
on-disk metadata table describing every log ever opened. It is the modular replacement for TorQ's
`code/processes/segmentedtickerplant.q` plus `code/segmentedtickerplant/{stplog,stpmeta,pubsub}.q`.

It orchestrates three hard dependencies — `di.pubsub` (subscribe/publish), `di.eodtime` (roll
timing) and `di.tplog` (log check/repair) — with an injected logger, timer and handler registry.

## Import and init

```q
stp:use`di.segmentedtp

trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$())
quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$())

stp.init[`log`timer`handlers`schemas`kdbtplog!(logdep;timerdep;handlersdep;
  `trade`quote!(trade;quote);"/var/kdb/tplogs")]
```

`init` takes a single deps dict:

| Key | Required | Description |
|---|---|---|
| `log` | yes | `` `info`warn`error `` dict of `{[ctx;msg]}` functions |
| `timer` | yes | `di.timer`'s exports; must expose `addjob` (with the `custom` variant), `deletejobs`, `disablejobs` and `enablejobs` |
| `handlers` | yes | `di.handlers`'s exports; must expose `register` and `remove` — used **solely** for `.z.exit` |
| `schemas` | yes | `tablename!schema` dict; the tables to capture |
| `kdbtplog` | yes, no default | base log directory (`stplogs/<logprefix>_<date>/` is created under it) |
| `multilog` | no | `` `tabperiod`` (default), `` `singular``, `` `periodic``, `` `tabular``, `` `custom``; any other value — `init` rejects it |
| `multilogperiod` | no | intraday roll period (timespan, default `0D01`); forced to `1D` when `multilog` is `` `singular`` or `` `tabular``; must be positive — `init` rejects zero/negative |
| `errmode` | no | `1b` (default) — write a separate error log for failed updates |
| `batchmode` | no | `` `defaultbatch`` (default), `` `memorybatch``, `` `immediate``; any other value — `init` rejects it |
| `replayperiod` | no | `` `day`` (default) or `` `period`` — how much history `subdetails` reports; any other value — `init` rejects it |
| `errorlogname` | no | `` `segmentederrorlogfile`` (default); must not collide with a real captured table name — `init` rejects it |
| `createlogs` | no | `1b` (default) — master log-creation switch. With `0b`, `upd` still stamps, buffers/publishes and advances `i`/`rowcounts` per the batch mode, but never opens a file or advances `j` |
| `tickinterval` | no | `1000` (default) — timer tick period in ms |
| `logprefix` | no | `"stp"` (default) — filename prefix; see "Design divergences" below |

`init` initialises the dependency modules (`di.eodtime`, `di.tplog`, `di.pubsub`), materialises the
schemas as root tables, opens today's logs (unless `createlogs` is `0b`), publishes `subdetails` and
`tablelist` at root, schedules the tick timer job, and registers the `.z.exit` handler. Dependencies
and config are re-applied on every call; runtime state (counts, the open logs, the current
period/date) is seeded only on the first — same rule as `di.tickerplant`.

## Naming modes

Five modes, dispatched per table through `.z.m.custommode` under `` `custom``, or uniformly under
any other `multilog` value. Directory layout is `stplogs/<logprefix>_<date>/`, one directory per day.

| Mode | Filename shape | Roll behaviour |
|---|---|---|
| `tabperiod` (default) | `<logprefix>_<table><timestamp>` | one log per table, rolled every `multilogperiod` |
| `singular` | `<logprefix>_<timestamp>` | one log, all tables, rolled daily |
| `periodic` | `<logprefix>_periodic<timestamp>` | one log, all tables, rolled every `multilogperiod` |
| `tabular` | `<logprefix>_<table><timestamp>` | one log per table, rolled daily |
| `custom` | per table, driven by a csv (see below) | mixed |

`tabular` and `tabperiod` use a **byte-identical naming function** — the only difference between
them is that `multilogperiod` is forced to `1D` for `tabular` (and `singular`) at `init` time. This
mirrors legacy TorQ exactly (`stplog.q:28` vs `:37`, `segmentedtickerplant.q:19`): it is not a
coincidence worth "fixing" into two separate implementations.

Legacy's settings-file comment for `multilog` also lists a sixth value, `` `none``. This is
**confirmed stale**: neither `stplog.q`'s naming dispatch nor `stpmeta.q`'s metadata dispatch has a
`` `none`` key, no test fixture or process config in the TorQ repo ever sets it, and it is not
implemented here.

### Custom mode

Per-table mode assignment via `readcustomcsv[file]` (a two-column csv: `tabname,mode`) or
`setcustommode[t]` (the same shape as an in-memory table) — mirroring `di.dbwrite`'s
`readcsv`/`setconfig`/`checkconfig` validation *pattern* (type/column/null/domain checks, each
logged before signalling), though the function and column names are STP's own — the two modules'
csv schemas are unrelated (`tabname,mode` here vs `tabname,att,column,sort` in `di.dbwrite`).

**Both must be callable before `init`**, unlike every other exported function. The natural order is
"load the custom assignment, then init" — `init`'s own custom-mode handling needs
`.z.m.custommode` already resolved to compute which tables it will log. If `multilog` is `` `custom``
and neither `readcustomcsv` nor `setcustommode` was ever called, that is a valid, if degenerate,
configuration: no tables are logged, matching legacy's own documented behaviour for a table absent
from the csv ("tables not specified in csv are not logged" — `stplog.q:40-41`).

### `rolltabs` — the one place a real design mistake was caught before implementation

A table's *naming* mode and whether it *participates in periodic rolling* are two separate
questions, and it is easy to conflate them. `di.eodtime`-driven period rolls only ever touch a
subset of tables called `rolltabs` internally, a literal port of `stplog.q:254`:

- under any **non-custom** top-level mode, every table participates unconditionally — even under
  `` `singular``/`` `tabular``, whose period was already forced to `1D` above, so periodic rolling and
  day rolling happen to coincide, but the *participation set* itself is never filtered;
- under `` `custom``, only tables assigned `` `periodic``/`` `tabperiod`` participate. Tables assigned
  `` `tabular``/`` `singular`` under custom mode are excluded from `rolltabs` entirely — they are only
  ever reopened with a fresh filename when the whole process re-initialises at day-roll, not on any
  independent cycle of their own.

An earlier draft of this module's design computed a **per-table period length** instead (`1D` for
`tabular`/`singular`, else the configured `multilogperiod`) and used it to derive an independent
roll boundary for every table. That is wrong: legacy has no per-table period boundary anywhere —
`currperiod`/`nextperiod` are single global scalars — and the per-table-period approach would have
given a custom-assigned `tabular` table its own independent daily cycle, decoupled from the
process's actual day-roll. The mistake was caught during review, before any code was written against
it, precisely by re-reading `stplog.q:253-256` a second time rather than trusting an earlier
paraphrase. `rolltabs` is the correct, literal mechanism; this module implements it, not the
per-table period-length version.

## Batch modes

| Mode | `upd` | on the timer |
|---|---|---|
| `defaultbatch` (default) | writes to the log immediately | publishes the batched buffer |
| `immediate` | writes and publishes in the same call | no-op |
| `memorybatch` | inserts into the buffer only — **no write, no publish** | writes the buffer to disk and publishes it |

### `memorybatch`'s risk — read this before choosing it

`memorybatch` genuinely risks losing buffered-but-unwritten data. Unlike `defaultbatch`/`immediate`,
which always write to the log immediately and only defer the *publish*, `memorybatch` defers the
on-disk **write** itself until the timer fires.

A `.z.exit` handler (registered via the injected `handlers` dependency — the only reason this module
takes that dependency at all) mitigates this on a **clean** exit: it flushes any buffered
`memorybatch` data to disk first, then performs the same general close-and-metadata-update every
batch mode gets on exit. But:

- the flush only runs when the process exits with code `0` (`x~0i`, matching legacy's own guard at
  `stplog.q:284` exactly). **Any non-zero exit code skips it entirely** — not just a hard `kill -9`.
  A crash, an uncaught signal, or a deliberate non-zero exit all lose whatever was buffered.
- even on a clean exit, this is a mitigation, not an elimination of the risk. A hard kill can still
  happen at any point, including mid-flush.

Treat `memorybatch` as an explicit, informed trade-off — highest throughput, real data-loss exposure
— not as something the exit handler makes safe.

## Root state

Two things this module owns live at **root**, not in `.z.m` — the same exception `di.tickerplant`
documents for its captured tables, extended here with the evidence specific to this module:

```q
currlog:([tbl:`symbol$()]logname:`symbol$();handle:`int$())
loghandles   / a tbl!handle dict derived from currlog
```

`currlog` tracks every currently-open log handle, keyed by table name (or by `errorlogname`, for the
error log's own entry). It must be root-visible because the legacy STP test harness reads it by bare
name over IPC — fixtures such as `tests/stp/subscription/subperiodic.csv` do
`currlog:stpHandle"currlog"`, which only resolves if `currlog` is a root name, not a module-private
one. `loghandles` is kept at root alongside it for the same reason legacy keeps them together.

Everything else — schemas, per-table counts, config, the naming/batch-mode dispatch tables, the
metadata table — stays in `.z.m`.

### `loghandles` is a plain recomputed dict, not a genuine kdb+ view — a deliberate divergence

Legacy's `loghandles::exec tbl!handle from currlog` (`stplog.q:7`) is a real kdb+ **view**: native
dependency tracking, lazily recomputed the next time it is read after `currlog` changes. That works
because legacy's code runs directly in the process's own root namespace, and the `::` view-dependency
syntax is registered by the parser against whatever namespace the assignment textually executes in.

Module code runs `.z.m`-rewritten. The same syntax written inside this module's implementation file
would register the view's dependency against the *module's* private namespace, not root — silently
defeating the whole point. There is also no sibling precedent for it: none of `di.tickerplant`,
`di.timer`, `di.handlers`, `di.eodtime`, `di.tplog`, `di.dbwrite` or `di.pubsub` uses a kdb+ view
anywhere. Instead, every function that mutates `currlog` (`openlog`, `closelog`, `rolllog`)
explicitly recomputes `` `.loghandles set exec tbl!handle from `.currlog `` immediately afterward.
Functionally identical, and considerably easier to reason about and test than relying on q's
lazy-dependency internals from inside rewritten module code.

## The subdetails / tablelist contract

Same shape `di.tickerplant` speaks, so `di.subscriptions` needs no STP-specific handling.

### `tablelist[x]` → symbol list

Unary on purpose — `di.subscriptions` sends `` (`tablelist;`) `` to resolve an all-tables request, so
a niladic form would throw `'rank` and silently degrade. The argument is accepted and ignored.

### `subdetails[tabs;syms]` → dict

| Key | Shape | Meaning |
|---|---|---|
| `schemalist` | list of `(tablename;schema)` pairs | the table and its empty schema |
| `logfilelist` | list of `(msgcount;logfile)` pairs | **can have more than one entry** — see below |
| `rowcounts` | dict keyed by table name | rows published for each subscribed table so far today |
| `date` | date | the current trading date |

`logfilelist`'s multi-entry shape is not new here — it is **why `di.tickerplant`'s own `logfilelist`
is a list at all**. `di.tickerplant`'s own docs say so explicitly: "a LIST because the protocol also
serves a segmented tickerplant, which writes one log per table." The modular subscription protocol
was already built anticipating this module; nothing extra needed adding to `di.subscriptions` for
it. Each entry's `msgcount` is either a real, bounded count (the currently-open period's log — a
subscriber should stop replaying there) or the sentinel `0Wj` (a closed log, meaning "replay
everything in this file" — it will never be appended to again). A subscriber can uniformly call
`di.tplog`'s `replayupto[logfile;msgcount]` for every entry without special-casing the sentinel.

### `tptype` was considered and dropped, not carved out

An early draft of this module's design carried a root-installed `tptype` value (mirroring legacy's
`` `segmented `` process-type marker, used by TorQ subscribers to disambiguate segmented-vs-standard
log-count semantics). It does not appear in the shipped module. A grep across every local
`kdbx-modules` clone found **zero references** to `tptype` anywhere — not in `di.subscriptions`, not
in `di.tickerplant`. `di.subscriptions.q:677`'s own comment confirms why it is genuinely unneeded:
the modular protocol solved legacy's ambiguity by **field shape** instead of a type tag —
`logfilelist` being a list, as above, replaces what `tptype` existed to disambiguate. There is
nothing for it to carve out an exception for.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `upd` | `[table;data]` | Feed entry point: stamp, log (per batch mode) and publish (or buffer) an update. |
| `teardown` | `[]` | Remove the root protocol, the timer job and the `.z.exit` handler installed by `init`. |
| `tablelist` | `[ignored]` | The tables offered for subscription. Published at root; unary. |
| `subdetails` | `[tables;syms]` | Subscribe and return the schemas, log details and counts `di.subscriptions` needs. Published at root. |
| `readcustomcsv` | `[file]` | Load per-table custom logging mode assignment from a csv file. Callable before `init`. |
| `setcustommode` | `[table]` | Set per-table custom logging mode assignment from an in-memory table. Callable before `init`. |
| `getcounts` | `[]` | `` `i`j`d`` — per-table message counts published (`i`) and logged (`j`), and the trading date. |

`getapimeta[]` and `version` are also exported, as metadata for `di.torq`/`di.depcheck`.
`getapimeta` documents these seven — `init`, `getapimeta` and `version` are treated as plumbing and
omitted, matching `di.tickerplant`'s real, shipped behaviour rather than an earlier illustrative
convention that would have included `version`.

## `getcounts` — a deliberate capability addition, and why it needs a real `i`/`j` split

`di.tickerplant` exports `getcounts` (`i`/`j`/`d`) for exactly the message/row-count state it
already tracks internally. Legacy STP never exposed this externally at all. The precedent is real
and direct — include it, and say so plainly rather than silently porting it as if legacy had it.

Unlike `di.tickerplant`, where `i`/`j` are scalars (one log), `getcounts` here returns **per-table
dicts** — `` `i`j`d!(.z.m.i;.z.m.j;date) `` where `i` and `j` are `table!count` dicts. This is not
just a mechanical generalisation: `i` (published watermark) and `j` (logged watermark) genuinely
diverge under `defaultbatch`, for the same reason they diverge in `di.tickerplant` — the log write
happens immediately in `upd`, but the published count lags until the next timer tick's flush. STP is
structurally multi-log where a plain tickerplant is single-log, so the same watermark pair needs
tracking once per table rather than once per process.

Both `i` and `j` accumulate for the whole trading day and reset only at day-roll (`dayrollover`) —
never at a period roll (`rolllog`), even though a period roll closes and reopens every table's log
file. This matches `di.tickerplant`'s own day-scoped `i`/`j` semantics exactly; a period-roll reset
was an earlier bug in this module (caught during review — see the design notes below), since it made
`getcounts` report counts dropping to zero on every `multilogperiod` boundary (hourly, by default)
rather than accumulating for the day as documented.

## Dependencies

Hard (imported via `use` in `init.q`, declared in `deps.q`): `di.pubsub`, `di.eodtime`, `di.tplog`.
Injected via `init`: `log`, `timer` and `handlers` (all required).

`di.tplog` is used only for `check`/`replay`/`replayupto`/`repair`/`write` — the naming-agnostic
operations on an already-resolved log path or handle. **Never `logname`/`open`/`roll`** — those
assume `di.tplog`'s own fixed `<dir>/tp<date>` naming, incompatible with this module's five naming
modes. `openlog` computes its own path per the active naming mode and hands `di.tplog.check` an
existing file before appending to it — adopting `di.tplog`'s corruption-check-on-restart behaviour,
which legacy's own `openlog` never had (it `hopen`s blindly). `check`'s repair path does **not**
rename or overwrite the corrupt file in place — `di.tplog.repair` writes every message that still
deserialises into a brand-new `<name>.good` file, leaving the original corrupt file on disk,
untouched, for later inspection. `openlog` uses the **returned** path as the live log going forward
(`currlog` records whatever is actually on disk) and logs a warning when it differs from the one
requested. Under `singular`/`periodic` mode, where multiple tables share one logical log file,
`openlog` re-runs its handle-reuse check against the **repaired** name too (not just the originally
requested one) before opening a fresh handle — see the design notes below for the bug this closes.

`di.tplog.replay`/`check`/`repair` used to only validate that `logfile` was *a* symbol
(`-11h=type logfile`) — not that it named a real, readable file. Passed a path to a directory,
`corruptp` reported it corrupt and `repair` silently created a `.good` marker file *inside* that
directory rather than raising a clear "not a file" error. Found while stress-testing `segmentedtp`
(a test script's own bug — an unguarded glob for a `.good` file that legitimately did not exist yet —
built exactly such a directory path and fed it to `replay`); never a reachable `segmentedtp` exposure
itself, since this module only ever calls `di.tplog` with paths it computed itself via its own naming
functions, never a caller-supplied or glob-derived one. Fixed directly in `di.tplog` (not here) —
`replay`/`replayupto`/`check`/`repair` now reject a directory path outright before `corruptp` gets a
chance to mischaracterise it; see `di.tplog`'s own design notes and testing section.

`di.pubsub` self-assigns `.z.pc` at load time rather than routing through `di.handlers` — a known,
pre-existing exposure `di.tickerplant` already documents as tracked separately, not something
`di.segmentedtp` introduces or can fix on its own. This module inherits the same exposure through the
same hard dependency.

## Chained mode — explicitly out of scope

Legacy's `sctp.q` chained sub-mode (subscribing to an upstream tickerplant via `.sub.subscribe`,
exiting on a lost upstream connection) is not implemented. The modularisation plan has a separate
`di.chainedtp` module for the general chained-TP case; STP's own chained mode is a different, more
specialised hybrid that nothing downstream currently needs.

This touches `stplog.q` and `segmentedtickerplant.q` in nine line-level `.sctp.*` references across
seven functions in two files (`generateschemas`, `setup`, the process-level `init`, `replaylog`'s
pass-through override, `endofperiod`, `.stplg.init` — which has two separate checks doing different
things — and the `.z.exit` handler). Every one of those branches collapses to its non-chained path
permanently in this module: `replaylog`'s pass-through-to-parent override, the SCTP-delegate variant
of `endofperiod`, and `sctp.q`'s `subscribe`/`init` are not implemented at all, not stubbed.

Note that ``.sctp.loggingmode:`none`` (a real, tested, documented value governing chained mode's own
log-creation policy) is a **different variable** from the stale ``.stplg.multilog:`none`` discussed
above — it is moot here regardless, since chained mode itself is out of scope.

## Design notes

- **`init` must be called first, and every callable export says so — except `upd`.** Same exception,
  same reasoning, as `di.tickerplant`: `upd` runs once per feed message, and the guard is a
  measurable per-message tax to catch a wiring mistake that can only happen at startup.
- **A re-init preserves runtime state**, seeded only on the first `init` call in a process — same
  precedent as `di.tickerplant`, `di.rdb` and `di.subscriptions`.
- **Day-roll advances state directly; it does not recurse into `init`.** Legacy's `dayrollover`
  literally calls `.stplg.init[...]` again (`stplog.q:233`). This module follows `di.tickerplant`'s
  actual mechanism instead: `di.tickerplant`'s own `endofday` performs its day-roll reset inline,
  without recursing into `init` — which would otherwise fight its own fresh/re-init guard (a second
  `init` call mid-process would see `initialised[]` already true and skip the very state-seeding
  block day-roll depends on). `dayrollover` here does the same: advance the date, reset counts, close
  and reopen every table's log, reload the metadata table — directly, not through `init`.
- **The naming timestamp is `currperiod`, consistently, everywhere a log is opened for the currently
  open period** — at `init`, at day-roll, and from every `upd`/tick call. Legacy itself is
  inconsistent here (`stplog.q:263` opens with the exact wall-clock time at init/day-roll, while
  `stplog.q:174` uses the period-aligned `currperiod` at a period roll); faithfully preserving that
  inconsistency in this module caused a real bug during implementation — the very first `upd` after
  init recomputed a *different* filename than the one just opened, and silently opened a second file
  for the same table in the same period. Using `currperiod` consistently everywhere closes that gap.
- **`teardown` is idempotent and narrow.** It withdraws the root protocol, the timer job and the
  `.z.exit` handler — module state, `currlog` and the captured tables are deliberately left intact.
- **`setmeta` persists the metatable to `<dldir>/stpmeta` after every state-changing event** — a
  period roll (`rolllog`), the initial open (`init`'s and `dayrollover`'s fresh-open blocks), and a
  clean exit (`exithandler`). Confirmed by directly wiping the in-memory metatable and calling
  `loadmetatable` again: the persisted file recovers every row and the log sequence number correctly.
  Without this, `loadmetatable`'s restart-recovery design would be unreachable — nothing would ever
  exist on disk for it to recover.
- **`getmeta`'s `open` action reconciles against a stale, never-closed row before appending — a real
  bug found during a holistic re-read, and confirmed directly.** A process that dies before closing
  its currently-open period (a crash, or any exit that skips `.z.exit`) leaves that row permanently
  null-`end` in the persisted `stpmeta`. `loadmetatable` restores it verbatim on the next `init`, and
  ``getmeta[`open`]`` used to append a fresh row on top unconditionally — confirmed by chaining three
  restarts against the same log directory without a clean close in between: the metatable ended up
  with **five rows all pointing at the same physical logfile**, and `subdetails`' `logfilelist` (via
  ``getlogs`day``) reported that one file five times over — a subscriber replaying "the day" would
  replay the same data five times. Fixed by matching on **logname**, not just the table group, before
  appending: a stale row with the SAME logname means this restart is resuming that exact file — reuse
  its existing row rather than duplicate it (logged as a recovery event); a stale row with a
  DIFFERENT logname is a genuinely orphaned segment from a period the process moved past — force-close
  it with the current timestamp, leaving `msgcount` null (honestly unknown, not guessed — an accurate
  count would mean replaying the file and triggering `upd` side effects this reconciliation must not
  cause) rather than fabricating a value. Both paths log a warning, since either is real evidence of
  an unclean prior shutdown worth knowing about operationally.
- **`singular`/`periodic` modes correctly share one OS file handle across every table writing to that
  shared log — verified directly, not just assumed.** `openlog`'s reuse check matches on `logname`
  alone (any table already holding a handle for this path), not `(tbl;logname)`. An earlier version
  matched per-table, which let a second table resolve to the same `logname` as an already-open first
  table and open its own **independent** `hopen` handle to that same path — confirmed, by direct
  handle-number inspection, to produce two distinct OS handles, and confirmed, by direct `di.tplog`
  replay against the resulting file, to make it entirely unreadable (`'rank`). Real alternating
  multi-table traffic through `periodic` mode now replays cleanly with the full, correct row count.
- **Six configurations are rejected at `init` rather than left to manifest as silent corruption or a
  confusing internal error:** `errorlogname` colliding with a real captured table name (`currlog` keys
  by a single `tbl` symbol and cannot tell the two apart — their entries would silently overwrite each
  other); a `custom`-mode CSV/table referencing a table not present in `schemas` (would otherwise open
  a real, orphaned log file that can never receive data, since `upd`'s own table-membership guard
  rejects it forever); a zero or negative `multilogperiod` (the resulting `currperiod` evaluates to
  a null timestamp, and `gentimeformat` of a null timestamp is the empty string — every period's
  filename would silently collide onto one name, intermingling unrelated periods' data in one file);
  and an unrecognised `multilog`, `batchmode` or `replayperiod` value — found during a holistic
  re-read and confirmed directly against a real process for each: an unrecognised `multilog` crashed
  `init` itself with a bare `'rank` (the naming dispatch dict indexed with a missing key returns
  generic null, applied as a 3-arg function); an unrecognised `batchmode` passed `init` silently and
  only threw `'rank` on the first `upd`, misfiled by `errmode` as a data-quality "bad message" forever;
  an unrecognised `replayperiod` was worst of all — no error anywhere, `subdetails`' `logfilelist`
  silently came back as the raw table list instead of `(msgcount;logfile)` pairs, corrupting the
  subscription protocol for any `di.subscriptions` consumer.
- **A thrown `init` call could not be safely retried.** Every validation guard above writes
  `.z.m.schemas` — among other state — before any of them can throw, since deps/config are applied
  before validation runs. `initialised[]` originally probed `.z.m.schemas` directly, so a caller who
  hit any rejection above, fixed their config, and retried was silently downgraded to a **re-init**:
  `fresh:not initialised[]` came back false, skipping every bit of first-time state seeding
  (`logtabs`, `currperiod`, the initial log open, `.z.m.scheduled`/`.z.m.handlerregistered`). The
  "corrected" retry itself then threw on an undefined `.z.m.scheduled`, and `upd` afterward threw on
  an undefined `.z.m.logtabs` — confirmed directly, both before and after the fix. Fixed by a
  dedicated `.z.m.initcomplete` flag, set only as `init`'s own final statement, with `initialised[]`
  probing that instead.
- **`upd` on a table that is schema-valid but unassigned under `custom` mode fails fast and clearly,**
  the same way an unknown table does — unconditionally, not gated by `errmode`. Without this, the
  call falls through to `openlog`, which indexes the naming dispatch dict with a null mode and throws
  a confusing internal `'rank` deep in the call stack; with `errmode` off, that throw is not caught at
  all, crashing the process for what is really a configuration gap, not bad data.
- **`createlogs:0b` genuinely works end to end, not just at `init`.** A real bug, found only by
  actually exercising this documented, first-class config option rather than trusting that `init`'s
  own `createlogs` gate was sufficient: `init` correctly skips creating a directory or opening any
  logs when it's off, but `.z.m.dldir` is then never set, and `openlog`/`setmeta`/`openlogerr`
  referenced it unconditionally — every single `upd` call threw an unrelated undefined-variable
  error. Worse, for a genuinely malformed message specifically, `badmsg`'s own error-recovery path
  (`openlogerr`) threw a *second*, unrelated error that would have escaped `errmode` entirely, since
  a throw inside an error handler is not caught by the protected apply it is handling. Fixed by
  having `openlog` return a null sentinel when `createlogs` is off, and having every write path
  (`updfn`'s three modes, ``ztsfn[`memorybatch]``, `openlogerr`, `setmeta`) check it before touching
  `dldir`. With logging off, `upd` still stamps, buffers/publishes and advances `i`/`rowcounts` per
  the batch mode — only the write itself, and `j`, are skipped.
- **The three roll-safety guards (`endofperiod`, `dayrollover`, `checkends`) disable only this
  module's own timer job, not the whole timer instance — a real bug found during review.** All three
  originally called `di.timer`'s `disable`, a **process-wide** flag that gates `main[]` for every job
  of every module sharing that timer instance (`di/timer/init.q`), not just this module's. A
  segmented-TP-specific clock-skew trip (e.g. "next period is in the past") would silently halt every
  other module's timer-driven work in the same process, with nothing in their own logs pointing at
  why. Fixed by switching all three call sites, and `init`'s corresponding dependency validation, to
  `disablejobs[enlist`segmentedtp]`, which only flips `status` for this module's own job id.
- **A tripped roll-safety guard disabled segmentedtp's own timer job but never re-enabled it, even
  after the module's own roll state self-healed — a real bug found during a dedicated smoke-test
  pass, confirmed directly.** `upd`'s own inline `checkends` call already recovers cleanly on the next
  natural roll attempt (`seq`/`currperiod` advance normally again — proven directly, including across a
  real wall-clock delay), but nothing ever called `enablejobs` to match. Left as-is, `defaultbatch`'s
  publish path — which runs *only* via the timer's `tick` → `ztsfn` → `pubclear`, never inline in
  `upd` — stayed silently dead forever after a single transient clock/data glitch: measured directly,
  `j` (logged) kept climbing across further normal messages while `i` (published) stayed frozen, with
  no error anywhere pointing at why, and a well-formed message could throw straight out of `upd`
  (uncaught by `errmode`, since `checkends` runs outside its protection) purely from stale roll
  bookkeeping. Fixed by calling `enablejobs[enlist`segmentedtp]` on every successful roll, in both
  `endofperiod` and `dayrollover` — harmless if the job was never disabled, since it just re-asserts
  `status:1b`. `init` now requires `enablejobs` on the injected `timer` dict alongside `disablejobs`.
- **`openlog`'s corruption-repair path could open a second, independent OS handle onto a file another
  table had already repaired and opened — a real bug found during review.** Under `singular`/
  `periodic` mode, every table computes the same log filename. If the file was corrupt on the first
  table's `openlog` call, `di.tplog.check` repairs it to a **new** `<name>.good` path (`repair` opens
  and closes its own handle internally, never returning one), and that first table's handle gets
  registered under the repaired name. A second table's `openlog` call recomputes the same *original*
  (still-corrupt) name, so its own reuse check — which queried by the pre-repair name — found nothing,
  fell through, re-ran `check` against the same corrupt file, and opened an independent second handle
  onto what should be one shared file, corrupting it. Fixed by re-running the reuse check against the
  repaired name before falling through to `hopen`.
- **`rolllog` reset `i`/`j` on every period roll, not just day roll — a real bug found during
  review.** With the default `0D01` `multilogperiod`, this made `getcounts` report counts dropping to
  zero hourly rather than accumulating for the day, contradicting the day-scoped semantics documented
  above and diverging from `di.tickerplant`'s own precedent. `dayrollover` already performed the
  correct day-scoped reset; `rolllog`'s own reset was simply removed.
- **`schemas` config values are validated as actual tables at `init`, not just that `schemas` itself
  is a dict.** A non-table value previously surfaced as a raw, unhelpful error deep inside
  `createtables` instead of a clear, named rejection — inconsistent with every other config mistake in
  `init`, which does get one.
- **`dayrollover` leaked one OS file handle per day, indefinitely — a real bug found during a
  dedicated smoke-test pass, confirmed directly via `/proc/self/fd`.** `openlogerr` is called
  unconditionally on every day-roll (when `errmode`/`createlogs` are on, the defaults) to open the new
  day's error log, but `closelog each .z.m.logtabs` — the line meant to close out the previous day's
  handles first — only ever covers the *captured* tables; `errorlogname` is guaranteed by `init`'s own
  collision guard to never be one of them. The previous day's error-log handle was therefore silently
  overwritten in `.currlog` and never closed. Measured before the fix: 5 real day-rolls (driven
  directly through `dayrollover`, white-box) leaked exactly 5 file descriptors; 0 after. Fixed by
  closing the error log's own handle alongside the captured tables', every day-roll — `closelog` is a
  safe no-op if no error-log handle was ever actually open.

## Design divergences from TorQ

- **`logprefix` is a necessary addition, not a straight port.** Every legacy naming function uses
  `.proc.procname` as the filename prefix — a TorQ framework variable with no equivalent outside it.
  `logprefix` (default `"stp"`) mirrors `di.tickerplant`'s own `logname` config key exactly (which
  plays the identical role there, default `"tp"`); named differently here only to avoid colliding
  with this module's internal `logname` naming-dispatch dict.
- **`stamp` is simplified from legacy's per-table-overridable `updtab` dict.** Legacy allows
  `.stplg.updtab` to be overridden with a per-table custom timestamp-injection function via a
  `` (enlist`)!enlist{...} `` default-dict idiom. No config or test anywhere in the TorQ repo actually
  overrides it. This module uses a single, non-overridable `stamp[x;now]` — the same pattern
  `di.tickerplant` already established for exactly this purpose — rather than porting an apparently
  unused customisation hook.
- **`tptype` dropped** — see the subdetails/tablelist section above.
- **Removed entirely:** all `.finspace.*`/`.aws.*` code. FinSpace is end-of-life.

## Testing

`test.csv`/`test.q` (k4unit, 78 checks) cover: `init` DI-validation (a reject path per guard,
including the `errorlogname`-collision, zero-`multilogperiod`, non-table `schemas` value,
custom-mode-unassigned-table and `multilog`/`batchmode`/`replayperiod` domain guards), each naming mode's filename shape including
the `tabular`/`tabperiod` shared-body case,
`defaultbatch` and `immediate` batch-mode write timing (`memorybatch` and the full `immediate`
publish-synchronicity check live in `test_integration.csv` instead — see below),
`readcustomcsv`/`setcustommode` validation failures, the `rolltabs` custom-mode-mixing scenario (a
`tabular`- or `singular`-assigned table alongside a `periodic`/`tabperiod`-assigned one under one
`multilogperiod` — a negative control specifically proving the design mistake caught during review
does not regress), `getcounts`' `i`/`j` divergence under `defaultbatch`, `errmode`/`badmsg` (a
malformed update is caught, not thrown, and does not advance `j`), teardown followed by a real
re-init (confirming the timer job and `.z.exit` handler are genuinely re-registered, not silently
skipped), `subdetails`' zero-match and partial-match paths, and `getapimeta`/`version` guards. Roll
logic (`checkends`/`periodrollover`/`dayrollover`) is driven directly through the module's private
namespace, the same white-box technique `di.rdb`'s suite uses for `di.k4unit`'s own internals, so
period and day rolls can be exercised deterministically without waiting on real clock time.

Every scenario that pokes module state and later asserts on it is written as a **single, atomic
before-row closure** (poke → act → capture → restore, all in one call), never split across separate
before/true rows. `k4unit` runs every `before` row in the file as one batch, in file order, strictly
before any `true`/`fail` row — a poke-then-restore split across two before rows is fully undone by
the time any assertion runs, and a capture-then-check split across a before row and a later true row
can be silently corrupted by an unrelated before row's writes landing in between. Both failure modes
were hit and fixed while extending this suite; every closure since follows the atomic pattern for
that reason.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.segmentedtp
```

`test_integration.csv` (58 checks) drives real on-disk log files across naming modes, a real period
and day roll, and a real `.z.exit` flush on simulated shutdown, each as its own spawned child q
process using real `di.pubsub`/`di.eodtime`/`di.tplog`/`di.timer`/`di.handlers` (not mocks). Twelve of
its seventeen scenarios exist specifically as regressions for bugs found during post-implementation
smoke testing and later review passes (the remaining five close out stress-testing and coverage gaps
— see below): `periodichandlescenario` proves `singular`/`periodic` mode's multi-table
shared log file replays cleanly with the correct row count (not just that writing to it didn't throw
— the corrupted-file version of this bug satisfied that weaker check); `daytimestampscenario` proves
a real day roll's new log file carries the new day's own timestamp in its filename, not a stale
wall-clock read; `immediatemodescenario` checks `immediate` mode's `i`/`j` publish-synchronicity in a
genuinely clean process — `test.csv`'s shared process cannot check this reliably, because its own
`subdetails` call in scenario A registers the in-process caller as a subscriber under a bogus
(non-IPC) handle, and any later `publish` correctly throws trying to notify it (`"0 is not an ipc
handle"`), caught by `errmode` for reasons that have nothing to do with `immediate` mode itself;
`preinitvalidationscenario` proves `checkcustommode`/`readcustomcsv` work correctly when genuinely
called before `init` (not just in `test.csv`'s shared process, where an earlier scenario's `init` call
already wired the logger, masking a real pre-init logging crash this scenario catches);
`phantomtablescenario` pins the custom-mode phantom-table `init` guard (a config referencing a table
absent from `schemas`) with a real, fresh `init` call rather than relying on manual verification;
`freshinitpoisonscenario` pins a real bug where a THROWN `init` call still left `initialised[]`
reporting true (every validation guard used to write `.z.m.schemas` before any of them could throw),
silently downgrading a corrected retry to a re-init that skips all first-time state seeding — fixed by
a dedicated `.z.m.initcomplete` flag set only as `init`'s own final statement; `crashresumescenario`
drives a real crash (a child process that exits non-zero, skipping `.z.exit` entirely) followed by a
real restart into the same log directory, proving `getmeta`'s restart-recovery reconciliation resumes
the dangling row rather than duplicating it; and `orphanedmetascenario` drives `getmeta` directly
(white-box — reproducing a genuinely orphaned, different-logname stale row needs a real elapsed-time
gap across a period boundary, impractical to wait for in a fast test) to prove the OTHER half of that
same fix: a stale row for an abandoned logname is force-closed rather than left dangling forever, with
its message count left honestly null rather than guessed; `rollguardscenario` proves the roll-safety
guard fix's actual blast-radius claim — a real, unrelated timer job registered through the same real
`di.timer` instance survives a deliberately-tripped guard untouched (`di.timer`'s process-wide
`enabled` flag and the unrelated job's own `status` are both unaffected), while `segmentedtp`'s own
job is correctly disabled; and `sharedhandlerepairscenario` reproduces the `openlog` corruption-repair
handle-reuse bug end to end — real `singular`/`periodic`-mode traffic, real on-disk corruption (via
the same byte-smash technique `di.tplog`'s own `test.q` uses), and a real restart proving both
tables end up sharing one handle onto the repaired file rather than a second table opening its own
independent handle and corrupting it again; `errorlogleakscenario` drives 5 real day-rolls
directly through `dayrollover` and measures `/proc/self/fd` before and after, proving the error log's
own OS handle is closed every day-roll rather than silently leaked (0 delta — this scenario reliably
measured a +5 leak before the fix); and `guardrecoveryscenario` trips a roll-safety guard for real,
lets real wall-clock time cross the (now near-term) period boundary, and proves a single subsequent
normal `upd` — which drives a natural, successful roll via the inline `checkends` call — re-enables
segmentedtp's own timer job, not just the module's internal roll state.

`combinedfailurescenario` deliberately overlaps two failure modes that had only ever been tested in
isolation: it corrupts the *currently open* periodic-mode shared file, then immediately trips a
roll-safety guard, then lets real wall-clock time cross the boundary for a natural recovery — proving
neither failure mode corrupts the other's handling (the guard still throws, the timer job still
re-enables, the shared handle survives, and the old corrupted file is simply superseded by a fresh
periodic-mode filename rather than ever being reopened). Its own first draft chased a phantom bug that
turned out to be in the test script itself (`di.tplog.replay` called against a glob that legitimately
matched nothing) rather than in `segmentedtp` — see the design notes below for what that surfaced
about `di.tplog`. `loadvolumescenario` drives 1500 messages across 30 period rolls (every other
scenario here runs single-digit counts) and measures `/proc/self/fd` before and after, proving
correctness and resource stability hold under real per-roll volume, not just repeated small rolls.

Three more scenarios close out the last two items ever left open in this module's own review history —
rapid successive rolls had never been stress-tested, and ``replayperiod:`period`` had never been
directly exercised (only `` `day``, the default). `rapidperiodrollscenario` drives 20 period rolls back
to back with no delay between them (through `endofperiod`, not `periodrollover` alone — see
`custommodescenario`'s own note above on why that alone would not advance `currperiod`), proving the
naming/metatable machinery — including this session's own `getmeta` and shared-handle fixes — holds up
under rapid succession, not just one roll at a time: every period gets its own distinct logname,
exactly one row stays open, and `seq` increments with no gaps or duplicates.
`rapiddayrollscenario` drives 10 day rolls back to back, with two tables sharing one OS handle
(`periodic` mode) so the shared-handle logic is exercised under rapid day-roll succession too — every
intervening day gets its own directory, none skipped or duplicated, and the shared handle survives all
10 rolls intact. (`multilogperiod` is set to `1D` explicitly for this one — `periodic` mode does not
force it the way `singular`/`tabular` do, and jumping a full day at once from a shorter, non-daily
period skips intermediate period boundaries and correctly trips `endofperiod`'s own "next period is in
the past" safety guard, confirmed directly while designing this test.) `periodmodescenario` proves
`subdetails`' `logfilelist` under ``replayperiod:`period`` reports ONLY the current period's live
count and logname — excluding closed history entirely, the opposite of `` `day`` mode's whole-day
picture — using the same process state to show both modes report differently for the exact same data.
`moduletest` only ever loads `test.csv`, so load and run this suite directly, in a fresh session:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.segmentedtp;`test_integration.csv]
.m.di.0k4unit.KUrt[]
```
