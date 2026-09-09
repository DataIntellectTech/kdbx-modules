# Reconciliation — `dbwrite` (stays flat: `di.dbwrite`)

**Status:** LANDED + verified (166 k4unit green; the consumer bridge it forced is now **deleted**).
**Decision:** canonical = **kdbx `main`** (merged 2026-08-05 as **#95**). This is a **re-sync**, not a
contest — we never patched it.
**Sides:** kdbx `origin/main:di/dbwrite` · TorqX `di/dbwrite` (vendored at `2a54956`, 2026-06-24)

## We had no patches — we were simply stale

Diffing our vendored copy against the tip made it *look* like we had substantial local changes.
Diffing against the **recorded vendoring source commit** (`2a54956`) shows the truth: **zero code
deltas**. Everything else was upstream drift we hadn't picked up — 129 changed lines in
`dbwrite.q` across two commits, one of them `c0ea8da` *"Updating following Jamie Grants comments on
git"*, i.e. our own review feedback already landed.

> Method note for the remaining re-syncs: always diff against the vendoring **source commit** to
> isolate local patches, and source-commit→tip to isolate drift. Diffing only against the tip
> conflates the two — that conflation is what put a phantom "eodtime patched (`di.tz`)" row into the
> RFC matrix.

## The win: the monadic log bridge is gone

Upstream moved dbwrite to the **binary** `` `info`warn`error `` `{[c;m]}` contract
([dbwrite.q:21-25](../../di/dbwrite/dbwrite.q#L21-L25), *"no adaptation here, so a monadic kx.log
instance must be wrapped first"*). That is exactly what di.torq injects, so the adapter both write
processes carried is now dead weight and has been **removed**:

- `di/proc/rdb/rdb.q` — deleted `monadiclog` (folded a fixed `` `rdb `` context into each message)
  and its explanatory comment; the init call is now
  `` (.z.m.dbw`init)[enlist[`log]!enlist deps`log] ``, passing the injected dep straight through.
- `di/proc/wdb/wdb.q` — same, with the `` `wdb `` context.
- `rdb.md` / `wdb.md` — the paragraphs describing the bridge rewritten to say no adapter is needed,
  noting why it used to exist.

## Changes applied

Placed at `di/dbwrite` (flat — vendored/upstream-canonical modules keep their upstream names until
the RFC phase-5 rename), byte-identical to `main` except:

- **`VERSION` (0.1.0)** and a **`version` export** — both required, not cosmetic: *two* consumer
  manifests declare it (`di/proc/rdb/deps.toml`, `di/proc/wdb/deps.toml`, each
  `"di.dbwrite" = "0.1.0"`), and di.torq runs both depcheck phases every startup — the pre-load
  walk reads the file, the post-load audit reads the export. Safe to export here: no `getapimeta`
  and no test asserting an exact export set.

## Verification

- **`di.dbwrite` k4unit: 166/166 green.**
- **`di.proc.rdb` 4/4 and `di.proc.wdb` 4/4 still green** after the bridge removal.
- Full 18-module regression: **1114 checks, 0 failures.**

## Note on consumer coverage (pre-existing gap)

`di.proc.rdb`, `di.proc.wdb` and `di.proc.gateway` each have only a 9-line `test.csv` — 4 real
checks apiece, covering init-validation errors and the export set, nothing behavioural. So the
bridge removal is verified by "init still succeeds and the module still loads", not by an
exercised savedown. `di.proc.hdb` (19) and `di.proc.tickerplant` (30, with a real `test.q`) are the
only proc modules with substantive suites. Worth its own piece of work.
