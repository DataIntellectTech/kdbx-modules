# di.subscriptions

Tickerplant subscription management for kdb+ subscriber processes (RDB, WDB, chained TP). Fetches table schemas and log details from a tickerplant in a single call, defines the subscribed tables at root, replays the pre-subscription tickerplant log exactly once, and records the subscription in an inspectable registry. Live updates then flow through the root `upd` as normal.

---

## Features

- Subscribe over an already-open tickerplant handle - the caller owns the connection, so this module never opens, retries or closes one
- Subscribe to all tables and syms, or to any subset, with sym filtering applied to the log replay as well as to the live feed
- Define subscribed tables at root from the schemas the tickerplant returns, preserving their attributes (e.g. `` `g# `` on `sym`)
- Replay exactly the messages the tickerplant had logged at the instant of subscription, so messages that also arrive on the live feed are not applied twice
- Verify every log before defining a single table, so a truncated or unreadable log fails with the process untouched (see Notes for the limit of that guarantee)
- Handle every payload shape a tickerplant may log - a list of columns, a table, a dict, or a single atom row - by resolving the `sym` column by name rather than position
- Replay across several log files, as a segmented tickerplant writes one log per table
- Track live subscriptions in a registry whose `active` flag is maintained from `.z.pc`, cross-checked against `.z.W`, and released explicitly by `unsubscribe` before the caller closes a handle
- Refuse to re-subscribe a table that already has a live subscription, rather than silently redefining it and replaying into it again
- Speaks TorQ's real `subdetails` protocol rather than a new one, and the remote entry point name is configurable

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn` and `error` - each binary `{[c;m]}` where `c` is a symbol context and `m` is a string. All three are called by this module |
| handlers | `` `handlers `` | yes | `register` and `remove`, per the `di.handlers` contract. Used to install a `.z.pc` observer that marks a dropped connection's subscriptions dead |

**Hard dependencies:** none. Both dependencies are injected, so the module imports no other `di.*` module.

Both deps must be passed to `init` inside the `deps` dict. The module throws immediately if either is absent or malformed - there is no fallback logger and no degraded no-handlers mode. The `log` dict must already match the binary `{[c;m]}` contract; the module does not detect or adapt other shapes (e.g. a raw `kx.log` instance, which is monadic). To use `di.log`, pass its `logdict``log`.

Handle resolution is the **caller's** job. `di.rdb` and `di.wdb` obtain a tickerplant handle from `di.servers.gethandlebytype` and pass it in, so there is no `di.servers` dependency here.

The configuration key `subdetailsfunc` is optional - omit it and the module calls the tickerplant's `subdetails`. See Initialisation.

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` and `handlers` dependencies with any configuration overrides.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep - `info`, `warn` and `error`, each `{[c;m]}` |
| `` `handlers `` | yes | Handlers dep - at minimum `register` and `remove` |
| `` `subdetailsfunc `` | no | Symbol naming the tickerplant-side function to call. Default: `` `subdetails `` |

`init` must be called before any operational function - `subscribe`, `unsubscribe`, `subscribed`, `getsubscriptions` and `teardown` each throw a clear error if it has not been. `getapimeta` and `version` are metadata and deliberately work without it, so `di.torq` can collect api rows and `di.depcheck` can read the version before anything is initialised. `init` registers a `.z.pc` observer through `di.handlers` and is idempotent - a second call refreshes the dependencies and replaces the registration in place rather than duplicating it, and leaves the registry intact.

Build `deps` as one multi-key dictionary. Do not join `di.log`'s `logdict` to another single-key dict: `` enlist[`k]!enlist somedict `` puts a table on the value side, and joining two of them throws `` 'mismatch `` at the call site before `init` runs.

