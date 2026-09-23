# di.torq.servers

Connection management and handle-by-type lookup for the modular TorQ world — the `di.*`
analogue of TorQ's `.servers` (`code/handlers/trackservers.q` + `servers.q`): no
password/access-list files, no FinSpace. `process.csv` here is a static **phone book** (who to
*dial*), **not** an identity source — self-identity comes from config, injected by `di.torq`.

**Discovery is not implemented here, and this module knows nothing about it.** Legacy TorQ
spread the discovery protocol across `.servers` on every process; in the modular world a discovery
service (`di.torq.proc.discovery`) is just another process that dials out through its *own*
injected servers instance and pushes what it finds into peers by calling the generic,
root-published `.torq.servers.addprocs` on them — and, when a row leaves the phone book for good,
`.torq.servers.removeprocs`. Every process can therefore receive pushed rows (and their removal)
whether or not anything is pushing — no discovery-specific config or code on the consumer side.
Non-TorQ processes need no special handling either: a `nontorqprocess.csv` in the same
`host,port,proctype,procname` format is just another phone book `startup` can be pointed at.

FRAMEWORK-tier module: no hard `di.*` dependencies; `log`, `timer` and `handlers` are all
**injected** (all required, no fallback).

## init and config

Standard **one-arg `init[deps]`**: `di.torq` merges this process's resolved config slice into
the same `deps` dict it passes the injectables in, so `deps` carries both the injectable
dependencies **and** the config keys. `init` wires the deps, records self-identity,
installs two one-time process-global side effects — a `.z.pc` cleanup handler and a 10s retry
timer job — and publishes the IPC targets `.torq.servers.addprocs` / `.torq.servers.removeprocs`
at root (every init; `set` is idempotent). It is **idempotent** (guarded by an internal `registered` flag): `di.torq` calls
it once per process, but a second call refreshes the dep refs without re-registering (a
duplicate `di.timer.addjob` id would throw). `init` does **not** open connections.

`deps` keys:

