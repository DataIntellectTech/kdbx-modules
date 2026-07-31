# di.torq.logroll

Optional stdout/stderr redirection and daily rotation, ported from `TorQ/torq.q`'s
`fileredirect`/`createalias`/`createlog`/`rolllogauto` (`torq.q:458-500,656-661`).
TorQ made this mandatory-by-default; TorqX makes it **opt-in**, since an app that
ships its output to Logstash/ELK wants everything on stdout/journal untouched, and
would lose that if this were forced on. Named to match `torq.q`'s own
`.proc.logroll` flag.

## Design

A process opts in with a `[logroll]` settings section:

```toml
[logroll]
enabled = true
dir = "logs"            # relative to TORQXAPPHOME, or absolute
suppressalias = false   # true skips the out_<procname>.log/err_<procname>.log symlinks
forceredirect = false   # true redirects even in an interactive session (see TTY guard below)
```

A missing `[logroll]` section, or `enabled` absent/false, is a **silent no-op** -
same convention as `di.torq.depcheck.check` on a missing `deps.toml`. `di.torq.init`
calls `di.torq.logroll.init[config;deps]` unconditionally on every process start (right
after the injected `deps` dict is built, *before* the process type's own
`init`/`run` - so the process type's own startup log lines land in the rolled files
too), so a process gets this purely by adding the section to its settings - no
per-process-type code changes needed anywhere.

### `resolvedir[dir]`

String-based (not symbol/`hsym`, since this feeds `system"1 ..."`/`ln -sf` shell
commands, not a q file load) - `di/proc/hdb/hdb.q`'s `resolvedir` is the symbol-based
equivalent for mounting a database directory. Absolute if the (string-normalized)
value starts with `/`, else joined against `TORQXAPPHOME`. A symbol-sourced value
(old `.q`-style settings, e.g. `` `:/var/log/myapp ``) stringifies with its leading
handle colon still attached - stripped before the absolute-ness check.

### `redirect[dir;filename;alias;handle]` / `rollnow[]`

`redirect` reassigns fd 1 or 2 (`handle`) to a real file via `system"1 ..."`/
`system"2 ..."` - kdb+'s own console-handle redirection, a real OS-level fd
reassignment - and, if `alias` is non-empty, points a stable `ln -sf` symlink at it.
`rollnow` builds this roll's timestamp-stamped `out_`/`err_` filenames and calls
`redirect` for both handles. Published at a real root name, `.logroll.rollnow`, so
it's callable manually (ops forcing an immediate roll without waiting for the
schedule) - same "publish at a real root name" convention `di.proc.hdb`'s
`.hdb.reload` uses, needed because `use` mangles a module's own namespace.

### Interactive sessions (the TTY guard)

Redirecting the console is right for a **background/daemon** process, but wrong when the process
is launched **interactively** - by hand via the `torqx` alias, or inside a tmux pane. Redirecting
stdout/stderr there steals the operator's console: the startup banner prints (before `init` runs),
then the `q)` prompt and everything after vanish into the logfile, so the process *looks* hung even
though it is perfectly healthy and answering IPC.

So `init` first checks `interactive[]` - is q's stdin a TTY? `interactive` shells out
(`test -t 0`) via `system`, whose child inherits q's own fd 0, so it reflects q's real stdin: a
`nohup` launch (stdin `/dev/null`), a systemd unit, or a stdin-detached child are all **not** a
TTY and redirect as normal; an operator at a terminal or a tmux pane **is** a TTY, and `init`
**skips** the redirect (and the roll schedule) with a one-line warning, leaving the console intact.
The probe is error-guarded: if it fails for any reason, it assumes *not* interactive (redirect -
the safe default for a real deployment). Set `[logroll] forceredirect = true` to redirect even in
an interactive session.

> This also matters for `torqx.sh`'s tmux dev mode (`start --tmux` / `devstart`): a tmux pane is a
> TTY, so a logroll-enabled process keeps a usable console when you `torqx.sh attach` to it, while
> `torqx.sh`'s own `pipe-pane` still tees that pane to a logfile. Without the guard, attaching to a
> logroll-enabled process would show a dead console.
>
> Historical note: because kdb+'s `\1`/`\2` split stdout/stderr correctly only on a non-TTY stdin
> in this build, an interactively-launched logroll process used to also merge all output into the
> `err_` file (`out_` left empty). The TTY guard removes that as a side effect - interactive
> sessions no longer redirect at all, and background launches split `out_`/`err_` correctly.

### `init[config;deps]`

Requires `log` and `timer` in the injected `deps` (same validation style as
`di/proc/hdb/hdb.q:21`). When enabled: calls `rollnow[]` once immediately, then
schedules the recurring roll via the injected timer contract - `period=86400`
(seconds/day), `mode=1h` (`kdbx-modules` `di.timer`'s "x seconds after previously
scheduled start" - fixed-rate, no drift), with `opts.startattime` overriding just
the first fire to next UTC midnight (`` `timestamp$1+`date$.z.p ``), so the very
first roll happens at the next real day boundary rather than 24h after whenever the
process happened to start - matching `torq.q`'s own scheduling exactly. The timer
job is handed the actual `rollnow` **function value**, not a symbol reference - a
bare `` `.di.torq.logroll.rollnow `` symbol would not reliably resolve later given how
`use` mangles a module's namespace, but the closure captured at `init`-time always
will (same `.z.m`-resolves-to-origin-module guarantee `.hdb.reload` relies on).

