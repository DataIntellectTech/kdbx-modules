# Reconciliation — `pubsub` (stays flat: `di.pubsub`)

**Status:** COMPLETE — our patch is **merged upstream** (`main` **#118**, 2026-08-06) and this branch
is re-synced to it. 96 k4unit green.
**Decision:** canonical = **kdbx `main`**. This was the one vendored module whose canonical home was
already merged, and the one genuine patch we owed upstream.
**Sides:** kdbx `origin/main:di/pubsub` · TorqX `di/pubsub` (vendored + patched)

## The defect we fixed

`callendofday` broadcast the end-of-day signal to every subscriber. Before #118:

```q
callendofday:{(neg getallhandles[])@\:`endofday`};
```

Two independent defects:

1. **The date was silently discarded.** The lambda has no explicit parameter list and never
   references `x`, yet still has **rank 1** — so `callendofday[d]` (which
   [tickerplant.q:83](../../di/proc/tickerplant/tickerplant.q#L83) does, after computing the
   partition date from eodtime) is accepted and the date thrown away. A subscriber had no way to
   learn which partition to save.
2. **The payload was not what it looked like.** Note the **trailing backtick**: `` `endofday` `` is
   not a bare symbol but a 2-element symbol *vector* `` (`endofday;`) `` — almost certainly a typo.

### The mechanism, corrected

Our own patch comment, and the project notes behind it, said *"a bare async symbol is not applied by
a default `.z.ps` — `value` returns the fn, doesn't call it — so the subscriber's EOD never fired."*
**That is wrong about this code**, and was corrected by direct test before the PR went out. It
describes a *bare* symbol, which is not what was sent. Verified behaviour under the default
`.z.ps` (= `value`):

| payload | what `value` does |
| --- | --- |
| `` `endofday `` (genuinely bare) | returns the function object, **never calls it** |
| `` `endofday` `` (what was sent) | **calls** `endofday[`]` — fires with the *empty symbol* as its date |
| `` (`endofday;d) `` (the fix) | calls `endofday[d]` with the real date |

So the stray backtick accidentally turned "never fires" into "fires with a junk argument" — the
worse failure, because it is silent. Concretely, [rdb.q:66](../../di/proc/rdb/rdb.q#L66)
`endofday:{[date] …}` ran with `` date=` ``, logged `"end of day for partition "` (empty, since
`` string ` `` is `""`), and passed that null symbol into `savedown` as the partition. `savefn`
traps and logs its errors, so it failed **quietly into the log** rather than stopping the roll —
which is why this presented as "EOD never happened".

## What merged

The author took the fix and **extended it to `callendofperiod`**, which had the identical shape and
which we had never patched:

```q
callendofday:{[d](neg getallhandles[])@\:(`endofday;d)};
callendofperiod:{(neg getallhandles[])@\:(`endofperiod;x)};
```

## Changes applied here

This branch's `di/pubsub` predated #118 and still carried the buggy version, so it was re-synced
byte-identical to `main`, plus:

- **`VERSION` (0.1.0)** and a **`version` export** — `di/proc/tickerplant/deps.toml` declares
  `"di.pubsub" = "0.1.0"`, so depcheck needs the file (pre-load walk) and the export (post-load
  audit). Safe: no `getapimeta`, no exact-export-set assertion.

## Verification

- **`di.pubsub` k4unit: 96/96 green** on the re-synced module.
- **`di.proc.tickerplant` 30/30 green** — it is the producer that calls `callendofday[d]`.
- Full 18-module regression: **1114 checks, 0 failures.**

> **This suite is flaky when run back-to-back with other spawn-heavy suites.** A run inside a
> sequential multi-module loop showed 14 failures in the subscription-registry assertions
> (`reqalldict[`quote]` and friends) — none of which even mention EOD. Three consecutive **isolated**
> runs, and a later full-regression pass, were all 96/96. The cause is spawned-child/port
> interference between consecutive q processes, not the module. If this suite reports failures, re-run
> it alone before believing them.
