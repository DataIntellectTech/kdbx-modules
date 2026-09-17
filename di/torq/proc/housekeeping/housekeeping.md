# di.torq.proc.housekeeping

The file-maintenance process type: reads a csv of cleanup jobs and applies them — removing,
gzipping or tarring files and directories older than a given age — on a daily schedule, and on
demand over IPC. Started by `di.torq` through the same `init[config;deps]` convention as every
other built-in proctype.

Ported from `TorQ/code/processes/housekeeping.q`.

Its first customer is the framework's own logs: `di.torq.logroll` deliberately has no retention
policy ("old `out_`/`err_` files accumulate forever… external housekeeping is expected"), and a
`rm` job over `{TORQXLOGDIR}` is exactly that.

## Dependencies

- **Injected** (from di.torq): `log`, `timer`.
- **`use`-imported**: `di.os` (for the `rm` action — it picks the right call for a file vs a
  directory, and its dry-run mode makes a destructive action testable).

> **No `deps.toml`.** `di.os` ships no `VERSION` file, and `di.torq.depcheck`'s manifest walk
> fails outright on a declared dependency it can't read a version for. Declaring `di.os` today
> would break every housekeeping start with a `DEPENDENCY CHECK FAILED … has no VERSION file`.
> Add the declaration once `di.os` carries a `VERSION`.

## Config

```toml
jobcsv = "appconfig/housekeeping.csv"   # the job list; relative paths resolve under TORQXAPPHOME
runtimes = "02:00 14:30"                # UTC time(s) of day to run; space-separated in .toml
runnow = false                          # also run once at startup (false, as in TorQ)
```

Each is read with a presence check and a code default, per consistency.md's stated convention for
a process module's tunables. Note `config` **is** the merged cascade (framework settings → app
settings → command line), so there is no separate "settings" lookup at runtime — the code default
applies only to a caller that bypasses the cascade and calls `init` directly, such as the tests.

The same defaults are also declared in `di/torq/settings/housekeeping.q`. That declaration is what
makes them discoverable and **command-line overridable** — the override tier only touches keys
already present in the cascade, so an undeclared setting is silently skipped. The two copies must
therefore agree, and tests assert both halves: that the shipped settings default is off, and that
a config omitting it defaults off too. A silently disagreeing pair is how legacy TorQ ended up
shipping `runtimes:02:00:00` in settings and a dead `12:00` in its code guard
(`housekeeping.q:5`), with its own `-hkusage` text (`:31`) quoting the dead one to operators.

`runtimes` accepts whatever the settings tier yields: a real time/second/minute list from a `.q`
settings file (`02:00:00 14:30:00`), or a space-separated string from `.toml` (which has no time
type). Each becomes one daily timer job.

### Setting `runnow`

Three ways, and the accepted spelling differs by tier:

| where | how |
|---|---|
| app `.toml` settings | `runnow = true` (toml has a real boolean type) |
| app `.q` settings | `runnow:1b` |
| command line | `-runnow 1` — **not** `-runnow true` or `-runnow 1b`, both of which are rejected |

The command-line tier parses the supplied text into the setting's *existing* type, so a boolean
wants a bare `1`/`0`. It also only applies to settings that already exist in the merged config —
which is why `runnow` is declared in `di/torq/settings/housekeeping.q` rather than defaulted only
in code: an undeclared setting is skipped with `skipping unknown setting(s): runnow`. (An app
settings file can introduce it either way; it is the *command-line* tier that needs it declared.)

> **`runtimes` are UTC, not local.** `di.timer` fires a job when its own clock — `cp:{.z.p}`,
> which is UTC — reaches the start time it was given, so the start times here are computed on
> that same clock. Deriving them from local time (`.z.P`/`.z.D`) instead makes every run late by
> the UTC offset: a `"02:00"` job on a UTC+1 box silently fires at 03:00 local. On a
> UTC-configured host the distinction disappears, which is exactly why it is easy to miss.

## The job csv

One row per cleanup job. All seven columns are required:

| column | type | meaning |
|---|---|---|
| `action` | symbol | `rm`, `gzip` or `tar` |
| `path` | string | directory to search (not recursive — `find -maxdepth 1`) |
| `match` | string | glob to match, e.g. `*.log` |
| `exclude` | string | glob to exclude; may be empty |
| `age` | int | minimum age, in `unit`s |
| `unit` | symbol | `d` (days) or `m` (minutes) |
| `dirs` | boolean | `1` to match directories instead of files (what `tar` wants) |

```csv
action,path,match,exclude,age,unit,dirs
rm,{TORQXLOGDIR}/,*.log,keepme.log,10,d,0
gzip,{TORQXLOGDIR}/,*.log,,2,d,0
tar,{TORQXDATAHOME}/oldruns/,run_*,,30,d,1
```

`{ENVVAR}` placeholders in `path` are expanded from the environment, so a csv follows a
deployment rather than hardcoding absolute paths (legacy TorQ did the same via
`.rmvr.removeenvvar`). An unset variable expands to empty, as in a shell.

