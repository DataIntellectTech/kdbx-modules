# di.torq.depcheck

Dependency, version, core-contract, and `.z.ts`-ownership auditing for kdb-x modules. Runs once at process startup — after every module has been loaded — and reports any declared dependency that is missing, out of date, or fails the shared core-dependency contracts. It is the modernised successor to legacy TorQ's `checkdependency`/`runchk`/`checkvers`: a per-module manifest replaces the old CSV registry, and real numeric semver replaces the 5-component digit-walk.

---

## Features

- **A post-load audit, not a pre-load gate** — it runs after the host process (`di.torq`) has already `use`d every module it needs, and never calls `use` on anything it checks. Each module's state is read by introspecting the session namespace the kdb-x loader populates: every loaded module lands under `` `.m.di `` keyed by a short form (`di.timer` → `` `.m.di.0timer ``), and that module's `export` dict is readable there directly. "Not found" in a report means a *declared* dependency was never loaded — it is not a filesystem scan.
- **Presence & minimum version** — for each loaded module that ships a manifest (symbol-keyed by dependency name, string-valued by minimum version), every declared dependency is checked: is it loaded, and does its exported `version` satisfy the declared minimum (real numeric `major.minor.patch` comparison)? A module with no manifest is skipped, not failed.
- **Dual-format manifests (`deps.q` and/or `deps.toml`)** — a module's dependencies are read from **both** a `deps.q` (a q dict literal) and a `deps.toml` (a `[dependencies]` section), wherever each exists, merged with **`.toml` winning on a clash** — mirroring di.config's `parsetier` so both formats can coexist mid-migration. `di.util.toml` is loaded **lazily and only when a `deps.toml` actually exists**; a module with only `deps.q` never triggers it.
- **Transitive manifest-graph walk** — beyond each loaded module's direct deps, `checkgraph` walks the graph **on disk** (reading each peer's own manifest whether or not it is loaded), cycle-guarded via a visited set, and reports a **presence** failure for any dependency reached at depth ≥ 2 that resolves nowhere on QPATH. It loads no module code. Transitive *version* checking is deferred (see Notes); direct (depth-1) deps keep the stronger presence=*loaded*/version=*exported* check and are excluded from the walk so the two never double-report.
- **Core dependency contracts** — for whichever of `di.log`, `di.timer`, or `di.handlers` are loaded, the export dict is checked for the required keys of the contract it provides (Logging: `info`/`warn`/`error`; Timer: `addjob`/`deletejobs`/`enablejobs`/`disablejobs`/`getactivejobs`/`cp`; Handlers: `register`/`remove`/`list`). The single-contract check is also exported directly as `checkcontract[provider;requiredkeys]` for a contract this module doesn't know by name.
- **`.z.ts` ownership** — warns if `.z.ts` is bound while di.timer is absent or uninitialised (its `enabled` flag is the proxy for "di.timer's `init` ran and bound `.z.ts`"). Warning-level only, and cannot detect a later rebind — an accepted limitation.
- **kdb-x engine version** (optional) — compares the running engine's `.z.K` against an optional `` `minkdbxversion `` passed alongside `log` on the same `deps` dict. Warning-level; no caller supplies a minimum today, so it is a no-op in every real invocation.

Presence, version, and core-contract failures are **fail-fast** — `init` logs a single multi-line report at `error`, then signals, so the caller sees a blocking error. The `.z.ts` and kdb-x-version checks are **warning-only** — logged at `warn`, never signalled.

```
DEPENDENCY CHECK FAILED:
  di.tplog requires minimum version 0.2.0, found 0.1.3
  di.pubsub requires minimum version 0.3.0, not found

WARNING:
  .z.ts has been directly assigned outside di.timer. This may cause timer conflicts.
```

