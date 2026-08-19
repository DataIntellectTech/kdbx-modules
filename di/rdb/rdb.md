# di.rdb

The real-time database. Subscribes to a tickerplant, replays the day's tickerplant log to recover
intraday state, accumulates live updates in memory, and at end of day writes each table down to the
hdb, clears it and tells the hdb(s) to reload.

Ported from TorQ's `code/processes/rdb.q`, together with the process-code files
`code/rdb/rdbstandard.q` and `code/rdb/endofperiod.q`, and the defaults in
`config/settings/rdb.q`.

## Usage

```q
rdb:use`di.rdb

/ the CALLER wires di.rdb's hard dependencies first - see "who initialises what" below
rdb.init[logging.logdict,`timer`hdbdir`reloadenabled!(timerdep;`:/data/hdb;0b)]
rdb.start[]
```

`init` configures the process and publishes its root entry points; it opens no sockets and touches
no other module. `start` does all the i/o: connect, wait for a tickerplant, subscribe and replay.

Both are safe to call again. `init` refreshes the dependencies and config on every call but seeds
the **runtime** state - the subscribed table list, the partition list, the end-of-day row-count
snapshot and the started flag - only on the *first* call, so re-applying config to a running rdb
cannot discard what it is holding. `teardown` is idempotent.

`start[]` re-publishes the root entry points as well, so `teardown[]` followed by `start[]` - with
no `init` in between - is a supported way to re-establish a subscription. Without that a restarted
rdb reported `started` `1b` while root carried no `upd` at all; see the fixes section.

## Exports

| Function | Signature | Description |
|---|---|---|
| `init` | `[deps]` | wire the injected dependencies and config, publish the root entry points |
| `start` | `[]` | connect to the tickerplant, subscribe, replay the log, set the partition |
| `teardown` | `[]` | remove the root entry points and the timer jobs that `init`/`start` installed. Does **not** unsubscribe - see below |
| `endofday` | `[date]` | the end-of-day roll. also published at root and as `.u.end` |
| `reload` | `[date]` | the wdb's ipc entry point once it has persisted the prior day. also at root |
| `endofperiod` | `[currp;nextp;data]` | the tickerplant's intraday period roll. also at root |
| `getpartition` | `[]` | the partition date(s) this rdb currently holds, for gateway routing |
| `moveandclear` | `[fromns;tons;tab]` | move a table's schema to another namespace and delete the original |
| `status` | `[]` | how this rdb is wired and what it currently holds |
| `getapimeta` | `[]` | api metadata for `di.torq` to register with `di.api` |
| `version` | | module version, read from the `VERSION` file |

## Dependencies

**Injected** via `init`, both **required** - there is no fallback and no default logger:

| Key | Contract |
|---|---|
| `log` | `` `info`warn`error `` of binary `{[c;m]}` - context symbol, message string. `di.log`'s `logdict` is a ready-made dep |
| `timer` | a dict with `addjob` (a variant dict exposing `custom`) and `deletejobs`. See `di.timer` |

**Hard** (`use`-imported in `init.q`, declared in `deps.q`): `di.servers`, `di.subscriptions`,
`di.dbwrite`, `di.eodtime`, `di.asyncutil`. What each is actually used for is listed per-edge in
`deps.q`.

`di.handlers` is **not** a dependency. The TorQ source assigns no `.z.*` handler, and the
tickerplant's `` (`endofday;date) `` broadcast arrives through the default `.z.ps`. `di.servers` and
`di.subscriptions` do each need a handlers dep, but the caller wires those.

`di.dbwrite` takes the same **binary** `{[c;m]}` log contract as everything else, so no adapter is
needed. (Earlier notes describing it as monadic `kx.log` style are out of date: `main`'s
`dbwrite.q` wires `.z.m.loginfo`/`logwarn`/`logerr`, and TorqX deleted its own adapter for the same
reason.)

### Who initialises what

**di.rdb initialises none of its hard dependencies.** `di.servers`, `di.subscriptions`,
`di.dbwrite` and `di.eodtime` are shared framework state whose lifecycle belongs to the caller -
`di.torq`, or a test harness. `di.rdb` only *uses* them, and only from `start[]` onwards.

That split is deliberate:

- `init` stays pure configuration, so it can be unit-tested with no sockets and no other module
  initialised;
- a process that also runs a gateway or a wdb does not get its shared `di.servers` re-initialised
  behind its back;
