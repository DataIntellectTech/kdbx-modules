# Reconciliation — `handlers` → `di.torq.handlers`

**Status:** RECOMMENDED (landed in working tree; feed the `transform` addition back to `feature-handlers`)
**Decision:** canonical = **kdbx `feature-handlers` implementation** (a clean superset), placed at
`di/torq/handlers`. TorqX's `di.torq.handlers` retired, **except** its result-transforming
capability, which is carried across as a new `transform` phase (below).
**Sides:** kdbx `origin/feature-handlers:di/handlers` · TorqX `di/torq/handlers` (was `di.zed`)

## Capability comparison

The `feature-handlers` author adopted TorqX's two-kind model (simple fan-out events vs phased
`pre → exec → post` around one owner) and extended it substantially. It is a superset:

| Capability | TorqX | kdbx `feature-handlers` |
|---|---|---|
| Events | 4 (`pc po`, `ps pg`) | **12** (`pc po exit wo wc`; `pg ps pi pp ph ws pw`) |
| Pre-existing/default `.z.*` handler | warns + overwrites | **captures, runs last, restores on remove** |
| Arg type validation | none | full |
| Exec ownership | one exec | explicit **owner** model + ordering rule |
| Auth/HTTP specials | none | `.z.pw` (redacted post), `.z.ph` default-restore |
| **`post` semantics** | **chained, can transform result** | **observe-only (owner owns the result)** |

kdbx's capture-and-restore behaviour is a genuine improvement — it also fixes the `di.pubsub`
sets-its-own-`.z.pc` coexistence gap (pubsub's handler is captured and still fires).

**Usage check (why the divergence is safe to reconcile):** across all of TorqX, only *simple*
events are used — `di.torq.servers` registers `.z.pc`, `di.proc.gateway` registers `.z.po`+`.z.pc`.
No consumer used phased events, post-transform, or exec-default. So adopting kdbx's model breaks
nothing we built.

## The one capability we preserve: result-transforming `post`

TorqX's `post` could **rewrite the outgoing result** (`{[acc;f] f acc}/[res;posts]`). kdbx made
`post` observe-only on purpose ("the exec owner owns the result"). Rather than reverting that
deliberate choice, we **split the two concerns** and added a distinct **`transform`** phase:

    pre (transform request) → exec (owner produces result) → transform (rewrite result, chained) → post (observe final)

- `transform` handlers are `{[result] …}`, priority-ordered, chained, unprotected (same shape as
  `pre`, but on the result side). Multiple allowed. Require an exec owner first (same rule as
  pre/post). Cleared when the exec owner is removed.
- kdbx's `pre`/`exec`/`post` semantics are **unchanged** — all upstream tests still pass. This
  keeps the addition a self-contained, cherry-pickable block.

**Rationale for a distinct phase (not overloading `post`):** an application decorating a query
result (serialisation, redaction, envelope-wrapping) wants to *rewrite* the result; a metrics/audit
watcher wants to *observe* the final result. Conflating them (TorqX's original `post`) means an
observer accidentally returning a value silently mutates the outgoing result. Separate phases make
the intent explicit and let both coexist.

Not ported (deliberately): TorqX's "exec defaults to `value`, pre/post without an exec owner".
kdbx's mandatory-owner model is sound and nothing depends on the default; left as-is.

## Changes applied on placement

- Placed at `di/torq/handlers`; `di.handlers` → `di.torq.handlers` throughout (error prefixes,
  docs, tests). Internal mangled namespace is `.m.di.0torq.0handlers` (test assertions updated).
- Added a `VERSION` file and read `version` from it in `init.q` (the author noted no version /
  depcheck convention existed; there is one — `di.depcheck` reads VERSION from disk).
- Added the `transform` phase (dispatch, register/remove routing, install, list, teardown, init,
  validation) + a `transform` test block.
- **Event-name convention:** the canonical module uses full `.z.*` symbols. Updated the placed
  consumer `di.proc.gateway` (`` `po ``→`` `.z.po ``, `` `pc ``→`` `.z.pc ``). **Note for the
  `servers` reconciliation:** `di.torq.servers` registers `` `pc `` and will need the same
  `` `.z.pc `` update when it lands.
- Simplified `di.torq`'s `buildhandlersdep` — the canonical module exports the contract names
  (`register`/`remove`/`list`) directly, so the old `deregister`→`remove` alias is gone.
- Verified: **160 k4unit checks green** including the full `transform` block. (The separate
  spawn-based `test_integration.csv` exercises the simple `.z.pc` path, untouched by this change.)

## PR feedback for the author (ready to paste on the feature-handlers PR)

> The TorqX consolidation adopted this module as canonical — it's a clean superset of our version
> (broader event coverage, the capture/restore of pre-existing handlers, the ownership model, the
> `.z.pw`/`.z.ph` specials). Thank you. One capability from our version we'd like to fold back:
> **a `transform` phase** for phased events.
>
> Our apps use phased handlers to *rewrite* the outgoing result (serialise/redact/wrap a `.z.pg`
> response), which your observe-only `post` intentionally doesn't allow. Rather than change `post`,
> we added a distinct `transform` phase that threads the result through a chained
> `{[result] …}` between `exec` and `post`: `pre → exec → transform → post`. It reuses your
> satellite-table machinery (priority-ordered, requires an exec owner, cleared on owner removal),
> leaves `pre`/`exec`/`post` untouched (all your tests pass), and adds a `transform` test block.
> The diff touches `dispatchphased`/`dispatchpw`, `installphased`, `registerprepost`/`removeprepost`
> (now pre/transform/post), `removeexec`, `phasedlist`, `init`, and the `register`/`remove` phase
> validation. Happy to open it as a PR against your branch — flagging here first so the design (a
> separate phase vs overloading `post`) is yours to weigh in on.
