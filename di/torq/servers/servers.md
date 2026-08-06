# di.torq.servers

Connection management and handle-by-type lookup for the modular TorQ world — the `di.*`
analogue of TorQ's `.servers` (`code/handlers/trackservers.q` + `servers.q`), scoped down
for v1: no discovery service, no password/access-list files, no non-TorQ process tracking,
no FinSpace. `process.csv` here is a static **phone book** (who to *dial*), **not** an
identity source — self-identity comes from config, injected by `di.torq`.

FRAMEWORK-tier module: no hard `di.*` dependencies; `log`, `timer` and `handlers` are all
**injected** (all required, no fallback).

## init and config

Standard **one-arg `init[deps]`**: `di.torq` merges this process's resolved config slice into
the same `deps` dict it passes the injectables in, so `deps` carries both the injectable
dependencies **and** the config keys. `init` wires the deps, records self-identity, and
installs two one-time process-global side effects — a `.z.pc` cleanup handler and a 10s retry
timer job. It is **idempotent** (guarded by an internal `registered` flag): `di.torq` calls
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

```q
svc:use`di.torq.servers
svc.init[deps]     / deps = injectables + config, assembled by di.torq
svc.startup[]      / open the configured connections (reads init config)
h:svc.gethandlebytype[`hdb;`any]
h "1+1"
```

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire deps + config, record identity, install the `.z.pc` handler + retry job. Idempotent. |
| `startup` | `startup[]` | Read `process.csv` (`processcsv`), drop self, connect to each row whose proctype is in `connections`. A failed connection is logged (not raised) and left as `w:0Ni` for `retry`. No-op if no connections configured. |
| `getservers` | `getservers[proctype]` | Live (`w` non-null) `SERVERS` rows for a proctype. |
| `gethandlebytype` | `gethandlebytype[proctype;selection]` | One live handle via `` `any``/`roundrobin`/`last``; `0Ni` if none. Bumps usage stats. |
| `waitfortype` | `waitfortype[proctype;timeoutms;pollms]` | Block until a live connection exists or timeout; `1b`/`0b`. Caller decides if a timeout is fatal. `startup` must have run first. |
| `getapimeta` | `getapimeta[]` | This module's api metadata, one row per **callable** API function (`init`/`getapimeta` plumbing omitted), for `di.torq` to register with `di.api`. |

Export is deliberately conservative — only functions `di.torq` or a consumer actually calls
(so `di.api` lists exactly these). The rest are **internal**: `retry` (the scheduled
`serversretry` job — passed to the timer *by value* at init, so it needs no export; it first
runs `cleanup` to sweep ungracefully-vanished handles, then reopens every dead handle),
`cleanup`, `formathp`, `opencon`, `readprocesscsv`, `retryrows`, `selector`, `updatestats`,
`signalfound`, `raiseerror`; plus state (`SERVERS`, `self`, `registered`, `HOPENTIMEOUT`,
`connections`, `processcsv`).

## The `SERVERS` table

```q
SERVERS:([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();hits:`int$();startp:`timestamp$();lastp:`timestamp$();endp:`timestamp$())
```

A direct analogue of legacy TorQ's `.servers.SERVERS`: `w` is the live handle (`0Ni` when
disconnected), `hits`/`lastp` drive handle selection, `startp`/`endp` track lifecycle.

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

## Conventions (learnings from di.config)

- **One-arg `init[deps]`** with config folded into `deps` (the project convention; matches
  `di.eodtime`'s optional-config-in-deps pattern), not a two-arg `init[config;deps]`.
- **Three-flat-var logging** — `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`, matching
  `consistency.md`, `di.compression` and `di.config`. (The project hasn't globally frozen this
  vs. the single-dict form — flag before changing.)
- **`raiseerror` (log-then-signal)** for all post-init domain errors (`formathp` unknown
  ipctype, `selector` unknown selection, missing `process.csv`). `init`'s own dependency
  validation is the one exception (plain `'` — no logger yet).
- **`getapimeta`** exported; a test asserts it documents exactly the module's *callable*
  exports — `init`/`getapimeta` are plumbing (di.torq calls them by convention) and are
  deliberately omitted from the registry rows, matching di.toml and the skill convention. No
  `version` export / VERSION file yet — deferred to the di.depcheck rollout, as in di.config.
- **Env-free** — di.torq.servers reads no environment variable; the `process.csv` path arrives via
  `config`processcsv` (di.torq resolves it), holding di.config's env-free boundary.

## Open items / not yet done

- **Live-peer integration tests are in place** (`test.q` + `test.csv`, 33 checks). They spawn a
  genuinely separate `q` peer (a self-connect returns pseudo-handle `0`, not a real socket) and
  cover: `startup` connecting to a live peer and logging a failed dial while excluding self,
  `gethandlebytype` returning a live remote handle (`2=h"1+1"`), the retry cycle recovering an
  ungraceful kill (`cleanup`+reopen), and `waitfortype` connected-vs-timeout — plus the mockable
  surface (init validation, dep-wiring, idempotency, input validation, `getapimeta`). Because
  `retry`/`cleanup` are internal, the retry cycle is driven by invoking the callback the **mock
  timer captured** at `addjob` (the actually-wired path), not a direct export.
- **Injected providers are mocked in tests by design.** `di.util.log` and `di.torq.handlers` are
  both present on this branch now (log = the real structured logger from `main` PR #90), but the
  unit tests still mock them so a failure localises to `di.torq.servers` rather than a provider.
  The handlers mock uses the real `register[event;phase;nm;pri;func]` shape from `handlers.q`; the
  real wiring is exercised end-to-end by di.torq's own suite.
- **`config`processcsv` and the assembled `connections` list** depend on di.torq's config
  wiring — coordinate when di.torq's servers dep is built.
- Scoped-out (v1): discovery service, password/access-list files, non-TorQ tracking, and the
  `tcps`/`unix` socket types end-to-end (only `tcp` is wired through `startup`).

## Tests

Run in a fresh q session (spawns and kills a real peer process; don't interleave with other
modules' tests). Needs `QHOME` set (the peer is launched via `$QHOME/bin/q`) and `di.os` on
`QPATH` (the harness uses `os.abspath` to load `test.q`):

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.servers
```