- and it avoids one module owning another's lifecycle.

The cost is one real constraint on the caller: **`di.servers` must be configured with a
`connections` list that covers the tickerplant and hdb proctypes before `start[]` runs.**
`di.servers.startup[]` takes no argument - it opens whatever `di.servers` was configured with at
its own `init` - so an rdb cannot hand it a role-specific list. `test_integration.csv` shows the
full wiring. (TorqX hit the same wall from the other side and changed `startup` to take the config;
that change is not on `feature-server`, so it is flagged as a follow-up rather than assumed here.)

`di.eodtime` must be initialised before `start[]` too, since the timeout job is scheduled off its
`getnextroll`. If it has not been, `start` fails loudly with a message naming it rather than
booking a job for `0Wp` that would never fire.

## Config

Every key is optional and carries TorQ's default. Config and dependency keys share the **one flat
dict** `init` takes.

| Key | Default | Meaning |
|---|---|---|
| `tickerplanttypes` | `` `tickerplant `` | proctype(s) to subscribe to |
| `hdbtypes` / `hdbnames` | `` `hdb `` / `` () `` | hdbs to notify at eod, resolved by type **or** by name |
| `gatewaytypes` | `` () `` | gateways to push eod attributes to. empty means no push. **TorQ defaults this to `` `gateway ``** |
| `ignorelist` | `` `heartbeat`logmsg `` | tables never saved or cleared at eod |
| `subscribeto` / `subscribesyms` | `` ` `` / `` ` `` | tables and syms to subscribe for; `` ` `` means all |
| `schema` | `1b` | take the table schemas from the tickerplant |
| `replaylog` | `1b` | replay the tickerplant log at subscribe |
| `hdbdir` | `` `:hdb `` | hdb root written to |
| `sortcsv` | `` ` `` | sort/attribute config handed to `di.dbwrite.readcsv`. Unset means `readcsv` is never called, and `di.dbwrite.sort` then falls back to its own `defaultparams`: sort by `time` ascending, no attributes. **TorQ defaults this to `` `:config/sort.csv ``** |
| `savetables` | `1b` | if false, tables are wiped at eod but not written |
| `onlyclearsaved` | `1b` | if true, a table whose save failed is kept rather than wiped (**TorQ defaults this to `0b`** - see divergences) |
| `gc` | `1b` | garbage collect in `reload` (see the caveat below) |
| `reloadenabled` | `0b` | `0b` standalone, `1b` wdb-fronted. **Explicit config, never auto-detected** |
| `parvaluesrc` | `` `log `` | where the partition value comes from: `` `log `` or `` `tab `` |
| `pardefault` | `.z.D` | partition used when the source yields a null date |
| `subfiltered` / `subcsv` | `0b` / `` ` `` | load subscription filters from a csv |
| `upd` | root-safe default | override the root `upd` with your own binary function |
| `savedownmanipulation` | `()!()` | `table!function`, applied to a table just before it is saved |
| `postreplay` | `{[d;p]}` | hook invoked after every table has been written down |
| `tpwaittimeout` / `tppollms` | `30000` / `500` | how long `start` blocks waiting for a tickerplant |
| `tpselection` | `` `any `` | selection algorithm for `di.servers.gethandlebytype` |
| `resubscribeenabled` | `1b` | automatically re-establish the subscription after a tickerplant bounce |
| `resubscribeperiod` | `30` | seconds between resubscribe checks (must be positive) |
| `suspendtimeoutonroll` | `1b` | `1b` **suspends** the query timeout around the roll. Renamed from `disabletimeout` |
| `timeoutlead` | `0D00:01` | how far before the roll to suspend the query timeout |
| `procname` / `proctype` | `` ` `` / `` ` `` | this process's identity, used only in the gateway attribute push |

Three defaults differ from TorQ's: `onlyclearsaved` (a deliberate data-safety choice, argued under
divergences), `sortcsv` and `gatewaytypes` (both TorQ paths/types that have no meaning until the
caller supplies one, so they default to "not configured" rather than to a path that does not exist).

`sortcsv` is worth one further caveat: `di.dbwrite`'s sort config is **process-wide** state, not
per-caller. A co-hosted module that calls `di.dbwrite.readcsv` changes the sort and attribute rules
this rdb writes with, and the last caller wins.

## Behaviour

### Startup

