# di.rdb — the real-time database process module

First module of Sprint 3 (PROCESS tier). Subscribes to a tickerplant, replays the day's log to
recover intraday state, accumulates live updates in memory, and at end of day either writes each
table down to the hdb and clears it, or — when a wdb fronts the writedown — snapshots row counts and
waits for the wdb's `reload`.

Ported from TorQ `code/processes/rdb.q`, plus `code/rdb/rdbstandard.q` and
`code/rdb/endofperiod.q`, with defaults from `config/settings/rdb.q`.

**Status:** 91 unit asserts, 22 integration asserts, both suites green; qlint reports no error-level
rows. `VERSION` is `0.1.0` and stays there until merge.

---

## 1. What this adapts

| Legacy file | Namespace | kdb-x module | State |
|---|---|---|---|
| `code/common/subscriptions.q` | `.sub` | `di.subscriptions` | PR #123, `feature-subscriptions` |
| `code/common/dbwriteutils.q` | `.sort`, `.save`, `.gc` | `di.dbwrite` | merged to `main` |
| `code/handlers/trackservers.q` | `.servers` | `di.servers` | PR #120, `feature-server` |
| `code/common/eodtime.q` | `.eodtime` | `di.eodtime` | merged to `main` |
| `code/common/async.q` | `.async` | `di.asyncutil` | merged to `main` |

Verified against `origin/main`: `dbwrite`, `eodtime`, `asyncutil` are merged; `servers` and
`subscriptions` are not, and were read off their PR branches.

There is a rough prior implementation on `feature-torqx` at `di/proc/rdb/`. It was treated as prior
art proving the shape works, not as a spec — see §7.

---

## 2. Scope: what shipped, and two reversals worth reviewing

The full TorQ feature set is ported, not the critical path only. Two functional areas were
originally scoped **out** during design and then put back after checking the source; both reversals
are the most review-worthy decisions here, so the evidence is given in full.

### 2.1 Partition tracking is IN — reversal

`getpartition` / `rdbpartition` / `setpartition` / `rmdtfromgetpar` were initially dropped on the
grounds that they serve only gateway partition-routing and that nothing calls them. That is wrong.
Two live callers exist:

- `code/rdb/rdbstandard.q:2` —
  ``.proc.getattributes:{`partition`tables!(.rdb.getpartition[],();tables[])}``