A loaded dependency that exports no `version` gets its own line — `di.timer requires minimum version 1.0.0, but di.timer exports no version` — and a transitive-only dependency missing from QPATH gets `di.zzc is required transitively by di.zzb but was not found on QPATH`.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string (per `consistency.md`) |
| kdb-x minimum version | `` `minkdbxversion `` | no | an optional float compared against `.z.K` |

**No hard dependencies** on other `di.*` modules — the module works standalone, and ships its own (empty) `deps.q`, dogfooding the convention it introduces.

**`di.util.toml` is a soft, lazy dependency** — it is not declared in `deps.q` and not loaded at import time. It is resolved once (cached) and called **only** when a module being audited ships a `deps.toml` file. A process whose modules use only `deps.q` never loads it, so it is not required to be on QPATH in that case. If a `deps.toml` *does* exist and `di.util.toml` is missing or fails to parse it, that is reported as one aggregated failure line (see Notes) rather than throwing.

The `log` dependency must be passed to `init` inside the `deps` dict keyed on `` `log ``, and must already match the binary `{[c;m]}` contract — the module validates key presence but does not detect or adapt other shapes (e.g. a monadic `kx.log` instance). To use `di.log`, pass its `logdict`.

---

## Initialisation

`init[deps]` takes a single dictionary combining the required `log` dependency with an optional kdb-x minimum version.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep — `info`/`warn`/`error`, each binary `{[c;m]}` |
| `` `minkdbxversion `` | no | Minimum kdb-x engine version, compared against `.z.K`. Default: unchecked |

`init` must be called **after** every module the host process needs has already been `use`d — typically the very last thing `di.torq` does during startup. It audits the fully-loaded session, so anything loaded later is not seen.

---

## Exported Functions

### `init[deps]`
Validate the required `log` dependency, then run every check against the current session and report. Throws on any presence, version, or core-contract failure; logs (but does not throw on) `.z.ts`-ownership or kdb-x-version warnings.
```q
depcheck.init[enlist[`log]!enlist logdep]
/ with an optional minimum kdb-x version:
depcheck.init[`log`minkdbxversion!(logdep;5.0)]
```

### `version`
The module version string.
```q
depcheck.version   / "0.1.0"
```

### `checkcontract[provider;requiredkeys]`
Standalone version of the per-contract check that `checkcontracts[]` runs automatically for the three known core dependencies — checks whether `provider`'s export dict (if it's loaded) contains every key in `requiredkeys`. Never calls `use`, matching this module's introspection-only design. Returns `()` on a pass, or if `provider` isn't loaded at all; returns an enlisted failure line naming the missing keys otherwise. `requiredkeys` accepts either a symbol vector or a single bare symbol atom.
```q
depcheck.checkcontract[`di.timer;`addjob`deletejobs]   / ()  - di.timer really exports both
depcheck.checkcontract[`di.timer;`addjob`cp]           / enlist "di.timer is missing required contract key(s): cp"
depcheck.checkcontract[`di.timer;`cp]                   / bare atom works the same as enlist`cp
```

---

## Usage Example

```q
/ log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
/   logging:use`di.log
/   depcheck.init[enlist[`log]!enlist logging.logdict]
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

/ di.torq loads every module the process needs first...
timer:use`di.timer
handlers:use`di.handlers