`start[]` opens the configured connections (`di.servers.startup`), blocks until a tickerplant is up
(`waitfortype`, which replaces TorQ's `.servers.startupdepcycles`, collapsing `tpconnsleepintv` and
`tpcheckcycles` into `tppollms`/`tpwaittimeout`), takes a handle, and subscribes through
`di.subscriptions.subscribe`. That call defines the subscribed tables at root from the
tickerplant's schemas - **the schema comes from the tickerplant, not a local `database.q`** - and
replays the log up to the message count the tickerplant reported at subscription time.

### Accumulation

The root `upd` is published by `init`, **before** `start[]`, because the replay drives it too
(`di.subscriptions` refuses to replay without a root `upd`). The default reproduces TorQ's `insert`
semantics - append, not upsert-by-key - and handles both payload shapes: a table from the live
feed, a list of columns from the `-11!` replay.

### Surviving a tickerplant bounce

`start[]` also schedules an `rdbresubscribe` timer job, every `resubscribeperiod` seconds. Each
cycle it asks `di.subscriptions.subscribed[]` whether anything is still live and, when nothing is,
resolves a fresh tickerplant handle off `di.servers` and calls `di.subscriptions.resubscribe`.

This exists because reconnection alone is not recovery. When a tickerplant restarts, `di.servers`
reopens the socket on its own 10s retry cycle - but the handle is a **new** one and the tickerplant
holds no subscription against it. Without this job the rdb sits connected and silently receives
nothing for the rest of the day, and `start[]` cannot be re-run to fix it: `di.subscriptions`
rejects a second subscribe on a handle it already holds, so the only recovery would be a process
restart. `di.subscriptions` deliberately keeps the knowledge of *what* was subscribed and leaves
*when* to re-establish it to this module; this job is that decision.

Notes on the shape of it:

- **The check never throws.** `di.timer` defaults `disableonfail` to `1b`, so one escaping error
  would disable the job for the life of the process - silently removing the recovery path exactly
  when the tickerplant is already misbehaving. The body swallows its own errors *and* the job is
  registered with `disableonfail 0b`; both, deliberately.
- **Mode 3**, so the period is measured from the previous *end*. The check makes an IPC round trip,
  and under mode 1 a run slower than the period would have its successor already due on return.
- **No replay and no filter re-application.** `resubscribe` passes `replay 0b`, so nothing is
  re-read from the tickerplant log and the tables are not double-fed; live data arrives already
  filtered by the tickerplant, which is why `applyfilters` is a `start`-only concern.
- **Worst-case recovery latency is `di.servers`' retry period plus `resubscribeperiod`** (~40s on
  the defaults), because the socket has to come back before there is a handle to resubscribe over.
- `subtables` is deliberately not rewritten from the result - it records what `start[]` established,
  and `reload` walks it to decide what the wdb has persisted.

Set `resubscribeenabled` to `0b` only if something else owns reconnection; `status[]` reports the
flag alongside `subscribed` so an operator can tell "the feed is down and something is retrying it"
from "the feed is down and nothing is".

### End of day

`endofday[date]` is what the tickerplant's `` (`endofday;date) `` broadcast lands on. Two modes:

- **standalone** (`reloadenabled` `0b`): capture the column attributes, write every non-ignored root
  table to `hdbdir` for `date` smallest-table-first, clear each, restore the timeout, reapply the
  attributes, drop the rolled date from the partition list, run `postreplay`, and tell every
  connected hdb to reload. A table whose save **fails** is logged at `error` and, on the default
  `onlyclearsaved` `1b`, deliberately left unwiped so the day's rows survive in memory - see
  divergences.
- **wdb-fronted** (`1b`): a wdb owns the writedown, so this rdb saves and clears nothing. It only
  **snapshots** the per-table row counts, pushes eod attributes to any gateways, and returns - the
  data stays live and queryable until the wdb calls `reload[date]`.

`reload[date]` then drops exactly the snapshotted number of rows from each subscribed table,
keeping the new day's ticks that arrived since the roll, reapplies attributes, garbage collects,
and zeroes the snapshot so a second call is a no-op.

Set `reloadenabled` to `1b` **only** when a wdb is actually present - otherwise the writedown is
deferred to a process that never calls back and the day is never persisted. Following TorQ's
fail-fast convention, this is explicit config and is never auto-detected.

### The rdb/wdb handshake

1. the tickerplant broadcasts `` (`endofday;date) `` to both. The rdb (`reloadenabled` `1b`)
   snapshots its row counts and returns. New-day ticks keep landing.
2. the wdb flushes to disk, sorts, moves the partition into the hdb, then calls `` (`reload;date) ``
   on each rdb and reloads each hdb.