- `code/dataaccess/getdata.q:31-33` — reads **both** `.rdb.getpartition[]` and `.rdb.rdbpartition`,
  gated by `if[(.proc.proctype=`rdb);` at line 24, i.e. running **in-process on the rdb**

The original check looked at `code/common/dataaccess.q`. That file exists — which is why the result
looked conclusive — but the reference lives in `code/dataaccess/getdata.q`, a different file in a
different directory. Worth stating because it is a reusable lesson: "not reachable over IPC" is not
the same as "dead", and the data-access layer runs *inside* the rdb process.

Shipped: full partition tracking, `getpartition` exported, and `getattributes` reproducing
`rdbstandard.q`'s `.proc.getattributes`.

### 2.2 Subscription filters are IN — reversal

`loadsubfilters` / `applyfilters` were initially dropped as dead code, on the grounds that
`.rdb.subcsv` is read at `rdb.q:189` but never defined. It is never defined *in that file* — it is
supplied externally, which is why it does not appear in `config/settings/rdb.q`. TorQ's own test
suite exercises the feature in six configurations, by two mechanisms:

- **command-line override in `process.csv` (5)** — `-.rdb.subfiltered 1 -.rdb.subcsv <path>`:
  `tests/stp/subfile`, `tests/stp/recovery`, `tests/stp/subscription`, `tests/stp/chainedrecovery`,
  `tests/stp/chainedstp`
- **direct q assignment in a k4unit script (1)** — `tests/rdb/rdbfilt.csv:4`

`subfiltered` itself is a documented config global (`config/settings/rdb.q:30`, `subfiltered:0b`).

The residual truth in the original objection: `subcsv` has no default, so enabling `subfiltered`
without supplying it fails obscurely. This module turns that into a named error —
`"subfiltered is set but no subcsv was configured"`.

### 2.3 Also shipped, beyond the original inventory

`moveandclear` (from `rdbstandard.q`, registered public API in TorQ's `apidetails.q`),
`endofperiod` (from `code/rdb/endofperiod.q`), and `status`.

### 2.4 Genuinely out

All FinSpace / `.aws.*` code, removed entirely per the plan's non-backward-compatible-changes
section: `newrdbready`, the FinSpace branches in `endofday`, the sym-file-to-scratch download. The
optional `.dataaccess`/`.checkinputs` integration inside `subscribe` is also out, per the tier table.

---

## 3. Dependencies

Hard (`use` in `init.q`): `di.servers`, `di.subscriptions`, `di.dbwrite`, `di.eodtime`,
`di.asyncutil`. Injected via `init`: `log` and `timer`, both required, never defaulted.

**`di.sort` is deliberately not a dependency**, though the plan's Tier 4 row and dependency diagram
both list it. PR #102 was closed without merging and the merged `di.dbwrite` already ships
`readcsv`/`setconfig`/`getconfig`/`sort`/`applyattr` over the same
`tabname`/`att`/`column`/`sort` config table, folded into `savedown`. Building against `di.sort`
would mean depending on a module that does not exist.

**No `handlers` dependency.** This module assigns no `.z.*` handler — the tickerplant's
`(`endofday;date)` broadcast arrives through the default `.z.ps`. `di.servers` and
`di.subscriptions` each need a handlers dep, but the *caller* wires those (§4).

`deps.q` declares every edge with what is called through it. Enforceable minimums today are
`di.servers` (0.1.0) and `di.subscriptions` (0.2.0) — pinned at 0.2.0 because `start[]` uses the
5-arg `subscribe` and reads `subtables`/`tplogdate` off its return.

⚠️ **`di.dbwrite`, `di.eodtime` and `di.asyncutil` ship no `VERSION` file, and this breaks
`di.depcheck` hard — see §10.0.** They are left declared deliberately (omitting them would
misdescribe the graph), but the consequence is a startup abort, not an advisory line.

---

## 4. Architecture: `init` / `start`, and who initialises what

`init[deps]` is **pure configuration plus root entry points** — no sockets, no other module's
`init`. `start[]` does all the I/O. The caller (`di.torq`, or a test harness) owns the lifecycle of
the shared framework modules and initialises them itself.

This is a deliberate departure from the `feature-torqx` model, where the rdb initialises
`di.servers`, `di.eodtime`, `di.dbwrite` and `di.subscriptions` on the caller's behalf and folds
connect/wait/subscribe into `init`. The reasons:

1. **Those modules are shared process-wide state.** An rdb that initialises `di.servers` claims a
   process-global registry that other modules in the same process also depend on. Whoever composes
   the process should own that, not one consumer of it.
2. **It makes `init` unit-testable with no sockets.** The 91-assert unit suite drives real root
   tables, both end-of-day modes, the reload handshake, both partition sources, both save policies
   and the filter loader without opening a single connection.
3. **The singleton question is now answered.** This design assumed a second `use` of a module
   returns the same instance. Measured: `a:use`di.servers; b:use`di.servers; a~b` → `1b`, with
   exactly one `0servers` namespace under `.m.di`. So `di.subscriptions`' internal `use`di.servers`
   sees the same populated `SERVERS` registry the caller initialised. The assumption holds.

`init` takes exactly one dict carrying dependency and config keys side by side — the shape
`di.torq` wires every module with. Config is resolved and validated **before** any state is mutated,
so a rejected re-init cannot leave the module half-configured. Re-init refreshes deps and config but
**seeds runtime state only when fresh** — wiping `eodtabcount` between the roll and the wdb's
`reload` would strand the prior day in memory permanently.

---

## 5. Recovering from a tickerplant bounce

`start[]` schedules an `rdbresubscribe` timer job. Each cycle it asks
`di.subscriptions.subscribed[]` whether anything is live and, when nothing is, resolves a fresh
handle off `di.servers` and calls `di.subscriptions.resubscribe`.

This closes a real gap. `di.subscriptions.resubscribe` exists and its own comment assigns the
*when* to this module — but nothing was calling it. When a tickerplant restarts, `di.servers`
reopens the socket on its 10s retry, **but the new handle carries no subscription**, so the rdb sits
connected and deaf for the rest of the day with nothing thrown. `start[]` cannot be re-run to fix it
(`di.subscriptions` rejects a duplicate subscribe), so the only recovery was a process restart.

Design notes:

- **A timer poll, not a `.z.pc` observer.** `.z.pc` fires while the socket is still down, which
  tells you nothing about whether `di.servers` has produced a live replacement yet — you would have
  to poll for that regardless. One poll collapses both phases and needs no handlers dep.
- **The check never throws.** `di.timer` defaults `disableonfail` to `1b`, so one escaping error
  would disable the job for the process lifetime — silently deleting the recovery path exactly when
  the tickerplant is misbehaving. The body swallows its own errors *and* the job registers with
  `disableonfail 0b`.
- **Mode 3** (period measured from the previous *end*), because the check makes an IPC round trip.
- Worst-case recovery latency is `di.servers`' retry plus `resubscribeperiod`, ~40s on defaults.

---

## 6. Exports

```q
export:([init;teardown;start;version;getapimeta;
         endofday;reload;endofperiod;
         getpartition;moveandclear;status])
```

`endofday`, `reload`, `endofperiod` and `upd` are additionally published at bare root (and `.u.end`
as TorQ's alias) so other processes reach them by name over IPC. They are exported *as well* so the
k4unit suite can call them directly without standing up a live tickerplant.

`getapimeta[]` returns one row per callable export, omitting `init`/`getapimeta` as framework
plumbing, per the house convention. A test asserts the two lists match exactly in both directions.

---

## 7. Bugs in the `feature-torqx` prior implementation, not carried over

1. **`subscribe` called with 4 arguments, missing `setschema`** — the current signature is
   `subscribe[tph;tabs;syms;setschema;replay]`.
2. **`notifyhdbs` looped synchronously per handle** — this uses `di.asyncutil.postback`, which
   serialises once for the whole set. Two measured details about `postback` that make it easy to
   misuse, both guarded here:
   - It takes a handle **list**. An atom returns `(,0b;"error: type")`.
   - It requires **positive** handles. TorQ's `.async.send` does `neg abs handles`; `di.asyncutil`
     does not. A negated handle **returns** `(,0b;"error: -4 is not an ipc handle")` rather than
     throwing — a silent no-notify if passed through unchecked. Hence the `abs h` at the call site.
3. **`di.servers` treated as injected** — only coherent with a `di.torq` orchestrator sharing one
   instance. Hard-`use`d here, matching `di.subscriptions`' own precedent.

---

## 8. Design questions resolved during implementation

- **Does a second `use` share the instance?** Yes — measured, see §4.3.
- **Is `endofday`'s second argument vestigial?** Yes. `endofday:{[date;processdata]}` at `rdb.q:85`;
  `processdata` appears on that line and nowhere else in the body. `rdbstandard.q:22`'s
  ``.u.end:{[d] .rdb.endofday[d;()!()]}`` — the standard kdb+tick EOD hook — always passes an empty
  dict. Shipped **unary**: a binary function would silently become a *projection* under
  `di.pubsub`'s one-argument broadcast and the roll would never happen.
- **How does `waitfortype` generalise over multiple `tickerplanttypes`?** `connecttp` waits on the
  **first** configured type. `di.servers.waitfortype` is single-proctype where TorQ's
  `startupdepcycles` polled a list. Flagged for review: adequate for every real rdb config seen, but
  a loop-over-types is the obvious extension if anyone needs it.
- **`savedownmanipulation` / `postreplay` have no `di.dbwrite` equivalent.** Built here rather than
  deferred: `manipulate` applies the per-table function before `savedown`, `runpostreplay` runs the
  hook after the writedown loop. Both protected — a manipulation that throws logs and saves the
  original rather than losing the day's data.

---

## 9. One default changed from TorQ

**`onlyclearsaved` defaults to `1b`; TorQ defaults it to `0b`.** This is the only default
deliberately changed. Under `0b` a `savedown` that throws still clears the table — the day's data is
unrecoverable and the sole trace is one error line. Under `1b` the table stays in memory, still
queryable, writable by hand once the cause is fixed. The cost is a table that grows while the save
keeps failing: loud, visible in `status[]`, bounded by the process — the better failure to have.

Both paths are driven by the suite, so neither can regress unnoticed.

---

## 10. Known gaps carried into review

**0. RESOLVED — depended on a companion change, land that first.** `di.dbwrite`, `di.eodtime` and
`di.asyncutil` exported no `version`, and `di.depcheck` classes that as a **failure**, not a
warning, with `init` signalling on any failure — so a process loading `di.rdb` and then calling
`di.depcheck.init` aborted at startup. No pin avoided it (`checkdepversion` returns that failure
before comparing numbers; `"0.0.0"` and `""` measured identical). Those three modules have been
versioned at `0.1.0` — a `VERSION` file plus `version` in the export dict, plus three guard asserts
each. `di.depcheck.init` now reports `0 failure(s), 0 warning(s)` with `di.rdb` loaded.

**That is a separate change to three merged modules and should land as its own commit/PR ahead of
this one**, since `di.rdb` cannot be composed into a depcheck-enabled process without it.

**0b. Separate `di.depcheck` bug found while checking the above, still open:** `shorttofull` drops
the first character of every short module name — `` `rdb ``→`` `di.db ``, `` `timer ``→`` `di.imer ``,
`` `log ``→`` `di.og ``. So `checkmoduledeps[shortname]` silently returns `()` for **every** module
and audits nothing. `checkdeps[]` (the full walk) is unaffected, which is why it has gone unnoticed.
Worth its own issue against `di.depcheck`.

**0c. `di.asyncutil`'s own test suite is red on `main`, unrelated to any of this:** 17 of 20 asserts
fail, all on spawned-peer handles. Verified against the pristine clone copy, so it pre-dates the
version change above. Worth its own issue.

**TorQ-inherited, present in this module, each worth its own change:**

1. `.z.m.timeout` is poisoned permanently if a wdb `reload` is ever missed — the next day's
   `timeoutreset` captures `T 0` as "the original", disabling the query timeout for the process life.
2. `reload` zeroes `eodtabcount` for every table, including ones whose drop failed, so a retry is a
   no-op and the prior day stays resident.
3. `notifyhdbs` blocks unbounded on a hung hdb — `postback`'s `h(::)` flush is answered only after
   the peer processes the reload, and `\T` does not bound an outgoing flush.
4. `start[]` sets `started:1b` before `setpartition`/`scheduletimeoutreset`, so a throw in either
   leaves a live subscription with no partition and no recovery short of a restart.

**Cross-module coordination, none of them di.rdb bugs:**

5. `di.servers.startup[]` takes no argument, so an rdb cannot hand it a role-specific connections
   list — the caller must configure `connections` with the tp and hdb proctypes.
6. `di.dbwrite`, `di.eodtime` and `di.asyncutil` export no `version` → three expected depcheck lines.
7. `di.pubsub.callendofperiod` is `{(neg getallhandles[])@\:(`endofperiod;x)}` — a rank-1 lambda
   broadcasting a 2-list. Legacy's producer sends four elements, and legacy's consumer
   (`code/rdb/endofperiod.q`) is
   ``endofperiod:{[currp;nextp;data] .lg.o[`endofperiod;"...",(string currp),", ",(string nextp),", ",.Q.s1 data]}``
   — genuinely triadic, with a body that exists solely to report all three. So this is not an
   abstract arity mismatch: the two dropped arguments are the entire content of the message. Under
   the current broadcast `endofperiod` receives one argument and q returns a **projection**
   (type 104h) rather than running — nothing is logged and nothing throws. Same defect class as the
   `callendofday` fix in PR #118; it needs fixing in `di.pubsub`, not narrowing the signature here.
