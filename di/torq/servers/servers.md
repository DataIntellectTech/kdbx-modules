# di.torq.servers

TorQ's `.servers` (`code/handlers/trackservers.q`) as a kdb-x module. The parts the discovery
protocol uses are ported line for line and published at root names (`.servers.*`,
`.dotz.liveh*`); the registry and settings are root `.servers.*` globals. No
password/access-list files, no FinSpace. `log`, `timer` and `handlers` are injected (all required).

## init and config

`init[deps]` takes the injectables and this process's config in one dict (di.torq merges them).
It sets the `.servers.*` globals, publishes the root names, and registers a `.z.pc`
observer (via `handlers`) and the `discoveryretry`/`serversretry` timer jobs (via `timer`). A
second call refreshes everything but registers nothing twice. It opens no connections.

`deps` keys:

| key | kind | meaning |
|---|---|---|
| `log` | injectable | binary `` `info`warn`error `` `{[c;m]}` logger dict |
| `timer` | injectable | di.timer contract; `addjob` = the 6-arg `custom` form `{[id;func;params;period;mode;opts]}` |
| `handlers` | injectable | di.torq.handlers contract; `register[event;phase;nm;pri;func]` |
| `proctype`/`procname` | config | this process's own identity (required); returned by `.servers.getdetails` |
| `processcsv` | config | **path** to `process.csv`; supplied by di.torq (legacy `.proc.file`) |
| `nontorqprocessfile` | config | path to the non-TorQ process file (legacy `NONTORQPROCESSFILE`); default `nontorqprocess.csv` in `processcsv`'s directory |

The settings are flat config keys, each setting its `.servers.*` global. `di/torq/settings/default.q`
supplies every process's values; `discoveryregister`, `connectionsfromdiscovery` and `debug` are
`0b` there, so discovery is off unless the app turns it on. `di/torq/settings/discovery.q`
supplies the discovery process's values.

| key | global | trackservers.q default |
|---|---|---|
| `enabled` | `.servers.enabled` | `1b` — gates the `discoveryretry`/`serversretry` timer jobs |
| `connections` | `.servers.CONNECTIONS` | `` ` `` |
| `discoveryregister` | `.servers.DISCOVERYREGISTER` | `1b` |
| `connectionsfromdiscovery` | `.servers.CONNECTIONSFROMDISCOVERY` | `1b` |
| `subscribetodiscovery` | `.servers.SUBSCRIBETODISCOVERY` | `1b` |
| `discoveryretry` | `.servers.DISCOVERYRETRY` | `0D00:05`; also a `"0D00:00:10"` string or seconds |
| `tracknontorqprocess` | `.servers.TRACKNONTORQPROCESS` | `0b` |
| `hopentimeout` | `.servers.HOPENTIMEOUT` | `2000` |
| `retry` | `.servers.RETRY` | `0D00:05`; also a `"0D00:00:10"` string or seconds |
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
| `waitfortype` | `waitfortype[proctype;timeoutms;pollms]` | Poll `startup` then `retry` every `pollms` until a live connection exists (`1b`) or `timeoutms` passes (`0b`). |
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

Defined directly at root in a `\d .servers` section, for legacy `.sub` and chainedtp:

| Name | trackservers.q |
|---|---|
| `.servers.attributematch` | l.64–68 |
| `.servers.getservers` (legacy 5-arg; the exported 1-arg `getservers` is separate) | l.75–89 |
| `.servers.connectcustom` (called by `retryrows`) | l.198 |
| `.servers.reqprocsnotconn` / `.servers.reqprocnamesnotconn` | l.348–351, l.357 |
| `.servers.startupdepcyclestypename` / `.servers.startupdepnamecycles` | l.360–373, l.379 |

The discovery process (`di.torq.proc.discovery`) calls `addw`, `removerows`, `cleanup`,
`startup`, reads `SERVERS`/`nontorqprocesstab`, and pushes `procupdate`/`autodiscovery` to
peers. Peers call discovery's root `register` (as `` `..register ``) and `getservices`.

**Conversions** (legacy calls with no di equivalent):
- `.lg.*` becomes the injected `log`.
- `.dotz.set` on `.z.pc` becomes `handlers[`register]`.
- `.timer.repeat` becomes `timer[`addjob]`, mode 3 (next run from finish), period in seconds.
- `.proc.cp[]` becomes `.z.p`.
- `.proc.procname`/`proctype` in `getdetails` become init's identity.
- `.proc.readprocs` becomes `readprocesscsv`.
- `.proc.getconfigfile` becomes `nontorqprocessfile`.
- In `startupdepcyclestypename`, `.servers.startup[]` becomes `.servers.startup ()!()` (the stored
  globals), `.proc.procname` becomes init's identity, and `.os.sleep` becomes `system "sleep "`.
- In `querydiscovery`, the 5-arg `getservers[`proctype;`discovery;()!();0b;0b]` becomes its result:
  live discovery rows.

**Not ported** (discovery does not reach them):
- passwords (`loadpassword`, `USERPASS`, `PASSWORDS`, `LOADPASSWORD`);
- `SOCKETTYPE`/FinSpace (so `formathp`'s ipctype is always `` `tcp `` from `formatprocs`/`addhw`,
  and `retryrows` dials `hpup`);
- `getserverbytype`/`gethpbytype`;
- `names`/`types`/`unregistered`/`checkw`/`reset`;
- the `addprocscustom` hook;
- `refreshattributes`;
- `reqproctypesnotconn`/`startupdepcycles`/`startupdependent`.

**Legacy behaviour that differs from di.torq.servers 0.3.0:**
- `startup` no longer excludes this process's own row.
- `retry` skips discovery rows and no longer sweeps first (`cleanup` runs from `.z.pc` and
  `addnthawc`).
- The retry job runs every `RETRY` (5m), not 10s.
- `localhost` hpups resolve to `.z.h`.
- With `connectionsfromdiscovery` on (off by default), `startup` dials only discovery rows and
  learns the rest from it.

## Tests

`test.q` + `test.csv` (56 checks) spawn real q peers. They cover:
- init validation, wiring and idempotency;
- `startup` against a live and a dead peer (discovery off);
- `gethandlebytype`, and retry recovering an ungraceful kill;
- `waitfortype`, including a discovery stub that comes up after `startup`;
- the root `.servers` functions (`attributematch`, 5-arg `getservers`, `startupdepnamecycles`);
- input validation and `getapimeta`.

The rest of the discovery protocol is covered by `di.torq.proc.discovery`'s suite. Run in a fresh
q session with `QHOME` set to a q install whose `bin/q` can be launched:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.servers
```