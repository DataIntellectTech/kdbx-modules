# di.subscriptions

Tickerplant subscription management for kdb+ subscriber processes (RDB, WDB, chained TP). Fetches table schemas and log details from a tickerplant in a single call, defines the subscribed tables at root, replays the pre-subscription tickerplant log exactly once, and records the subscription in an inspectable registry. Live updates then flow through the root `upd` as normal.

---

## Features

- Subscribe over an already-open tickerplant handle - the caller owns the connection, so this module never opens, retries or closes one
- Subscribe to all tables and syms, or to any subset, with sym filtering applied to the log replay as well as to the live feed
- Define subscribed tables at root from the schemas the tickerplant returns, preserving their attributes (e.g. `` `g# `` on `sym`)
- Replay exactly the messages the tickerplant had logged at the instant of subscription, so messages that also arrive on the live feed are not applied twice
- Verify every log before defining a single table, so a truncated or unreadable log fails with the process untouched
- Handle every payload shape a tickerplant may log - a list of columns, a table, a dict, or a single atom row - by resolving the `sym` column by name rather than position
- Replay across several log files, as a segmented tickerplant writes one log per table
- Track live subscriptions in a registry whose `active` flag is maintained from `.z.pc` and cross-checked against `.z.W`
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

`init` must be called before any operational function - `subscribe`, `subscribed`, `getsubscriptions` and `teardown` each throw a clear error if it has not been. `getapimeta` and `version` are metadata and deliberately work without it, so `di.torq` can collect api rows and `di.depcheck` can read the version before anything is initialised. `init` registers a `.z.pc` observer through `di.handlers` and is idempotent - a second call refreshes the dependencies and replaces the registration in place rather than duplicating it, and leaves the registry intact.

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
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.subscriptions
```

Run in a fresh q session - the integration layer spawns and kills a real q process, so do not interleave with other modules' tests. Needs `QHOME` set (the peer is launched via `$QHOME/bin/q`) and `di.os` on `QPATH` (the harness uses `os.abspath` to load `test.q`).

The suite is 209 assertions and wires the real merged `di.log` and `di.handlers` rather than mocks, so both injected contracts are proven end to end. It covers: pre-`init` guards on every export; dependency validation (non-dict deps, each missing key, each malformed value); `init` arity asserted by observable effect rather than by "it did not throw"; idempotent re-init; the `VERSION` file and exported `version`; `getapimeta`; all-tables and sym-filtered replay; all four payload shapes a tickerplant may log; symbol-atom table and sym selectors; a multi-table log where only the requested table is defined; replay across two log files; requested-but-absent and offered-but-unrequested tables; a configured `subdetailsfunc`; partial, unreadable, absent and empty logs; a replay requested with no root `upd`; malformed `schemalist` shapes; the double-subscribe guard; malformed tickerplant responses; `setschema:0b` preserving a populated table; `logdir` passthrough; and input validation on every argument.

The integration block subscribes to a genuinely separate tickerplant process over IPC, kills it, confirms `.z.pc` marks the subscription dead, reconnects onto a recycled handle number, and confirms the stale row stays dead and the re-subscribe succeeds.

---

## Notes

- Replay uses kdb+'s native `-11!` directly rather than `di.tplog`. This module replays the first *n* messages; `di.tplog.check` is built for the replay-everything caller and would rewrite an entire log to a `.good` file when corruption lies beyond the messages actually needed, and cannot report the good-message count the preflight requires
- Every log is verified with the non-executing `-11!(-2;logfile)` streaming count *before* any table is defined. This matters: `-11!(n;logfile)` past a corruption point replays the good messages and only then throws, leaving tables half populated
- The subscribed set is what was requested intersected with what the tickerplant offered. A requested table the tickerplant does not return is logged at `warn` and skipped; a table it volunteers unasked is logged at `warn` and ignored - neither defined nor replayed
- Liveness needs both signals, which is why `handlers` is a required dependency. `.z.pc` fires when the tickerplant drops, at the instant of the drop and before kdb+ can reissue the handle number; `.z.W` catches a handle the caller closed itself, which does not fire `.z.pc`. `.z.W` alone is not sufficient - kdb+ reissues the lowest free descriptor, so a recycled number would revive a stale registry row
- The double-subscribe guard runs after the tickerplant has been asked what it offers, so it compares resolved table lists. An all-tables subscribe is refused only where it genuinely overlaps a live subscription, not merely because some other subscription exists
- Tables are created at root with `@[`.;name;:;schema]`, and `-11!` resolves `upd` at root even when invoked from module context. A root-level `upd` must therefore be defined before calling `subscribe` with `replay` set - this is **enforced**, not merely expected: without it every replayed message would be silently discarded and the narrowed path would leave its no-op stand-in bound at root, so the live feed would vanish into it too
- A malformed `subdetails` response is rejected before anything is defined, including a `schemalist` that is not a list or whose entries are not `(tablename;schema)` pairs. An empty entry is tolerated, as legacy does
- `setschema:0b` skips table definition entirely, so a subscriber that pre-loads its own schema keeps it. With `setschema:1b` the returned schema replaces whatever is at root, which is why re-subscribing a live table is refused
- `subdetails` is TorQ's real protocol, defined at root by `chainedtp.q` and `segmentedtickerplant.q`, returning `` `schemalist`logfilelist`rowcounts`date `` and optionally `` `logdir ``. The key names and shapes here were taken from that source and are exercised against a tickerplant process built to the same protocol in the integration tests; the module has **not** yet been run against a live TorQ chained or segmented tickerplant. `di.tickerplant` is not built yet - when it lands, point `subdetailsfunc` at its entry point if the name differs
- Not in v1: auto-reconnect and resubscribe on tickerplant bounce, filtered-column subscriptions, and remote-log streaming (the subscriber is assumed to share the tickerplant's filesystem, the classic tick assumption)
- The modularisation plan lists `di.servers` and `di.pubsub` as dependencies of this module. Neither is used: handle resolution is the caller's job, and `di.pubsub` is the publisher side - the tickerplant's own subscriber registry - which a subscribing process never calls
- One residual liveness gap: a handle the caller closes itself, without the tickerplant dying, whose number is then reissued to an unrelated connection, can leave a stale row appearing live. Tickerplant death and local close without reuse are both exact