3. the rdb's `reload` drops the first `eodtabcount[t]` rows of each table - exactly the prior day
   the wdb just persisted - leaving the new day intact.

### Query-timeout suspension

A `\T` that expires mid-writedown aborts the roll. TorQ disables the timeout **before** the roll
rather than at the top of `endofday`, where changing it mid-execution would be racing the timer it
sets. `start[]` therefore schedules a daily `rdbtimeoutreset` job through the injected timer at
`di.eodtime.getnextroll[] - timeoutlead`.

Restoring it is **mode-dependent**, which matters operationally: the *standalone* `endofday`
restores at the end of its writedown, but the wdb-fronted one does not - it defers the writedown, so
the suspension stands until the wdb calls `reload[date]`. If that call never comes, the query
timeout stays at `0` for the rest of the day. That is TorQ's shape too, and it is one more reason
`reloadenabled` `1b` is only safe when a wdb is genuinely present.

This is the only use `TorQ`'s `rdb.q` makes of `.eodtime`, and it is what makes `di.eodtime` and the
injected timer real dependencies rather than declared ones.

## Design decisions and divergences from TorQ

Recorded so a reviewer can check each one rather than take it on trust.

### Two features nearly cut as "dead", and the evidence they are not

Both were scoped **out** during design and put back after re-reading the source. They are recorded
here rather than in a review comment because the failure mode is recurrence: the reasoning that cut
them was plausible, and a future maintainer will reach the same wrong conclusion from the same
partial evidence.

- **Partition tracking** (`getpartition`, `rdbpartition`, `setpartition`, `rmdtfromgetpar`) was cut
  on the grounds that it serves only gateway routing and has no callers. It has two:
  `code/rdb/rdbstandard.q:2` uses it in `.proc.getattributes`, and `code/dataaccess/getdata.q:31-33`
  reads **both** `.rdb.getpartition[]` and `.rdb.rdbpartition`, gated by `if[(.proc.proctype=`rdb);`
  at line 24 — i.e. the data-access layer runs **in-process on the rdb** and depends on this.
  The original search looked at `code/common/dataaccess.q`, which exists and is a different file in
  a different directory. The lesson worth keeping: *not reachable over IPC* is not *dead*.
- **Subscription filters** (`loadsubfilters`, `applyfilters`) were cut because `.rdb.subcsv` is read
  at `rdb.q:189` and never defined. It is never defined *in that file* — it arrives externally.
  TorQ's own tests exercise the feature in six configurations: five pass
  `-.rdb.subfiltered 1 -.rdb.subcsv <path>` as command-line overrides in `process.csv`
  (`tests/stp/subfile`, `recovery`, `subscription`, `chainedrecovery`, `chainedstp`), and
  `tests/rdb/rdbfilt.csv:4` assigns it directly in a k4unit `before` row. `subfiltered` itself is a
  documented config global at `config/settings/rdb.q:30`. The real defect is only that `subcsv` has
  no default, which this module converts into a named error.

- **`onlyclearsaved` defaults to `1b`, where TorQ defaults it to `0b`.** This is the only *behavioural*
  default changed from legacy (`sortcsv` and `gatewaytypes` also differ, but only by defaulting to
  "not configured" instead of to a TorQ-layout path or proctype), and it is a data-safety choice.
  Under `0b`, a `savedown` that
  throws still clears the table: the day's data is gone, unrecoverable, and the only trace is one
  `error` line in the log - the failure mode is silent loss at exactly the moment the operator most
  needs the rows. Under `1b` the table stays in memory, so it is still queryable and can be written
  down by hand once the cause (a full disk, a bad permission, an unmounted hdb root) is fixed. The
  cost is a table that keeps growing while the save keeps failing - loud, visible in `status[]`, and
  bounded by the process - which is the better failure to have. Set it back to `0b` for
  TorQ-identical behaviour; `test.csv` drives both paths so neither can regress unnoticed.
- **`endofday` is unary.** TorQ's is `endofday[date;processdata]`, but the function body never
  references `processdata` and the shipped `.u.end` alias passes `()!()` for it. `di.pubsub`
  broadcasts one argument, and a binary function would silently become a **projection** rather than
  running - so the roll would never happen and nothing would throw.
- **No pre-sort before savedown.** TorQ sorts the in-memory table (`.sort.sorttab`) and then writes
  it; `di.dbwrite.savedown` writes and then sorts and attributes the partition on disk from the same
  config. Same end state, one pass instead of two.
- **`gc` gates only `reload`'s collection.** `di.dbwrite.savedown` calls `gc[]` unconditionally, so
  `gc:0b` cannot suppress the post-save collect. The flag still gates the collection this module
  owns. Changing that needs a `di.dbwrite` change, which is out of scope here.
- **`upd` appends through `@[`.;t;,;data]`, not a join lambda.** A lambda doing `tab,data` returns a
  new table and silently **drops every column attribute** - measured: a `` `g#sym `` column comes
  back unattributed after one update and stays that way for the rest of the day. The amend form
  modifies in place and maintains the index, which is why TorQ's default `upd` is `insert`.
- **Attributes are captured and reapplied around every wipe.** Measured: both the `0#` clear in
  `endofday` and the `n _` drop in `reload` discard attributes. TorQ's capture/reapply is therefore
  load-bearing, not defensive padding.
- **`endofday` walks `tables[`.]`, `reload` walks `subtables`.** That asymmetry is TorQ's and is
  preserved: a table this process never subscribed to was not fed by the tickerplant, so the wdb has
  not persisted it and dropping rows from it would destroy data nothing else holds.
- **`moveandclear` moves the schema only.** TorQ's shipped version stores `0#` of the table and then
  deletes the original, so the rows do not survive the move. That reads like a bug, but it is a
  publicly-registered api in `code/rdb/apidetails.q` and changing it would change what a shipped
  function does. Preserved deliberately; flagged here rather than silently "fixed".