```q
`log`handlers!(logging.logdict`log;handlerdep)                  / correct
logging.logdict,`handlers`subdetailsfunc!(handlerdep;`subdetails)   / also correct
logging.logdict,enlist[`handlers]!enlist handlerdep             / 'mismatch
```

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log and handlers dependencies, applies config, and registers the `.z.pc` observer.
```q
sub.init[`log`handlers!(logging.logdict`log;`register`remove!(handlers.register;handlers.remove))]
```

### `subscribe[tph;tabs;syms;setschema;replay]`
Subscribe over an already-open tickerplant handle. `tph` is an int handle (or a function standing in for one). `tabs` and `syms` are `` ` `` for all, or one or more symbols - a bare symbol atom names a single table or sym and is normalised to a list. `setschema` defines the returned schemas at root; `replay` replays the pre-subscription log and requires a root-level `upd`.

Returns a dictionary of `subtables`, `tplogdate`, `rowcounts` and `date`, plus `logdir` when the tickerplant supplies one.
```q
sub.subscribe[tph;`;`;1b;1b]                        / all tables, all syms, define schemas, replay
sub.subscribe[tph;`trade`quote;enlist`AAPL;1b;1b]   / two tables, one sym
sub.subscribe[tph;`;`;0b;0b]                        / subscribe only - keep my schemas, skip the replay
/ `subtables`tplogdate`rowcounts`date!(`trade`quote;2025.06.01;`trade`quote!(1042;3311);2025.06.01)
```

### `unsubscribe[tph]`
Release the subscriptions held on a tickerplant handle and return the tables released. **Call this before `hclose`.** It never closes the handle — the caller owns the connection — and never messages the tickerplant, because the `subdetails` protocol has no unsubscribe verb.

It exists for the one liveness signal kdb+ cannot supply: a handle the *caller* closes fires no `.z.pc`, and the freed descriptor is then reissued to the next connection. Without this call, that stale registry row goes on reporting live and the duplicate guard refuses a legitimate re-subscribe. Idempotent — a second call logs at `warn` and returns an empty list rather than throwing, so a shutdown path is safe to run twice.

A deliberate release **deletes** its registry rows rather than flagging them dead: the caller already knows it closed the handle, so the row carries nothing it does not have. A `.z.pc` drop is the opposite case and **keeps** its row, because an unexpected disconnect is worth being able to see afterwards. It selects on the *stored* flag, not the live/dead one, so calling it after `hclose` still removes the row — which is the case that matters most.
```q
sub.unsubscribe[tph]
/ `trade`quote
hclose tph;
```

### `subscribed[]`
Return whether any subscription is currently live. The connectivity check a subscriber process needs before declaring itself ready.
```q
sub.subscribed[]
/ 1b
```

### `getsubscriptions[]`
Return the subscription registry: the handle, subscribed tables, syms, subscription timestamp, and a live/dead `active` flag.
```q
sub.getsubscriptions[]
/ handle tabs        syms subtime                       active
/ ------------------------------------------------------------
/ 4      trade quote      2025.06.01D08:00:00.000000000 1
```
`tabs` and `syms` are general columns, so symbols display without backticks and an all-syms subscription shows an empty `syms`.

### `teardown[]`
Remove the `.z.pc` registration installed by `init`, leaving no process-global residue.
```q
sub.teardown[]
```
**Liveness degrades while torn down.** With the observer gone, `markdead` no longer fires, so `active` rests on the `.z.W` check alone and the handle-recycling protection is lost until `init` runs again. `init` is idempotent and reinstalls the observer, so the exposure is narrow — but do not treat a torn-down module as merely "quiet".

### `getapimeta[]`
Return this module's api metadata, one row per callable export, for `di.torq` to register with `di.api`.
```q
sub.getapimeta[]
```

### `version`
The module version string, read from the `VERSION` file.
```q
sub.version
/ "0.1.0"
```

---

## Usage Example

```q
/ log and handlers deps must already match their contracts - use di.log and di.handlers:
logging:use`di.log
handlers:use`di.handlers
handlers.init[logging.logdict]
handlerdep:`register`remove!(handlers.register;handlers.remove)

/ load and initialise
sub:use`di.subscriptions
sub.init[`log`handlers!(logging.logdict`log;handlerdep)]

/ define the root upd the replay will drive, exactly as the subscriber process does
upd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]];}

/ the caller resolves the tickerplant handle. NB di.servers is not merged yet (feature-server), so
/ on main today obtain the handle however the process already does - any open handle works
servers:use`di.servers
tph:servers.gethandlebytype[`tickerplant;`any]

/ subscribe to everything and replay the log
r:sub.subscribe[tph;`;`;1b;1b]
r`subtables      / the tables now defined at root and receiving live updates
r`tplogdate      / the tickerplant log date, for setting the partition

/ check connectivity
sub.subscribed[]
sub.getsubscriptions[]

/ on shutdown - declare the handle finished BEFORE closing it, so a reissued
/ descriptor cannot revive the registry row
sub.unsubscribe[tph]
hclose tph
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.subscriptions
```

Run in a fresh q session - the integration layer spawns and kills a real q process, so do not interleave with other modules' tests. Needs `QHOME` set (the peer is launched via `$QHOME/bin/q`) and `di.os` on `QPATH` (the harness uses `os.abspath` to load `test.q`).

The suite is 318 assertions (`true`, `fail` and `run` rows, excluding the 5 fixture `before`/`after` rows) and wires the real merged `di.log` and `di.handlers` rather than mocks, so both injected contracts are proven end to end. It covers: pre-`init` guards on every export; dependency validation (non-dict deps, each missing key, each malformed value); `init` arity asserted by observable effect rather than by "it did not throw"; idempotent re-init; the `VERSION` file and exported `version`; `getapimeta`; all-tables and sym-filtered replay; all four payload shapes a tickerplant may log; symbol-atom table and sym selectors; a multi-table log where only the requested table is defined; replay across two log files; requested-but-absent and offered-but-unrequested tables; a configured `subdetailsfunc`; partial, unreadable, absent and empty logs; a replay requested with no root `upd`; malformed `schemalist` **and** `logfilelist` shapes, including a non-table schema, a column-less table, a duplicated table name, and a keyed schema that must still be accepted; a negative message count, asserted with `replay:0b` as well so the guard cannot drift behind the replay branch; every `setschema`/`replay` combination, including `setschema:0b` with `replay:1b` on both the narrowed and all-syms paths; empty `tabs` and `syms` selectors; the double-subscribe guard and its release by `unsubscribe`; `unsubscribe` deleting rather than flagging, its idempotency, and its `warn` on an unheld handle; malformed tickerplant responses; `setschema:0b` preserving a populated table; `logdir` passthrough; and input validation on every argument.

The suite also covers teardown/re-init lifecycle cycles, and asserts the `di.handlers` isolation contract: a co-registrant that throws at a priority ahead of this module's observer must not suppress `markdead`. That assertion is made through `unsubscribe`, which matches on the stored flag - checking `active` alone would be vacuous, since the closed handle reads dead through `.z.W` either way.

The integration block subscribes to a genuinely separate tickerplant process over IPC, kills it, confirms `.z.pc` marks the subscription dead, reconnects onto a recycled handle number, confirms the stale row stays dead and the re-subscribe succeeds, then drives live updates through the replayed tables to prove the exactly-once boundary. It finishes on the two cases only a real handle can reach: releasing a handle and `hclose`ing it while the tickerplant is still alive (so nothing fires `.z.pc`), reopening onto the same reissued descriptor and confirming no revival; and the reverse order — `hclose` *first*, then `unsubscribe` — which proves the release matches on the stored flag rather than the computed one, and so still finds a row `.z.W` has already given up on.

---

## Notes

- Replay uses kdb+'s native `-11!` directly rather than `di.tplog`. This module replays the first *n* messages; `di.tplog.check` is built for the replay-everything caller and would rewrite an entire log to a `.good` file when corruption lies beyond the messages actually needed, and cannot report the good-message count the preflight requires
- Every log is verified with the non-executing `-11!(-2;logfile)` streaming count *before* any table is defined. This matters: `-11!(n;logfile)` past a corruption point replays the good messages and only then throws, leaving tables half populated
- **That guarantee covers log corruption, not every replay failure.** Preflight cannot vet the root `upd` itself. If `upd` throws part-way through a replay — bad data, or a bug in the caller's own handler — the tables are already defined and partially populated, and no registry row exists, because the row is appended after the replay completes. `subscribe` signals, but the process is *not* untouched. Do not read the preflight guarantee more broadly than it is stated
- The registry retains a row for every subscription that ended via `.z.pc` (tickerplant death) for the life of the process; only `unsubscribe` removes rows. This is deliberate for v1 rather than merely unfixed: the case that would make it matter — a flapping tickerplant generating dead rows continuously — **is not reachable without auto-reconnect**, which this module does not implement. Today a dead handle is only replaced by a human or an external supervisor calling `subscribe` again, which is inherently rate-limited. Bounding this belongs with the auto-reconnect design, where the reconnect cadence will be known rather than guessed at now. `activesubscriptions` recomputes liveness across the whole registry on every accessor call, so the bound on rows is also the bound on that cost
- The subscribed set is what was requested intersected with what the tickerplant offered. A requested table the tickerplant does not return is logged at `warn` and skipped; a table it volunteers unasked is logged at `warn` and ignored - neither defined nor replayed
- Liveness needs three signals, and the measured behaviour of each is what dictates the design. On KDB-X 5f: a handle the process `hclose`s itself fires **no** `.z.pc` and leaves `.z.W`; a remote death fires `.z.pc` with the handle; and a closed descriptor **is** reissued to the next connection (`4` → `4`). So `.z.pc` covers tickerplant death, `.z.W` covers a local close *until the number is reused*, and `unsubscribe` covers the reuse case by clearing the stored flag outright. `.z.pc` is why `handlers` is a required dependency; `.z.W` alone is not sufficient, because a recycled number would revive a stale registry row
- The double-subscribe guard runs after the tickerplant has been asked what it offers, so it compares resolved table lists. An all-tables subscribe is refused only where it genuinely overlaps a live subscription, not merely because some other subscription exists
- Tables are created at root with `@[`.;name;:;schema]`, and `-11!` resolves `upd` at root even when invoked from module context. A root-level `upd` must therefore be defined before calling `subscribe` with `replay` set - this is **enforced**, not merely expected: without it every replayed message would be silently discarded and the narrowed path would leave its no-op stand-in bound at root, so the live feed would vanish into it too
- A malformed `subdetails` response is rejected before anything is defined, including a `schemalist` that is not a list or whose entries are not `(tablename;schema)` pairs. An empty entry is tolerated, as legacy does
- The *schema* half of each entry must actually be a table. This is not pedantry: `createtables` uses `@[`.;name;:;schema]`, which succeeds for **any** value, so without the check a tickerplant sending a dict or an atom would have it planted at root under the caller's table name and `subscribe` would report success over a root name that is not a table. The test is `.Q.qt` rather than `98h=type`, deliberately — a **keyed** table is `99h` and must still be accepted, while a column-less `([])` is also `99h` and must not be, since it has no columns to replay into
- A `schemalist` naming the same table more than once is rejected rather than deduplicated. The duplicate would otherwise flow straight into `subtables` — which `di.rdb` and `di.wdb` iterate over — and into the registry's `tabs`. Deduplicating would hide a tickerplant bug; every other malformed response here fails loud, so this does too
- `setschema:0b` skips table definition entirely, so a subscriber that pre-loads its own schema keeps it. With `setschema:1b` the returned schema replaces whatever is at root, which is why re-subscribing a live table is refused. Combining `setschema:0b` with `replay:1b` requires the tables to exist at root already, and that is **checked** — otherwise the replay fails inside the caller's own `upd` on the all-syms path, or from `cols get t` on the narrowed one, neither of which reaches the log
- A malformed `logfilelist` is rejected on the same terms as `schemalist` — a non-list, an entry that is not a `(messagecount;logfile)` pair, a non-integer count or a non-symbol log file. A **negative** count is rejected too, which no shape check catches, since `-1` is a perfectly good integer; that guard lives in the response validation rather than the replay preflight so it also fires when `replay` is `0b`
- `subdetails` is TorQ's real protocol, defined at root by `chainedtp.q` and `segmentedtickerplant.q`, returning `` `schemalist`logfilelist`rowcounts`date `` and optionally `` `logdir ``. The key names and shapes here were taken from that source and are exercised against a tickerplant process built to the same protocol in the integration tests; the module has **not** yet been run against a live TorQ chained or segmented tickerplant. `di.tickerplant` is not built yet - when it lands, point `subdetailsfunc` at its entry point if the name differs
- Not in v1: auto-reconnect and resubscribe on tickerplant bounce, filtered-column subscriptions, and remote-log streaming (the subscriber is assumed to share the tickerplant's filesystem, the classic tick assumption)
- The modularisation plan lists `di.servers` and `di.pubsub` as dependencies of this module. Neither is used: handle resolution is the caller's job, and `di.pubsub` is the publisher side - the tickerplant's own subscriber registry - which a subscribing process never calls
- `unsubscribe` is the supported way to close the local-close liveness gap, but it is a **cooperative** mechanism, not a structural one: kdb+ exposes no way to detect an *unannounced* `hclose`, and no way to tell whether a reissued descriptor is still the same remote. A caller that closes a tickerplant handle without calling `unsubscribe` first, and whose descriptor is then reissued, can still leave a stale row appearing live. Tickerplant death, and any local close that goes through `unsubscribe`, are both exact
