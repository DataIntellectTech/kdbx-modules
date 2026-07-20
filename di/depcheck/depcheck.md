# di.depcheck

Dependency, version, core-contract, and `.z.ts`-ownership auditing for kdb-x modules. It is the modernised
successor to legacy TorQ's `checkdependency`/`runchk`/`checkvers` (`torq.q`): a per-module `deps.q` replaces the
old CSV registry, real numeric semver replaces the 5-component digit-walk, and — new — it enforces the shape of
the shared "core dependency contracts" (Logging / Timer / Handlers) that the DI dependency-injection pattern
relies on.

---

## How it works

di.depcheck is a **post-load audit, not a pre-load gate**. It is intended to run once, after a host process
(`di.torq`) has already `use`d every module it needs for that process. It never calls `use` on anything it
checks — every check reads other modules' state purely by introspecting the session namespace the kdb-x `use`
loader already populates:

- Every loaded module lands under `` `.m.di `` keyed by a short form (`di.timer` → `` `0timer ``, giving
  `` `.m.di.0timer ``), and that module's full `export` dict is itself readable there
  (`` .m.di.0timer.export ``). This is how di.depcheck reads another module's exports and `version` without
  importing it.
- "Not found" in a failure report means a *declared* dependency was never `use`d into this session by whatever
  loaded di.depcheck's caller — it is not a QPATH filesystem scan.

### Checks performed

1. **Presence & minimum version** — for every currently-loaded module that ships a `deps.q`
   (`` deps:`di.tplog`di.pubsub!("0.2.0";"0.3.0") ``, symbol-keyed by dependency module name, string-valued by
   minimum version), each declared dependency is checked: is it loaded, and if so does its exported `version`
   satisfy the declared minimum (real numeric `major.minor.patch` comparison, not a digit-walk)? A module with no
   `deps.q` is skipped, not treated as an error — most modules don't ship one yet.
2. **Core dependency contracts** — for whichever of `di.log`, `di.timer`, or `di.handlers` are loaded, their
   export dict is checked for the required keys of the contract they provide (Logging: `info`/`warn`/`error`;
   Timer: `addjob`/`deletejobs`/`enablejobs`/`disablejobs`/`getactivejobs`/`cp`; Handlers:
   `register`/`remove`/`list`). This is a fixed, named set — not a generic self-declaration registry, since no
   such mechanism exists elsewhere in this codebase.
3. **`.z.ts` ownership** — warns if `.z.ts` is bound to something while di.timer either isn't loaded or doesn't
   look initialised (its `enabled` state is used as a proxy for "di.timer's `init` ran and bound `.z.ts`
   itself"). This does **not** prove nothing has overwritten `.z.ts` afterwards — an accepted limitation of a
   warning-level check. Scope is deliberately limited to `.z.ts` only.
4. **kdb-x engine version** (optional, and currently unwired) — compares the running engine's `.z.K` (e.g. `5f`)
   against an optional `` `minkdbxversion `` passed alongside `log` on the same `deps` dict. **This is the shape
   of the check, not a live check yet**: if `` `minkdbxversion `` is absent from `deps` — which is every real
   call site today, since no caller exists that supplies one — `kdbxcheck` returns immediately without looking
   at `.z.K` at all. There is currently no config path that could supply a real minimum: di.config's cascade
   isn't wired to di.torq yet (di.config's own docs list that as future work), and `deps.q`'s format is
   per-dependency *module* versions, not an engine-level minimum. The comparison itself is unit-tested and
   correct in isolation (see `test.csv`) — what's missing is a caller that has an opinion on what the minimum
   should be. Uses `.z.K`, not `.z.v` — `.z.v`'s value on the box this module was developed on
   (`"5.0.20260122"`) is a build-stamp string, not a confirmed match for the kdb-x product version, and
   di.k4unit already has a working precedent for exactly this problem (`minver<=.z.K` gates which tests run).

Presence and version failures, and core-contract failures, are **fail-fast**: `init` logs a single multi-line
report at `error` and then signals, so a caller sees a blocking error. The `.z.ts` and kdb-x-version checks are
**warning-only**: logged at `warn`, never signalled.

### Report format

```
DEPENDENCY CHECK FAILED:
  di.tplog requires minimum version 0.2.0, found 0.1.3
  di.pubsub requires minimum version 0.3.0, not found

