# Reconciliation — `log` → `di.util.log`

**Status:** LANDED (additive — no competing implementation to reconcile)
**Decision:** place TorqX `di.util.log` as-is. It is an **interim stub**; the real Sprint-1
implementation (wrapping `kx.log`) is unbuilt on both sides and remains a TODO.
**Sides:** kdbx `origin/feature-logging` (**empty**) · TorqX `di/util/log`

## Finding: there is no competing implementation

`origin/feature-logging` has **zero diff from `main`** and no commits of its own — it is an empty
placeholder branch. No `di/log` or `di/logging` module exists on any branch. So the plan's
"Tier-1 logging" sprint was never started on the kdbx side; TorqX's `di.util.log` fills an empty
sprint rather than colliding with anyone's work.

## What `di.util.log` currently is

A **minimal stub** satisfying the injected-`log` DI contract (`info`/`warn`/`error`, each
`{[ctx;msg]}`) documented in `consistency.md`. It formats `.z.p LEVEL ctx msg` and writes to
stdout (`info`/`warn`) / stderr (`error`). No deps, loads standalone.

- Placed at **`di/util/log`**. Verified: k4unit 4/4 green on `feature-torqx`.

## Follow-ups

- **Real implementation (its own sprint):** wrap `kx.log` (from `$HOME/.kx/mod`) — structured
  levels, JSON option, sinks — behind the same `info`/`warn`/`error` contract, so injected
  consumers need no change. The stub's own header already flags this ("Real di.util.log wraps
  kx.log; swap later").
- `feature-logging` can be closed or repurposed as the branch for that real work.
