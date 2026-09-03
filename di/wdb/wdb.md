# di.wdb

The write database. Subscribes to a tickerplant, replays the day's tickerplant log to recover
intraday state, accumulates live updates in memory, periodically flushes each table to a working
directory partitioned by date, and at end of day sorts that data, moves it into the hdb and tells
the rdb/hdb processes to reload.

Ported from TorQ's `code/processes/wdb.q`, plus `code/wdb/origstartup.q`, `code/wdb/writedown.q`
and the `.save` section of `code/common/dbwriteutils.q`, with defaults from
`config/settings/wdb.q`.

## Scope of this version

**`mode=`saveandsort` and `writedownmode=`default` only.** Both are validated by `init`, which
errors clearly on anything else rather than silently accepting it.

Deliberately deferred, all additive later:

| Deferred | Why it is not here |
|---|---|
| `mode=`save` / `mode=`sort` | The separate sort-worker process split — see design decision 9 |
| `writedownmode=`partbyattr`/`partbyenum`/`partbyfirstchar` | The parted write-down modes, which need `di.merge`'s dispatch |
| IDB tier | No `di.idb` yet; `notifyidbs` is not ported |
| Compression (`.z.zd`) | No compression config in this version |

FinSpace (`.finspace.*`, `.aws.*`) is **removed, not deferred** — it is end-of-life and every
`.finspace.enabled`-gated branch in the legacy source simply does not exist here.

> ⚠️ **The shipped TorQ `config/settings/wdb.q` will not load unmodified.** That file sets
> ``mode:`save``, which selects the deferred sort-worker architecture rather than being a variant
> of ``saveandsort`` — see design decision 9. The fix is one line: ``mode:`saveandsort``.

## Dependencies

### Injected, via `init`

| Key | Required | Contract |
|---|---|---|
| `log` | **yes** | `` `info`warn`error `` — each a binary `{[ctx;msg]}` taking a context symbol and a message string. All three are called. Use `di.log`'s `logdict`. |
| `timer` | **yes** | `addjob` (exposing the `` `custom `` variant) and `deletejobs`. Optionally `cp`, a niladic returning a timestamp — see design decision 10. |
| `handlers` | no | Accepted and stored if supplied, never required and never validated. This version assigns no `.z.*` handler at all. |

### Hard, via `use`

`di.servers`, `di.subscriptions`, `di.dbwrite`, `di.os`, `di.merge` — see `deps.q` for what is
called through each edge.

### Who initialises what

`di.wdb.init` performs **no I/O and initialises no other module.** `di.servers`,
`di.subscriptions` and `di.dbwrite` are shared framework state whose lifecycle belongs to the
caller (`di.torq`, or a test harness); this module only *uses* them, and only from `start[]`
onwards.

In particular **the caller must call `di.dbwrite.init`.** The precise failure is narrower than it
sounds, and the distinction is worth stating because it decides where the fix belongs:

| State of `di.dbwrite` | `sort` behaviour |
|---|---|
| `init` called, `readcsv` **not** called | **Works.** `init` seeds `.z.m.sortconfig:(::)`, and `sort` tests `` (::)~.z.m.sortconfig `` and falls through to its own `defaultparams` (sort by `time` ascending). |
| `init` **never** called | **Throws.** The name `.z.m.sortconfig` does not exist, so `sort` dies on an undefined-name error — and then *every* table fails, not one. |

`di.wdb` deliberately does **not** call `di.dbwrite.init` itself to close that hole, because doing so
would cause a worse failure: `init` **resets** `sortconfig` to `(::)`, so calling it from `start`
would silently wipe a sort config the caller had already loaded with `readcsv` and downgrade every
table to sort-by-time. The caller owns that lifecycle.

What `di.wdb` does instead is protect each per-table sort, so a caller who forgot `di.dbwrite.init`
gets a loud error per table and the day's data still reaches the hdb unsorted — recoverable by
re-sorting in place — rather than being stranded in the working directory.

## Initialisation

`init` takes **exactly one dictionary**, carrying dependency and config keys side by side — the
call shape `di.torq` wires every module with.

```q
wdb:use`di.wdb
logging:use`di.log
timer:use`di.timer

timer.init[()!()]
timerdep:`addjob`deletejobs!(timer`addjob;timer`deletejobs)

wdb.init[logging.logdict,`timer`hdbdir`savedir!(timerdep;`:/data/hdb;`:/data/wdbhdb)]
```

> ⚠️ Build the deps as **one multi-key dict**. Joining `di.log`'s `logdict` to a chain of
> single-key dicts (`` logdict,enlist[`timer]!enlist timerdep ``) throws `'mismatch`, because both
> value sides are tables.

