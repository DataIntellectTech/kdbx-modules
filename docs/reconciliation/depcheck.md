# Reconciliation — `depcheck` → `di.torq.depcheck` (merge)

**Status:** module reconciled + verified (120 k4unit checks). Both the pre-load graph AND the
post-load `init` audit are wired into di.torq. End-to-end verification awaits `servers` (di.torq is
inert until then).
**Decision:** **merge** (your call) — kdbx `feature-depcheck` canonical, + TorqX's pre-load VERSION graph.
**Sides:** kdbx `origin/feature-depcheck:di/depcheck` · TorqX `di/torq/depcheck`

## The fork

The two took fundamentally different approaches:

- **kdbx `feature-depcheck` — post-load session audit.** Runs via `init[deps]` *after* di.torq has
  `use`d everything, introspecting the loaded modules' namespaces — never calls `use` itself. More
  polished: reads **both `deps.q` and `deps.toml`** (merged), robust semver (malformed-version
  sentinel, non-string-minver detection), **introspection-based** contract checks, a kdb-x
  **engine-version check** (`.z.K`), and careful malformed-manifest handling. Its one acknowledged
  limitation: it **can't version-check unloaded modules transitively** ("deferred until a per-module
  VERSION-file rollout").
- **TorqX `di.torq.depcheck` — pre-load filesystem check.** Runs at the *start* of di.torq.init
  (before any load), resolving modules on QPATH and reading **VERSION files** — catching version
  mismatches *before* the `use` avalanche, transitively. The "customer bumped gateway but not
  serverselect → clean startup error" scenario.

They're complementary: TorqX's on-disk VERSION-file walk is exactly what lifts kdbx's deferred
limitation, now that the VERSION-file rollout is happening.

## What was done

**Canonical = kdbx feature-depcheck**, placed at `di/torq/depcheck`, `di.depcheck`→`di.torq.depcheck`,
`di.toml`→`di.util.toml`, VERSION file + `version` read in init.q.

**Hierarchy adaptation (necessary — kdbx assumed flat names).** kdbx introspects the session
namespace assuming `di.x` → `.m.di.0x`. Our framework modules are nested (`di.torq.handlers` →
`.m.di.0torq.0handlers`). Generalised:
- `modparentns`/`modns`/`nspathtomod` — map an arbitrarily-nested module name to/from its namespace
  (replacing the flat `modvendorns`/`shorttofull`).
- `loadedmodules[]` — recursively enumerate every loaded di.* module by full dotted name (a node is
  a module iff it has an `export` key; it may also parent children — di.torq is both). Replaces the
  flat `key .m.di` walk in `checkdeps`/`checkgraph`.
- `checkmoduledeps` now takes a full dotted name (a nested name can't be rebuilt from a bare `0x`).
- `contracts` dict updated to the reconciled provider names (`di.util.log`/`di.timer`/`di.torq.handlers`).

**Grafted TorqX's pre-load VERSION graph** (reusing kdbx's `resolvemodule`/`readdeps`/`vergte` +
a new on-disk `readversion`): `checkinstalledversion`, `visitversion`, **`checkversiongraph`**
(from module entries), **`checkversiongraphfile`** (from an app/custom manifest file). Exported.
Pure on-disk reads — safe at the very start of init.

**Wired into di.torq (pre-load):** replaced the old `check`/`checkgraph`/`checkgraphfrom`/
`checkztsintegrity` calls with `checkversiongraphfile` (app deps.toml) + `checkversiongraph`
(built-in proctype entry) / `checkversiongraphfile` (custom process manifest), still before any load.

**Verified: 117 k4unit checks green** — kdbx's full audit (hierarchy-adapted) + 21 new pre-load
version-graph tests (readversion, checkinstalledversion pass/below-min/not-found, transitive
`checkversiongraph` attributing a depth-2 fault, `checkversiongraphfile` pass/fail/absent).

## Post-load `init` audit into di.torq — DONE (`cp` contract aligned)

kdbx's `init` (checkdeps + checkgraph + checkcontracts + ztscheck + kdbxcheck) is a valuable
post-load audit. Wiring it as a *fatal* startup audit hit one snag: the `contracts` dict required
**`cp`** on `di.timer`, which the real `di.timer` exports as `setcp` — so `checkcontracts[]` would
always report "di.timer missing cp" and `init` would raise on **every** startup.

**Resolution (chosen): aligned the timer contract** — dropped `cp` down to the five keys di.torq's
own `buildtimerdep` actually uses (`addjob`/`deletejobs`/`enablejobs`/`disablejobs`/`getactivejobs`).
`checkcontract` stays generic, so a caller can still audit `cp` explicitly. Updated the two tests
built on the old gap: the standalone `checkcontracts[]` assertion now checks di.timer *satisfies*
its contract, and the end-to-end "init throws" test drives its failure from a fabricated loaded
module whose on-disk `deps.q` requires an absent module (a real `checkdeps` failure) instead.

**Wired:** `(dc\`init)[\`log\`minkdbxversion!(logdep; config\`minkdbxversion or 0Nf)]` runs after
`loadappcode` (every module loaded), so it audits the live session — contract shapes, `.z.ts`
ownership (kdbx's `ztscheck`, which replaces TorqX's old pre-load `checkztsintegrity`), and an
optional engine-version minimum. Raises on a real contract/dependency gap.

Both di.torq and di.torq.depcheck load clean. End-to-end verification (the audit running in a real
booting stack) awaits the `servers` reconciliation, after which di.torq's own suite goes green.