### Extending the action set

`addaction[name;handler]` registers an action a csv row can then name. From a file under
`$TORQXAPPHOME/code/`, which `di.torq` loads after this module's `init`:

```q
hk:use`di.torq.proc.housekeeping          / same instance init ran on - use is cached
(hk`addaction)[`s3upload;{[f] ... }]       / handler takes one matched path
```

`actionnames[]` returns the current set. A handler is called once per matched path, exactly like
the built-ins, and is subject to the same per-file error trapping.

This is the front door for what legacy TorQ got from `wrapper` calling `value` on **any**
root-level function the csv named — genuinely extensible, but unbounded: a csv naming `exit`, or
any other root function, got it called with file paths. Dispatch here stays closed over one
dictionary that an app adds to deliberately. `addaction` rejects a non-symbol name, a
non-function handler, and any attempt to shadow `rm`/`gzip`/`tar` (silently swapping `rm` out
from under a job csv that already names it helps nobody); re-registering an existing custom action
is allowed but warns.

Note a bare `` actions[`x]:… `` from app code does **not** work: app code is loaded with
`system "l"` and lands at root, while this module's `actions` lives in the private namespace
`use` mangles it into. You would be amending an unrelated root dictionary of the same name, the
csv row would still be rejected as unknown, and nothing would say why until a scheduled run
logged it.

The csv is **re-read on every run**, so jobs can be edited without bouncing the process.

### Migrating a TorQ housekeeping csv

Columns were renamed for clarity; the behaviour is the same:

| legacy TorQ | here |
|---|---|
| `function` | `action` |
| `agemin` (boolean: age is in minutes) | `unit` (`d`/`m`) |
| `checkfordirectory` | `dirs` |

Legacy also allowed the last two columns to be omitted, and needed a fragile column-rename dance
to cope. Here all seven are required and a mismatched header is a clear error naming both the
columns found and the columns expected.

## Behaviour

- **Startup**: resolve config, `use` di.os, publish `.housekeeping.runjobs`, register one daily
  timer job per `runtimes` entry, and (only if `runnow`) perform one run.
