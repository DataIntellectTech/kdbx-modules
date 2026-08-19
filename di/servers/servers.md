# di.servers

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
duplicate `di.timer.addjob` id would throw). `teardown` resets that flag, so an
`init`→`teardown`→`init` cycle re-installs both side effects rather than being skipped by the
guard. `init` does **not** open connections.

`deps` keys:

| key | kind | meaning |
|---|---|---|
| `log` | injectable | binary `` `info`warn`error `` `{[c;m]}` logger dict — di.log's `logdict``log` satisfies this directly (it carries all six levels; the extra `trace`/`debug`/`fatal` are ignored) |
| `timer` | injectable | the di.timer export dict. Must expose `` `addjob `` (a variant dict of `custom`/`default`/`simple`; di.servers calls the 6-arg `` timer[`addjob][`custom] ``) **and** `` `deletejobs ``, which must be **callable** — `teardown` needs it, and a timer dep missing it fails *silently* there rather than loudly at `init` (see [Lifecycle](#lifecycle-requireinit-and-teardown)) |
| `handlers` | injectable | di.handlers contract. Must expose callable `` `register `` (`register[event;phase;nm;pri;func]` — `init` uses it) **and** `` `remove `` (`remove[event;phase;nm]` — `teardown` uses it) |
| `proctype`/`procname` | config | this process's own identity (required); used to exclude self from `process.csv` |
| `connections` | config | proctypes this process should dial (symbols, or strings from a `.toml` cascade — normalised). Optional; default = none |
| `processcsv` | config | **path** to `process.csv`; supplied by di.torq. Optional; required only once `connections` is non-empty |

```q
svc:use`di.servers
svc.init[deps]     / deps = injectables + config, assembled by di.torq
svc.startup[]      / open the configured connections (reads init config)
h:svc.gethandlebytype[`hdb;`any]
h "1+1"
```

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire deps + config, record identity, install the `.z.pc` handler + retry job. Idempotent. **The only function that may be called before `init`** — every other one below (except `getapimeta`) refuses to run until it has completed. |
| `teardown` | `teardown[]` | Release both process-global registrations `init` installed — the `.z.pc` handler and the `serversretry` timer job. Module state, `SERVERS` included, is **deliberately left intact**. Idempotent. See [Lifecycle](#lifecycle-requireinit-and-teardown). |
| `startup` | `startup[]` | Read `process.csv` (`processcsv`), drop self, connect to each row whose proctype is in `connections`. A failed connection is logged (not raised) and left as `w:0Ni` for `retry`. No-op if no connections configured. **Idempotent**: skips procs already tracked in `SERVERS`, so a repeat call (or a grown `process.csv`) adds only new rows — never a duplicate or a leaked second handle. `process.csv` must be the strict v1 4-column `host,port,proctype,procname` layout — a reordered or wider header is **rejected loudly** (the reader is positional, so it would otherwise misparse silently). **Self-exclusion is an exact `(proctype;procname)` match against the identity from config**, so a `process.csv` that disagrees would leave this process dialling itself; any row carrying this process's `procname` **that survives the connections filter (i.e. one this process would otherwise dial)** is therefore skipped with a warning naming both proctypes. A drifted row whose proctype isn't a connection type is already filtered out and poses no self-connection risk, so it is not warned about. |
| `getservers` | ``getservers[proctype]`` | Live (`w` non-null) `SERVERS` rows. Accepts a **symbol**, a **symbol list** (rows for any of them), or `` ` `` for **every** proctype — the contract legacy TorQ's `.servers.getservers` (`trackservers.q:75`) and sibling `di.serverselect.getservers` both implement, so a consumer written against either works here unchanged. |
| `gethandlebytype` | `gethandlebytype[proctype;selection]` | One live handle via `` `any``/`roundrobin`/`last``; `0Ni` if none. Bumps usage stats. |
| `waitfortype` | `waitfortype[proctype;timeoutms;pollms]` | Block until a live connection exists or timeout; `1b`/`0b`. Caller decides if a timeout is fatal. `startup` must have run first. A **zero or already-expired `timeoutms`** performs no active retry — see [waitfortype with a zero timeout](#waitfortype-with-a-zero-timeout). |
| `getapimeta` | `getapimeta[]` | This module's api metadata, one row per **callable** API function (`init`/`getapimeta`/`version` plumbing omitted), for `di.torq` to register with `di.api`. |
| `version` | `version` | The module's semver string (`"0.1.0"`) — metadata, not a function. Read at load from the plain-text `VERSION` file in the module folder; `di.depcheck` resolves it from the export dict to satisfy other modules' declared minimum-version requirements. |

Export is deliberately conservative — only functions `di.torq` or a consumer actually calls
(so `di.api` lists exactly these), plus the `version` metadata string. The rest are **internal**: `retry` (the scheduled
`serversretry` job — passed to the timer *by value* at init, so it needs no export; it first
runs `cleanup` to sweep ungracefully-vanished handles, then reopens every dead handle),
`cleanup`, `formathp`, `opencon`, `readprocesscsv`, `retryrows`, `selector`, `updatestats`,
`signalfound`, `raiseerror`, `initialised`, `requireinit`, `iscallable`; plus state (`SERVERS`, `self`,
`registered`, `HOPENTIMEOUT`, `connections`, `processcsv`).

## Lifecycle: requireinit and teardown

### `requireinit` — nothing runs before `init`

`startup`, `getservers`, `gethandlebytype`, `waitfortype` and `teardown` each call
`requireinit[ctx]` as their first statement and signal
`di.servers: <fn>: init must be called before any other function` if `init` has not completed.
`getapimeta` deliberately does **not** — it returns static metadata derived from no init'd state,
matching every other module in this project.

This is not a nicety. `SERVERS`, `self`, `registered` and `HOPENTIMEOUT` are **load-time**
constants, so before the guard existed a pre-init call was *silently* wrong rather than loud:

| call | before `init`, without the guard | indistinguishable from |
|---|---|---|
| `getservers[pt]` | an empty table | no process of that type is connected |
| `gethandlebytype[pt;sel]` | `0Ni` | nothing of that type is connected right now |
| `waitfortype[pt;t;p]` | spins the **full** timeout, then `0b` | a peer that never came up |

Only `startup` threw at all, and then with a bare unnamed error off the unset `.z.m.connections`.
With no `di.torq` yet, every process here is wired by a hand-written script calling `init` on
several modules in order — exactly the situation where an ordering mistake is plausible — and a
failure that looks precisely like "the dependency is still starting up" is the worst shape this bug
could take. `di.rdb` already wraps its `gethandlebytype` calls protectively *on the assumption this
guard exists* (`rdb.q:656`).

**Why the probe reads `.z.m.loginfo`.** `initialised[]` must read something whose value can only
come from `init`. `self` and `registered` cannot serve — both are declared at **load** time, so
neither distinguishes "init ran" from "the module was merely loaded". `.z.m.loginfo` has no
load-time default and is written only by `init`; it is also the truest probe of what the guard
protects, since without a wired logger the module cannot even report its own failures.

It is deliberately **not** `registered`. `teardown` resets that flag, and conflating the two would
make every function report *"init must be called before any other function"* after a teardown —
untrue, and it would put `SERVERS` out of reach of exactly the shutdown path `teardown` leaves it
intact for. The two flags stay separate, as in `di.rdb` (probes `hdbdir`, resets `started`) and
`di.subscriptions` (probes `subscriptions`, resets `observing`).

### `teardown[]` — what it releases, and what it does not

`init` installs **two** process-global things, so there is something to give back:

| released by `teardown` | how |
|---|---|
| the `.z.pc` cleanup handler | `` handlers[`remove][`.z.pc;`;`servers] `` — same event, phase and registrant name it was registered under |
| the `serversretry` timer job | `` timer[`deletejobs][`serversretry] `` |

**Not** released — module state is deliberately left intact, the same convention every other
teardown in this project follows:

- `SERVERS` keeps every row, so a shutdown path can still see what was connected and to whom.
- The logger, timer and handler dep refs, self-identity, `connections` and `processcsv` all stay.
- `getservers`, `gethandlebytype`, `waitfortype` and `startup` all remain callable. What is
  withdrawn is only the *automatic* behaviour: with the `serversretry` job gone nothing reattempts
  a dropped connection on a cycle, and with the `.z.pc` handler gone a clean disconnect is no longer
  swept. `waitfortype` still drives `retry` itself, so it keeps working. There is no
  `requireobserver`-style refusal on `startup` after a teardown.

`teardown` resets `registered` to `0b`, so a later `init` installs both side effects again rather
than being skipped by the idempotency guard — a `teardown`→`init` cycle fully works.

**Idempotent — a second `teardown[]` does not throw.** Both release calls are no-ops on an
already-removed registration, verified in the dependencies rather than assumed:
`di.timer.deletejobs` is a delete-where over its jobs table (`di/timer/init.q:95`), so an id that
is not there matches nothing; `di.handlers`' `removesimple` early-returns with an info log when the
event or the name is not registered (`di/handlers/handlers.q:71-72`).

**Why `init` validates the timer's `deletejobs`.** A timer dep's value side is dict-typed, so a
*missing* key returns a null-shaped **dict** rather than erroring. `@[x;y;z]` is "try `x[y]`, catch
with `z`" only when `x` is a **function** — with a dict, `teardown`'s
`` @[.z.m.timer[`deletejobs];`serversretry;handler] `` is read as three-argument **amend** instead:
it upserts the id into that throwaway dict using the error handler as the value, discards the result
and carries on. Nothing throws, nothing warns, the job is never deleted, and `teardown` still logs
success — a false positive. Presence alone is not enough either: a non-callable `deletejobs` lands
in the identical amend. `init` therefore checks both presence and callable type, and the same pair
is applied to `handlers`' `register` and `remove`. The checks must be at `init` time because
`teardown` cannot detect the problem at all.

The callable test is the internal `iscallable`, **not** a bare `` within 100 112h ``. That range
spans every genuinely callable form — lambda, primitive, operator, iterator, projection,
composition — but it also admits **`101h`, the generic null `::`**, which is callable in no useful
sense and is precisely what a dict hands back for a *missing* key when its value side is plain
functions (`` `deletejobs _ di.timer `` yields `101h`; only a *table*-valued dep yields the `99h`
null-shaped dict). Left in, a dep that was absent or explicitly null passed `init`, and `teardown`
then ran `` @[::;`serversretry;handler] `` — which simply returns the id, deleting nothing, while
`teardown` logged success. Measured end to end, which is why `iscallable` excludes `101h`:

```q
iscallable:{[x] t:type x; :(t within 100 112h) and 101h<>t; };
```

> **Known divergence.** `di.rdb` performs the equivalent check with a bare `` within 100 112h `` and
> therefore still carries this hole. It was left untouched deliberately — it is a separate module and
> its own unit of work — but the same tightening applies there.

## `waitfortype` with a zero timeout

**Decision: `waitfortype[pt;0;pollms]` performs no active retry, and that is intended.** With a
zero (or already-expired) `timeoutms` the deadline is in the past by the time the loop condition is
first evaluated, so `retry[]` is never called; the function reports current state, logs the usual
timeout warning, and returns `0b`.

Reasoning, recorded rather than left implicit:

- `retry[]` calls `opencon` for every dead row at `HOPENTIMEOUT` = 2000 ms. Granting a "0 ms" call
  one active attempt could therefore block for **seconds** per unreachable peer — violating the
  caller's explicit budget in the most surprising possible direction. A caller who asks for no wait
  should get no wait.
- Nothing is lost. The scheduled `serversretry` job reattempts every 10 s regardless, so a reconnect
  is *deferred*, not skipped.
- A caller who does want one active attempt asks for one by passing a `timeoutms` of at least
  `pollms`; there is no need for a zero timeout to mean something different from what it says.
- The `0b` return still carries the existing timeout warning, so the outcome stays diagnosable.

## The `SERVERS` table

```q
SERVERS:([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();hits:`int$();startp:`timestamp$();lastp:`timestamp$();endp:`timestamp$())
```

A direct analogue of legacy TorQ's `.servers.SERVERS`: `w` is the live handle (`0Ni` when
disconnected), `hits`/`lastp` drive handle selection, `startp`/`endp` track lifecycle.

## `.z.pc` registration via di.handlers

`.z.pc` (connection closed) is a **simple/observer** event in di.handlers — side-effect only,
fan-out — so di.servers registers its cleanup callback through the injected `handlers`
dependency rather than assigning `.z.pc` directly:

```q
(handlers[`register])[`.z.pc;`;`servers;0j;pcfunc]
```

`register`'s signature is `register[event;phase;nm;pri;func]`; for a simple event the `phase`
must be `` ` `` (null) — di.handlers rejects a non-null phase on an observer event. This lets
di.servers' disconnect hook coexist with every other `.z.pc` registrant in the same
priority-ordered fan-out.

`teardown` gives the registration back through the same dependency, under the same event, phase
and registrant name:

```q
(handlers[`remove])[`.z.pc;`;`servers]
```

## Conventions (learnings from di.config)

- **One-arg `init[deps]`** with config folded into `deps` (the project convention; matches
  `di.eodtime`'s optional-config-in-deps pattern), not a two-arg `init[config;deps]`.
- **Three-flat-var logging** — `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`, matching
  `consistency.md`, `di.compression` and `di.config`. (The project hasn't globally frozen this
  vs. the single-dict form — flag before changing.)
- **`raiseerror` (log-then-signal)** for all post-init domain errors (`selector` unknown
  selection, missing or malformed `process.csv`). `init`'s own dependency validation is the one
  exception (plain `'` — no logger yet).
- **`getapimeta`** exported; a test asserts it documents exactly the module's *callable*
  exports — `init`/`getapimeta`/`version` are plumbing/metadata (di.torq calls or reads them by
  convention) and are deliberately omitted from the registry rows, matching di.toml and the skill
  convention.
- **`version` export** — a bare exported semver string (`"0.1.0"`, numeric `major.minor.patch`),
  read by di.depcheck to satisfy other modules' declared minimum-version requirements. The single
  source of truth is the **`VERSION`** file in the module folder, read module-relative at load by
  `init.q` and `trim`med so a trailing newline cannot pad the semver. There is no compiled-in
  fallback: a missing, unreadable or empty `VERSION` signals a named error at load rather than
  yielding a silently stale or `0.0.0` version that would corrupt di.depcheck's comparison. Bump the
  release by editing `VERSION` alone.
- **Env-free** — di.servers reads no environment variable; the `process.csv` path arrives via
  `config`processcsv` (di.torq resolves it), holding di.config's env-free boundary.

## Open items / not yet done

- **Live-peer integration tests are in place** (`test.q` + `test.csv`, 84 checks), and now wire the
  **real merged `di.timer` and `di.log`** — only `di.handlers` (not yet merged) is mocked. They spawn
  a genuinely separate `q` peer (a self-connect returns pseudo-handle `0`, not a real socket) and
  cover: `startup` connecting to a live peer and logging a failed dial while excluding self,
  `gethandlebytype` returning a live remote handle (`2=h"1+1"`), the retry cycle recovering an
  ungraceful kill (`cleanup`+reopen), and `waitfortype` connected-vs-timeout — plus init validation,
  dep-wiring, idempotency, input validation, and `getapimeta`. `init` schedules `serversretry` in the
  real `di.timer` (asserted via `` timer.getalljobs[] ``); because `retry`/`cleanup` are internal, the
  retry cycle is driven by invoking the exact func di.servers handed the timer (`` firejob `` reads it
  back from `` getalljobs[] `` — the actually-wired path), not a direct export. Idempotent re-init is
  a genuine test here: the real timer's `` addjob[`custom] `` throws on a duplicate id, so a
  non-idempotent `init` would fail outright. A final check re-inits against di.log's real `logdict` to
  prove the injected-log contract holds end-to-end.
  The lifecycle rows added alongside `requireinit`/`teardown` are worth knowing about when editing
  the suite: the pre-init guard rows must stay **above every `init` attempt**, failing ones included
  — an `init` validation gap would let one of those succeed, wire the logger, and make the guard rows
  fail for that reason instead of a missing guard (measured). They assert the *named* message via
  `ss`, not merely that something threw, since a bare `fail` row would pass on any unrelated throw
  and a "returned empty" row would pass under the old silent behaviour. Each guard also asserts the
  **function name** in the message: `gethandlebytype` calls `getservers` internally, so dropping its
  own `requireinit` still produces an "init must be called" error — from the nested guard — and only
  the function-name assertion catches it. `teardown` is covered for both its releases, a second call,
  and an `init` after it re-installing both side effects (which is what proves the `registered`
  reset). The handlers mock's `remove` deletes its recorded row rather than being a no-op, so a
  broken `teardown` cannot pass.
- **`di.handlers` not in kdbx-modules yet**, so only that injected contract is mocked. The handlers
  mock uses the real `register[event;phase;nm;pri;func]` shape from `handlers.q`; the `.z.pc` observer
  path is therefore exercised only via the explicit `retry`→`cleanup` sweep, not a live auto-fired
  `.z.pc` (which real di.handlers would install).
- **`config`processcsv` and the assembled `connections` list** depend on di.torq's config
  wiring — coordinate when di.torq's servers dep is built.
- Scoped-out (v1): discovery service, password/access-list files, non-TorQ tracking, and
  `tcps`/`unix` socket types. Only `tcp` is supported; `formathp` builds a `tcp` handle with no
  socket-type arg — a future `SOCKETTYPE` config reintroduces that (with a test) when needed.

## Tests

Run in a fresh q session (spawns and kills a real peer process; don't interleave with other
modules' tests). Needs `QHOME` set (the peer is launched via `$QHOME/bin/q`) and `di.os` on
`QPATH` (the harness uses `os.abspath` to load `test.q`):

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.servers
```
