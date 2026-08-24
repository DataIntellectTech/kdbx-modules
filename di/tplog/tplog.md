# di.tplog

Tickerplant log utilities: create/open a log, append to it, roll to the next day, replay it on
startup, and repair a corrupt one. It is the modular replacement for the inline log handling in
TorQ's `code/processes/tickerplant.q` (`.u.ld` / `.u.endofday`) and the recovery code in
`code/common/tplogutils.q`, folded into one module.

Self-contained: no hard `use` dependencies (built on base q). Its one runtime dependency, a logger,
is injected via `init`.

## Import and init

```q
tp:use`di.tplog

/ with di.log (its logdict is already shaped as `log!(`info`warn`error!...))
logging:use`di.log
tp.init[logging`logdict]

/ or a hand-rolled logger
mylog:`info`warn`error!(
  {[c;m] -1 string[c],": ",m;};
  {[c;m] -1 string[c],": ",m;};
  {[c;m] -2 string[c],": ",m;})
tp.init[enlist[`log]!enlist mylog]
```

`init` must be called before anything else — there is no default logger. It validates the `log`
dependency and signals immediately if it is missing or malformed.

## The upd replay contract

`open`, `replay`, and `replayupto` restore state with `-11!`, which runs the root-level `upd` for
each stored `(`upd;t;x)` message. A caller must define a root `upd` before calling them: a
tickerplant publishes its `upd` at root during init, before opening the log; a subscriber does the
same before replaying.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `logname` | `[dir;date]` → `` `:<dir>/tp<date> `` | Log-file handle for an absolute-path `dir` string and a `date`, one file per date. |
| `open` | `[dir;date]` → `(handle;count)` | Open the log, creating it if absent (count `0`). If present, fail fast when corrupt, else replay through the root `upd` once and return the message count. |
| `write` | `[handle;msg]` → `` (::) `` | Append one message (typically `` (`upd;t;x) ``) to an open handle. |
| `roll` | `[handle;dir;olddate]` → `(handle;count)` | Close `handle` and open the `olddate+1` log. |
| `replay` | `[logfile]` → `count` | Replay through the root `upd`, repairing first if corrupt. |
| `replayupto` | `[logfile;n]` → `count` | Replay only the first `n` messages (repair-aware) — a subscriber replays up to the point it subscribed, so live messages logged after that are not processed twice. |
| `check` | `[logfile]` → `logfile` \| `` `<logfile>.good `` | Return `logfile` if usable, else a repaired copy. |
| `repair` | `[logfile]` → `` `<logfile>.good `` | Scan the log and write every message that still deserialises to `` `<logfile>.good ``. |

`getapimeta[]` and `version` are also exported, as metadata for `di.torq` / `di.depcheck`.

## Injectable dependencies

| Injectable | Keys | Signature |
|---|---|---|
| `log` | `` `info`warn`error `` | `{[ctx;msg]}` — context symbol, message string. Extra levels (e.g. di.log's six) are accepted and ignored. |

No config keys beyond `log`, and no hard `use` dependencies (`deps.q` is empty).

## Design notes

The module registers no `.z.*` handlers — it is called directly by the tickerplant
(`open`/`write`/`roll`) and by subscribers on startup (`replay`/`replayupto`), so it sits outside the
`di.handlers` observer/decider model.

Corruption handling was written against measured KDB-X `-11!` behaviour, which differs from classic
kdb+:

- `-11!(-2;logfile)` counts a clean log without running `upd`, and throws on any corruption — it does
  not return the classic `(goodcount;bytes)` pair. Corruption is detected by trapping that throw
  (`corruptp`); `open` counts with it before replaying, so a corrupt log fails fast before any partial
  replay.
- `-11!(-1;logfile)` counts but runs `upd`, so it is not used for detection.

`replay`/`replayupto` check with the non-executing `corruptp`, repair to a `.good` file if needed (a
byte-scan that never calls `upd`), then replay once, so no message is processed twice.

`replay`/`replayupto`/`check`/`repair` validate that `logfile` is *a* symbol, but a symbol alone
doesn't mean it names a real log file — a directory path is a valid symbol too. Before the `isdir`
guard was added, a directory handed to any of these was misreported as merely "corrupt" (`corruptp`
traps whatever `-11!(-2;…)` throws on a directory, indistinguishable from real corruption) and
`repair` would then silently write `<dir>/.good` *inside* that directory rather than raising a clear
error. Found via `di.segmentedtp`'s own stress-testing (a test script's unguarded glob for a
not-yet-existing `.good` file legitimately resolved to a bare directory path and fed it to `replay`)
— not a `di.segmentedtp` exposure, since that module only ever calls in with paths it computed itself,
but a real gap in this module regardless. Fixed: `replay`/`replayupto`/`check`/`repair` now reject a
directory path outright (`isdir`, checked via `type key` — 11h for a directory's listing, -11h for a
real file's own name back, 0h for nonexistent) with a "logfile is a directory, not a file" error,
before `corruptp` ever gets a chance to mischaracterise it.

## Known limitations

- `repair` is tuned to the `(`upd;`trade;…)` message shape (inherited from `tplogutils`); other tables
  are recovered only if their messages share that prefix. Detection (`corruptp`, `open`'s fail-fast) is
  schema-agnostic — only the repair byte-scan is trade-specific.
- `check` takes only the logfile. TorQ's `lastmsgtoreplay` argument is dropped: its skip-repair
  optimisation needed `-11!(-2)`'s partial good-count, which this build does not provide.
- The filename convention is fixed (`<dir>/tp<date>`, one log per date).

## Testing

`test.csv` / `test.q` (k4unit, 30 checks) cover the metadata/version contract, strict `init`
validation, public-input validation, the open/write/roll lifecycle, fail-fast `open` on a corrupt log,
`replay` recovering a corrupt log while processing each message exactly once, `replayupto`,
`check`/`repair` on clean and corrupt logs (asserting the warning via a capturing logger), and
`replay`/`replayupto`/`check`/`repair` all rejecting a directory path instead of mistaking it for a
corrupt log.

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.tplog
```
