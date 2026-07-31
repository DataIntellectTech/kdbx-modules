# Data Intellect KDB-X Module Consistency Guide

## module Contents
Every module must have: 
1. The code 
2. Documentation in a .md file
3. Tests, conforming to k4unit

The tests should be runnable as 

```q
q)k4unit:use`k4unit
q)k4unit.moduletest`module_to_test
```

## Paths 

Use module local paths for loading and file references

```q
/ local loading
\l ::local/path/to/file.q

/ local path
get`:::local/path/to/datafile
```

## Export

Only export the functions which should be called externally. 

## Namespaces

Avoid `\d` namespace switches.

## Injectable Dependencies

Pass dependencies as a single dict to `init` — this keeps the signature stable as more injectables are added. All dependencies are required; `init` must error immediately with a clear message if any are absent. Store each injected function in `.z.m` and always call it through `.z.m` at call sites.

```q
/ mymodule.q
init:{[deps]
  / deps - `log!(logdict) or `log`timer!(logdict;timerdict)
  /   `log: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required
  / examples:
  /   mymodule.init[enlist[`log]!enlist logdep]
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;
    '"di.mymodule: log dependency is required; pass `info`warn`error functions - see di.log or refer to confluence documentation";
  ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  };

myfunc:{[x]
  .z.m.loginfo[`mymodule;"processing ",string x];
  };
```

Callers provide a dict of functions. Use `di.log` if no custom logger is needed:

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
mymodule.init[enlist[`log]!enlist logdep]
```

---

# Framework & DI conventions (surfaced by the TorqX framework tier)

> The sections below **extend** the base guide with conventions surfaced while building the
> orchestration / process tier (`di.torq` and the process modules). They are additive to the
> rules above; where one refines an existing rule (e.g. the `init` signature) that is called out.
> Provenance: distilled from the TorqX POC (see the "TorqX POC: Status & Design Findings"
> Confluence page). Some points are pending formal alignment with `kdbx-modules` — flagged inline.

## `init` signature: `init[config;deps]` for framework/process modules

The base guide shows `init[deps]`. That holds for pure **library** modules. **Framework and
process modules** — anything `di.torq` orchestrates (the process types, and the injected core
modules) — take **`init[config;deps]`**:

- `config` — the merged settings dictionary for this process, produced by `di.config`'s cascade
  and distributed by `di.torq`. Read a tunable with a presence check:
  `$[`somekey in key config;config`somekey;default]`.
- `deps` — the injected-capability dict, exactly as in the base guide.

A module that needs no settings may ignore `config`, but should still accept it so every module
is called through one convention.

Storage: the base guide stores each injected function individually (`.z.m.loginfo` …). Framework
modules may instead store the **whole dep dict** and index it at the call site
(`.z.m.log:deps`log;` then `.z.m.log[`info][`ctx;"msg"]`). Either is fine; be consistent within a
module. Both still route every call through `.z.m`.

## What to inject vs what to `use`

Two kinds of dependency, kept deliberately distinct:

- **Injected** (passed in `deps`, built once by `di.torq`) — cross-cutting, substitutable
  **singletons with a lifecycle**: `log`, `timer`, `handlers`, `servers`. There must be exactly
  one per process, callers may want to swap the implementation, and their `init` has side effects
  (handler/timer registration) that must run once. Contract key sets:
  - `log` → `` `info`warn`error `` (each `{[ctx;msg]}`)
  - `timer` → `` `addjob`deletejobs`enablejobs`disablejobs`getactivejobs ``
  - `handlers` → `` `register`remove`list ``
  - `servers` → `` `startup`getservers`gethandlebytype`waitfortype `` (its `init` is owned by
    `di.torq`; consumers call `startup` with their own connection list)
- **`use`-imported** (a real, greppable module dependency) — stateless / process-local
  **libraries** with no substitution need: e.g. `di.tplog`, `di.subscriptions`, `di.dataaccess`,
  `di.pubsub`, `di.dbwrite`.

**Rule of thumb: inject cross-cutting singletons; `use` libraries.** `use` is the default; reach
for injection only where there is shared state, a single lifecycle, or a substitution seam.

An injected module's `init` must be **idempotent** — guard the one-time registrations (a
`registered` flag) so a second `init` in the same process can't double-register a `.z.pc` handler
or a timer job.

## The module-namespace write boundary

A `use`-loaded module runs in its own private namespace. The consequence bites everyone who
maintains root state, so treat it as a contract:

- **Reads** of a bare name fall through to root — `select from trade` reads the root `trade`.
- **Writes** — `set`, bare `insert`/`upsert`, and anything run under `-11!` replay — land in the
  module's **private** namespace, **not** root.

So a module that must maintain a **root** table, or publish a **root-level IPC entry point**, must
target root explicitly:

```q
@[`.;`upd;:;updfn];                     / publish a root-callable upd
@[`.;t;{[tab;d] tab upsert d}[;x]];     / upsert into the ROOT table t (works under -11! too)
set[`.hdb.reload;reloadfn];             / publish a root IPC function a peer can call by name
```

A subscriber's root `upd` (invoked by the tickerplant and by `-11!` log replay) must be written
this way, or replayed/pushed rows silently vanish into the module namespace.

## Versioning & dependency manifests

Extends "module Contents". In addition to code / docs / tests, every module ships:

- a plain-text **`VERSION`** file (semver), read into the exported `version`;
- an optional **`deps.toml`** declaring the minimum versions of the modules it `use`s:
  ```toml
  [dependencies]
  "di.serverselect" = "0.2.0"
  ```

`di.depcheck` validates these at startup — the app's own `deps.toml`, **plus** a manifest-graph
walk from the process's entry module through each peer's own `deps.toml` (transitive, on-disk
reads only, loads no module code). A missing `deps.toml` is a silent no-op, so adoption is
incremental. This catches "upgraded one module but not the peer it now needs" as a clear startup
error instead of a cryptic runtime one.

## Module namespace hierarchy  *(agreed — RFC-0001, phased rollout)*

TorqX groups modules into a namespace hierarchy rather than flat `di.*`:

- `di.proc.*` — deployable process types (hdb, rdb, wdb, tickerplant, gateway)
- `di.torq.*` — the orchestrator plus the framework machinery it owns (config, depcheck, servers,
  handlers, logroll)
- `di.util.*` — standalone utilities usable outside a di.torq app (toml, log)
- flat `di.*` — the reusable library layer and all vendored / upstream modules

kdb-x supports this: `di.a.b` resolves to `di/a/b/`, and a parent (`di.torq`) can be both a
loadable module and a parent of children (loading a child does not load the parent).

> **Status:** the hierarchy is the **agreed** target scheme (RFC-0001). Rollout is **phased**:
> new framework/process modules (`di.torq.*`, `di.proc.*`, `di.util.*`) land in the hierarchy now;
> the existing flat utility modules migrate in one coordinated change later (RFC phase 5), *after*
> the in-flight branches are drained/rebased. So flat and hierarchical names coexist for now — do
> **not** pre-emptively rename existing flat modules or open branches ahead of phase 5.