v1 scope matches `torq.q`'s existing behavior exactly rather than adding new knobs:
always UTC midnight (no `-localtime`-equivalent config), always a 1-day period (no
configurable roll hour/interval), unix `ln -sf` only (no Windows `mklink` branch -
TorqX is Linux-only so far). All flagged as known gaps below, not built, since the
ask was to retain existing TorQ behavior, not extend it.

## The systemd interaction

`torqx.sh`'s own `${TORQXLOGDIR:-/tmp}` default is bash-level redirection used only
by the non-systemd `start_one` path (`> "$logfile" 2>&1 &`) - it captures fd 1/2
until something else reassigns them. A generated `export-systemd` unit has no such
redirect at all; stdout/stderr go to the journal by default.

`di.torq.logroll`'s redirect **takes over from whichever supervisor initially owned fd
1/2, identically regardless of launch mode** - it's a real fd reassignment, not
something layered on top. Enabling `di.torq.logroll` under a systemd unit makes
`journalctl` go quiet for that unit the moment the redirect fires (the same
startup-banner-only transient you'd see under the old `/tmp` capture); the flat
files under `di.torq.logroll`'s configured `dir` become the sole source of truth from
then on. Confirmed directly, not just asserted: running `hdb` via `torqx.sh start
hdb` with `[logroll]` enabled left the original `torqx.sh` nohup-redirect target
file (`/tmp/torqx_<stack>_hdb.log`) completely empty, while the configured `dir`
picked up every line, including `hdb`'s own mounting/loaded messages and the
launcher's `torqx: started hdb hdb` line. No change to `torqx.sh`/`export-systemd`
is needed to support this - the generated unit's `ExecStart` is untouched either
way, and `WorkingDirectory`/`TORQXAPPHOME` already being absolute means
`resolvedir` has no cwd dependency to worry about under systemd.

## Dependency

Requires `log` and `timer` injected (Tier-2-ish, alongside `di.proc.hdb`/`di.torq.handlers`) - not
a hard `use`-imported module dependency beyond that.

## Usage

```q
q)lr:use`di.torq.logroll
q)(lr`init)[config;deps]     / no-op unless config has [logroll] enabled=true
q).logroll.rollnow[]         / force an immediate re-roll, e.g. from a qcon session
```

In practice nothing calls these directly - `di.torq.init` calls `init` on every
process start:

```q
lr:use`di.torq.logroll;
(lr`init)[config;deps];
```

## Known gaps (v1)

- Always UTC midnight, always a 1-day period - no `-localtime`-equivalent config,
  no configurable roll hour/interval. Matches `torq.q`'s existing behavior exactly;
  extending this means adding settings keys and threading them into the
  `addjob`/`startattime` calculation in `init`, not a design change.
- Unix `ln -sf` only - no Windows `mklink` branch (`torq.q`'s `createalias` has
  one). Add if TorqX ever needs to run on Windows.
- No log-file cleanup/retention policy - old `out_`/`err_` files accumulate
  forever under `dir`, same as `torq.q`'s own behavior (which also never deletes
  old files). External housekeeping (e.g. a cron job) is expected, same as today.

## Testing

`test.csv`/`test.q` (k4unit) cover the no-op paths (missing `[logroll]` section,
`enabled=false`) and the missing-`log`/missing-`timer` dependency failures
in-process (safe - these all return/throw before ever touching fd 1/2). The
"enabled" cases - real redirect, aliasing, `suppressalias`, relative-dir
resolution, and the exact `addjob` call shape - are each run via
`test_childinit.q`, spawned as a genuine separate q process
(`spawnchildinit` in `test.q`), **not** called in-process: confirmed empirically
that calling `logroll.init` with `enabled=true` directly inside the k4unit test
runner reassigns the runner's own fd 1/2 and corrupts its own result reporting
(same class of problem `di/torq/servers/test.q` solves by spawning a real peer process
for its own self-connect case). The spawned child serializes its captured
`addjobcalls` mock-table to disk before exiting so the parent process can load and
assert on it. Run with:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.logroll
```