WARNING:
  .z.ts has been directly assigned outside di.timer. This may cause timer conflicts.
```

A loaded dependency that exports no `version` at all gets its own distinct line (neither "found" nor "not
found" fits): `di.timer requires minimum version 1.0.0, but di.timer exports no version`.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, and `error`, each binary `{[c;m]}` where `c` is a symbol context and `m` is a string (per `consistency.md`) |
| kdb-x minimum version | `` `minkdbxversion `` | no | an optional float compared against `.z.K` |

**No hard dependencies** on other `di.*` modules — the module works standalone, and ships its own (empty)
`deps.q`, dogfooding the convention it introduces.

---

## Initialisation

```q
depcheck:use`di.depcheck

logdep:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});

depcheck.init[enlist[`log]!enlist logdep]

/ with an optional kdb-x minimum version:
depcheck.init[`log`minkdbxversion!(logdep;5.0)]
```

`init` must be called after every module the host process needs has already been `use`d (this is what it
audits) — typically the very last thing `di.torq` does during startup.

---

## Exported Functions

### `init[deps]`
Validate the required `log` dependency, then run every check against the current session and report. `deps` is
a dict with a `` `log `` key and an optional `` `minkdbxversion `` float. Throws on any presence, version, or
core-contract failure; logs (but does not throw on) `.z.ts`-ownership or kdb-x-version warnings.
```q
depcheck.init[enlist[`log]!enlist logdep]
```

### `version`
The module version string.
```q
depcheck.version   / "0.1.0"
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.depcheck
```

Tests drive real, already-shipped modules rather than synthetic fixtures, so the assertions track the codebase's
actual current state:

- **di.timer** is merged to `main`, so it is loaded unconditionally and always exercised for real (missing
  `version`; `cp` defined but not exported — both real, live gaps).
- **di.kafka** (PR #112) and **di.handlers** (PR #114, the positive control — the one module that does export
  `version`) are still unmerged, so this suite must not assume they're present. Their loads are protected
  (`.dc.havekafka`/`.dc.havehandlers`), and every assertion depending on them is written as
  `(not haveflag) or realassertion` — a real check when the module is loaded, a no-op pass when it isn't.
  Verified directly against a bare `main`-only checkout (no other branches merged in): all 34 tests pass there
  too, exercising real di.timer coverage and no-op'ing the di.kafka/di.handlers-dependent assertions rather than
  crashing on a missing module.
- **di.log** (PR #90, DI-Dexter fork) follows the same graceful pattern — checked for real when resolvable on
  QPATH, a no-op pass otherwise.

---

## Notes

- **Known, flagged gaps**, not fixed here:
  - Three real, shipped modules were found missing `version` during development: di.timer, di.kafka, and di.log
    (the DI-Dexter fork PR #90 candidate). di.handlers is the only one that has it, and its own source comments
    call that a placeholder pending this module's existence.
  - di.compression imports `kx.log` directly rather than following the binary `{[c;m]}` three-flat-var
    convention this module (and di.handlers/di.kafka/di.config/di.eodtime) uses — a pre-`consistency.md` outlier
    worth a separate cleanup pass.
  - The `.z.ts` ownership check is a best-effort proxy (see above) — it cannot detect something rebinding
    `.z.ts` after di.timer's `init` runs.
  - The 0.x.y semver tension: a passing `>=` check during 0.x.y development does not guarantee contract
    compatibility, since every module in this workstream is currently pre-1.0. Implemented as literal `>=`
    anyway, per the plan.
  - The kdb-x-version check is **shape-only as of this PR, not operating against anything real yet**: it is
    warning-only rather than fail-fast, and — more importantly — no caller exists today that passes
    `` `minkdbxversion ``, so it is a no-op in every real invocation until di.torq (or some other caller) is
    built and threads a real minimum through. Do not describe this PR as "implements the kdb-x version check"
    to reviewers — it implements the comparison, unit-tested in isolation, with no live minimum source wired up.
  - `test.csv` assumes di.timer is present (true of every real checkout of this repo, since it's merged to
    `main`) — verified against a bare `main`-only checkout, but not against an arbitrarily minimal QPATH
    containing only di.depcheck and di.k4unit. The module itself has no such assumption (verified standalone
    against exactly that minimal QPATH); only the test suite's negative control does.
  - The `checkdeps[]` case of two different loaded modules declaring the same dependency at different minimums
    is manually verified, not committed as an automated test — it needs two real `deps.q` fixtures on disk, and
    no real module ships a non-empty `deps.q` yet to build a portable, no-hardcoded-path test against. Verified
    directly: `di.handlers` required simultaneously at a satisfied minimum (by one fixture consumer) and an
    unsatisfied one (by another) correctly produced exactly one failure line, for the unsatisfied case only.
  - A malformed `deps.q` — present but not a dict (wrong type; a plausible authoring mistake) — is reported as
    its own failure line (`"<mod> deps.q is malformed - expected a dict, got type <n>"`) rather than crashing.
    Not committed as an automated test, for the same real-file-on-disk reason as the point above; manually
    verified: a fixture with `deps:"a string"` produced exactly that report line and did not abort the walk.