## Configuration

Every key is optional and falls back to the default below.

| Key | Default | Meaning |
|---|---|---|
| `savedir` | `` `:temphdb `` | Working directory data is flushed to intraday |
| `hdbdir` | `` `:hdb `` | The hdb root the day is moved into, and whose sym file enumerates |
| `sortcsv` | `` ` `` | Sort/attribute config handed to `di.dbwrite.readcsv`; unset uses di.dbwrite's defaults |
| `numrows` | `100000` | Default in-memory row limit before a table is flushed |
| `numtab` | `` `quote`trade!10000 50000 `` | Per-table row limit overrides |
| `replaynumrows` | *falls back to `numrows`* | Row limit applied during the log replay |
| `replaynumtab` | *falls back to `numtab`* | Per-table replay limit overrides |
| `partitiontype` | `` `date `` | Partition domain |
| `immediate` | `0b` | Flush on every timer tick regardless of row counts |
| `settimer` | `0D00:00:10` | Interval of the periodic write-down job |
| `mode` | `` `saveandsort `` | Validated — only `` `saveandsort `` is accepted |
| `writedownmode` | `` `default `` | Validated — only `` `default `` is accepted |
| `subtabs` / `subsyms` | `` ` `` / `` ` `` | Tables and syms to subscribe for (`` ` `` = all) |
| `schema` | `1b` | Ask the tickerplant to define the table schemas |
| `replay` | `1b` | Replay the tickerplant log on startup |
| `ignorelist` | `` `heartbeat`logmsg `` | Tables never written down |
| `tickerplanttypes` | `` `tickerplant `` | Proctypes to wait for and subscribe to |
| `tpconnsleepintv` | `10` | Seconds between tickerplant connection attempts |
| `tpcheckcycles` | `0W` | Attempts before giving up (`0W` = retry effectively forever) |
| `hdbtypes` / `rdbtypes` | `` `hdb `` / `` `rdb `` | Proctypes to notify at reload |
| `gatewaytypes` | `` `$() `` | Gateways told when the reload starts and ends |
| `reloadorder` | `` `hdb`rdb `` | Order the reload is issued in |
| `permitreload` | `1b` | Trigger downstream reloads at end of day |
| `gc` | `1b` | Garbage collect after each save and each sort |
| `eodwaittime` | `0D00:00:10` | How long to wait for reload replies before releasing waiters |
| `upd` | built-in | Root `upd`; override for bespoke ingest semantics |
| `savedownmanipulation` | `()!()` | `tablename!function` applied before a table is written |
| `postreplay` | `{[d;p] }` | Called after every table is on disk |

## `requireinit` guard

Every exported function except `init` calls `requireinit` first and throws

```
di.wdb: <function>: init must be called before any other function
```

if `init` has not run. There is no default logger, so without this an early call would die with a
bare `'type`.

## Exported functions

### `init[deps]`
Wires the injected dependencies and config, then publishes the root entry points. Idempotent — a
re-init refreshes config but does **not** wipe live runtime state (partition, subscription,
started flag).

### `start[]`
The runtime bootstrap, split from `init` deliberately: `init` is pure configuration and unit-testable
with no sockets; everything here needs the other modules wired. Loads the sort config, clears stale
working-partition data, installs the replay `upd`, opens connections, waits for a tickerplant,
subscribes and replays, primes the partition, re-checks the replay limits, restores the live `upd`,
and starts the write-down timer.

### `teardown[]`
Withdraws the root entry points and deletes the timer jobs. Module state is left intact so a
shutdown path can still inspect it. Safe to call twice.

### `endofday[date]`
**Unary.** Flushes every table, sorts the partitions, moves them into the hdb, runs `postreplay`,
triggers the reloads, and primes the next partition. See design decision 2.

### `endofperiod[currentperiod;nextperiod;data]`
**Ternary.** The intraday period roll. Log-only, as legacy is.

### `status[]`
A snapshot of how the wdb is wired and what it holds: `started`, `subscribed`, `mode`,
`writedownmode`, `savedir`, `hdbdir`, `partition`, `subtables`, `tabsizes`, `permitreload`, `gc`,
`ignorelist`.

### `version`
The module version string, read from the `VERSION` file. Stays exported — `di.depcheck` resolves a
dependency's version from the export dict.

### `getapimeta[]`
One row per callable export, for `di.torq` to register with `di.api`.

## Root entry points

`init` publishes these into the **root** namespace, and `teardown` withdraws only the ones still
bound to this module's functions:

| Name | Why it must be at root |
|---|---|
| `upd` | Driven by the live feed and by `di.subscriptions`' `-11!` replay |
| `endofday` | The tickerplant's `` (`endofday;date) `` broadcast |
| `endofperiod` | The tickerplant's intraday period roll |
| `.u.end` | TorQ's alias for `endofday` |
| `wdbreloadhandler` | The reload **reply** callback — see design decision 4 |

If a name is already bound to something this module did not install, it is replaced and a warning
is logged; `teardown` will not give the previous binding back.

## Design decisions

1. **`di.wdb` owns the `.save` namespace, and a failed manipulation keeps the original data.**
   `dbwriteutils.q`'s `.save` section (`savedownmanipulation`, `manipulate`, `postreplay`) is
   genuinely *not* in `di.dbwrite`, despite the modularisation plan describing di.dbwrite's scope as
   "the `.save` namespace". That is a confirmed contradiction between the plan and what shipped, so
   this module owns it. `manipulate` reproduces legacy's graceful degradation exactly: if a
   registered manipulation throws, the error is logged and the **original unmanipulated** rows are
   written. Losing a day's data because a user hook threw is worse than saving it unmanipulated.

2. **`endofday` is unary.** TorQ's is `endofday[pt;processdata]`, but `processdata` is never
   referenced in the body and the shipped `.u.end` alias passes `()!()` for it.
   `di.pubsub.callendofday` broadcasts `` (`endofday;d) `` — one argument — so a binary function
   would silently become a *projection* and the roll would never happen.

3. **The intraday write path is hand-rolled, not `di.dbwrite.savedown`.** `savedown` enumerates with
   `.Q.en[dir;…]` and writes under `.Q.par[dir;…]` — the *same* `dir`. The wdb must enumerate
   against the **hdb** sym file while writing to a **separate** working directory, so it cannot be
   used. `di.dbwrite` is used only for `readcsv` and the end-of-day `sort`.

4. **The reload callback is published at root as `wdbreloadhandler`.** A reloading process runs the
   lambda this module sends it and answers with an async `(name;args)` message, which the default
   `.z.ps` evaluates in **root**. Module functions live in private `.z.m` and cannot be reached by
   name, so without a root binding every reply would die on an unresolved name and the roll would
   hang until the timeout. Legacy names it `.wdb.handler`; a plain root name is used here because
   this module authors the lambda that names it, and a `.wdb.*` namespace is what the migration
   moves away from.

5. **`movetohdb` takes the hdb root from config, not by string-slicing.** Legacy locates it as
   `-10 _ hw`, dropping exactly the ten characters of a *date* partition, which silently breaks for
   `` `month `` or `` `year `` partitiontypes.

6. **`initmissingtables` is kept; `notifyidbs` is dropped.** Legacy reaches both through
   `idbreload`. The IDB *notification* goes with the deferred IDB tier, but the partition
   *priming* is real default-mode on-disk behaviour that leaves a partition complete and queryable
   rather than ragged, so it still runs at end of day and after an intraday save.

7. **A gateway notification failure no longer aborts the roll.** Legacy wraps each `informgateway`
   send in a protected apply that **rethrows**, so one unreachable gateway aborts the end of day —
   after the data is already on disk. The rethrow is deliberately dropped: the failure is logged and
   the roll continues.

8. **`replaymaxrowcheck` forces the save.** Legacy passes `forcesave 0b`, so `savetables` re-checks
   the table against the **live** `maxrows` and can silently refuse the flush that was just logged
   as "flushing table to disk…". That only bites when `replaynumrows` is below `numrows` — odd but
   legal — and it is exactly the kind of silent gap this project makes explicit. The decision to
   flush was taken against the replay limit, so re-taking it against a different threshold is
   incoherent. Equivalent to legacy whenever `replaynumrows >= numrows`, the normal case.

9. **``mode=`save`` is rejected, not silently treated as `` `saveandsort ``.** This is the one
   scope decision with real architectural weight, so the trace matters. `wdb.q:93-94` sets

   ```q
   saveenabled: any `save`saveandsort in mode;
   sortenabled: any `sort`saveandsort in mode;
   ```

   so ``mode:`save`` gives `sortenabled:0b`, and `endofday` (`wdb.q:218-221`) dispatches on exactly
   that flag to `informsortandreload` rather than `endofdaysort` — shipping
   `` (`.wdb.endofdaysort;…) `` to a separate `` `sort `` process **over IPC** (`wdb.q:513-525`).
   That is the sort-worker split this version defers. Accepting `` `save `` would run the sort
   in-process that the operator deliberately delegated elsewhere, **double-sorting** whenever a sort
   process also exists. Hence a loud rejection.

   Consequence: the shipped `config/settings/wdb.q` describes that deferred architecture and will
   not load unmodified. It is therefore also not ground truth for this module's defaults — `mode`
   takes the code-level default here, as does `tickerplanttypes` (the config's
   `` `segmentedtickerplant `` is site-specific).

10. **The `timer` dep requires `addjob`/`deletejobs`; `cp` is optional.** `di.timer` exports `setcp`
    but no `cp` **getter**, so requiring `cp` would reject every caller wiring a timer dep from
    di.timer's own exports. It is honoured when supplied — that is legacy's `.proc.cp[]`
    simulated-clock hook — and falls back to `.z.p` otherwise.

    > Note: `di.depcheck`'s own core-contract table *does* list `cp` for `di.timer`, so
    > `di.depcheck.init` currently reports `di.timer is missing required contract key(s): cp`. That
    > is a pre-existing `di.timer`↔`di.depcheck` mismatch — it reproduces with `di.wdb` not loaded
    > at all — and is out of this module's scope.

11. **`normpath` replicates `.os.pthq` locally.** `pthq` normalises OS-native paths to forward-slash
    kdb form, preserving the leading colon. `di.os.topath` goes the **opposite** way (kdb form →
    OS-native, stripping the colon) and cannot substitute. Legacy's `pthq` has exactly one caller in
    the entire TorQ repo, so growing di.os's public surface for a single wdb-only need was the worse
    trade. Identity on Linux; it exists for Windows configs written with backslashes.

12. **`replaynumrows`/`replaynumtab` fall back to the resolved `numrows`/`numtab`.** Legacy leaves
    both entirely undefined except via config layering — `config/settings/wdb.q` is their only
    definition anywhere in the codebase — which is an inconsistency rather than a design. A caller
    who sets `numrows` and leaves `replaynumrows` alone now gets their value on both paths.

13. **`tpcheckcycles=0W` is clamped rather than multiplied.** `di.servers.waitfortype` takes a
    millisecond budget where legacy loops a cycle count, and `0W` — legacy's **default** — overflows
    a long when multiplied out, coming back *negative*, which would make the wait return immediately
    and abandon a tickerplant that was merely slow to start. The cycle count is capped first.

14. **`status[]` replaces `notpconnected`.** Legacy's `notpconnected` has no caller anywhere in
    TorQ, and `di.subscriptions.subscribed[]` now answers the underlying question authoritatively. A
    status dict is more useful operationally than a bare boolean predicate.

15. **The async reload sends the function VALUE plus its arguments, not the result of calling it.**
    `asyncreload` puts the triple `` (remotereload;d;ptype) `` on the wire, which the remote's default
    `.z.ps` applies as `remotereload[d;ptype]` — the same shape legacy sends through its `sendfunc`
    (`wdb.q:476,486`). Writing `remotereload[d;ptype]` in the send instead **calls it in this
    process**, against this process's own root `reload` and its own `.z.w`, and puts the *result* on
    the wire rather than the work. Verified against a genuine second process: with the triple the
    peer reloads and nothing leaks locally; with the local call the peer never reloads at all. An
    in-process check cannot see this — kdb+ resolves a connection to your own listening port to the
    self-handle, which evaluates the message locally either way — so the proof lives in
    `test_integration.csv`.

16. **`flushend` releases waiting processes by handle vector, not by `key` of the keyed table.**
    Legacy writes `` each key reloadsummary ``. `key` on a **keyed table** returns a *table*, so that
    iterates one-column dictionaries (`` (,`handle)!,4i ``) rather than handles: `neg[dict]` is just a
    dict with a negated value, the send then indexes that dict instead of writing to a socket, and
    the enclosing protected apply swallows the mismatch. The release notified **nobody** while still
    logging that it had. `` exec handle from `` gives the int vector the sends actually need.

17. **`tablelist` intersects the `tabsizes` ordering with what is actually at root.** `tabsizes` is
    internal bookkeeping that outlives the tables it describes. Legacy builds the list as
    `` sorted union tables[`.] ``, so a table written down earlier and since dropped from root is
    still handed to `savetables`, whose `` value t `` throws `` '<tablename> `` — taking the **whole
    end of day** down and leaving the day's other tables unwritten. `tabsizes` drives the *order*
    here, not membership.

18. **`init` rejects `savedir` equal to `hdbdir`.** It is never a valid configuration — `savedir` is
    the intraday staging area the end-of-day move drains into `hdbdir` — and the failure it causes is
    quiet and recurring rather than loud: `savetables` writes straight into the hdb, `movetohdb` then
    finds every table present in both source and destination and aborts, logging *"present in both"*
    on **every** roll for the life of the process. The data lands in the right place, so nothing
    looks broken until somebody reads the log.

19. **A roll with nothing to write does not shell out.** With no root tables — or every table on the
    `ignorelist` — no working partition exists. Attempting the move anyway makes `di.os` shell out to
    a doomed `mv`, whose OS error text reaches **stderr as raw output** before this module can catch
    it. `movetohdb` returns early with an info line instead.

20. **A missing hdb sym file is normal, not an error.** `.Q.en` creates it on the first write, so an
    hdb that has never been written to legitimately has none. Legacy's unguarded `load` logs a
    failure at **error** level on every clean no-data roll — precisely the noise that teaches an
    operator to stop reading the log.

## Usage example

```q
wdb:use`di.wdb
logging:use`di.log
timer:use`di.timer
dbwrite:use`di.dbwrite

/ the caller owns the lifecycle of the shared framework modules
timer.init[()!()]
dbwrite.init[logging.logdict]
/ ... di.servers and di.subscriptions likewise ...

timerdep:`addjob`deletejobs!(timer`addjob;timer`deletejobs)

wdb.init[logging.logdict,
  `timer`hdbdir`savedir`numrows`settimer!(timerdep;`:/data/hdb;`:/data/wdbhdb;100000;0D00:00:10)]

wdb.start[]                     / connect, subscribe, replay, start the timer
wdb.status[]                    / how it is wired and what it holds
/ endofday arrives from the tickerplant; call it directly to force a roll:
wdb.endofday[.z.D]
wdb.teardown[]
```

## Running tests

```bash
export QPATH=/path/to/kdbx-modules
q
```

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.wdb
```

The suite wires a capturing logger and a mock timer, and drives real on-disk partitions under a
temporary directory. Every fixture lives under `.t` deliberately: `endofday` walks `` tables[`.] ``,
so a root-level fixture table would be written into the hdb.

### Integration suite

`test_integration.csv` drives the end-of-day reload against a **real second q process**. It is not
loaded by `moduletest` (which reads `test.csv` only), so run it explicitly, in a **fresh** session:

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf hsym`$"<repo>/di/wdb/test_integration.csv"
.m.di.0k4unit.KUrt[]
```

It exists because kdb+ resolves a connection to your own listening port to the self-handle, which
evaluates a sent message locally — so an in-process check cannot tell work done on the remote from
work done here, which is precisely what the async reload path turns on (design decision 15).