- **`notifyhdbs` broadcasts through `di.asyncutil.postback`.** TorQ sends a separate **sync** message
  per handle, so the roll waits for every hdb in turn; this serialises the message **once** for the
  whole set and error-traps each send into a success vector. It is genuinely fire-and-forget -
  `postback` flushes the outgoing queue and returns without waiting for a reply - so a slow or hung
  hdb cannot stall the roll. The success vector means "on the wire", not "reloaded". `postback` also
  requires **positive** handles; passing TorQ's `neg abs handles` returns a caught
  `"-4 is not an ipc handle"` failure rather than throwing, i.e. a silent no-notify.

  That "fire-and-forget" depended on a fix in `di.asyncutil`, and the story is worth recording
  because an earlier draft of this document had it backwards. It claimed `postback`'s trailing
  `x(::)` was a **sync** flush the peer answered only after processing the reload, leaving the roll
  blocked without bound. Measurement showed the reverse: `x(::)` on a handle **list** is list
  indexing, so it flushed nothing, and `postback` returned a success vector while the broadcast was
  still sitting in q's outgoing queue — a silent delivery failure reported as success, which is a
  worse failure mode than the hang that was assumed. Fixed with `flushhandles` (a per-handle
  `neg[h][]`); see `di/asyncutil/asyncutil.md`.

  One measurement from that investigation stands on its own account: **`hopen`'s timeout does not
  bound subsequent blocking calls.** A handle opened with `hopen (h;2000)` still blocked the full 5s
  on a peer doing `system"sleep 5"`, so `di.servers`' `HOPENTIMEOUT` covers the connect only.
  Nothing here relies on it bounding anything else, but code that assumes otherwise will hang.
- **TorQ's gmt-rounding term is dropped** from the timeout job's start time. It is
  `{00:01*15*"j"$(`minute$x)%15}(.proc.cp[]-.z.p)`, which is zero outside backtesting, where
  `.proc.cp[]` is overridden to simulate a clock. Porting it without that machinery would be
  copying a no-op.
- **`eval` is kept in `applyfilters`.** It is not decoration around an applied functional select:
  applying the same arguments directly, `?[value t;filters;0b;columns]`, throws `'type`, with and
  without an extra enlist on the constraint (both measured). `moveandclear`'s `eval` *was* removable
  and has been removed - it was building a parse tree only to evaluate it immediately.
- **A re-init preserves runtime state.** Dependencies and config are refreshed on every `init`, but
  the subscribed table list, partition list, eod snapshot and started flag are seeded only on the
  first. Measured before this was guarded: re-applying config between the roll and the wdb's
  `reload[date]` wiped `eodtabcount` and `started`, so `reload` threw its start guard, dropped
  nothing, and left the prior day in memory permanently - silently doubling what the rdb held.
  Same precedent as `di.subscriptions`, which seeds its registry only when fresh.