- **Two real bugs found and fixed**, both by directly constructing and running the edge case, not by reading the
  code — both looked entirely reasonable on the page:
  1. **`checkdepversion`'s eager `or`.** Originally combined `(xp~(::)) or not \`version in key xp` as a single
     condition. q's `or`/`and` are eager vector operators, not short-circuiting, so `key xp` was evaluated even
     when `xp` was already known to be `(::)`, throwing `'type` (`key` doesn't accept a generic null). Fixed to
     sequential `if[]` early returns, matching the pattern `checkonecontract` already used correctly for the
     same situation. Constructed via direct `.m.di` namespace manipulation, since no real broken module could be
     made to load successfully and then fail an export read.
  2. **A malformed `deps.q` crashed the entire audit, not just the one bad module.** `checkmoduledeps` handed
     whatever `readdepsq` returned straight to `key`/`value`/`checkonedep'` with no type check. A `deps.q` that
     defines `deps` as something other than a dict (e.g. a plain string) threw a raw `'dict` error out of that
     `each` call — and since `each` doesn't isolate per-element errors, one badly-authored `deps.q` anywhere in
     the loaded module set aborted `checkdeps[]` entirely, masking every real failure in every other module.
     Fixed by validating `99h=type d` in `checkmoduledeps` and reporting malformed `deps.q` as its own clear
     failure line instead. This one is the more serious of the two: for a tool whose entire purpose is to run
     reliably at startup, an unhandled crash from one module's authoring mistake defeats the purpose more
     thoroughly than any single check being wrong.
  3. **Dependency resolution was silently wrong for any non-`di.*` name.** `getexport`/`checkonedep`/
     `checkonecontract` all hardcoded the `` `.m.di `` namespace when checking whether a dependency was loaded.
     A di.* module's `deps.q` can legitimately name an external vendor module as a hard dependency (e.g.
     `kx.log`) — but vendor modules register under their own `` `.m.<vendor> `` namespace (`kx.log` →
     `` `.m.kx ``, confirmed directly: `use\`kx.log` populates `` `.m.kx ``, not `` `.m.di ``). A genuinely
     loaded `kx.log` was reported as `"kx.log requires minimum version 1.0.0, not found"` — a silent false
     negative, worse than a crash, since it looks like a correct, actionable result. Fixed by generalising
     `shortmod`/introducing `modvendorns` to resolve a dependency's vendor namespace from its own name instead
     of assuming `di.`. `checkdeps`'s outer walk of *which modules to audit as consumers* stays intentionally
     scoped to `` key `.m.di `` — di.depcheck audits the di.* modularisation effort's dependency graph, not
     arbitrary vendor modules' own internal needs; only *resolving a declared dependency's target* needed to
     stop assuming di.*. `kx.log` itself isn't committed anywhere in this repo (confirmed via `git ls-tree`
     across every branch — it's only vendored locally on this dev machine), so the regression test fabricates a
     non-di.* module via direct namespace manipulation (`` `.m.zz.0widget ``) rather than depending on it.
