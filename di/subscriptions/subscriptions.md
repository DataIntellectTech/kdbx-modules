# di.subscriptions

Subscribe a process to a tickerplant: fetch the schema + log details, define the tables locally,
replay the pre-subscription log **exactly once**, then let live updates flow through the root
`upd`.

Consumed today by `di.torq.proc.rdb`, `di.torq.proc.wdb` and `di.torq.proc.chainedtp` (which
subscribes to its own upstream through this module, then drives its replay itself).

Ported and simplified from `TorQ/code/common/subscriptions.q` (`.sub`), written against the
modular single-call `subdetails` protocol rather than the classic standard-TP
`.u.i`/`.u.L`/`.u.d` global reads.

## Dependencies

Both injected and both **required**, validated for presence, type and the keys this module calls:

| Dep | Keys used | For |
|---|---|---|
| `log` | `` `info`warn`error `` | everything |
| `handlers` | `` `register`remove `` | the `.z.pc` hook that marks a dropped subscription inactive |

`init` also `use`s `di.tplogmgr` (for the repair-aware, count-limited replay).

`handlers` became required when liveness tracking landed. Nothing broke: all three consumers
(`di.torq.proc.rdb`, `wdb` and `chainedtp`) already forward their whole deps dict to this module's
`init`, and `di.torq` injects `` `register`remove`list `` into every process.

`init` takes `[config;deps]`, matching the `di.torq` proc-tier convention that
`di.torq.startbuiltin` wires every module through.

## Config

| Key | Default | Meaning |
|---|---|---|
| `failonreplayerror` | `0b` | `1b` makes an unreplayable log file **fatal** instead of logged-and-skipped |

Values may be booleans, symbols (a `.q` settings file), strings (`.toml`, command-line overrides)
or numbers; they are coerced at the point of use, so `0b`, `` `false ``, `"false"`, `"f"`, `"no"`,
`"off"` and `0` all work, in any case.

An **unrecognised** word signals rather than defaulting to false — a typo in a setting is a
configuration error, and reading it as "off" silently is how a safety setting gets disabled without
anyone noticing. Every boolean in every deployed settings file was checked before this change: all
canonical `true`/`false`.

> The `` `1 ``/`` `0 `` words are load-bearing and must not be trimmed. A command-line override
> arrives as a **string**, and `di.torq.proc.chainedtp`'s integration suite passes
> `-replay 1 -clearlogonsubscription 1` specifically to exercise that path.

`failonreplayerror` exists because both policies are legitimate and the right one depends on the
consumer. An RDB is better off up with most of the day than refusing to start over one corrupt
segment. A consumer whose own state must faithfully mirror the tickerplant's cannot accept silently
incomplete history — `di.torq.proc.chainedtp` raises today for exactly that reason, in its own
duplicate of this replay logic.

## Functions

| Function | Description |
|---|---|
| `init[config;deps]` | validate config and the `log`/`handlers` deps, load di.tplogmgr, reset the registry, hook `.z.pc` |
| `subscribe[tph;tabs;syms;withreplay]` | subscribe over an open TP handle; returns the subscription details |
| `replay[sd;tabs;syms]` | replay a subscription's log(s) through root `upd`; returns the messages replayed |
| `unsubscribe[tph]` | forget the subscription recorded against a handle |
| `teardown[]` | forget every record and give the `.z.pc` registration back |
| `subscribed[]` | `1b` if any subscription is still **live** (its handle has not closed) |
| `getsubscriptions[]` | the active-subscriptions registry table |
| `getapimeta[]` | api metadata rows for `di.torq` to register with `di.api` |

Every one of these refuses to run before `init` and says so — without that guard a pre-init call
fails deep inside on an unset name and reports a module internal
(`.m.di.0subscriptions.registry`) rather than the actual mistake.

### The registry, and what `subscribed[]` actually means

`subscribe` keeps **one row per handle** — re-subscribing over the same handle replaces its row
rather than adding a second.

Each row carries an `active` flag. `init` registers a `.z.pc` handler through the injected
`handlers` dependency whose whole body is to set `active:0b` for a handle that closes — exactly
what TorQ's `.sub.pc` does. `subscribed[]` counts only active rows, so it no longer answers `1b`
for a tickerplant that has gone away.

What it still cannot tell you is whether a live-looking subscription is actually *receiving* data —
only that its handle has not closed. A dead row is **kept, not deleted**: `active` is the
load-bearing half of the reconnect design this module will grow, where it selects what to retry.

`unsubscribe` clears this module's record for a handle. It does not tell the tickerplant, because
`di.pubsub` drops a subscriber on `.z.pc` and a closed handle therefore deregisters itself there.
`teardown` clears every record **and gives the `.z.pc` registration back**, leaving the module
dormant until `init` runs again.

### `replay[sd;tabs;syms]` — driving the replay yourself

`subscribe` replays for you when asked. `replay` is the same machinery exposed, for a consumer that
must sequence its own work **around** the replay rather than inside one call.

`di.torq.proc.chainedtp` is why it exists. It subscribes with `withreplay` off, opens its own log
for the date `subdetails` returned, and only then replays — because a replayed message must not
reach `upd` before that log is open, or the history never lands in it and nothing downstream can
replay it in turn. Calling `subdetails` twice instead would register twice and double-process live
ticks.

`subscribe` calls this same function, so there is **one** replay path rather than a public one and
a private twin free to diverge. That mattered: three private copies of this logic existed before it
was exported, and they had drifted — a payload shape fixed in one was still broken in another.

It returns the number of messages **replayed**, which is not the number of rows kept: the
tables/syms filter drops rows downstream of the count.

### `withreplay` decides whether the tables are reset

`subscribe` defines the subscribed tables at root from the returned schemas. With `replay=1b` an
existing table is **cleared first**, so the replay lands in a clean table and cannot duplicate rows
already present. With `replay=0b` an existing table is **left alone** — a re-subscribe would
otherwise silently discard everything the process had accumulated.

## Two tickerplant protocols

The tickerplant modules do not all speak one subscription protocol, so `subscribe` picks one the
way TorQ's own `.sub.subscribe` does (`subscriptions.q:92-105`): it sends a function that reads a
root `tptype` **on the tickerplant**, defaulting to `` `standard `` where that variable is
undefined.