- **`teardown` reads `.u.end` through a protected `value`.** A shutdown path that calls it twice
  would otherwise die on an unlogged `'.u.end` reading the name the first call deleted.
- **`upd` normalises the same three payload shapes as `di.subscriptions.payloadtable`** - a table, a
  column dict, or a list of columns - deliberately kept in step with the module that drives it during
  replay. A tickerplant that logs a dict is as valid as one that logs a list.
- **`notifyhdbs` dispatches on `postback`'s return type.** It returns a plain boolean vector when the
  broadcast went out and `(booleanvector;errorstring)` when it did not, so taking `first` of it only
  happens to suit both shapes.
- **Removed entirely:** all `.finspace.*` / `.aws.*` code, including `newrdbready` and the
  changeset/sym-file branches. FinSpace is end-of-life.

## TorQ-inherited defects fixed here

Three faults carried over from `code/processes/rdb.q` were found in review and fixed. Recorded
because each is still present in legacy, and because the first is worse than it looks.

- **The query timeout was clobbered by any roll this module did not suspend.** `timeoutreset` and
  `restoretimeout` were both unconditional, and `.z.m.timeout` seeds to `0i`. So `savecycle` —
  which calls `restoretimeout` on *every* standalone roll — wrote that seeded zero over whatever
  `\T` the operator had set, whenever no suspend had preceded it. With `suspendtimeoutonroll` `0b` (no
  suspension job scheduled at all) that is the **first** end of day: measured `\T 30` → one
  `endofday` → `\T 0`, query timeout disabled for the life of the process. The separate
  double-suspend case (a wdb that missed its `reload`, so the next day's `timeoutreset` recaptured
  our own zero as "the original") had the same end state. Both are fixed by a `timeoutsuspended`
  flag: `timeoutreset` refuses to recapture while already suspended, and `restoretimeout` is a
  no-op unless this module actually suspended.
- **`reload` discarded the eod snapshot for tables whose drop failed.** `dropfirstnrows` is
  protected per table, but the snapshot was then zeroed for *every* table regardless, so a failed
  drop left the prior day resident with no record of how much to remove — a retry was a guaranteed
  no-op. `dropfirstnrows` now returns a success flag and only the tables that actually dropped are
  cleared; the rest keep their count and are named in a `warn`.
- **`start[]` set `started` immediately after subscribing**, before `applyfilters`,
  `dbwrite.readcsv`, `setpartition` and the two timer jobs. A throw in any of those left the module
  reporting `started` `1b` with an empty partition list and no scheduled jobs — a half-started rdb
  that `status[]` called healthy. `started` is now set last and means "`start[]` completed".

Two further changes made in the second review pass:

- **A partial `start[]` is now recoverable in place.** Setting `started` last made a half-started rdb
  *honest*, but not *fixable*: the subscription was live, so re-running `start[]` hit
  `di.subscriptions`' rejection of a duplicate subscribe, and recovery meant a process restart.
  `start[]` now reads `di.subscriptions.subscribed[]` **before** subscribing and, when one is already
  live, skips the connect-and-subscribe and resumes from the post-subscribe steps. This works because
  `init` seeds runtime state only on the first call, so `subtables` and `tplogdate` from the failed
  attempt are still there to resume from. A *persistent* fault — an unparseable filter csv, an
  unreadable sortcsv — throws again on the retry, which is correct rather than a loop: the operator
  fixes the file and calls `start[]` once more. `subscribed[]` is read through the same
  `@[…;::;{0b}]` guard `resubscribecheck` and `status[]` use, so a throw is read as "not subscribed"
  and retries the subscribe — the safe way to be wrong.