- **Scheduled**: each timer job repeats every 24h in di.timer **mode 1h**, which reschedules from
  the previous *scheduled* start rather than the previous finish — so a slow run doesn't drift
  the daily time. The first fire is pinned via `startattime` to the next occurrence of that time
  **on the UTC clock** (today if it hasn't passed, otherwise tomorrow), so a process started at
  09:00 UTC with `runtimes = "02:00"` waits until tomorrow rather than firing immediately.
- **On demand**: `.housekeeping.runjobs[]` over IPC, for an operator or a cron job.
- **Per run**: read the csv, then for each job `find` the matches and apply the action to each.
  A missing/malformed csv, an unknown action, or a failing `find` is **logged and skipped** — the
  process stays up and tries again on the next schedule, rather than one bad row ending the
  night's housekeeping.

### Why `.housekeeping.runjobs` and not `.housekeeping.run`

`di.torq`'s `runhook` calls `.{proctype}.run[]` once after init for any process type that
publishes one. For this proctype that name would mean **every process start performs a
destructive cleanup pass** — silently reversing legacy TorQ's `runnow:0b` default, and making the
`runnow` setting dead. So the entry point is published as `runjobs`, leaving "run at startup" an
explicit opt-in via `runnow`. A test asserts nothing is published at `.housekeeping.run`.

## Not included (deliberately)

- **Windows.** Legacy shipped parallel `.unix.*`/`.win.*` implementations and dispatched on
  `.z.o`. `find`/`gzip`/`tar` here are unix; `di.os` covers the rest cross-platform. `init`
  errors on Windows rather than starting half-working — legacy's own Windows `zip`/`tar` were
  never implemented either, and the framework tier has dropped Windows elsewhere (see
  `logroll.md`). Add if TorqX ever needs it.
- **`kdbzip`** (kdb `-19!` column compression). That whole concern belongs to `di.compression`,
  which does it far more thoroughly, csv-driven, with its own stats.
- **"Run once and exit"** (legacy's `runnow` semantics). Exiting from inside `init` would fight
  `torqx.sh`, which owns this process's lifecycle. `runnow` here means "also run once now"; a
  genuine one-shot is a cron job calling `.housekeeping.runjobs[]` over IPC.
- **Recursion.** `find -maxdepth 1` keeps a job to the directory it names. A tree walk is one
  glob away from deleting far more than intended; add per-job depth if a real need appears.

## Not yet included (candidate v2)

Roughly in the order they'd pay off:

- **Dry-run / report mode.** The highest-value gap for a process whose whole job is deleting
  things: ask "what *would* this csv remove tonight?" and get the match list without acting.
  `di.os` already has the machinery (`setdrysyscalls` caches calls instead of running them), but
  it only covers the `rm` action — `gzip`/`tar` shell out directly, and `di.os` doesn't export
  `syscall`, so a complete dry run needs either an export from `di.os` or a local indirection.
- **kdb-native compression as an action.** Legacy's `kdbzip` (`.cmp.compress`, `-19!`). Deliberately
  dropped because `di.compression` does it far more thoroughly; a v2 could wire that module in as
  a `kdbcompress` action rather than reimplementing it.
- **Per-job schedules.** Every job runs at every `runtimes` entry. Retention policies usually want
  different cadences (nightly log sweep, weekly archive), which today needs two processes.
- **Recursion / depth control.** `find -maxdepth 1` is hardcoded, so a job only sees the directory
  it names. A per-job `depth` column would cover nested layouts — with care, since a glob plus
  unbounded recursion is a foot-gun.
- **A run summary worth monitoring.** Counts and bytes reclaimed per job, kept as a table (like
  `di.compression`'s stats) so a dashboard or heartbeat can see that housekeeping is actually
  keeping up, rather than reading log lines.
- **`deps.toml` declaring `di.os`** — blocked purely on `di.os` shipping a `VERSION` file (see
  Dependencies above).
- **Windows.** The `.win` branch, if TorqX ever needs it.
- **Malformed-header reporting.** `0:` pads a too-short header with invented names, so the error
  says `has columns wrong, header, entirely, x, x1, x2, x3`. Reporting the raw header line would
  read better.
- **`tar` path noise.** Absolute paths make `tar` emit `Removing leading '/' from member names` to
  stderr on every archive. Harmless and matches legacy, but `-C` would silence it.

One operational assumption worth testing rather than trusting: di.timer's `disableonfail` defaults
to `1b`, so a job that *throws* is disabled and never runs again. `runjobs` traps its csv read and
every per-file action, so it shouldn't throw — but nothing currently proves that, and the failure
mode is silent (housekeeping simply stops, with `status 0b` in the timer table as the only clue).

## Security note

The job csv is operator-supplied config, at the same trust level as a settings file, and its
values reach the shell (quoted) as `find`/`gzip`/`tar` arguments. It is not a place to accept
untrusted input.

## Testing

`test.csv`/`test.q` (k4unit) cover: init erroring without `log`, without `timer` and without
`jobcsv`; the published entry point (and the absence of `.housekeeping.run`); one timer job per
runtime, with the right period/mode/`startattime`, for both `.toml`-style string runtimes and a
real time list; a full `runnow` run against a fixture directory proving all four selection rules
at once (matched-and-old removed; wrong glob, too recent, and excluded all left alone); and that
an unknown action, a malformed csv and a missing csv are each logged rather than thrown.

`addaction` is covered too: three of its rejections (non-symbol name, non-function handler,
shadowing a built-in), the warn-not-error on re-registration, and a full round trip — register a
handler, name it from a csv row, and assert dispatch reached it with the matched path.

The **pre-init** guard (`requireinit`, on `addaction` and `runjobs`) is *not* in the suite and was
verified by hand: the suite's `before` block inits the module, and `initialised[]` stays true for
the rest of the session, so nothing after that point can exercise the unguarded path without
reaching into module internals to unset the probe. `actionnames` is deliberately unguarded — it
only reads the action dictionary, which exists from load — and a test asserts it answers correctly
either way.

**All three actions** are exercised, each against its own fixture directory (the `rm` job really
deletes its inputs, so a shared directory would make test order significant): `rm`, `gzip`
(asserting the `.gz` appears *and* the original is consumed), and `tar` with `dirs = 1`
(asserting the archive appears *and* that `--remove-files` deleted the original directory — the
most destructive thing this module does). A separate job uses `unit = m` to exercise `find`'s
`-mmin` branch, which is otherwise one character from `-mtime` and would ship broken unnoticed.

`runnow` is tested in **both** directions: that setting it performs a run, and — asserted on the
earlier no-`runnow` init, *before* the runnow test consumes the fixture — that omitting it does
**not**. The ordering matters: assert it later and a wrongly-defaulted-on `runnow` is
indistinguishable from the runnow test's own deletions, since the files are gone either way.

Those were each confirmed to actually discriminate by mutation: hardcoding `agearg` to `-mtime`
fails only the minutes assertion, dropping `--remove-files` fails only the
original-directory-removed assertion, and defaulting `runnow` to `1b` fails only the two
fixture-still-intact assertions.

The timer dep is mocked so the tests stay independent of `di.timer` and can init repeatedly in
one session (a real `di.timer` rejects a re-used job id). Run in a fresh q session (this suite
calls `setenv`, so don't interleave it with other modules' tests in one shared process):

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.proc.housekeeping
```

One assertion pins the `startattime` to di.timer's **UTC** clock specifically. It can't fail on a
UTC-configured host — which is the point of stating it: the local-time version of that arithmetic
is wrong everywhere else, and nothing else in the suite would notice.

The paths mocks can't reach — `di.torq`'s `runhook`, the real config cascade, real `di.timer`
registration, and a timer job actually *firing* — were verified by running the process for real
under `torqx.sh` against a temp app and reading its live job table. Both bugs that survived the
unit tests (the `.run` hook collision and the local-vs-UTC clock) were caught that way.