/ ...then depcheck audits the fully-loaded session, last
depcheck:use`di.torq.depcheck
depcheck.init[enlist[`log]!enlist logdep]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.depcheck
```

Run in a fresh q session — `moduletest` doesn't reset its internal result table between calls, so a second call duplicates this file's rows. The unit suite drives real, already-shipped modules rather than synthetic fixtures: **di.timer** (merged to `main`) is always loaded and exercises real gaps (no `version`; `cp` defined but unexported), while **di.kafka**, **di.handlers** (the positive control — the one module that does export `version`), **di.log**, and **di.util.toml** (on its own `feature-toml` branch) are all on unmerged PRs, so every assertion depending on them gracefully no-ops when the module isn't resolvable on QPATH — the suite passes standalone on a bare `feature-depcheck` checkout, exercising the real path only when the module happens to be present. The manifest readers, dual-format merge, and transitive walk are exercised against scratch modules written under a QPATH root at runtime — the q-only / toml-only / both-formats-clashing / neither cases, a deliberately-broken `deps.toml`, and an A→B→C chain with a B→A cycle — all cleaned up afterwards, with no hardcoded paths and no committed fixtures. The di.util.toml-dependent assertions among these no-op when di.util.toml is absent.

The **integration suite** (`test_integration.csv`) spins up a real, separate child kdb-x process (the child must itself be kdb-x-capable to `use` the modules) to prove two things the unit suite structurally cannot: that a genuine zero-failure run completes cleanly end to end, and that a real signalled failure terminates a real host process with a non-zero exit code and the real report in captured output. `moduletest` only ever loads `test.csv`, so load and run this suite directly:
```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.torq.depcheck;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]                / one row per assertion; ok=1 is a pass
```

---

## Notes

- **`di.util.toml` coupling.** `deps.toml` is inert data parsed by the `di.util.toml` module (no evaluation), whereas `deps.q` is a q dict literal read by executing it. Module keys in a `[dependencies]` section must be **quoted** — `"di.timer" = "0.2.0"` — because di.util.toml rejects unquoted dotted keys. di.torq.depcheck reads only string version values via `parsefile`, so it is unaffected by di.util.toml's scalar value-typing. All format-specific reading lives behind `finddepsq`/`readdepsq`/`finddepstoml`/`readdepstoml`/`readdeps`; every other function consumes only their merged, format-agnostic dict, so dropping a format later is a change to those readers alone. Which format the repo ultimately standardises on is an open cross-team decision (with the TorqX POC), deliberately not resolved here.
- **Deliberate divergence from di.config.** di.config's `requiretoml` throws and aborts its entire settings cascade the instant a `.toml` tier can't be read, because it must hand back one complete, correct config. di.torq.depcheck does the **opposite** on the same event — it catches, folds one clearly-worded line (matching `requiretoml`'s wording) into the aggregate report, and keeps walking — because its whole purpose is to surface *every* problem across *many* modules in one pass. Two right answers to two different jobs, not an inconsistency.
- **Transitive presence is walked; transitive version is not, yet.** `checkgraph` reports a missing transitive dependency at depth ≥ 2, but cannot check the *version* of an unloaded module without either loading it (which the walk must not do) or a per-module `VERSION` file. `VERSION` files are not yet a repo-wide convention — modules carry an inline exported `version` — so adopting them is a coordinated rollout; the walk gains transitive version checking for free once they land.
- **`.z.ts` ownership is a best-effort proxy.** di.timer's `enabled` flag evidences that its `init` bound `.z.ts`; it cannot detect something rebinding `.z.ts` afterwards. Scope is deliberately limited to `.z.ts` only.
- **The kdb-x-version check is shape-only for now.** The comparison is implemented and unit-tested in isolation, but no caller supplies `` `minkdbxversion `` yet, so it is a no-op in every real invocation until di.torq (or another caller) threads a real minimum through. It is warning-only, not fail-fast. Uses `.z.K`, not `.z.v`, matching di.k4unit's existing precedent.
- **Semver is numeric `X.Y.Z` only** — no pre-release/build-metadata support, matching every version string in this codebase. A malformed declared minimum or exported found-version is reported as its own distinct failure line rather than silently mis-compared. During 0.x.y development a passing `>=` check does not guarantee contract compatibility.
- **Modules currently missing a `version` export** — di.timer, di.kafka, and di.log were all found without one; di.handlers is the only module that exports it (and its own comments call that a placeholder pending this module). Adding `version` everywhere is a coordinated repo-wide rollout, of which di.torq.depcheck is the consumer side. di.compression separately imports `kx.log` directly rather than following the binary `{[c;m]}` convention — a pre-`consistency.md` outlier worth its own cleanup.
