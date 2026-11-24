# di.torq.proc.filealerter

The file-alerter process type: polls directories for files named in a csv, runs an app-defined function on
each new or changed file, records every file it tried in a splayed table on disk, and moves the files whose
functions passed. Started by `di.torq` through the same `init[config;deps]` convention as every other
built-in proctype.

Ported from `TorQ/code/processes/filealerter.q` and `TorQ/code/filealerter/pcapdecoder.q`.

## Dependencies

- **Injected** (from di.torq): `log`, `timer`, `servers`. `init` errors naming the missing one.
- **`use`-imported**: `di.util.cfg` (settings coercion and path roots) and `di.os` (copying an old flat
  processed table aside); declared in `deps.toml`.

Unix only: the scan shells out to `find` and `md5sum`, and `init` errors on Windows.

## Loading

`di.torq` starts it for any process.csv row with proctype `filealerter`:

```
host,port,proctype,procname,startwithall
localhost,5313,filealerter,filealerter1,1
```

Standalone, with mock or real dependencies:

```q
fa:use`di.torq.proc.filealerter
logging:use`di.util.log
fa.init[`inputcsv`alreadyprocessed!("/data/fa.csv";"/data/faprocessed");`log`timer`servers!(logging`logdict`log;timerdep;serversdep)]
```

## Exports

| Function | Signature | Description |
|---|---|---|
| `init` | `[config;deps]` | Reads config, loads the csv and the processed table, registers the poll timer job (once per process) and starts connections to `tickerplanttype` plus any configured `connections` |
| `run` | `[]` | One poll: TorQ's `FArun` |
| `loadcsv` | `[]` | Re-read `inputcsv`, to pick up edits without a restart |
| `sendtotickerplant` | `[tptype;t;x]` | Sync `.u.upd[t;x]` on a tickerplant of type `tptype`; logs an error and returns `()` if there is no connection |
| `processpcaps` | `[path;file;pcaptab]` | Decode a pcap 2.4 file and publish it as table `pcaptab` to `tickerplanttype` |
| `version` | | From `VERSION` |

Nothing is published at root. App code reaches the exports through `use`, which returns the same instance
`di.torq` initialised:

```q
fa:use`di.torq.proc.filealerter
fa[`run][]
```

## Config

```toml
inputcsv = "appconfig/filealerter.csv"   # relative paths resolve under TORQXAPPHOME
polltime = "0D00:00:10"                  # a bare number is seconds
alreadyprocessed = "filealerterprocessed" # relative paths resolve under TORQXDATAHOME
skipallonstart = false
moveonfail = false
tickerplanttype = "segmentedtp"
usemd5 = true
```

Each is read with a presence check and a code default equal to `di/torq/settings/filealerter.q`, so a tier
that sets one key does not lose the others. A `connections` list, if set, is kept and `tickerplanttype`
appended to it, as TorQ appended it to `.servers.CONNECTIONS`.

| Key | Default | Meaning |
|---|---|---|
| `inputcsv` | `appconfig/filealerter.csv` | The csv driving the process |
| `polltime` | 10 seconds | Poll period; the timer job reschedules from its scheduled start (di.timer mode 1, TorQ's mode 0) |
| `alreadyprocessed` | `filealerterprocessed` | Splayed table of `filename`, `md5hash`, `filesize`; created if absent |
| `skipallonstart` | `false` | At startup, record every file the csv already matches as processed without running anything |
| `moveonfail` | `false` | Move a file even if one of its functions failed |
| `tickerplanttype` | `segmentedtp` | The tickerplant proctype to connect to and `processpcaps` publishes to |
| `usemd5` | `true` | Compare md5 hashes as well as sizes to detect a changed file |

## The csv

```
path,match,function,newonly,movetodirectory
/data/in,trades_*.csv,loadtrades,1,/data/done
{FEEDDIR}/pcap,*.pcap,loadpcap,1,
```

- `path` - the directory scanned (not recursively). `{ENVVAR}` placeholders are expanded on every poll; an
  unset variable warns and expands to empty, unmatched braces error.
- `match` - a `find -name` pattern.
- `function` - the name of a root function (or a namespaced one such as `.myapp.loadtrades`), looked up when
  the poll runs. Module-private names are not reachable.
- `newonly` - `1`: a file is handled once per filename. `0`: it is handled again when its size (or, with
  `usemd5`, its md5) changes.
- `movetodirectory` - where to move the file after its functions all passed; blank leaves it in place.

Rows with an empty `path` or `match` or a null `function` are dropped with an info log. To run two functions on
one file, give it two rows; the move happens after both.

## Writing the functions

A csv-named function takes `[path;file]`: `path` is the directory with a trailing `/`, `file` the bare name.
Define them in app code, which `di.torq` loads at root after `init`:
`$TORQXAPPHOME/code/filealerter/*.q` (every filealerter) or `$TORQXAPPHOME/code/<procname>/*.q` (one
instance). They are looked up by name at each poll, so loading after `init` is fine.

```q
/ $TORQXAPPHOME/code/filealerter/handlers.q
fa:use`di.torq.proc.filealerter;
/ a csv of the trade columns after time; the segmented tickerplant stamps time itself
loadtrades:{[path;file] t:("SFIBCCS";enlist ",") 0: hsym `$path,file; fa[`sendtotickerplant][`segmentedtp;`trade;value flip t]};
/ processpcaps takes three arguments, so a csv row names a two-argument wrapper
loadpcap:{[path;file] fa[`processpcaps][path;file;`packets]};
```

A function that throws, or a name that is not defined, is logged and counts as failed: the file is not moved
(unless `moveonfail`).

### Sending to the segmented tickerplant

The segmented tickerplant (`segmentedtp`) prepends its own `time` column to every message by default, so
send the table's columns *without* `time`. A message that already has `time` is rejected with
`Bad message received, error: length` in the tickerplant's log. Because `sendtotickerplant` is a sync call, the
handler still sees success and the file is moved.

`processpcaps` sends the capture time from the pcap file, as TorQ did, so the tickerplant must leave the
`packets` table alone. Set this in the tickerplant's app code, e.g. `$TORQXAPPHOME/code/segmentedtp/packets.q`:

```q
.stplg.updtab[`packets]:{[x;y] x};
```

### Porting TorQ handlers

TorQ handlers called framework functions that TorQ defined at root. Nothing in this module is published at
root, and most of TorQ's root framework is absent from a TorqX process too, so a TorQ handler usually needs
editing before it works. The alternative would be root aliases or a TorQ compatibility shim. Neither is used:
the TorqX ports (the POC's `feed.q`, `di.torq.proc.housekeeping`) rewrite against the injected dependencies
and document the break, and this module does the same.

| TorQ name | In a TorqX filealerter | Use instead |
|---|---|---|
| `sendtotickerplant[tptype;t;x]` | missing | ``fa[`sendtotickerplant][tptype;t;x]`` |
| `processpcaps[path;file;tab]` | missing | ``fa[`processpcaps][path;file;tab]`` |
| `tickerplanttype` | missing, and not exported | the proctype itself (`` `segmentedtp ``); TorqX's segmented tickerplant is not named `segmentedtickerplant` |
| `FArun[]`, `loadcsv[]` | missing | ``fa[`run][]``, ``fa[`loadcsv][]`` (over IPC, see below) |
| `.lg.o`, `.lg.w`, `.lg.e` | missing | ``lg:use`di.util.log;`` then ``lg[`info]``, ``lg[`warn]``, ``lg[`error]``, each `[ctx;msg]` |
| `.proc.cp[]`, `.os.*`, `.pcap.*` | missing | `.z.p`; `di.os`; `processpcaps` |
| `getfile`, `getpath`, `filealertercsv`, `alreadyprocessed` | missing | not available. The handler's `path` and `file` arguments are already split |
| `.servers.gethandlebytype[pt;sel]` | present | unchanged, but it returns `0Ni` with no connection where TorQ returned an empty list, so test with `null h`, not `count h` |

The table covers what filealerter handlers typically call. Before relying on any other TorQ root name, check
it exists in a running process: ``@[value;`.name;{`missing}]``.

To keep a handler's body unchanged, alias the exports at root before it, in the same app code file:

```q
fa:use`di.torq.proc.filealerter;
sendtotickerplant:fa`sendtotickerplant;
processpcaps:fa`processpcaps;
```

To run a poll by hand over IPC, wrap the call in a lambda: ``h({fa[`run][]};::)``. The lambda runs on the
filealerter, so `fa` must be defined there, as the app code above does. With permissions enabled, a
string query in the form ``"fa[`run][]"`` fails with `'type`. This happens on every TorqX process, not only
filealerter.

### A broken handler is easy to miss

q looks up a function's global names when the function runs, not when it is defined. A handler that calls a
missing name therefore loads cleanly and fails only at its first poll:

1. The call signals with the missing name (for example `'sendtotickerplant`), and `action` logs
   `failed to execute loadtrades on /data/in/trades_1.csv: sendtotickerplant`.
2. The file stays in place (unless `moveonfail`), but it is **recorded as processed**, so it is not retried:
   never for a `newonly` row, and for any other row only once the file changes.

After a port, check the error log for `failed to execute` and `has not been defined` once the first files have
arrived. To reprocess files after fixing a handler, remove their rows from the `alreadyprocessed` table or
rename the files.

A top-level expression that uses a missing name fails at load time instead, for example
``pcaptrades:processpcaps[;;`packets]``. `di.torq` stops loading the app code and the process exits at startup,
so this case is noticed immediately.

## Behaviour

At `init`: the csv is read (an unreadable csv errors, as TorQ's startup did), the processed table is loaded or
created, an older TorQ flat processed table is copied to `<path>_bk` and re-saved splayed with `md5hash` as
strings, and `skipallonstart` runs.

Each poll, for each csv row: find the matches, drop those already processed, and run the function on each of
the rest. Then every file tried - passed or failed - is appended to the processed table, so a failed file is
not retried unless it changes and its row is not `newonly`. Files whose functions all passed are moved; files no
longer present, rows with no `movetodirectory`, and files given two different directories (logged) are not.

`sendtotickerplant` is a sync call, so the poll waits for the tickerplant to apply each publish.

## Differences from TorQ

- `{ENVVAR}` expansion keeps the text before the first `{`. TorQ's `.rmvr.removeenvvar` dropped it, so
  `/data/{X}/in` became `$X/in`.
- An undefined function is a failure (`0b`), as the TorQ docs describe. TorQ put the logger's return value in
  `funcpassed` instead.
- Linux only: TorQ's Windows branch (`dir /B`, no md5, `\` paths) is not ported.
- The processed table defaults under `TORQXDATAHOME` rather than the config directory, and the tickerplant type
  defaults to TorqX's `segmentedtp` rather than TorQ's `segmentedtickerplant`.
- `skipall` still scans the csv `path` without expanding `{ENVVAR}`, as TorQ did; see below.

## Not included (candidate follow-ups)

- `skipallonstart` with an `{ENVVAR}` path matches nothing, since TorQ's `skipall` does not expand it.
- `find` and `mv` take paths unquoted, as TorQ did; a path with a space fails.
- A failed function's file is recorded as processed, so it is never retried unchanged.
- No startup wait for the tickerplant: `sendtotickerplant` logs and returns `()` with no connection, and the
  file is still recorded. A publish-critical function should signal when there is no handle so the file counts as
  failed; `di.torq`'s `startupdeps` setting can make the process wait at startup.

## Testing

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.proc.filealerter
```

Run from the repo root in its own q process: `test.q` sets environment variables and defines root `.u.upd` as a
local tickerplant. Fixtures go to `/tmp/di_filealerter_k4unit_fixture` and are removed afterwards. The pcap
fixtures in `tests/` are TorQ's (`TorQ/tests/pcap`).