8. No `di.tickerplant` module exists, so the roll is proven against the harness tickerplant only.

---

## 11. Testing

**`test.csv` — 91 asserts.** Behavioural, not a load-and-export check: real root tables through
`upd`, both end-of-day modes, the wdb `reload` handshake, both partition sources, both
`onlyclearsaved` paths, the filter loader, the timeout and resubscribe jobs, re-init safety and
`teardown` — with a capturing logger and a mock timer. It asserts **observable effects** of `init`
rather than "init did not throw", which passes even under a wrong `init` arity.

**`test_integration.csv` — 22 asserts.** Stands up a real tickerplant and a real hdb as separate q
processes on OS-assigned ports and drives the lifecycle over genuine IPC: `startup`, `waitfortype`,
`subscribe`, log replay, live capture, the `endofday` broadcast, savedown, and the hdb's `reload`.

It then performs a **real tickerplant bounce** — kill the peer, respawn on the same port, let
`di.servers` reconnect — and asserts the intermediate state explicitly: the socket returns
**carrying no subscription**, which is the bug itself, then that recovery re-establishes it and a
freshly published row arrives.

That scenario was checked with a **negative control**: replacing the `resubscribecheck` call with a
no-op fails exactly two asserts (subscription re-established; live data flows again) and leaves the
other three passing. So it tests the fix rather than restating the setup.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.rdb                 / unit

