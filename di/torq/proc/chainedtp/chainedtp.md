# di.torq.proc.chainedtp

The chained tickerplant: a **subscriber** to an upstream tickerplant (as `di.torq.proc.rdb` is, through
`di.subscriptions` over a handle from the injected `di.torq.servers`) that re-presents itself to its own
subscribers as a **tickerplant** — the same root surface `di.torq.proc.tickerplant` publishes, in the
same two publish modes, with an optional log of its own that a downstream can replay from. It lets a tick
chain fan out through an intermediate hop, or bridge a tickerplant across a process or network boundary,
instead of every consumer dialling the origin. It is the TorqX process type for TorQ's `chainedtp`
proctype, built from `TorQ/code/processes/chainedtp.q` and `config/settings/chainedtp.q` onto the
`di.torq` process-module conventions.

It follows the upstream's date rather than computing one: the date arrives with the subscription and
advances when the upstream ends its day. It therefore has no `di.eodtime` and no schema file of its
own — the tables it relays are whatever the upstream's `.u.subdetails` returns.

| Dependency | Kind | Role |
| --- | --- | --- |
| `log` | injected | `` `info`warn`error ``, each `{[ctx;msg]}` — required |
| `timer` | injected | `` `addjob`deletejobs `` (di.timer contract) — required; used only in batched mode, but required unconditionally, as `di.torq` injects all four into every process |
| `handlers` | injected | `` `register`remove `` (di.torq.handlers contract) — required; the `.z.pc` registrations |
| `servers` | injected | `` `startup`gethandlebytype`waitfortype `` (di.torq.servers contract) — required; dials and waits for the upstream |
| `di.subscriptions` | `use` | the single `.u.subdetails` call that registers for live delivery and defines the tables at root |
| `di.pubsub` | `use` | subscribe / publish / end-of-day broadcast to this process's own subscribers |
| `di.tplogmgr` | `use` | `write` and `replayupto` only — the own log is named, opened, counted and rolled here (see the design record) |

`deps.toml` declares all three `use`d modules at `0.1.0`.

---

## Config

> **Boolean settings.** Values may be booleans, symbols (a `.q` settings file), strings (`.toml` or
> a command-line override) or numbers: `1b`, `` `true ``, `"true"`, `"t"`, `"yes"`, `"on"`, `1` and
> their negatives all work, in any case. An **unrecognised** value fails `init` rather than silently
> defaulting to false — a typo in a setting is a configuration error, and reading it as "off" is how
> a safety setting gets disabled unnoticed. Every boolean in every deployed settings file was checked
> before this change: all canonical `true`/`false`.

`init[config;deps]` — the merged settings dict from `di.torq`'s cascade. Values may be symbols (`.q`
settings), strings (`.toml`, command-line overrides) or numbers; each is coerced where it is read
(booleans accept `1b`/`0b`, `"true"`/`"false"`, `"1"`/`"0"`; integers accept numbers or numeric
strings — strings are parsed, never cast).

| Key | Default | Notes |
| --- | --- | --- |
| `upstreamtype` | **required** | the **proctype** of the tickerplant to subscribe to, e.g. `` `tickerplant `` (or another `chainedtp` - see Known gaps). No name-based option: `di.torq.servers` looks up by proctype only |
| `subscribeto` | `` ` `` | tables to subscribe to; `` ` `` for all |
| `subscribesyms` | `` ` `` | syms to subscribe to; `` ` `` for all |
| `replay` | `0b` | replay the upstream's log on subscribe, into the own log (and, in batched mode, the buffer) |
| `clearlogonsubscription` | `0b` | truncate the own log on (re)subscribe. Pair it with `replay` — a replay onto a log that already holds the day's messages appends them again (logged at `warn`) |
| `tplogdir` | absent = no log | the own log's directory, relative to `TORQXDATAHOME` (falls back to `TORQXAPPHOME`) or absolute. **Presence is the switch**, as `di.torq.proc.tickerplant`; an empty value is absence |
| `publishmode` | `` `immediate `` | `immediate` (publish every update as it arrives) or `batched` (buffer at root, flush on a timer), exactly `di.torq.proc.tickerplant`'s fork |
| `pubperiod` | `1` | batched only: flush period in **seconds** (di.timer's unit) |
| `connecttimeoutms` / `connectpollms` | `10000` / `500` | passed straight to `di.torq.servers.waitfortype`; a timeout fails `init` naming the proctype |
| `logprefix` | the process name | the own log is `<tplogdir>/<logprefix>_<date>` — TorQ named it `<procname>_<date>`, and `di.torq` stamps `procname` into every config, so two chained tickerplants sharing a directory, or one sharing its upstream's, cannot write the same file. `"chainedtp"` only when no `procname` is in the config; an empty value is rejected |
| `proctype` / `procname` | stamped by `di.torq` | identity; `procname` names the log |

`publishmode` is a dispatch key, so an unrecognised value fails `init` naming the setting; so do a
non-positive `pubperiod`, `connecttimeoutms` or `connectpollms`.

Deliberately absent, versus TorQ's `.ctp` settings: `tickerplantname` (proctype-keyed lookup only),
`tpconnsleep`/`tpcheckcycles` (`di.torq.servers.waitfortype` owns the retry loop), `schema` (the tables
always come from the upstream's `.u.subdetails` — there is nothing to toggle), `createlogfile`/`logdir`
(folded into `tplogdir`), `pubinterval` (`publishmode`/`pubperiod`).

```toml
# appconfig/settings/chainedtp.toml
upstreamtype = "tickerplant"
tplogdir = "ctplog"
publishmode = "immediate"
replay = true
clearlogonsubscription = true
```

---

## Initialisation

```q
ctp:use`di.torq.proc.chainedtp
ctp.init[`upstreamtype`tplogdir!(`tickerplant;"ctplog");`log`timer`handlers`servers!(logdep;timerdep;handlersdep;serversdep)]
```

`di.torq` does this for a `chainedtp` proctype (`di.torq.builtin`). `init`:

1. validates the four deps (plain signals — nothing is wired yet), tears down a previous successful
   `init`, and releases anything a previous *failed* `init` left behind (the log handle, the flush job,
   the `.z.pc` registrations — removals are no-ops when absent);
2. reads and validates every setting;
3. loads `di.pubsub`, `di.subscriptions` and `di.tplogmgr`, and registers `di.pubsub`'s `closesub` on
   `.z.pc` through `handlers` (name `` `pubsub ``);
