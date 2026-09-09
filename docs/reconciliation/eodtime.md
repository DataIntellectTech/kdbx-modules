# Reconciliation — `eodtime` (stays flat: `di.eodtime`)

**Status:** LANDED + verified (49 k4unit green — the 3 long-standing kx.log-env failures are gone).
**Decision:** canonical = **kdbx `main`** (merged 2026-08-05 as **#108**). A **re-sync**; we never
patched it.
**Sides:** kdbx `origin/main:di/eodtime` · TorqX `di/eodtime` (vendored at `5f09606`, 2026-06-25)

## Correcting the record: there was never a `di.tz` patch

The RFC appendix listed this module as *"vendored + **patched** (`di.tz`) → PR the fix back"*. That
is **empirically false**. The vendored base commit `5f09606` already had `` tz:use`di.tz ``, as do
main's tip and our copy — the three agree, so there is nothing to feed back. The `di.tz`
vs `di.timezone` business was **cross-branch naming churn**, not an eodtime code change: main
renamed timezone→tz in #91, while `feature-serverselect` and `feature/dbwritemodule` are still based
on pre-rename main and carry the old names. Our copy pointed at the main-side name, which was a
*choice about which checkout we ran against*, never a patch.

Likewise, the `normlog` helper in our copy (which auto-normalised a monadic kx.log instance) was
**not ours** — it was upstream code, added in `bb637de` and **removed** upstream in `bb9f1a2`. We
were simply holding a snapshot that still contained it.

## What we gain by re-syncing

Three commits of upstream work we were missing:

- **A real DST fix.** Upstream extracted `rolltod` and changed `getroll` to recompute the roll
  offset for **tomorrow** when today's roll time has passed
  (`$[z<=p;("d"$p+1D)+rolltod[p+1D];("d"$p)+z]`) instead of just adding `1D` to today's offset.
  That matters across a DST transition, and upstream ships the test for it (Europe/London clocks
  going back on 2025.10.26).
- The newer logging format, and an `init` that requires **at minimum** an `` `info `` key rather
  than all three levels.
- The test suite that replaced our copy's three kx.log-environment failures.

## Contract check — no consumer change needed

`init` wants `deps`log` as a binary `{[c;m]}` dict with at least `` `info ``
([eodtime.q:78](../../di/eodtime/eodtime.q#L78)) — exactly what di.torq injects.
`di.proc.tickerplant`'s `eoddeps` builds `` `log ``→logdep plus optional tz config and passes it
straight in, so it works unchanged.

## Changes applied

Placed at `di/eodtime` (flat — vendored/upstream-canonical names hold until the RFC phase-5
rename), byte-identical to `main` except:

- **`VERSION` (0.1.0)** and a **`version` export** — required, because
  `di/proc/tickerplant/deps.toml` declares `"di.eodtime" = "0.1.0"` and di.torq runs both depcheck
  phases (pre-load reads the file, post-load reads the export). Safe: no `getapimeta`, no
  exact-export-set assertion.
- Deliberately **no `deps.toml`** for the module itself. It `use`s `di.tz`, which ships no `VERSION`
  file, so declaring that peer would make depcheck's "has no VERSION file" branch fail a live
  tickerplant. A manifest-less module is a safe leaf — the walk stops there. (Adding a VERSION file
  to `di.tz` is the clean fix, and is a separate upstream change.)

## Verification

- **`di.eodtime` k4unit: 49/49 green** (our stale copy had 3 failures).
- **`di.proc.tickerplant` 30/30 green** against the re-synced module, unchanged.
- Full 18-module regression: **1114 checks, 0 failures.**