/ integration - run in a FRESH session; QHOME must point at a real q install,
/ since both peers are launched with $QHOME/bin/q
.m.di.0k4unit.KUltf .Q.dd[hsym`$"<path>/di/rdb";`test_integration.csv]
.m.di.0k4unit.KUrt[]
select from .m.di.0k4unit.KUTR where not ok
```

### Reproducing the runtime claims

The repo-side citations in this document can be checked by reading TorQ. The runtime claims cannot —
they need a q session — so here is what to run and what it produced, rather than asking a reviewer to
take them on report:

| Claim | Check | Result |
|---|---|---|
| `use` returns one instance (§4.3) | ``a:use`di.servers; b:use`di.servers; a~b`` | `1b`, and one `0servers` namespace under `.m.di` |
| `postback` needs a handle list (§7.2) | `postback[h;"1+1";cb]` with `h` an atom | `(,0b;"error: type")` |
| `postback` needs positive handles (§7.2) | `postback[enlist neg h;…]` vs `postback[enlist h;…]` | `(,0b;"error: -4 is not an ipc handle")` vs `,1b` — **returned, not thrown** |
| Unit suite (§11) | ``k4unit.moduletest`di.rdb`` | 91 asserts, 0 failures |
| Integration suite (§11) | `KUltf`/`KUrt` on `test_integration.csv` | 22 asserts, 0 failures |
| qlint (header) | `qlint` over `rdb.q`, count `errorClass=error` rows | 0 (warnings only) |