4. publishes the root IPC surface: `upd`, `.u.upd`, `.u.sub`, `.u.subdetails`, `endofday`, `.u.end`;
5. dials the upstream: `servers.startup` with `connections` = the upstream proctype (skipped when an
   earlier `init`'s handle is still live), `waitfortype`, `gethandlebytype`;
6. registers its own `.z.pc` handler (name `` `chainedtp ``) — before subscribing, so an upstream lost
   during the subscription is seen;
7. subscribes: **one** `.u.subdetails` call through `di.subscriptions.subscribe` with replay **off**,
   which registers this process for live delivery and defines the subscribed tables at root; the date
   and the table list come back with it. `connected[]` is true from here, and the root surface is live;
8. initialises `di.pubsub` on those tables;
9. opens the own log for that date (cleared first when `clearlogonsubscription`), counting — never
   executing — whatever it already holds;
10. if `replay` and the upstream had logged anything: replays the upstream's log through root `upd`
    itself, count-limited to the `rowcount` the subscription reported (`di.tplogmgr.replayupto`), with
    a table/sym filter installed for a narrowed subscription — so every replayed message lands in the
    own log;
11. schedules the flush job `` `chainedtp `` every `pubperiod` seconds in batched mode;
12. sets its initialised flag as the **literal last statement**, so a throw anywhere above leaves the
    module uninitialised and a retry runs a full `init`.

Steps 8–11 run under a protected apply: the root surface goes live at step 7 (the upstream may already be
sending), so a failure after it — an unwritable `tplogdir`, a corrupt upstream log — takes the surface down
again (`connected[]` `0b`, `upd` signals) rather than leaving a half-initialised process relaying with no
log and no flush job. The retry is a full `init`.

Every exported function except `init`, `getapimeta` and `version` signals if called before `init`; the
root surface signals until the subscription exists. All post-`init` errors are logged at `error` before
being signalled.

---

## Exported functions

| Function | Description |
| --- | --- |
| `init[config;deps]` | see above |
| `upd[t;x]` | what the upstream publishes and what its log replays (also root `upd` / `.u.upd`): `t` one table symbol (or its string — a symbol list is rejected), `x` a table or a list of columns, already timestamped by the upstream. Written to the own log, then published (immediate) or buffered at root (batched). A publish that throws (a subscriber gone without `.z.pc` firing) is logged at `error` and signalled rather than lost in the async handler |
| `connected[]` | is the upstream subscription live — `1b` once subscribed, `0b` after the upstream connection closes or `teardown`. Backed by module state: `di.subscriptions`' registry tracks no disconnects (TorQ's `notpconnected` read `.sub.SUBSCRIPTIONS where active`; there is no `active` column now) |
| `getcounts[]` | `` `msgcount`date`tables `` — messages in the own log for the current date, the date, and per-table `rowcount` (published) and `pendingrowcount` (in the unflushed batch) |
| `teardown[]` | flush, close the own log, remove the flush job and the module's own `.z.pc` registration. `di.pubsub`'s `closesub` registration is deliberately left in place — a subscriber leaving between a teardown and the next init would otherwise stay registered and the first publish after that init would throw on its dead handle. The upstream subscription itself cannot be withdrawn (no protocol for it) and the socket stays with `di.torq.servers` |
| `getapimeta[]` | api metadata for `di.torq` to register with `di.api` (callable functions only) |
| `version` | the `VERSION` file's contents |

`sub`/`subdetails`/`endofday` are not exported: they exist only as the root surface below.

---

## The surface offered to this process's own subscribers

Structurally identical to `di.torq.proc.tickerplant`'s, so `di.torq.proc.rdb` (via `di.subscriptions`)
subscribes to a chained tickerplant exactly as it would to the origin, without knowing the difference:

| Root name | Description |
| --- | --- |
| `upd` / `.u.upd` | the feed entry point — here fed by the upstream's publishes and log replay rather than a feed |
| `.u.sub[tabs;syms]` | `di.pubsub.subscribe` |
| `.u.subdetails[tabs;syms]` | registers the caller and returns `` `tables`schemas`logfile`rowcount`date `` — `logfile` is the own log (`` ` `` without one), `rowcount` the messages it holds, `date` the upstream's date. In batched mode the buffer is **flushed first**, to the subscribers that already exist: the new one replays those rows from the log, so its replay count never includes a row it would also receive in the next flush (`di.torq.proc.tickerplant` had that double-delivery; fixed alongside this module) |
| `endofday[d]` / `.u.end[d]` | what the upstream sends at its end of day (`di.pubsub.callendofday`'s `` (`endofday;d) ``): flush, `callendofday[d]` to this process's own subscribers — so the chain chains — then roll the own log into `d+1` and follow the date. A `d` **later** than the current date is followed with a `warn`; a `d` **earlier** than it — a day already ended — is ignored with a `warn` (rolling into `d+1` would reopen an older log and move the date backwards, and re-broadcasting would make every subscriber save that day down twice); a non-date is rejected |

