# di.depcheck

Dependency, version, core-contract, and `.z.ts`-ownership auditing for kdb-x modules. It is the modernised
successor to legacy TorQ's `checkdependency`/`runchk`/`checkvers` (`torq.q`): a per-module `deps.q` replaces the
old CSV registry, real numeric semver replaces the 5-component digit-walk, and — new — it enforces the shape of
the shared "core dependency contracts" (Logging / Timer / Handlers) that the DI dependency-injection pattern
relies on.

---

## Features

- A **post-load audit, not a pre-load gate** — runs once, after a host process (`di.torq`) has already `use`d
  every module it needs. It never calls `use` on anything it checks: every check reads other modules' state
  purely by introspecting the session namespace the kdb-x `use` loader already populates. Every loaded module
  lands under `` `.m.di `` keyed by a short form (`di.timer` → `` `0timer ``, giving `` `.m.di.0timer ``), and
  that module's full `export` dict is itself readable there (`` .m.di.0timer.export ``) — this is how
  di.depcheck reads another module's exports and `version` without importing it. "Not found" in a failure
  report means a *declared* dependency was never `use`d into this session — it is not a QPATH filesystem scan.
- **Presence & minimum version** — for every currently-loaded module that ships a `deps.q`
  (`` deps:`di.tplog`di.pubsub!("0.2.0";"0.3.0") ``, symbol-keyed by dependency module name, string-valued by
  minimum version), each declared dependency is checked: is it loaded, and if so does its exported `version`
  satisfy the declared minimum (real numeric `major.minor.patch` comparison, not a digit-walk)? A module with no
  `deps.q` is skipped, not treated as an error — most modules don't ship one yet.
- **Core dependency contracts** — for whichever of `di.log`, `di.timer`, or `di.handlers` are loaded, their
  export dict is checked for the required keys of the contract they provide (Logging: `info`/`warn`/`error`;
  Timer: `addjob`/`deletejobs`/`enablejobs`/`disablejobs`/`getactivejobs`/`cp`; Handlers:
  `register`/`remove`/`list`). This is a fixed, named set — not a generic self-declaration registry, since no
  such mechanism exists elsewhere in this codebase.
- **`.z.ts` ownership** — warns if `.z.ts` is bound to something while di.timer either isn't loaded or doesn't
  look initialised (its `enabled` state is used as a proxy for "di.timer's `init` ran and bound `.z.ts` itself").
  This does **not** prove nothing has overwritten `.z.ts` afterwards — an accepted limitation of a warning-level
  check. Scope is deliberately limited to `.z.ts` only.
- **kdb-x engine version** (optional, and currently unwired) — compares the running engine's `.z.K` (e.g. `5f`)
  against an optional `` `minkdbxversion `` passed alongside `log` on the same `deps` dict. This is the shape of
  the check, not a live check yet: no caller exists today that supplies `` `minkdbxversion ``, so it is a no-op
  in every real invocation. Uses `.z.K`, not `.z.v` — `.z.v`'s build-stamp string isn't a confirmed match for the
  kdb-x product version, and di.k4unit already has a working precedent for exactly this problem
  (`minver<=.z.K` gates which tests run).
- Presence and version failures, and core-contract failures, are **fail-fast**: `init` logs a single multi-line
  report at `error` and then signals, so a caller sees a blocking error. The `.z.ts` and kdb-x-version checks are
  **warning-only**: logged at `warn`, never signalled.

Report format:

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

`init[deps]` takes a single dictionary combining the required `log` dependency with an optional kdb-x minimum
version override.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep — `info`/`warn`/`error`, each binary `{[c;m]}` |
| `` `minkdbxversion `` | no | Minimum kdb-x engine version, compared against `.z.K`. Default: unchecked |

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

## Usage Example

