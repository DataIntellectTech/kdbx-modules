# di.subscriptions

Subscribe a process (the RDB, and later other real-time consumers) to a tickerplant:
fetch the schema + log details, define the tables locally, replay the pre-subscription
log **exactly once**, then let live updates flow through the root `upd`.

Ported and simplified from `TorQ/code/common/subscriptions.q` (`.sub`), but written
against `di.proc.tickerplant`'s clean single-call `subdetails` protocol rather than the
classic standard-TP `.u.i`/`.u.L`/`.u.d` global reads.

## Dependency

`log` (required) — the injected di.torq logging dep. `init` also `use`s `di.tplogmgr`
(for the repair-aware, count-limited replay).

## Functions

| Function | Description |
|---|---|
| `init[config;deps]` | validate the `log` dep, stash it, load di.tplogmgr |
| `subscribe[tph;tabs;syms;replay]` | subscribe over an open TP handle; returns the subdetails dict |
| `subscribed[]` | `1b` if any subscription is active |
| `getsubscriptions[]` | the active-subscriptions registry table |

### `subscribe[tph;tabs;syms;replay]`

`tph` is an already-open tickerplant handle (the RDB gets it from `di.torq.servers`). `tabs`
/ `syms` are `` ` `` for all, else a list. `replay` is `1b` to replay the tp log. It:

1. calls `tph(`.u.subdetails;tabs;syms)` — one synchronous call that **registers** the
   handle for live updates (di.pubsub, keyed on `.z.w`) **and** returns
   `` `tables`schemas`logfile`rowcount`date ``;
2. **defines the tables at root** from the returned schemas (they carry `` `g# `` etc.) —
   via `@[`.;name;:;schema]`, which targets root explicitly (see Notes);
3. if `replay`, replays the log up to `rowcount` through the root `upd`
   (`di.tplogmgr.replayupto`), filtered to the subscribed tables/syms;
4. records the subscription and returns the subdetails dict.

**Exactly-once replay.** `rowcount` is the number of messages the TP had logged *at the
instant of subscription* (captured atomically inside `subdetails`). The replay uses
`di.tplogmgr.replayupto[logfile;rowcount]`, so any messages that arrive after subscription —
which are also delivered over the live feed — are **not** double-processed. A whole-file
replay would reprocess them.

## Notes / requirements (the module-namespace boundary)

A `use`-loaded module **cannot create or populate ROOT tables via bare symbols** — a bare
`` `trade set x`` or `insert[`trade;x]` from inside a module (or under `-11!`, which runs
in di.tplogmgr's module context) lands in the module's *private* namespace, not root. So:

- table creation uses `@[`.;name;:;schema]` (explicit root);
- **the caller's root `upd` must be root-namespace-safe** — di.proc.rdb's `upd` appends via
  `@[`.;t;…]`. A bare `upd:insert` would, under replay, insert into the wrong namespace
  and silently capture nothing. (Reads are safe: a bare `value t` falls through to root.)

## Not yet (future)

Auto-reconnect / resubscribe on TP bounce; filtered-**column** subscriptions;
remote-log streaming (v1 assumes the subscriber shares the TP's filesystem to read the
log — the classic tick assumption).

## Testing

`test.csv`/`test.q` (k4unit) mock the TP handle as a **function** — `h(msg)` applies `h`
whether it's an int handle (real IPC) or a function — answering `subdetails` with a canned
dict that points at a **real** di.tplogmgr-built log, so the replay path is genuine. Covers:
the dep-check, all/all subscribe + full replay (table created, `g#` preserved, all rows
replayed, registry recorded), and a sym-filtered subscribe replaying only the matching
rows. Real cross-process IPC subscribe is covered by the TorqX-POC end-to-end.

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.subscriptions
```