Note `endofday` here is **monadic** (`[d]`, what a subscriber receives) where `di.torq.proc.tickerplant`'s
is niladic (its own roll). The names match; the arity follows the direction of the call.

---

## Connection loss

The `.z.pc` handler, registered through `handlers` as a simple event alongside `di.torq.servers`' own
cleanup hook and `di.pubsub`'s `closesub`, checks whether the closed handle is the upstream's. If it is:
the loss is logged at `error`, `connected[]` flips to `0b`, and the process **exits with code 0**.

This is deliberate, not a bare port of TorQ's `exit 0`: nothing in the current stack resubscribes a
bounced tickerplant — `di.subscriptions` lists auto-reconnect/resubscribe under *not yet*, and while
`di.torq.servers`' retry job would reopen the socket, nothing would call `di.subscriptions.subscribe`
on it again. A process that stayed up would be silently disconnected for good. Under a process
supervisor (`torqx.sh` / systemd, restart-on-exit) a clean `exit 0` — an expected, handled condition —
is the right signal. If `di.subscriptions` gains reconnect support, revisit this. The exit goes through
an internal `exitfn` so the tests can observe it without leaving.

---

## Design record

### Verified against the current modules, not assumed

- `di.subscriptions.subscribe[tph;tabs;syms;replay]` always calls `` tph(`.u.subdetails;tabs;syms) `` —
  no `tptype` branching, no `tablelist` — so legacy's `tptype`/`tablelist` exports have nothing to
  serve and are gone. This process only has to present the same root surface the origin does.
- `di.torq.servers` is proctype-keyed throughout (`getservers`/`gethandlebytype`/`waitfortype`), hence
  `upstreamtype`, and its `waitfortype` replaces the `tpconnsleep`/`tpcheckcycles` retry loop.
- `di.subscriptions.SUBSCRIPTIONS` has no `active` column and no disconnect tracking, hence
  `connected[]` is backed by module state.
- `di.pubsub` has no `getsubtables`; `setsubtables` + `init` are called after the subscription has
  defined the tables at root.

### Why the log is opened before the replay, and the replay is driven here

The own log must be open — for the upstream's date — before any replayed message reaches `upd`, or
that history never lands in it and no downstream can replay it from this process (TorQ's `refreshtp`
opened the log first, reading the upstream's `.u.d` directly). `di.torq.proc.tickerplant` publishes no
root `.u.d`; the date only comes back inside `.u.subdetails`, and `di.subscriptions.subscribe` replays
inside that same call. Calling `.u.subdetails` twice would register twice and double-process live ticks
arriving between the calls (a sync call services queued async messages on its handle). So `subscribe`
is called with replay off, the log is opened for the returned date, and the replay is then driven here
with `di.tplogmgr.replayupto` — count-limited to the reported `rowcount`, since live delivery has
already started, and filtered for a narrowed subscription (the upstream log holds every table and sym,
as `di.subscriptions`' own private `replayfilter` handles for an rdb). The filter is a private mirror of
that function — a second instance, after segmentedtp, of `di.subscriptions`' replay machinery being
needed but not exported (see *Findings*).

`upd` treats a log that is not yet open as a skip, never a throw: under single-threaded input no tick
can reach it between the subscription and the log open (`init` runs as one block against the event
loop), but di.torq.handlers documents multithreaded input (a negative `-p`) as a real exception, and the
window costs nothing to close. The integration suite feeds ticks before, during and after the process
starts and asserts every one reaches the own log exactly once.

### Why log handling is self-implemented on top of `di.tplogmgr.write`

`di.tplogmgr.open` replays an existing log through root `upd` — right for a tickerplant restoring its
buffer, wrong here, where `upd` **publishes**: a restart would republish the day. The own log is
therefore **counted** on open (`-11!(-2;file)`, which streams without executing) and only appended to.
It is also named `<procname>_<date>`, not `tp<date>`, so it cannot collide with an upstream's log in a
shared directory. Rolling is a close and an open of the next date.

Corruption is handled as `di.torq.proc.segmentedtp` handles it, not with `di.tplogmgr`'s re-exported
`check`/`repair`: `di.tplog.repair`'s byte signature is hardcoded to `` `trade `` messages, so it would
silently drop every other table — and this process relays whatever it was subscribed to. The good
prefix is copied to `<name>.good` in bounded chunks, the original is left untouched, the recovery is
logged at `warn`, and later starts keep using the `.good`. TorQ's `openlog` had no recovery at all (a
corrupt log was fatal).