```q
/ log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
/   logging:use`di.log
/   depcheck.init[enlist[`log]!enlist logging.logdict]
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

/ typical usage: di.torq loads every module the process needs first...
timer:use`di.timer
handlers:use`di.handlers

/ ...then depcheck audits the fully-loaded session, last
depcheck:use`di.depcheck
depcheck.init[enlist[`log]!enlist logdep]

/ with an optional kdb-x minimum version:
depcheck.init[`log`minkdbxversion!(logdep;5.0)]
```

---

## Running Tests

**Unit suite** (`test.csv`) — introspects session state and fabricated namespace fixtures, no child processes.
`moduletest` loads and runs it:

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.depcheck
```

Run in a fresh q session. `moduletest` doesn't reset its internal test table between calls, so calling it twice
in the same session duplicates this file's rows and produces spurious failures in the fixture that creates and
removes a scratch `deps.q` on disk.

Tests drive real, already-shipped modules rather than synthetic fixtures, so the assertions track the
codebase's actual current state. **di.timer** is merged to `main`, so it is loaded unconditionally and always
exercised for real (missing `version`; `cp` defined but not exported — both real, live gaps). **di.kafka**,
**di.handlers** (the positive control — the one module that does export `version`), and **di.log** are all
still on open, unmerged PRs, so their loads are protected and every assertion depending on them gracefully
no-ops when the module isn't resolvable on QPATH — verified directly against a bare `main`-only checkout (no
other branches merged in), where every test still passes, exercising real di.timer coverage and no-op'ing the
rest rather than crashing on a missing module. `checkmoduledeps`/`finddepsq`/`readdepsq` are also exercised
directly against real on-disk `deps.q` files, not only indirectly via `checkdeps[]` — including di.depcheck's
own real shipped (empty) `deps.q`, di.timer's real absence of one, and a genuinely malformed one written to a
scratch module directory derived from `getenv\`QPATH\`` at runtime (no hardcoded absolute path, no new committed
fixture file, cleaned up afterwards).

**Integration suite** (`test_integration.csv`) — spins up a real, separate child kdb-x process (needed because,
unlike a plain q peer, the child must itself be kdb-x-capable to `use\`di.timer\`/use\`di.depcheck\``) and proves
two things the unit suite structurally cannot: that a genuine zero-failure success path completes cleanly end
to end in a real process (unreachable in `test.csv`, since di.timer is always loaded there as a live negative
control and permanently fails its own contract), and that a real signalled failure actually terminates a real
host process with a real non-zero exit code and the real report visible in real captured output, not a mock
logger. The child binary is resolved via `` /proc/<pid>/exe `` of the *currently running* process rather than
`QHOME` — on this dev machine `QHOME` resolves to a pre-kdb-x q build with no `use` keyword at all, so guessing
from `QHOME` the way `di.handlers`' integration test does (which only ever needs a plain q peer, not a
kdb-x-capable one) would silently pick the wrong binary. Skips cleanly if the resolved binary doesn't exist.
`moduletest` only ever loads `test.csv`, so load and run this suite directly, in a fresh session:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.depcheck;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]                / one row per assertion; ok=1 is a pass
```

---

## Notes

- **Known, flagged gaps**, not fixed here:
  - Three real, shipped modules were found missing `version` during development: di.timer, di.kafka, and di.log
    (the DI-Dexter fork PR #90 candidate). di.handlers is the only one that has it, and its own source comments
    call that a placeholder pending this module's existence.
  - di.compression imports `kx.log` directly rather than following the binary `{[c;m]}` three-flat-var
    convention this module (and di.handlers/di.kafka/di.config/di.eodtime) uses — a pre-`consistency.md` outlier
    worth a separate cleanup pass.
  - The `.z.ts` ownership check is a best-effort proxy (see Features above) — it cannot detect something
    rebinding `.z.ts` after di.timer's `init` runs.
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
    This is now committed as an automated test (a real, malformed `deps.q` written to a scratch module directory
    at runtime, see "Running Tests" above) — closing what was previously a manually-verified-only gap.
  - This kdb-x build's `like` throws `` 'nyi `` on any pattern with more than one `*`-delimited literal segment
    (e.g. `` "*a*b*" ``), regardless of whether the string being matched contains a newline. Every `like`
    assertion in `test.csv` uses a single literal segment (`` "*single clause*" ``) for this reason — worth
    knowing before adding a new one.

- **Five real bugs found and fixed**, all by directly constructing and running the edge case, not by reading the
  code — every one looked entirely reasonable on the page:
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
  4. **`parsesemver` silently mis-handled any non-numeric version component**, found during a later adversarial
     re-pass over the shipped code, again by direct testing rather than reading. It only guarded the wrong
     *count* of dot-separated parts; an individual part that partially parsed (any leading digits followed by
     non-numeric text, e.g. a pre-release tag `"3-rc1"`) silently became `0Ni` (null) at just that position,
     rather than failing the whole version. Since q's integer null sorts as the lowest possible value, this
     produced two confirmed wrong answers, not merely an "unsupported" gap: `vergte["1.2.3-rc1";"1.2.0"]`
     returned `0b` — a real, newer version reported as failing an *older* minimum, solely because its unparsed
     suffix nulled out the patch component that would otherwise have decided the comparison; and
     `vergte["1.2.3";"abc"]` returned `1b` — a typo'd `deps.q` minimum silently treated as "no real requirement
     at all," with nothing surfaced anywhere. Fixed by collapsing *any* unparseable component to the same
     `(0Ni;0Ni;0Ni)` "malformed" sentinel used for the wrong-part-count case (`ismalformed`), and having
     `checkfoundversion` check for it explicitly on both sides (declared minimum and exported found-version)
     before ever handing either to the numeric comparison — surfacing a distinct, correctly-worded failure line
     instead of a silent, misleading pass or fail. See `checkonedep`/`checkfoundversion` and the malformed-semver
     tests in `test.csv`.
  5. **Warnings were silently dropped from the log whenever a failure also occurred.** `init` computed `warnings`
     up front but only logged them in a branch positioned *after* the failures check, and the failures check
     signals (`` ' ``) on any failure — so if a real warning (e.g. `.z.ts` misuse, a stale kdb-x version)
     happened to coincide with a real failure in the same `init` call, execution never reached the
     `.z.m.logwarn` line at all: the warning was computed, then silently discarded, with nothing about it ever
     logged anywhere. Found by directly asking "is this thoroughly tested and does it have thorough logging" and
     reading the actual `init` body, not by running anything new — the bug was visible directly in the code once
     someone looked at execution order rather than just at each `if[]` block in isolation. Fixed by moving the
     warnings-logging line to run unconditionally before the failures check, so a coinciding warning is always
     logged regardless of whether `init` also throws. Regression test: `init` is now called end-to-end with a
     real failure (di.timer's contract gap) and a real, simultaneously-computed warning
     (`` `minkdbxversion `` set above `.z.K`), and the captured log table is asserted to contain *both* an
     `error` row and a `warn` row with the real kdbxcheck text — previously that `warn` row would never have
     appeared.

- **Two further gaps noted but not changed** (defensive-completeness items, not bugs — no real file or call site
  in this codebase currently triggers either):
  - `readdepsq` assumes a `deps.q` is a *single pure* `deps:...` assignment, per every real precedent seen so
    far. This is unenforced: a `deps.q` that also defines stray globals beyond `deps` would leak them into the
    root namespace permanently, since only `deps` itself is ever explicitly deleted after being captured.
  - `init`'s validation of its own injected `log` dependency checks key presence only (`info`/`warn`/`error`
    present), not function arity — the same shape-only limitation already called out above for how
    `checkcontracts` audits *other* modules' contracts applies equally to di.depcheck validating its own.