- **`init` now rejects a `timer` dep with no `deletejobs`.** `teardown` cannot detect this itself, and
  the reason is worth recording because the idiom looks protective and is not. The timer dep's value
  side is dict-typed, so a *missing* key returns a null-shaped **dict** rather than erroring — and
  `@[x;y;z]` is "try `x[y]`, catch with `z`" only when `x` is a **function**. With a dict, q reads
  `@[.z.m.timer[`deletejobs];ids;handler]` as three-argument **amend**: it upserts the job ids into
  that throwaway dict using the error handler as the value, discards the result, and continues.
  Nothing throws, nothing warns, the timer jobs are never deleted, and `teardown` still logs
  *"timeout job removed"* — a false positive. Measured both ways a caller can shape the dep. The
  `init` check is what keeps that line honest.

## Defects in this module fixed in the third review pass

Unlike the section above, none of these came from TorQ - they were introduced here, and each was
reproduced before being fixed.

- **`teardown[]` then `start[]` left an rdb with no root entry points at all.** `installroot` was
  only ever called from `init`, but `teardown` removes what it published and `start[]`'s resume path
  completes happily without it, because `di.subscriptions.subscribed[]` is still true after a
  teardown. Measured: `roots 1111b` → teardown → `0000b` → `start[]` → still `0000b`, with
  `status[]` reporting `started` `1b`. Every subsequent tick would error in the default `.z.ps`, the
  tickerplant's roll broadcast would land nowhere, and nothing would say so - the same
  half-started-but-reported-healthy shape fixed twice already. `start[]` now re-publishes them
  (`installroot` is idempotent, so the ordinary path is unchanged).
- **`pushattributes` could not detect a failed broadcast.** It wrapped `di.asyncutil.postback` in a
  protected apply, but `postback` traps its own send failures and returns
  `(booleanvector;errorstring)` rather than throwing - so the error handler was unreachable and the
  *"pushed eod attributes to N gateway handle(s)"* line fired unconditionally. Measured against a
  dead handle: `postback` returned `` (,0b;"error: 999 is not an ipc handle") `` and the module still
  logged success. It now dispatches on the return shape exactly as `notifyhdbs` does. The gateway
  push is the only signal a gateway gets that this rdb has rolled, so a silent failure there routes
  queries at the wrong process for the rest of the day.
- **`installroot` clobbered a foreign root binding silently**, while `uninstallroot` deliberately
  refuses to *delete* one (`dropifours`). That asymmetry is how a co-hosted process loses its own
  `upd` without a word. Publishing now warns when the name already holds something that is neither
  the function being installed nor the one this module installed last time - the second half of that
  test is what keeps a legitimate re-init quiet when the `upd` config key itself changed.

## Known gaps

- **`di.servers.startup[]` takes no argument** - see "who initialises what". The caller must
  configure `di.servers` with a `connections` list covering the tickerplant and hdb proctypes before
  `start[]` runs, because an rdb cannot hand it a role-specific list.
- **`teardown` does not unsubscribe.** It withdraws the root entry points and the timer jobs, but
  the tickerplant subscription stays live - and this module never stores the handle (`start[]` holds
  it as a local), so it could not release one if it wanted to. The consequence is that between a
  `teardown` and the next `init`/`start`, every message the tickerplant publishes hits a root `upd`
  that is no longer there. A caller shutting the process down should call
  `di.subscriptions.unsubscribe` on the tickerplant handle - or simply exit - rather than leaving an
  rdb torn down but still subscribed.
- **No equivalent of TorQ's `connectonstart` `0b`.** The modular answer is "don't call `start[]`",
  which is not quite the same thing: TorQ's flag still ran `setpartition` off `.proc.cd[]`, so the
  process reported a partition. Here `getpartition[]` stays empty until `start[]` succeeds, and
  `setpartition` is not exported, so a process fed by something other than a tickerplant has no way
  to publish a partition for gateway routing.
- **There is no `di.tickerplant` in kdbx-modules**, so the end-to-end roll is proven against the
  test harness tickerplant in `test_integration.csv` (which publishes through the real `di.pubsub`),
  not against a production one.
- **Module naming.** RFC-0001's decision D1 (a `di.proc.*` / `di.torq.*` / `di.util.*` hierarchy) is
  unresolved and gates all merge work. This module is flat `di.rdb`, matching every module merged or
  up for review. If the hierarchy is adopted it is renamed by the coordinated repo-wide change the
  RFC describes in its phase 5.

### Dependency fixes this module required

Two defects in dependencies had to be fixed before di.rdb worked. Both are done and pushed; they are
recorded here because they are the reason those modules changed, and because di.rdb's behaviour
depends on them.

- **`di.pubsub.callendofperiod` was unary** (`{(neg getallhandles[])@\:(`endofperiod;x)}`) where
  TorQ's producer broadcasts `` (`endofperiod;currentperiod;nextperiod;data) ``
  (`code/common/pubsub.q:19`) and both its subscribers are `{[currp;nextp;data]}`. That failed two
  ways at once, both measured: `callendofperiod[c;n;d]` threw `'rank`, so a caller following TorQ's
  contract could not call it at all; and the one-argument form left this module's **ternary**
  `endofperiod` as a **projection** (type `104h`) - the body never ran and nothing threw or logged.
  Same defect class as the `callendofday` bug PR #118 fixed. Keeping `endofperiod` ternary here
  rather than narrowing it to fit the broken broadcaster was the right call. **Fixed on
  `feature-subscriptions`**; until that merges, an rdb running against `main`'s `di.pubsub` still
  sees a silently no-opped `endofperiod`.
- **`di.dbwrite`, `di.eodtime` and `di.asyncutil` exported no `version`**, which was a blocker
  rather than an advisory: `di.depcheck` classes a missing version as a `failure`, not a `warning`,
  and `di.depcheck.init` signals on any failure - so a process that loaded `di.rdb` and then called
  `di.depcheck.init` **aborted at startup**. No pin avoided it: `checkdepversion` returns the
  "exports no version" failure before comparing numbers, so `"0.0.0"` and `""` failed identically.
  All three were versioned at `0.1.0` (a `VERSION` file plus `version` in the export dict) on this
  branch. Verified:

  ```q
  rdb:use`di.rdb; dc:use`di.depcheck
  dc.init[enlist[`log]!enlist mylog]     / "dependency check complete: 0 failure(s), 0 warning(s)"
  ```

## Module-namespace notes

A source-level bare identifier inside a `use`-loaded module is rewritten at load to the module's
private namespace, so it can never reach root. This module therefore:

- **reads** root tables with a bare `value t` / `tables[`.]`, which fall through to root;
- **writes, clears and drops** through an explicit `@[`.;t;…]`;
- publishes its root entry points with an explicit `@[`.;…]`, or `set[`.u.end;…]` for the dotted
  alias, never a bare assignment.

A q-sql `select`/`where`/`by` **clause** additionally cannot resolve a module-level name at all, so
any config value used in one is hoisted into a function-local first (see `handlesbytypeandname`).
The `from` target is unaffected - only the clauses are.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.rdb
```