### The batched buffer is appended in place, by name

The buffer is a root table appended with `t insert x` — a runtime symbol, which resolves to the root
table from this module's private namespace and under `-11!` replay alike; only *source-level* names are
rewritten module-local (the unit suite drives both paths and asserts the rows land at root). The
`@[`.;t;{tab upsert …}]` idiom `di.torq.proc.rdb` uses is root-safe too, but it copies the whole buffer on
every update: measured on this build, 20k single-row updates took 242ms and 40k 878ms (quadratic), against
14ms by name. For a buffer holding a whole `pubperiod` of a busy feed that matters; the integration suite's
`volume` scenario pushes 2,000 ten-row batches through each mode.

### Batched-mode replay count

`.u.subdetails` flushes the batched buffer *before* registering the caller. `di.torq.proc.tickerplant`
counts a message the moment it is logged, so a subscriber arriving while rows sit in the buffer replays
them from the log and then receives them again in the next flush; flushing first (to the existing
subscribers only) keeps the count exact without pending counters. Building this exposed the same
double-delivery in `di.torq.proc.tickerplant`'s own batched mode (its `upd` logs before it buffers and its
`subdetails` registered the caller without flushing); it is fixed there the same way, with a test.

### Other divergences from TorQ's `chainedtp.q`

- Payloads are normalised to vector columns before logging and publishing, so a single record and a
  batch take one path and a replayed message is always column-list form (what a narrowed replay filter
  indexes).
- An update for a table not in the subscription is rejected (logged, signalled) rather than inserted
  blind; the upstream only ever sends subscribed tables.
- `.u.end` propagates `di.pubsub.callendofday[d]` — `` (`endofday;d) `` — the message
  `di.torq.proc.rdb` expects, rather than legacy's `` (`.u.end;d) ``.