| | `` `standard `` | `` `segmented `` |
|---|---|---|
| modules | `di.torq.proc.tickerplant`, `di.torq.proc.chainedtp` | `di.torq.proc.segmentedtp` |
| publishes `tptype` | no (so the probe defaults) | `` `segmented `` |
| root name called | `.u.subdetails` | bare `subdetails` |
| schemas | `schemas` — a `tablename!schema` dict | `schemalist` — `(table;schema)` pairs |
| log details | `logfile` + scalar `rowcount` | `logfilelist` — `(msgcount;file)` pairs |

**The root name is why the probe has to happen first.** A segmented TP has no `.u.subdetails` to
answer, so the choice cannot be deferred until the dict comes back and be made on its shape.

**`rowcounts` is not a replay bound.** A segmented TP also returns `rowcounts`, which counts
**rows** per table for the day; `-11!` is **message**-limited. The message counts live inside
`logfilelist`. Feeding `rowcounts` to `replayupto` would replay the wrong amount.

**The `0W` sentinel needs no special case.** A closed segment reports `0W` messages, and
`di.tplogmgr.replayupto` already treats `n >= good-count` as "replay the whole file".

### `subscribe[tph;tabs;syms;replay]`

`tph` is an already-open tickerplant handle (the RDB gets it from `di.torq.servers`). `tabs` /
`syms` are `` ` `` for all, else a list. `replay` is `1b` to replay the tp log. It:

1. probes `tptype` over the handle and calls the matching root `subdetails` name — one
   synchronous call that **registers** the handle for live updates (di.pubsub, keyed on `.z.w`)
   **and** returns the schemas and log details;
