# RFC-0001 — Consolidating TorqX and kdbx-modules

- **Status:** Draft — for discussion
- **Author:** Jamie Grant
- **Audience:** Jonny Press (plan owner) + kdbx-modules contributors
- **Related:** [TorQ Modularisation Plan](https://data-intellect.atlassian.net/wiki/spaces/TK/pages/2375450629) · [TorqX POC: Status & Design Findings](https://data-intellect.atlassian.net/wiki/spaces/TK/pages/2646409222)

> This RFC proposes how to merge the TorqX effort and the kdbx-modules sprint work into one
> aligned codebase, and asks for decisions on the handful of choices that gate everything else.
> It does **not** change the plan's design principles (DI, the tier model, versioning-by-QPATH);
> it's about *consolidation mechanics and naming*. Nothing merges until the decisions below land.

---

## 1. TL;DR

TorqX (a de-risking spike) has grown into a working implementation of the plan's entire
**orchestration / process / query tier** — modules that in kdbx-modules exist only as unmerged
feature branches or not at all. In doing so it made several **design choices that diverge from the
plan** (a namespace hierarchy, `di.servers` injected, per-module dependency manifests) and now
holds **parallel implementations** of a set of modules that kdbx-modules contributors are also
building. We should consolidate before the divergence gets more expensive.

**Decisions requested** (detail in §4):

| # | Decision | Recommendation |
|---|---|---|
| D1 | Module naming: flat `di.*` vs hierarchy `di.proc.*`/`di.torq.*`/`di.util.*` | Adopt the hierarchy — *but this is the highest-cost call; see §4* |
| D2 | Base repo: kdbx-modules vs TorqX | **kdbx-modules** as git base; merge TorqX in |
| D3 | Topology: one repo vs framework-depends-on-library | One repo |
| D4 | In-flight branches/PRs: drain-then-migrate vs rebase | Drain the near-done, rebase the rest |
| D5 | Per-module canonical implementation (where both exist) | Case-by-case with the branch author (§ appendix) |

The naming decision (D1) is the one that blocks in-flight work and downstream consumers; please
prioritise it.

---

## 2. Why now

Two efforts are building the same thing from opposite ends:

- **kdbx-modules** — the sprint-driven extraction. `main` holds the Tier-1 utility modules; the
  framework/process tiers are in feature branches under active development by several people.
- **TorqX** — a spike that built top-down: the orchestrator (`di.torq`), the process types, the
  gateway/query tier, and a round of DI/dependency-management hardening, all proven end-to-end.

They now overlap on ~9 modules with **two independent implementations each**. Every week that
passes, the reconciliation cost rises and the risk of shipping divergent contracts grows. This is
the moment to align.

---

## 3. Current state (from a checkout of both repos)

**kdbx-modules `main`** — Tier-1 utilities, flat names:
`analytics asyncutil cache compression datadog dataloader k4unit memstats os pubsub querylog
simtick timer tz tplog`. No `.github/` CI, no git tags. Has `consistency.md`, `style.md`, an empty
`.claude/`, and `.reviewagent.yml`.

**kdbx-modules feature branches** (framework/process work, unmerged): `feature-config`,
`feature-depcheck`, `feature-handlers`, `feature-logging`, `feature-dataaccess`,
`feature-serverselect`, `feature-asyncdispatch`, `feature-eodtime`, `feature/dbwritemodule`,
`feature-sort`, `feature-merge`, `feature-API`, `feature-kafka`, `extract-html`.

**TorqX** — the framework/process/query tier, built and proven:
`di.torq` + `di.torq.{config,depcheck,servers,handlers,logroll}`, `di.util.{log,toml}`,
`di.proc.{hdb,rdb,wdb,tickerplant,gateway}`, `di.subscriptions`, `di.tplog`, `di.dataaccess`,
plus **vendored** copies of `asyncdispatch`, `serverselect`, `pubsub`, `dbwrite`, `eodtime`
(some patched — see appendix). Full k4unit regression green; stack boots + queries end-to-end.
Adds beyond the plan: the namespace hierarchy, injected `di.servers`, per-module `deps.toml` +
a startup dependency-graph check, and an operational layer (`torqx.sh`, `export-systemd`, tmux dev
mode) shipped inside the `di.torq` module at `di/torq/bin/`.

**The key point:** merging is **not a file-move**. For ~9 modules there are two implementations
that must be reconciled module-by-module with their authors (see appendix).

---

## 4. Decisions requested

### D1 — Module naming: flat vs hierarchy

The plan uses **flat** `di.*` names across five conceptual tiers. TorqX introduced a **namespace
hierarchy** that maps onto those tiers: `di.proc.*` (process types), `di.torq.*` (orchestrator +
the machinery it owns), `di.util.*` (standalone utilities), with the library layer and all
vendored/upstream modules staying flat.

- **For:** groups ~16+ authored modules by role instead of a flat list of 30+; makes "what is
  this module's job" legible; kdb-x supports it natively (a parent can be a module *and* hold
  children; loading a child doesn't load the parent — verified).
- **Against:** it is a **breaking change** — every `use`di.rdb`` becomes `use`di.proc.rdb``, so
  every open PR/branch and every downstream consumer must change; and it revises the plan's stated
  design.

If we adopt a hierarchy, a sub-decision: **`di.torq.*` vs `di.core.*`** for the framework
machinery. `di.torq.servers` reads as "servers belongs to the orchestrator"; `di.core.servers`
reads as "a core framework module, peer to di.torq." TorqX currently uses `di.torq.*`.

> **Recommendation:** adopt the hierarchy — it's a real, low-controversy-once-settled improvement
> and it's already proven. But it is the **highest-cost, least-reversible** decision here, so it
> must be made deliberately and *before* any branch merges (renaming after contributors build on
> flat names is far more expensive). If the appetite for a breaking rename isn't there, the
> fallback is: keep flat names for now, keep the hierarchy as a documented future option. I lean
> `di.torq.*` but am genuinely open on the sub-decision.

**This decision gates all merge work.**

### D2 — Which repo is the base

Instinct is often "make the more-complete repo (TorqX) the new main." I'd argue the base-repo
choice should be decided on **community and continuity, not capability**, because the hierarchy and
the TorqX designs can win *regardless* of which git history is the base:

- **kdbx-modules as base** — preserves contributors, open PRs, the review bot, the established name
  and download URLs. TorqX's biggest contribution (the whole orchestration/process tier) fills
  **empty** sprints, so it lands as additive modules, not collisions. The hierarchy can still be
  adopted repo-wide as part of the consolidation.
- **TorqX as base** — starts from the coherent single-author design + hierarchy already in place,
  but orphans kdbx-modules' contributors/PRs/tooling/name and still requires importing ~15 utility
  modules from it.

> **Recommendation: kdbx-modules stays the base repo; merge TorqX into it.** You keep the
> community and lose only the "TorqX" repo name — the cheapest thing to give up.

### D3 — Repo topology: one repo or two layers

The plan says "import one module for a capability, or import `di.torq` for the full stack" — which
argues for **one** repo containing everything. TorqX's vendoring pattern hints at an alternative:
`kdbx-modules` = the module *library*, a separate `TorqX` = the *framework/reference-app*
(`di.torq` + processes) that depends on it.

> **Recommendation: one repo.** Simpler for contributors, versioning, and CI at this stage; revisit
> a split only if the library genuinely needs an independent release cadence.

### D4 — In-flight branches and PRs

Adopting the hierarchy (D1) breaks every open branch. Options: **drain** (merge the near-complete
branches to `main` *first*, then migrate everything together) or **rebase** (each author re-bases
their branch onto the new scheme). Realistically it's both: drain what's close, rebase the rest —
but the sequencing must be explicit so no one's work is silently orphaned.

> **Recommendation:** freeze new framework-branch work; land the branches that are review-ready;
> then do the naming migration in one coordinated change; rebase the remainder with author help.

### D5 — Canonical implementation per overlapping module

For each module that exists on both sides (§appendix), pick the canonical implementation *with the
branch author in the loop* — theirs, TorqX's, or a merge. Our per-module `deps.toml` + the
`di.depcheck` graph is a useful tool during this phase (declare peer versions, catch mismatches as
modules move).

---

## 5. Recommended end-state (synthesis)

One repo (**kdbx-modules**, kept as base), containing every module under an agreed **hierarchy**,
with the TorqX orchestration/process/query tier merged in, the overlapping modules reconciled to a
single canonical implementation each, vendored patches contributed back with attribution, a
licensed CI running the k4unit regression on every PR, the shared conventions in
`consistency.md`/`style.md` (extended) + a root `CLAUDE.md`, and a branch/PR workflow open to
contributors.

---

## 6. Migration plan (phased)

1. **Decisions** — this RFC signed off (D1–D5). *Nothing merges before this.*
2. **Context docs** — land `CLAUDE.md` + the extended `consistency.md`/`style.md` (drafted;
   distilled from the TorqX findings) into the base repo, to set conventions for contributors.
3. **CI with licence** — stand up a runner with the corporate `k4.lic` (secret / self-hosted) that
   runs the k4unit regression, including the spawn-heavy suites (real ports). *This is the biggest
   net-new build and what makes the PR workflow safe.*
4. **Consolidate, in dependency order:**
   a. utility modules (kdbx-only) — adopt as-is (place under the agreed scheme).
   b. TorqX-only tier (orchestrator/process/query) — additive, brings in the empty sprints.
   c. overlapping modules — reconcile per D5, author in the loop.
   d. vendored patches — contribute back to the origin branches as **attributed** PRs; retire the
      vendored copies. Resolve the `di.tplog` (lifecycle) vs kdbx `di.tplog` (= check/repair, our
      `di.tplogutils`) **name collision**.
5. **Naming migration** — apply the agreed scheme repo-wide in one coordinated change (if D1 =
   hierarchy). Provide a compat shim / codemod note for downstream consumers.
6. **Governance** — branch-protect `main`, require PR + review (align with `.reviewagent.yml`), add
   `CODEOWNERS` + `CONTRIBUTING.md`, agree a monorepo **tag/release** convention (none exist yet).
7. **Open the workflow** to collaborators.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Hierarchy rename breaks every `use` + open PR | Decide D1 first; migrate in one coordinated change; codemod + compat note |
| Orphaning contributors' branches | Drain review-ready branches first; rebase the rest *with* authors (D4) |
| Vendored patches land un-attributed | Contribute back as PRs to the origin branches, crediting original authors |
| No CI → regressions merge silently | Phase 3 (licensed CI) before opening the PR workflow |
| `di.tplog` name collision | Resolve explicitly during phase 4d |
| Downstream users stranded by rename | `di.torq` compat shim (already in the plan) before onboarding real users |
| Two implementations silently diverge further | Freeze framework-branch work at phase 1 |

---

## 8. Non-goals

- Re-litigating the DI principle, the tier model, versioning-by-QPATH, or FinSpace removal — all
  stand as the plan states.
- Building the remaining unbuilt tiers (IDB, monitor, DQC/DQE, discovery, …) — separate sprints.

---

## 9. Open questions

- D1 sub-decision: `di.torq.*` vs `di.core.*` for framework machinery.
- Release/tagging model for a monorepo of independently-versioned modules (the plan assumes tagged
  releases; none exist yet).
- Where the operational layer (`torqx.sh`/`export-systemd`) belongs long-term — inside `di.torq`
  (current TorqX choice) or a separate ops module.

---

## Appendix — module reconciliation matrix

"Canonical" and "Action" are proposals for discussion, not decisions.

| Module | kdbx-modules | TorqX | Proposed canonical | Action |
|---|---|---|---|---|
| log / logging | `feature-logging` | `di.util.log` (built) | reconcile | compare contracts; pick one |
| config | `feature-config` | `di.torq.config` (built) | reconcile | compare; TorqX has the cascade + `.toml` |
| depcheck | `feature-depcheck` | `di.torq.depcheck` (built, + manifest graph) | reconcile | TorqX superset (graph) — verify vs branch |
| handlers | `feature-handlers` | `di.torq.handlers` (built; was `di.zed`) | reconcile | compare `.z.*` registry designs |
| dataaccess | `feature-dataaccess` | `di.dataaccess` (rebuilt; branch didn't fit) | likely TorqX | confirm with branch author |
| serverselect | `feature-serverselect` | vendored (unpatched) | **branch** | drop vendored copy; track the branch |
| asyncdispatch | `feature-asyncdispatch` | vendored + **patched** (callback-baking) | branch + our patch | PR the patch back, attributed |
| eodtime | `feature-eodtime` | vendored + **patched** (`di.tz`) | branch + our fix | PR the fix back |
| dbwrite | `feature/dbwritemodule` | vendored | branch | PR the enum-dir suggestion back |
| pubsub | `main` | vendored + **patched** (`callendofday` 2-list) | main + our patch | PR the patch back |
| tplog | `main` = check/repair (**our** `tplogutils`) | `di.tplog` = lifecycle | **both, renamed** | resolve the name collision |
| timer, tz, os, cache, compression, dataloader, simtick, k4unit, querylog, memstats, analytics, datadog, asyncutil | `main` | consumed (external) | kdbx | adopt as-is under the agreed scheme |
| torq, servers, subscriptions, rdb, wdb, hdb, tickerplant, gateway, logroll, toml | — | built | **TorqX** | additive — fills empty sprints |
| sort, merge, API, kafka, html | branches | — | kdbx | out of scope here; land via their branches |
