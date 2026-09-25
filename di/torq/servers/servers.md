# di.torq.servers

Connection management and handle-by-type lookup for the modular TorQ world — the `di.*`
analogue of TorQ's `.servers` (`code/handlers/trackservers.q` + `servers.q`). The parts of
`trackservers.q` the discovery protocol uses are **ported line for line** and published at
their **legacy root names** (`.servers.*`, `.dotz.liveh*`), with the registry and config at
legacy's root `.servers.*` globals — see [Discovery protocol](#discovery-protocol-ported-from-trackserversq).
No password/access-list files, no FinSpace.

FRAMEWORK-tier module: no hard `di.*` dependencies; `log`, `timer` and `handlers` are all
**injected** (all required, no fallback).

## init and config

Standard **one-arg `init[deps]`**: `di.torq` merges this process's resolved config slice into
the same `deps` dict it passes the injectables in, so `deps` carries both the injectable
dependencies **and** the config keys. `init` wires the deps, records self-identity, sets the
`.servers.*` config globals, publishes the legacy root names, and installs the one-time
process-global side effects — a `.z.pc` handler and trackservers.q's `discoveryretry` and
`serversretry` timer jobs. It is **idempotent** (guarded by an internal `registered` flag): a
second call refreshes deps, config and root names without re-registering (a duplicate
`di.timer.addjob` id would throw). `init` does **not** open connections.

`deps` keys:

| key | kind | meaning |
|---|---|---|
| `log` | injectable | binary `` `info`warn`error `` `{[c;m]}` logger dict |
| `timer` | injectable | di.timer contract; `addjob` = the 6-arg `custom` form `{[id;func;params;period;mode;opts]}` |
| `handlers` | injectable | di.torq.handlers contract; `register[event;phase;nm;pri;func]` |
| `proctype`/`procname` | config | this process's own identity (required); returned by `.servers.getdetails` |
| `processcsv` | config | **path** to `process.csv`; supplied by di.torq (legacy `.proc.file`) |
| `nontorqprocessfile` | config | path to the non-TorQ process file (legacy `NONTORQPROCESSFILE`); default `nontorqprocess.csv` in `processcsv`'s directory |

The trackservers.q settings (l.13–28) are flat config keys, each setting its legacy global. The
default is trackservers.q's own. `di/torq/settings/default.q` carries legacy
`config/settings/default.q`'s values, and `di/torq/settings/discovery.q` carries legacy
`config/settings/discovery.q`'s.

| key | global | trackservers.q default |
|---|---|---|
| `connections` | `.servers.CONNECTIONS` | `` ` `` |
| `discoveryregister` | `.servers.DISCOVERYREGISTER` | `1b` |
| `connectionsfromdiscovery` | `.servers.CONNECTIONSFROMDISCOVERY` | `1b` |
| `subscribetodiscovery` | `.servers.SUBSCRIBETODISCOVERY` | `1b` |
| `discoveryretry` | `.servers.DISCOVERYRETRY` | `0D00:05` |
| `tracknontorqprocess` | `.servers.TRACKNONTORQPROCESS` | `0b` |
| `hopentimeout` | `.servers.HOPENTIMEOUT` | `2000` |
| `retry` | `.servers.RETRY` | `0D00:05` |
| `retain` | `.servers.RETAIN` | `` `long$0D00:30 `` |
| `autoclean` | `.servers.AUTOCLEAN` | `0b` |
| `debug` | `.servers.DEBUG` | `1b` |
| `startup` | `.servers.STARTUP` | `0b` — when set, di.torq runs `.servers.startup` after the process module loads (legacy torq.q l.673); `di/torq/settings/hdb.q` sets it, as legacy's hdb.q does |
| `discovery` | `.servers.DISCOVERY` | `` enlist` `` |