`test.csv` is a behavioural suite (**143 asserts**), not just a load-and-export check: it drives real
root tables through `upd`, both end-of-day modes, the wdb `reload` handshake, both partition
sources, both `onlyclearsaved` paths, the subscription-filter loader and its three guard paths, the
save-down manipulation hook and its fallback, the post-replay hook and its fallback, the timeout and
resubscribe jobs, the gateway attribute push in both outcomes, re-init safety, `teardown` and
teardown-then-start, using a capturing logger and a mock timer. It asserts **observable effects** of
`init` rather than "init did not throw" - the latter passes even under a wrong `init` arity, which
returns a projection instead of running.

One caution learned from the third pass: a `fail` row proves only that *something* threw. The
`reload`-before-`start` row had been passing on an unrelated throw (a scenario had left `started`
`1b` and no root `trade` table, so it died in `grabattrs` rather than in `requirestart`), and it
went green or red depending on which scenario happened to run last. It now forces `started` to `0b`
itself, so it tests the guard it names.

`test_integration.csv` (**26 asserts**) stands up a real tickerplant and a real hdb as separate q
processes on OS-assigned ports and drives the whole lifecycle over genuine IPC: `startup`,
`waitfortype`, `subscribe`, log replay, live capture, the tickerplant's `endofday` broadcast,
savedown to disk, and the hdb's `reload[date]`.

It then performs a **real tickerplant bounce**: kill the peer, respawn it on the same port, let
`di.servers` reconnect, and assert the socket comes back carrying *no* subscription before
`resubscribecheck` runs - then that the subscription is re-established and a freshly published row
actually arrives. Removing the `resubscribecheck` call fails exactly two of those asserts
(`RSRESUB` and `RSAFTER>RSBEFORE`) and leaves the other three passing, which is the check that the
scenario is testing the fix rather than restating the setup.

Run it in a **fresh** q session - after `moduletest` the unit rows are still loaded and would be
re-run against dirty module state:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$"<path>/di/rdb";`test_integration.csv]
.m.di.0k4unit.KUrt[]
select from .m.di.0k4unit.KUTR where not ok
```

Both peers are launched with `$QHOME/bin/q`, so **`QHOME` must point at a real q install** - not
just at whatever `q` happens to be on `PATH`. A stale `QHOME` fails the whole suite up front with
`'integration: a peer never reported a port`, which looks like a module fault and is not one.
