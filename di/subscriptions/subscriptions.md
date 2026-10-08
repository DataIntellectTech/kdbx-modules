# di.subscriptions

Subscribe a process (the RDB, and later other real-time consumers) to a tickerplant:
fetch the schema + log details, define the tables locally, replay the pre-subscription
log **exactly once**, then let live updates flow through the root `upd`.

Ported and simplified from `TorQ/code/common/subscriptions.q` (`.sub`), but written
against `di.torq.proc.tickerplant`'s clean single-call `subdetails` protocol rather than the
classic standard-TP `.u.i`/`.u.L`/`.u.d` global reads.

## Dependency

`log`, `timer` and `handlers` (required) — the injected di.torq deps. `init` also `use`s
`di.tplogmgr` (for the repair-aware, count-limited replay).

## Functions

| Function | Description |
|---|---|
| `init[config;deps]` | validate the deps, stash `log`, load di.tplogmgr, apply the `.sub` settings, register `.sub.pc` and the `checksubscriptions` job (once) |
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
- **the caller's root `upd` must be root-namespace-safe** — di.torq.proc.rdb's `upd` appends via
  `@[`.;t;…]`. A bare `upd:insert` would, under replay, insert into the wrong namespace
  and silently capture nothing. (Reads are safe: a bare `value t` falls through to root.)

## Root `endofperiod`

A segmented tickerplant (di.torq.proc.segmentedtp) broadcasts end of period through
`di.pubsub.callendofperiod`, which sends the `(current;next;data)` triple as a **single**
argument — not three. The subscribing process must have a root `endofperiod` or the publish
fails on this side, so `init` installs a monadic default that logs and returns.

It is installed **only when root `endofperiod` is not already defined**, the same rule
di.torq.proc.chainedtp uses for `upd`. A subscriber with real work to do on a period roll —
forwarding downstream, for instance — defines its own before calling `init` and keeps it.
di.torq.proc.wdb and di.torq.proc.rdb both rely on the default: their partitions only advance
at end of day.

## `.sub`

A second subscription API at root `.sub`, in a `\d .sub` section at the end of `subscriptions.q`, with
its own state: `AUTORECONNECT`, `checksubscriptionperiod`, `SUBSCRIPTIONS`, `getsubscriptionhandles`,
`updatesubscriptions`, `reconnectinit`, `reducesubs`, `createtables`, `replay`, `subscribe`,
`replayupd`, `checksubscriptions`, `retrysubscription`, `autoreconnect`, `pc`. `subscribe` asks the
publisher for its `tptype` (`standard`, `chained` or `segmented`) and subscribes to match. It calls
`.servers.getservers`, `.servers.enabled` and `.servers.connectcustom` from `di.torq.servers` 0.5.0.

- Settings (flat config): `autoreconnect` (default `0b`), `checksubscriptionperiod` (default `0D00:00:10`).
- `init` registers, once per process: `.sub.pc[::;]` on `.z.pc` through `handlers`, and
  `checksubscriptions` every `checksubscriptionperiod` (converted to seconds, timer mode 1) through
  `timer` when the period is above 0.

## Not yet (future)

Auto-reconnect / resubscribe on TP bounce (for the API above); filtered-**column** subscriptions;
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