- The `.z.pc` registration coexists with `di.torq.servers`' in `di.torq.handlers`' fan-out instead of
  wrapping the previous handler by hand. This required `di.pubsub` to stop assigning `.z.pc` itself at
  load (which replaced the dispatcher — and `di.torq.servers`' hook — in every process that loaded it):
  consumers now register `closesub` through `handlers`, as this module, `di.torq.proc.tickerplant` and
  `di.torq.proc.segmentedtp` do.
- No FinSpace paths, no `.api.add` (api metadata is `getapimeta[]`).

---

## Findings outside this module (flagged, not fixed here)

- **`di.tplogmgr.replayupto` repairs a corrupt log with `di.tplog.repair`**, whose message signature is
  hardcoded to `` `trade ``; every subscriber replaying a multi-table log through `di.subscriptions`
  is exposed to silent non-trade message loss on corruption. The fix is generalising `di.tplog`'s
  byte-signature scan — standalone work on a shared module.
- **`di.subscriptions`' replay machinery (`replayfilter`/`runreplay`/`doreplay`) is private.** Both
  `di.torq.proc.segmentedtp` and this module needed private variants of pieces of it; worth exporting
  or factoring.
- `di/torq/torq.md` still describes the `builtin` registry as holding one entry.
- `di.torq.proc.tickerplant.subdetails` assumes `di.pubsub.subscribe` returned cleanly: for a request
  naming a table it does not have, pubsub returns `(errmsg;(tables;schemas))` and the tickerplant's
  `tables` becomes the error symbol. `di.torq.proc.segmentedtp` and this module unpack that shape.
- `di.pubsub.publish` sends with `-25!` to every all-data subscriber at once; one dead handle (a subscriber
  that vanished before `.z.pc` ran) fails the send for all of them. This module logs and signals it; it
  cannot prune the handle, as pubsub's registry is private.
- On this build `0#` keeps `` `g# `` on an empty table but drops it once the table has held rows, so
  `di.pubsub.pubclear`'s `0#` strips the attribute from a batched buffer after its first flush. Harmless for
  a transient buffer (schemas are captured at `init`, while the tables are empty), noted in case a consumer
  ever derives a schema from a live buffer.

## Known gaps

- No resubscribe path (hence `exit 0` on upstream loss); no unsubscribe on `teardown`.
- One upstream: if `process.csv` holds several processes of `upstreamtype`, `gethandlebytype[…;`any]` picks
  one at random and only that connection is watched.
- Multithreaded input (a negative `-p`) is untested; the no-log-yet skip in `upd` is the only concession
  to it.
- `replay` without `tplogdir` is harmless but pointless: nothing is retained for a downstream to replay.
- Only `` `tickerplant ``-shaped upstreams (a `.u.subdetails` returning `` `tables`schemas`logfile`rowcount`date ``)
  are supported — `di.torq.proc.tickerplant`, or another chained tickerplant. `di.torq.proc.segmentedtp`'s
  `subdetails` returns a different dict, as `di.subscriptions` does not yet speak it either.

---

## Running tests

**Unit suite** (`test.csv` + `test.q`, 56 checks): mock log, timer, handlers and servers, with the servers
mock handing out a genuine IPC handle to a stub upstream (`test_upstream.q`, spawned as a separate
process) that answers `.u.subdetails` from a fixture log. Real `di.pubsub`, `di.subscriptions` and
`di.tplogmgr`. Run from the repo root in a fresh session:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.chainedtp
```

**Integration suite** (`test_integration.csv` + `test_integration.q`, 10 scenarios): real child
`di.torq.proc.tickerplant`, `di.torq.proc.chainedtp` and `di.torq.proc.rdb` processes wired to `di.timer`,
`di.torq.handlers`, `di.util.log` and `di.torq.servers`, with the test session as a downstream subscriber
— relay, exactly-once across a replaying start, 2,000-batch volume in each mode, the real timer's batched
flush, a narrowed subscription, a **real rdb** replaying from the chained tp through `di.subscriptions` then
following live and ending its day on the chained broadcast, a **chain of two** chained tickerplants, end of
day through the chain, a `kill -9` of the upstream (exit code 0 observed), and a real `di.torq` boot of both
process types through `torqx_init.q`. Children run the same kdb-x binary as
the session and are killed by the `after` row; `moduletest` only loads `test.csv`, so run this directly:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.torq.proc.chainedtp;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]
```
