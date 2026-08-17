# di.tplog

Tickerplant **log lifecycle** — create/open, append, roll, and replay-on-startup — together with
best-effort **corruption check/repair**. It is the modular replacement for TorQ's inline log handling
in `TorQ/code/processes/tickerplant.q` (`.u.ld` / `.u.endofday`) plus the recovery utilities in
`TorQ/code/common/tplogutils.q`, folded into a single import surface.

The module is **self-contained**: it has no hard `use` dependencies and is built on base q only. Its
one runtime dependency, a logger, is **injected** via `init`.

## Import and init

```q
tp:use`di.tplog

/ using di.log (its logdict is pre-shaped as `log!(`info`warn`error!...))
logging:use`di.log
tp.init[logging`logdict]

/ or a hand-rolled binary logger
mylog:`info`warn`error!(
  {[c;m] -1 string[c],": ",m;};
  {[c;m] -1 string[c],": ",m;};
  {[c;m] -2 string[c],": ",m;})
tp.init[enlist[`log]!enlist mylog]
```

`init` **must** be called before any other function — there is no default logger. It validates the
`log` dependency strictly and errors immediately if it is missing or malformed (no silent fallback).

## The `upd` replay contract

`open`, `replay`, and `replayupto` restore state by running `-11!` over the log, which executes the
**root-level `upd`** for each stored `(`upd;t;x)` message. **A caller must define a root `upd` before
calling any of them.** A tickerplant publishes its `upd` at root during init, ahead of opening the
log; an RDB/subscriber does the same before replaying.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `logname` | `[dir;date]` → `` `:<dir>/tp<date> `` | Build the log-file handle for an absolute-path `dir` string and a `date` (one file per date). |
| `open` | `[dir;date]` → `(handle;count)` | Open (creating if absent) the log. Absent → empty log, count `0`. Present → **fail fast** if corrupt, else replay through the root `upd` once and return the message count. |
| `write` | `[handle;msg]` → `` (::) `` | Append one message (typically `` (`upd;t;x) ``) to an open handle. |
| `roll` | `[handle;dir;olddate]` → `(handle;count)` | Close `handle` and open (create) the `olddate+1` log. |
| `replay` | `[logfile]` → `count` | Replay through the root `upd`, **repairing first if corrupt** (recovers rather than failing). Returns the replayed count. |
| `replayupto` | `[logfile;n]` → `count` | Replay only the **first `n`** messages (repair-aware). For a subscriber replaying exactly its pre-subscription rowcount so later live-and-logged messages are not double-processed. |
| `check` | `[logfile;lastmsgtoreplay]` → `logfile` \| `` `<logfile>.good `` | Return `logfile` if usable as-is, else a repaired `` `<logfile>.good ``. |
| `repair` | `[logfile]` → `` `<logfile>.good `` | Scan a corrupt log in chunks and write every recoverable message to `` `<logfile>.good ``. |

`getapimeta[]` and `version` are also exported, as module metadata for `di.torq` / `di.depcheck` — not
callable API.

## Injectable dependencies

| Injectable | Required keys | Signature |
|---|---|---|
| `log` (required) | `` `info`warn`error `` | `{[ctx;msg]}` — context symbol, message string. Extra levels (e.g. di.log's six) are accepted and ignored. |

No config keys beyond `log` are accepted. There are **no hard `use` dependencies** (`deps.q` is empty).

## Design notes

### Observer/decider classification

`di.tplog` registers **no `.z.*` handlers** — it is a pure log-file utility invoked directly by the
tickerplant (`open`/`write`/`roll`) and by subscribers on startup (`replay`/`replayupto`). It therefore
sits outside the observer/decider handler model entirely and never touches `di.handlers`.

### KDB-X `-11!` behaviour (verified on the installed build)

This module's corruption handling was rebuilt against **measured** KDB-X behaviour, which diverges from
classic kdb+ (and from assumptions in the TorqX POC):

- **`-11!(-2;logfile)` is the non-executing primitive.** On a clean log it returns the message count
  **without running `upd`**; on **any** corruption it **throws** (it does *not* return a
  `(goodcount;bytes)` 2-list as classic kdb+ does). Corruption is therefore detected by trapping that
  throw (`corruptp`), and `open` counts with `-11!(-2)` *before* replaying, so a corrupt log fails fast
  before any partial replay mutates state.
- **`-11!(-1;logfile)` also counts but *executes* `upd`** — so it is unsafe for detection and is not
  used here (using it caused an early double-replay bug).
- **No double-processing:** `replay`/`replayupto` detect corruption with the non-executing `corruptp`,
  repair to a `.good` file (a byte-scan that never calls `upd`), then replay the good log exactly once.
  A naive trap-and-retry would partially replay before throwing and then replay again.

### Known gaps / limitations

- **`repair`'s message signature is hardcoded to the `` (`upd;`trade;…) `` shape** (inherited from
  TorQ `tplogutils`). Logs of other tables are recovered only if their messages share that prefix. The
  corruption *detection* (`corruptp`, and `open`'s fail-fast) is schema-agnostic; only the *repair*
  byte-scan is `trade`-specific. Generalising the signature is future work.
- **`check`'s `lastmsgtoreplay` optimisation is not available on KDB-X.** In classic TorQ, `check` could
  skip repair when a corrupt log still held enough good messages for the caller's needs. That relied on
  `-11!(-2)` returning a partial good-count, which this build does not do (it throws). The parameter is
  retained for signature compatibility, but `check` now conservatively repairs on any corruption.
- **Filename convention is fixed** (`<dir>/tp<date>`, one log per date). Sharing a directory between
  multiple logical logs would need a prefix parameter on `logname`.

## Testing

`test.csv` / `test.q` (k4unit) cover: version/`getapimeta` metadata, strict `init` dependency
validation (a `fail` row per guard), `logname`, the open/write/roll lifecycle, fail-fast `open` on a
corrupt log, `replay` repairing a corrupt log while processing each recovered message exactly once (the
double-processing regression), `replayupto` replaying only the first `n`, and `check`/`repair` on clean
and corrupt logs (asserting the warning is logged via a capturing logger). Run with:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.tplog
```
