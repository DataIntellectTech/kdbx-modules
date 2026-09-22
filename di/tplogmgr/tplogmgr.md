# di.tplogmgr

Tickerplant **log lifecycle**: create/open, replay-on-startup, append, and roll. These
pieces do not exist as a module in `kdbx-modules` — `di.tplog` there covers only
corruption *check/repair*, which this module re-exports so consumers have a single
import surface. Ported from the inline log handling in
`TorQ/code/processes/tickerplant.q` (`.u.ld` / `.u.endofday`), which is where classic
TorQ keeps it (its `u.q` is pure pubsub).

Stateless utility, like `di.tplog` — every function takes its state (dir, date,
handle) as arguments; there is no `init` and no module-local state.

## The `upd` replay contract

`open` and `replay` restore state by running `-11!` over the log, which executes the
**root-level `upd`** for each stored `(`upd;t;x)` message. **A caller must define a
root `upd` before calling either.** `di.torq.proc.tickerplant` publishes its `upd` at root during
`init`, before it opens the log; the RDB will do the same before calling `replay`.

## Functions

- `logname[dir;date]` — the log filename handle for an absolute-path `dir` string and a
  `date`, one file per date: `<dir>/tp<date>` (e.g. `` `:/var/tplog/tp2026.07.13 ``).
- `open[dir;date]` → `(handle;count)`. Creates an empty log if absent (count `0`);
  otherwise replays it through the root `upd` and returns the message count. Corruption
  is detected up front with the **non-executing** `-11!(-2;…)` streaming count, so a
  corrupt log is a **fail-fast error** *before* any partial replay mutates state — a
  tickerplant must not silently continue on a bad log.
- `write[h;msg]` — append one message (typically `(`upd;t;x)`) to an open handle.
- `roll[h;dir;olddate]` → `(handle;count)`. Closes `h` and opens (creating) the
  `olddate+1` log.
- `replay[logfile]` → count. Replays through the root `upd`, **repairing first if
  corrupt** (unlike `open`, which fails). Corruption is checked with the non-executing
  `-11!(-2;…)` first, so good messages before the corruption point are never replayed
  twice — a naive `@[-11!;logfile;{…repair…}]` would partially replay before throwing
  and then replay again, double-processing. For consumers (e.g. RDB startup) that should
  recover rather than abort.
- `replayupto[logfile;n]` → count. Replays only the **first `n`** messages through the root
  `upd`, repairing first if corrupt (as `replay` does). This is what a *subscriber* uses on
  startup: it replays exactly the messages the tickerplant had logged at the instant it
  subscribed, so live messages arriving after that — which are **also** delivered over the
  feed — are not double-processed. Whole-file `replay` would reprocess them.

  Two properties consumers rely on:

  - **`n >= good-count` replays the whole (repaired) log.** So a caller may pass a sentinel
    rather than a real count — `di.torq.proc.segmentedtp` reports `0W` for a closed segment,
    meaning "replay all of it", and needs no special case here.
  - **It is repair-aware, where `open` is fail-fast.** A corrupt log is repaired and replayed
    rather than aborting the process, because a subscriber should recover where a tickerplant
    must not silently continue.

  One call per file: a segmented tickerplant reports several `(msgcount;logfile)` pairs, and
  the loop over them belongs in the caller (`di.subscriptions`), not here.
- `check[logfile;lastmsgtoreplay]` / `repair[logfile]` — re-exported from
  `di.tplog`.

## Dependency

`di.tplog` (kdbx-modules), called per-invocation via `use` (idempotent, so cheap,
and it sidesteps module-local dependency-variable resolution). No injected DI deps.

Declared in `deps.toml` as well as here. Without a manifest `di.torq.depcheck` skips the
module entirely rather than failing it (`depcheck.md`), so this edge would silently drop out
of the transitive dependency graph for every consumer.

## Known gaps

- `di.tplog`' message signature is **hardcoded to the `trade` schema** upstream;
  `check`/`repair` (and therefore `replay`'s repair path) inherit that limitation until
  that module is generalised. `open`'s own corruption *detection* uses `-11!(-2;…)` and
  is schema-agnostic; only the *repair* path is trade-specific.
- Filename convention is fixed (`tp<date>`); if multiple logical logs ever need to share
  a directory this would need a `logname` prefix parameter.

## Testing

`test.csv`/`test.q` (k4unit) cover: fresh open (count 0) + write + reopen-replays-count,
replay restoring state through the root `upd`, roll creating the next day's file,
fail-fast on a corrupt log (`open`), replay repairing a corrupt log while processing
each good message exactly once (the double-processing regression), and `check` returning
a clean log unchanged. Run with:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.tplogmgr
```
