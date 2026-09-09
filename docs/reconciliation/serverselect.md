# Reconciliation — `serverselect` (stays flat: `di.serverselect`)

**Status:** LANDED + verified (129 k4unit + 67 integration assertions green).
**Decision:** canonical = **kdbx `feature-serverselect`, taken verbatim**. There was no
implementation contest to settle: TorqX's copy *is* this branch, vendored unchanged.
**Sides:** kdbx `origin/feature-serverselect:di/serverselect` · TorqX `di/serverselect` (vendored)

## Why this one is trivial

TorqX never wrote a serverselect. It **vendored the branch tip verbatim** (source commit `d8167c3`,
2026-07-14) so the POC built on the in-progress official work instead of diverging. Verified this
session with a full recursive diff: `serverselect.q`, `serverselect.md`, `test.csv` and
`integration.q` are **byte-identical** to the branch tip, which has not moved since. TorqX's only
additions were a `VERSION` file, a `version` export, and a header comment recording the vendoring.

So this reconciliation is: take the branch files as-is, keep the two version grafts, drop the
now-meaningless vendoring note. This matches the RFC-0001 appendix action for the module
(*"drop vendored copy; track the branch"*).

It is also self-contained — `serverselect.q` `use`s **no** `di.*` module (logging is injected as a
binary `` `info`warn`error `` dict, matching di.torq's inject contract; `kx.log` appears only in
`integration.q`'s final step). So none of the `di.log`→`di.util.log` /
`di.handlers`→`di.torq.handlers` rename grafts the framework-tier modules needed apply here.

## Naming: deliberately **not** renamed into the hierarchy

Unlike the framework tier, this module keeps its flat `di.serverselect` name. Three reasons, all
pointing the same way:

- `CLAUDE.md` puts the reusable library layer and everything tracking a `kdbx-modules` branch at
  flat `di.*`, and says the existing flat modules are renamed into the hierarchy **later, in one
  coordinated change (RFC phase 5)** — *don't pre-rename ahead of it*.
- Renaming would fork a module whose canonical home is an unmerged branch, turning a no-op merge
  into a conflicted one.
- Its consumers and tests already bake in the flat name: `di/proc/gateway/deps.toml` declares
  `"di.serverselect"`, and `test.csv:193` asserts the literal `"di.serverselect"` error prefix.

This is the one deviation from the framework-tier method (`di.torq.*`/`di.util.*` renames) — the
rename is deferred to phase 5, not skipped.

## Changes applied

Placed at `di/serverselect` (flat), byte-identical to `origin/feature-serverselect` except:

- **`VERSION` (0.1.0)** — new file.
- **`version:first read0`:::VERSION`** in `init.q`, added to the `export` list.

Both grafts are **required**, not cosmetic, because `di/proc/gateway/deps.toml` declares
`"di.serverselect" = "0.1.0"` and di.torq now runs *both* depcheck phases on every startup:

| depcheck phase | reads | without the graft |
| --- | --- | --- |
| pre-load version graph (`checkversiongraph*`) | the on-disk `VERSION` file, no code load | `depcheck.q:351` — *"has no VERSION file at …"* |
| post-load session audit (`checkdeps`) | the loaded module's **`version` export** | `depcheck.q:223-226` — *"…exports no version"* |

Either one fails a real `gateway` startup. Adding `version` to the export dict is safe here
(unlike toml/config/depcheck/servers, where it would break their `getapimeta` contract test):
serverselect has no `getapimeta` and no test asserting its exact export set.

`serverselect` correctly ships **no `deps.toml`** — it has no peers to declare, so it is a safe
leaf and the manifest walk stops there.

## Verification

- **k4unit `di.serverselect`: 129/129 green** (registration, selection strategies, attribute
  routing, argument validation, injected-logger capture, init error prefixes).
- **`integration.q`: 67/67, exit 0** — the standalone real-process test, run unsandboxed so the
  spawned child listeners can `bind()`. It launches genuine child q backends, opens real IPC
  handles, and routes live queries to the selected handle, so the selection functions are proven to
  hand back handles that actually answer.
- **Both depcheck integration points proven** against the exported API: `checkversiongraphfile`
  passes a manifest requiring `di.serverselect` at 0.1.0 and raises the correctly attributed
  `(required by di.proc.gateway) …` failure at an unmeetable 9.9.9; the `version` export reads back
  as `"0.1.0"`.
- **Regression, each in its own process:** depcheck 120/120, di.torq 35/35 — a new module on QPATH
  changed nothing.

## Feeding back to the branch

Nothing to send back as a fix — the implementation is untouched. The only delta to carry when
`feature-serverselect` merges is the two version grafts (`VERSION` + the `version` export), a
cherry-pickable two-line change. Worth raising with the author as a general convention point rather
than a serverselect bug: any module that a shipped `deps.toml` declares needs both.

`di.proc.gateway` is still inert on this branch — it also `use`s `di.asyncdispatch` and
`di.dataaccess`, neither yet reconciled. Remaining D5: dataaccess, pubsub, subscriptions, and the
vendored asyncdispatch(→asyncutil)/eodtime/dbwrite, then the proc modules' own suites.