```q
svc:use`di.torq.servers
svc.init[deps]           / deps = injectables + config, assembled by di.torq
svc.startup[config]      / config`connections / config`processcsv as legacy CONNECTIONS / .proc.file
h:svc.gethandlebytype[`hdb;`any]
h "1+1"
```

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire deps + config, record identity, publish root names, install the `.z.pc` handler + timer jobs. Idempotent. |
| `startup` | `startup[config]` | Legacy `startup` (l.323–345). `config`connections`/`config`processcsv` stand in for `.servers.CONNECTIONS`/`.proc.file`. |
| `getservers` | `getservers[proctype]` | Live (`w` non-null) `SERVERS` rows for a proctype. |
| `gethandlebytype` | `gethandlebytype[proctype;selection]` | One live handle via `` `any``/`roundrobin`/`last``; `0Ni` if none. Bumps usage stats. |
| `waitfortype` | `waitfortype[proctype;timeoutms;pollms]` | Block until a live connection exists or timeout; `1b`/`0b`. Caller decides if a timeout is fatal. `startup` must have run first. |
| `getapimeta` | `getapimeta[]` | This module's api metadata, one row per **callable** API function (`init`/`getapimeta` plumbing omitted), for `di.torq` to register with `di.api`. |

## The `SERVERS` table

Legacy's `.servers.SERVERS` (l.10), at that root name:

```q
.servers.SERVERS:([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();hits:`int$();startp:`timestamp$();lastp:`timestamp$();endp:`timestamp$();attributes:())
```

`w` is the live handle (`0Ni` when disconnected), `hits`/`lastp` drive handle selection,
`startp`/`endp` track lifecycle, `attributes` is the process's `.proc.getattributes[]` dict.
`.servers.procstab` and `.servers.nontorqprocesstab` (l.325–326) are set by `startup`.

## Discovery protocol (ported from trackservers.q)

Published at root by `init`, same bodies as legacy:

| Name | trackservers.q |
|---|---|
| `.dotz.liveh` / `.dotz.livehn` / `.dotz.liveh0` | dotz.q l.8 |
| `.servers.opencon` | l.50–59 (DEBUG logging; no passwords) |
| `.servers.cleanup` | l.116–118 |
| `.servers.addnthawc` | l.121–128 |
| `.servers.getdetails` | l.137 |
| `.servers.addhw` / `.servers.addw` | l.139–150 |
| `.servers.retry` | l.157 |
| `.servers.retrydiscovery` | l.158–168 |
| `.servers.autodiscovery` | l.171 |
| `.servers.retryrows` | l.174–185 |
| `.servers.removerows` | l.201–204 |
| `.servers.register` | l.207–211 |
| `.servers.querydiscovery` | l.215–221 |
| `.servers.registerfromdiscovery` | l.225–231 |
| `.servers.addprocs` | l.233–244 |
| `.servers.procupdate` | l.251 |
| `.servers.domainsocketsenabled` | l.261–267 |
| `.servers.formathp` | l.271–307 |
| `.servers.formatprocs` | l.310–314 |
| `.servers.startup` | l.323–345 |
| `.servers.pc` | l.383, run on `.z.pc` |
| timers `discoveryretry` / `serversretry` | l.387–389 |

The discovery process (`di.torq.proc.discovery`) calls `addw`, `removerows`, `cleanup`,
`startup`, reads `SERVERS`/`nontorqprocesstab`, and pushes `procupdate`/`autodiscovery` to
peers. Peers call discovery's root `register` (as `` `..register ``) and `getservices`.

**Conversions** (legacy calls with no di equivalent):
- `.lg.*` becomes the injected `log`.
- `.dotz.set` on `.z.pc` becomes `handlers[`register]`.
- `.timer.repeat` becomes `timer[`addjob]`, using mode 2 (legacy's default schedule) and the period in seconds.
- `.proc.cp[]` becomes `.z.p`.
- `.proc.procname`/`proctype` in `getdetails` become init's identity.
- `.proc.readprocs` becomes `readprocesscsv`.
- `.proc.getconfigfile` becomes `nontorqprocessfile`.
- In `querydiscovery`, the 5-arg `getservers[`proctype;`discovery;()!();0b;0b]` becomes its result:
  live discovery rows.

**Not ported** (discovery does not reach them):
- passwords (`loadpassword`, `USERPASS`, `PASSWORDS`, `LOADPASSWORD`);
- `SOCKETTYPE`/FinSpace (so `formathp`'s ipctype is always `` `tcp `` from `formatprocs`/`addhw`,
  and `retryrows` dials `hpup`);
- the 5-arg `getservers`/`attributematch`/`getserverbytype`/`gethpbytype`;
- `names`/`types`/`unregistered`/`checkw`/`reset`;
- the `connectcustom`/`addprocscustom` hooks;
- `refreshattributes`;
- `startupdep*`;
- `enabled`.

**Legacy behaviour that differs from di.torq.servers 0.3.0:**
- `startup` no longer excludes this process's own row.
- `retry` skips discovery rows and no longer sweeps first (`cleanup` runs from `.z.pc` and
  `addnthawc`).
- The retry job runs every `RETRY` (5m), not 10s.
- `localhost` hpups resolve to `.z.h`.
- Legacy defaults route connections through a discovery process: with
  `connectionsfromdiscovery` on, `startup` dials only discovery rows and learns the rest from it.

## `.z.pc` registration via di.torq.handlers

`.z.pc` (connection closed) is a **simple/observer** event in di.torq.handlers — side-effect only,
fan-out — so di.torq.servers registers `pc` through the injected `handlers` dependency rather
than assigning `.z.pc` directly:

```q
(handlers[`register])[`.z.pc;`;`servers;0j;pc]
```

`register`'s signature is `register[event;phase;nm;pri;func]`; for a simple event the `phase`
must be `` ` `` (null) — di.torq.handlers rejects a non-null phase on an observer event.

## Conventions (learnings from di.torq.config)

- **One-arg `init[deps]`** with config folded into `deps`, not a two-arg `init[config;deps]`.
- **Three-flat-var logging** — `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`.
- **`raiseerror` (log-then-signal)** for di's own post-init domain errors (`selector` unknown
  selection, missing `process.csv`). `init`'s dependency validation signals plainly (no logger yet).
- **`getapimeta`** exported; a test asserts it documents exactly the module's *callable* exports.
- **Env-free** — the `process.csv` path arrives via `config`processcsv` (di.torq resolves it).

## Tests

`test.q` + `test.csv` (36 checks) spawn a genuinely separate `q` peer and cover init validation,
wiring and idempotency, `startup` against a live and a dead peer (discovery switched off in the
fixture), `gethandlebytype`, retry recovering an ungraceful kill, `waitfortype`, input validation
and `getapimeta`. The discovery protocol is exercised by `di.torq.proc.discovery`'s suite.

Run in a fresh q session. Needs `QHOME` set to a q install whose `bin/q` can be launched (the
peer is started via `$QHOME/bin/q`):

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.servers
```