| key | kind | meaning |
|---|---|---|
| `log` | injectable | binary `` `info`warn`error `` `{[c;m]}` logger dict |
| `timer` | injectable | di.timer contract; `addjob` = the 6-arg `custom` form `{[id;func;params;period;mode;opts]}` |
| `handlers` | injectable | di.torq.handlers contract; `register[event;phase;nm;pri;func]` |
| `proctype`/`procname` | config | this process's own identity (required); used to exclude self from `process.csv` |
| `connections` | config | proctypes this process should dial (symbols, or strings from a `.toml` cascade — normalised). Optional; default = none |
| `processcsv` | config | **path** to `process.csv`; supplied by di.torq. Optional; required only once `connections` is non-empty |
| `hopentimeout` | config | `hopen` timeout in **ms** for **every** dial this instance makes — `startup`'s first attempt *and* each `retry` redial. Positive long (a numeric string is parsed). Optional; default **2000** (the module constant `HOPENTIMEOUT`). Per-process: a process that dials many possibly-down hosts should run tight — `di/torq/settings/discovery.q` ships `hopentimeout:200` for the discovery proctype (legacy `config/settings/discovery.q` parity), overridable in the app's `settings/discovery.toml`. |

```q
svc:use`di.torq.servers
svc.init[deps]     / deps = injectables + config, assembled by di.torq
svc.startup[cfg]   / open the configured connections (cfg carries connections + processcsv)
h:svc.gethandlebytype[`hdb;`any]
h "1+1"
svc.getallservers[]                       / the whole registry, connected or not
svc.addprocs ([]procname:`rdb2;proctype:`rdb;hpup:`:host:5031)   / merge a known-not-connected row
svc.removeprocs ([]procname:`rdb2;proctype:`rdb;hpup:`:host:5031)   / decommission: close + delete that exact row
```

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire deps + config, record identity, install the `.z.pc` handler + retry job. Idempotent. |
| `startup` | `startup[config]` | Read the phone book at `config`processcsv`, drop self, merge each row whose proctype is in `config`connections` (see the merge rule below) and dial only the **new** ones. A failed connection is logged (not raised) and left as `w:0Ni` for `retry`. No-op if no connections configured. **Repeat-safe**: calling it again skips known rows and dials nothing already known — a caller may re-run it to pick up rows added to the file since (di.torq.proc.discovery does, every tick, and again against a `nontorqprocess.csv`). |
| `addprocs` | `addprocs[rows]` | Merge externally supplied rows (a table with `procname`/`proctype`/`hpup`; strings normalised to symbols) into `SERVERS` as **known, not connected** (`w:0Ni`) — the retry job opens them on its normal 10s cycle. Drops self. Returns the number of rows added. Also published at root as **`.torq.servers.addprocs`** so a peer (a discovery service) can call it by name over IPC. Generic and discovery-unaware. |
| `removeprocs` | `removeprocs[rows]` | Remove rows (same table shape as `addprocs`; **exact** `(procname;proctype;hpup)` match — the identity `mergerows` dedups on) from `SERVERS`, **closing a live handle first**: removal means *decommissioned*, not merely down (a down process stays, for `retry`). Unknown rows are ignored (logged). Returns the number removed. Published at root as **`.torq.servers.removeprocs`** (a discovery service tells a subscriber a row is gone) **and** in the injected contract (a process evicts from its own registry) — see below for why the asymmetry with `addprocs`. |
| `getservers` | `getservers[proctype]` | Live (`w` non-null) `SERVERS` rows for a proctype. |
| `getallservers` | `getallservers[]` | Every `SERVERS` row, all proctypes, connected or not — the full registry view. Part of the injected contract (≥ 0.4.0). |
| `gethandlebytype` | `gethandlebytype[proctype;selection]` | One live handle via `` `any``/`roundrobin`/`last``; `0Ni` if none. Bumps usage stats. |
| `waitfortype` | `waitfortype[proctype;timeoutms;pollms]` | Block until a live connection exists or timeout; `1b`/`0b`. Caller decides if a timeout is fatal. `startup` must have run first. |
| `getapimeta` | `getapimeta[]` | This module's api metadata, one row per **callable** API function (`init`/`getapimeta` plumbing omitted), for `di.torq` to register with `di.api`. |

Export is deliberately conservative — only functions `di.torq` or a consumer actually calls
(so `di.api` lists exactly these). The rest are **internal**: `retry` (the scheduled
`serversretry` job — passed to the timer *by value* at init, so it needs no export; it first
runs `cleanup` to sweep ungracefully-vanished handles, then reopens every dead handle),
`cleanup`, `formathp`, `opencon`, `readprocesscsv`, `mergerows`, `dial`, `conflicts`,
`describerows`, `tosym`, `aslong`, `checkrows`, `retryrows`, `selector`, `updatestats`,
`signalfound`, `raiseerror`; plus state (`SERVERS`, `self`, `registered`, `HOPENTIMEOUT`,
`hopentimeout`, `connections`, `processcsv`).

## The injected contract (what di.torq hands consumers as `deps`servers`)

`` `startup`getservers`getallservers`removeprocs`gethandlebytype`waitfortype `` —
`di.torq.buildserversdep` builds it after `init`. `init` is deliberately not in it (di.torq has
already run it once), and neither is `addprocs`: nothing calls `addprocs` on its *own* instance —
it is the root-published target that *other* processes call on this one. `removeprocs` (0.5.0) is
different: it is root-published for the same reason **and** injected, because a process must be
able to evict from its *own* registry (di.torq.proc.discovery drops a row that has left every
phone book) and nothing else in the contract can. `getallservers` was added in 0.4.0 for
discovery, which needs the whole registry (every proctype, connected or not) to decide what to
push; consumers that only check the keys they use are unaffected.

## The `SERVERS` table

```q
SERVERS:([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();hits:`int$();startp:`timestamp$();lastp:`timestamp$();endp:`timestamp$())
```

A direct analogue of legacy TorQ's `.servers.SERVERS`: `w` is the live handle (`0Ni` when
disconnected), `hits`/`lastp` drive handle selection, `startp`/`endp` track lifecycle.