2. **defines the tables at root** from the returned schemas (they carry `` `g# `` etc.) — via
   `@[`.;name;:;schema]`, which targets root explicitly (see Notes);
3. if `replay`, replays **every** reported log file through the root `upd`
   (`di.tplogmgr.replayupto`), count-limited per file and filtered to the subscribed tables/syms;
4. records the subscription and returns the details.

**Exactly-once replay.** Each count is the number of messages that file held *at the instant of
subscription* (captured atomically inside `subdetails`). The replay is count-limited per file, so
messages arriving after subscription — which are also delivered over the live feed — are **not**
double-processed. A whole-file replay would reprocess them.

**A corrupt segment is skipped, not fatal.** Each file replays inside its own protected block: a
failure is logged at `error` naming that file, and the loop continues. The subscriber comes up
with a real, possibly partial dataset rather than refusing to subscribe because one older segment
is unreadable. This is TorQ's own policy (`.sub.replay`'s per-file `@[...]` loop). Set
`failonreplayerror` in config to make it fatal instead.

**A narrowed subscription filters across the whole replay, not per file.** Each physical log file
holds the messages of *every* table written to it, including tables outside this request, so the
root-`upd` filter wrapper is installed once before the loop and restored once after it.

### What `subscribe` returns

A **standard** TP's dict is passed through **untouched** — `` `tables`schemas`logfile`rowcount`date ``
— so existing consumers are unaffected (`di.torq.proc.chainedtp` asserts that exact key set).

A **segmented** TP's dict is normalised to carry the same keys those consumers read, plus its own:

| Key | Value |
|---|---|
| `tables`, `schemas` | derived from `schemalist` |
| `rowcount` | messages **actually replayed** (a standard TP's is the count it *reported*) |
| `date` | the roll date |
| `logfilelist`, `logdir`, `rowcounts` | passed through from the segmented TP |

No `logfile` key is synthesised for a segmented TP — its absence is the honest signal that
`logfilelist` is authoritative.

### `replayed` — added to **both** protocols

`rowcount` keeps its protocol-native meaning, which differs: a standard TP's is the count it
*claimed* at subscription time, a segmented TP's is the replayed total (there is no comparable
claimed total, since closed segments report the `0W` sentinel and summing those is meaningless).

`replayed` is always the number of messages that actually made it through the root `upd`. It
exists because the default replay policy logs a failed file and continues, so without it a caller
could not tell a clean replay from one where **every** file was skipped: a standard TP's dict
would still report the tickerplant's claim while nothing at all had landed, and
`di.torq.proc.rdb` would log that claim as fact. Compare `replayed` against `rowcount` (standard)
or check it is non-zero to detect a degraded replay.

### Nothing to replay is not a failure

An empty history is normal and subscribes cleanly:

- a standard TP with **logging disabled** (no `tplogdir`) reports `rowcount` 0 and `logfile` `` ` ``;
- a segmented TP with nothing logged for the requested tables returns an **empty** `logfilelist`.

Both yield `replayed` 0. A missing log file is only an error when the tickerplant *claims* it
logged something — that contradiction is reported with the claimed count in the message.

## Notes / requirements (the module-namespace boundary)

A `use`-loaded module **cannot create or populate ROOT tables via bare symbols** — a bare
`` `trade set x`` or `insert[`trade;x]` from inside a module (or under `-11!`, which runs
in di.tplogmgr's module context) lands in the module's *private* namespace, not root. So:

- table creation uses `@[`.;name;:;schema]` (explicit root);
- **the caller's root `upd` must be root-namespace-safe** — di.torq.proc.rdb's `upd` appends via
  `@[`.;t;…]`. A bare `upd:insert` would, under replay, insert into the wrong namespace
  and silently capture nothing. (Reads are safe: a bare `value t` falls through to root.)

## Not yet (future)

Auto-reconnect / resubscribe on TP bounce; filtered-**column** subscriptions;
remote-log streaming (the subscriber is assumed to share the TP's filesystem to read the
logs — the classic tick assumption).

`logfilelist` ordering is taken as given. `di.torq.proc.segmentedtp` orders it by its metatable
sequence; this module replays the pairs in the order it receives them and does not re-sort, having
no ordering key to sort on (a pair carries only a count and a filename).

## Testing

`test.csv`/`test.q` (k4unit) mock the TP handle as a **function** — `h(msg)` applies `h` whether
it's an int handle (real IPC) or a function — so one mock answers the `tptype` probe *and* the
subdetails call. The mocks **reject the wrong root name**, so a dispatch regression fails loudly
rather than passing by accident, and `mockmismatch` reports one `tptype` while accepting the other
name specifically to prove which name was sent. The canned dicts point at **real**
di.tplogmgr-built logs, so every replay is genuine.

Covers: the dep check and registry seeding; api metadata; the standard path end to end
(regression); sym- and table-filtered subscribes; a segmented multi-file replay asserting
exactly-once delivery, no duplication and ascending `time` across files; a narrowed segmented
subscription spanning separate files; a deliberately corrupted middle segment asserting the
subscriber still comes up with the other segments plus a logged error naming the bad file; and the
unknown-`tptype` and missing-logfile guards. Real cross-process IPC subscribe is covered by the
TorqX end-to-end.

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.subscriptions
```

Run from the repository root (the suite loads `di/subscriptions/test.q` by relative path).

**Integration suite** (`test_integration.csv`) — spawns REAL child kdb-x processes, a
`di.torq.proc.tickerplant` (`test_integration_tp.q`) and a `di.torq.proc.segmentedtp`
(`test_integration_stp.q`), and this process plays the subscriber, wiring the real module against
them over genuine IPC. That is the half the unit suite cannot reach: there the tickerplant is a
mock function, so the root name, the dict shape and the log files are whatever the fixture says.
Covers both protocols end to end, a segmented TP rolled twice so several real segments are
replayed, live delivery not redelivering what replay already applied, a subscriber restart landing
on the same set, and a deliberately destroyed segment being logged and skipped while the rest
arrive. Run it in its own fresh q session, not after `moduletest`:

```q
q)k4unit:use`di.k4unit
q).m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.subscriptions;`test_integration.csv]
q).m.di.0k4unit.KUrt[]
q)k4unit.getresults[]
```

Two things the scenarios deliberately do *not* assert on: the **number** of segments (period
boundaries are wall-clock aligned, so a third sleep can straddle one and produce an extra, empty
segment — multi-file replay is the property, the count is a property of the clock), and atom-row
feed payloads (see below).

> **Feed payload shape.** The suite feeds *enlisted columns*, not rows of atoms. A tickerplant
> accepts either — `stamp[]` keeps an atom row atomic and logs it that way — but
> `di.torq.proc.rdb`'s and `di.torq.proc.wdb`'s `updfn` replay a logged payload with
> `flip (cols tab)!d`, which throws `'rank` on atoms. Live delivery hides it, because the TP
> enlists before publishing; it surfaces only on replay. That gap is in those modules, not this
> one.
