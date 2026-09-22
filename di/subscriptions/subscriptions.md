# di.subscriptions

Subscribe a process to a tickerplant: fetch the schema + log details, define the tables locally,
replay the pre-subscription log **exactly once**, then let live updates flow through the root
`upd`.

Consumed today by `di.torq.proc.rdb`, `di.torq.proc.wdb` and `di.torq.proc.chainedtp` (which
subscribes to its own upstream through this module, then drives its replay itself).

Ported and simplified from `TorQ/code/common/subscriptions.q` (`.sub`), written against the
modular single-call `subdetails` protocol rather than the classic standard-TP
`.u.i`/`.u.L`/`.u.d` global reads.

## Dependency

`log` (required) — the injected di.torq logging dep. `init` also `use`s `di.tplogmgr`
(for the repair-aware, count-limited replay).

`init` takes `[config;deps]`, matching the `di.torq` proc-tier convention that
`di.torq.startbuiltin` wires every module through.

## Config

| Key | Default | Meaning |
|---|---|---|
| `failonreplayerror` | `0b` | `1b` makes an unreplayable log file **fatal** instead of logged-and-skipped |

Values may be symbols (a `.q` settings file) or strings (`.toml`, command-line overrides); they are
coerced at the point of use, so `"false"` and `0b` both work.

`failonreplayerror` exists because both policies are legitimate and the right one depends on the
consumer. An RDB is better off up with most of the day than refusing to start over one corrupt
segment. A consumer whose own state must faithfully mirror the tickerplant's cannot accept silently
incomplete history — `di.torq.proc.chainedtp` raises today for exactly that reason, in its own
duplicate of this replay logic.

## Functions

| Function | Description |
|---|---|
| `init[config;deps]` | validate config and the `log` dep, load di.tplogmgr, reset the registry |
| `subscribe[tph;tabs;syms;replay]` | subscribe over an open TP handle; returns the subscription details |
| `subscribed[]` | `1b` if any subscription is recorded |
| `getsubscriptions[]` | the active-subscriptions registry table |
| `getapimeta[]` | api metadata rows for `di.torq` to register with `di.api` |

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