### The merge rule (`mergerows` — one path for `startup` and `addprocs`)

Every row entering `SERVERS` goes through the same merge, so neither a repeated `startup` nor a
repeated push can ever duplicate a row:

| incoming row vs existing rows | result |
|---|---|
| exact `(procname;proctype;hpup)` match | **skipped** — already known, connected or not. Reconnecting a known-dead row is `retry`'s job, not the caller's. |
| same `hpup`, different name/type (a port re-used by another process) | **replaces** the old row: its handle is closed, the row deleted, the new one appended `w:0Ni`. |
| same `(procname;proctype)`, different `hpup` (a port moved in the phone book) | **replaces** likewise — no ghost row left behind to be dialled forever. |
| no overlap | **appended** `w:0Ni`; `startup` dials it immediately, `addprocs` leaves it to `retry`. |
| two rows *within one batch* sharing a name/type or an hpup | the **last wins** (warned) — an ambiguous phone book (one process listed on two ports) cannot seed two rows to be dialled forever. |

Legacy TorQ (`trackservers.q` `addprocs`) only replaced on `hpup` and left the name/type ghost;
this is a deliberate tightening. Before 0.4.0 `startup` had **no** dedup at all — every call
appended a fresh row per matching phone-book entry; nothing noticed because every consumer called
it exactly once at init.

### Removal (`removeprocs`)

Rows only ever *leave* `SERVERS` through `mergerows`' replace branch or `removeprocs`. A
disconnect is **not** a removal: a dead row stays (`w:0Ni`) and `retry` keeps dialling it — the
legacy retain-forever / no-autoclean behaviour, kept on purpose. `removeprocs` is the separate
*decommission* event: an exact-triple match is closed (if live) and deleted, so neither this
process's `retry` nor any peer it was pushed to keeps a phantom. Nothing in this module decides
*when* to remove — that is the caller's (discovery diffs the registry against its phone books
every tick; an operator or test may call it directly).

## `.z.pc` registration via di.torq.handlers

`.z.pc` (connection closed) is a **simple/observer** event in di.torq.handlers — side-effect only,
fan-out — so di.torq.servers registers its cleanup callback through the injected `handlers`
dependency rather than assigning `.z.pc` directly:

```q
(handlers[`register])[`.z.pc;`;`servers;0j;pcfunc]
```

`register`'s signature is `register[event;phase;nm;pri;func]`; for a simple event the `phase`
must be `` ` `` (null) — di.torq.handlers rejects a non-null phase on an observer event. This lets
di.torq.servers' disconnect hook coexist with every other `.z.pc` registrant in the same
priority-ordered fan-out.

## Conventions (learnings from di.torq.config)

- **One-arg `init[deps]`** with config folded into `deps` (the project convention; matches
  `di.eodtime`'s optional-config-in-deps pattern), not a two-arg `init[config;deps]`.
- **Three-flat-var logging** — `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`, matching
  `consistency.md`, `di.compression` and `di.torq.config`. (The project hasn't globally frozen this
  vs. the single-dict form — flag before changing.)
- **`raiseerror` (log-then-signal)** for all post-init domain errors (`formathp` unknown
  ipctype, `selector` unknown selection, missing `process.csv`). `init`'s own dependency
  validation is the one exception (plain `'` — no logger yet).
- **`getapimeta`** exported; a test asserts it documents exactly the module's *callable*
  exports — `init`/`getapimeta` are plumbing (di.torq calls them by convention) and are
  deliberately omitted from the registry rows, matching di.util.toml and the skill convention. The
  `VERSION` file (0.5.0) is read by di.torq.depcheck's manifest walk; `version` stays out of
  `export` because that same test pins the exact export set.
- **Nothing module-local inside a qsql expression.** Inside a `use`-loaded module a qsql
  (`select`/`update`/`exec`) cannot see module-local *functions* (`'formathp`) and a `$[..]`
  conditional inside one throws `'rank` (both fine at root — measured on kdb-x 5f 2026.01.22 while
  building 0.4.0). `startup`/`dial`/`addprocs` therefore compute those values into locals first and
  reference the locals in the qsql (`hp:formathp'[..]; update hpup:hp from ..`), or use `@[t;cols;fn]`.
- **Env-free** — di.torq.servers reads no environment variable; the `process.csv` path arrives via
  `config`processcsv` (di.torq resolves it), holding di.torq.config's env-free boundary.

## Open items / not yet done

- **Live-peer integration tests are in place** (`test.q` + `test.csv`, 114 checks). They spawn
  genuinely separate `q` peers (a self-connect returns pseudo-handle `0`, not a real socket) and
  cover: `startup` connecting to a live peer and logging a failed dial while excluding self,
  `gethandlebytype` returning a live remote handle (`2=h"1+1"`), the retry cycle recovering an
  ungraceful kill (`cleanup`+reopen), and `waitfortype` connected-vs-timeout — plus the mockable
  surface (init validation, dep-wiring, idempotency, input validation, `getapimeta`). Because
  `retry`/`cleanup` are internal, the retry cycle is driven by invoking the callback the **mock
  timer captured** at `addjob` (the actually-wired path), not a direct export. 0.4.0 added:
  `startup` called twice (no duplicates, live handle untouched), a moved port replacing the old
  row and closing its handle, every `addprocs` merge case, and a second, **kdb-x** peer
  (`test_modpeer.q`, which has loaded di.torq.servers itself) on which `.torq.servers.addprocs`
  is called *by name over a real handle* — the exact path a discovery push takes. Peers are
  spawned from this process's own executable (`/proc/self/exe`), so the suite no longer depends
  on `QHOME` pointing at a runnable install.
- **Injected providers are mocked in tests by design.** `di.util.log` and `di.torq.handlers` are
  both present on this branch now (log = the real structured logger from `main` PR #90), but the
  unit tests still mock them so a failure localises to `di.torq.servers` rather than a provider.
  The handlers mock uses the real `register[event;phase;nm;pri;func]` shape from `handlers.q`; the
  real wiring is exercised end-to-end by di.torq's own suite.
- **`config`processcsv` and the assembled `connections` list** depend on di.torq's config
  wiring — coordinate when di.torq's servers dep is built.
- Not implemented: password/access-list files, and the `tcps`/`unix` socket types end-to-end
  (only `tcp` is wired through `startup`). `formathp` does not translate `localhost` to the real
  hostname (legacy did), so an hpup built from a `localhost` phone-book row — and therefore any
  such row pushed onward by a discovery service — is only dialable from the same box.
- **0.4.0 (for di.torq.proc.discovery):** repeat-safe `startup` via `mergerows` (a genuine bug
  fix — see the merge rule), `addprocs` (root-published `.torq.servers.addprocs`), and
  `getallservers` added to the injected contract (`di.torq.buildserversdep`, `consistency.md`).
  The module itself stays discovery-unaware.
- **0.5.0 (discovery follow-up):** `removeprocs` (root-published **and** injected — the
  decommission counterpart of `addprocs`; `checkrows` is the shared validation) and the
  per-instance `hopentimeout` config key (the constant was applied to every dial, including the
  10 s retry redials, so a process dialling many down hosts stalled 2 s per row per cycle;
  `di/torq/settings/discovery.q` ships 200 for discovery); a no-op `addprocs` push is silent;
  `mergerows` resolves conflicts *within* a batch (last wins, warned). Tests: `removeprocs` semantics incl.
  closing a live handle and the by-name IPC path on the kdb-x peer; `hopentimeout` parsing,
  validation and a timed dial to a non-routable host.

## Tests

Run in a fresh q session from the repository root (spawns and kills real peer processes —
launched from this process's own executable — and loads `test.q` by the cwd-relative path
`di/torq/servers/test.q`; don't interleave with other modules' tests):

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.servers
```
