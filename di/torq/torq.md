# di.torq

The process orchestrator - the single entry point every TorqX process goes through,
whether it's a built-in process type (a `di.*` module, like `di.proc.hdb`) or a custom one
(a plain file under the app's own `code/processes/`). Resolves who this process is,
builds its config from the settings cascade, builds its injected dependencies, and
starts the right process type - all through one call: `init[proctype;procname;
overrides]`.

This is TorqX's analogue of legacy TorQ's `torq.q`, but narrower in scope: the
launcher-side responsibilities (parsing a command line, actually starting a q
process, supervising start/stop across a whole `process.csv`) live in
`TorqX/di/torq/bin/torqx_init.q` and `TorqX/di/torq/bin/torqx.sh` instead - two deliberately thin
files that call into `di.torq.init` rather than duplicating what it does. Everything
below is `di.torq`'s own job; see the note at the end for how the launcher fits in.

## Design

### Identity resolution

`init`'s first job is figuring out `proctype`/`procname`, via `resolveidentity`:

```q
resolveidentity:{[proctype;procname]
  $[(null proctype) or (null procname);
    autodetect[];
    `proctype`procname!(proctype;procname)]
  }
```

Both-or-neither - there's no partial mode where one is given explicitly and the other
auto-detected. If either is null, `autodetect[]` reads `process.csv` (from
`TORQXAPPCONFIG`) and matches it against this session's own listening port
(`` system"p" ``), with host as a tiebreaker (own hostname → own IP → `` `localhost ``,
case-insensitive) - ported from legacy TorQ's `torq.q`'s `readprocfile`, scoped down
(no envvar substitution in the CSV, no `-procfile` override, no FinSpace host
handling). If autodetection narrows to exactly one candidate and no port was given yet
(`` system"p" `` was `0i`), `autodetect` binds the port itself (`` system"p ",string
port ``) rather than requiring it to already be set - so `torqx -p 5560` alone is
enough, you don't have to separately track which port belongs to which row.

Fails fast, with a specific message, in both ambiguous cases:

```q
q)tq.init[`;`;()!()]
'di.torq: cannot auto-detect identity - 2 process.csv rows match this host with no port to disambiguate; pass -p or proctype/procname explicitly
```

(or `"...no process.csv row matches this host"` if the port/host combination matches
nothing at all).

### Environment variables

Three independent, explicitly-set env vars - not derived from each other:

| var | what it points at | used for |
|---|---|---|
| `TORQXHOME` | the `di.torq`/framework checkout | builtin settings root (`$TORQXHOME/di/torq/settings`) |
| `TORQXAPPCONFIG` | the app's `appconfig/` directory | app settings root (`$TORQXAPPCONFIG/settings`) and `process.csv` |
| `TORQXAPPHOME` | the app's own project root | `code/processes/{proctype}.q` (custom proctypes), and where `di.proc.hdb`'s relative `dir:` settings resolve against |

### Config cascade

`roots[]` builds the two roots `di.torq.config.cascade` needs
(`` `$TORQXHOME/di/torq/settings ``, `` `$TORQXAPPCONFIG/settings ``); `init` calls
`` (cc`cascade)[r 0;r 1;proctype;procname] `` and then adds the resolved
`proctype`/`procname` into the result itself, so any module (or anything it calls)
can find out who it is just by looking at its own `config` dict - no global to reach
for. See `di.torq.config`'s own docs for the 5-tier cascade itself.

### Dependency building

`buildlogdep`/`buildtimerdep`/`buildhandlersdep` each build one of the three DI
contract dependencies (`log`, `timer`, `handlers`), defaulting to `di.util.log`/`di.timer`/
`di.torq.handlers` respectively, with an override escape hatch - the `overrides` dict passed
into `init` can specify a different module name under the `` `log ``/`` `timer ``/
`` `handlers `` key. `buildtimerdep` also initializes `di.timer` itself (with no deps
of its own - it's Tier 1 standalone) and reshapes its exported `addjob` (a dict of
`custom`/`default`/`simple` variants) down to the one signature the DI contract
expects.

### Process-type dispatch

A small built-in registry maps proctype → module name:

```q
builtin:(enlist`hdb)!enlist`di.proc.hdb
```

If `proctype` is in `builtin`, `startbuiltin` `use`-loads that module and calls its
`init[config;deps]`. Otherwise `startcustom` loads
`` $TORQXAPPHOME/code/processes/{proctype}.q `` directly (a plain `system "l ..."`,
not `use` - custom proctypes aren't kdb-x modules, they're app code, so there's no
namespace-mangling to work around) and calls `` .{proctype}.init[config;deps] ``.
Both paths call the exact same `init[config;deps]` shape either way - a custom
proctype is indistinguishable from a built-in one from `di.torq`'s point of view.

### Application code cascade

After the process type is started, `init` calls `loadappcode[lg;config;proctype;procname]`
to load any add-on q scripts the **app** drops under `` $TORQXAPPHOME/code/<dir>/ ``. This is
the modular equivalent of TorQ's `.proc.reloadallcode` (`torq.q`) — but scaled to a **single
app code root**: the TorqX framework ships behaviour as `di.*` *modules* (loaded via `use`), so
there is no framework `code/<proctype>` tree to cascade over, only the app's.

The cascade mirrors the config cascade's shape:

| tier | directory | flag | default |
|------|-----------|------|---------|
| common | `code/common/` | `loadcommoncode` | on |
| proctype | `code/<proctype>/` | `loadprocesscode` | on |
| procname | `code/<procname>/` | `loadnamecode` | **off** |

So **yes, it supports per-procname customisation** just like the config cascade — but, exactly
as in TorQ (`.proc.loadnamecode` defaults `0b`), the procname tier is **off by default** and
opt-in via `loadnamecode:1b` in that process's settings. Each flag is read from the merged
config (so it's overridable per-process in settings). `parentproctype` (TorQ's 4th tier, for
sharing code between a WDB and its sort workers) is omitted — there is no sort-worker tier yet.

Within a directory, files load in this order: an optional `order.txt` (one filename per line)
is loaded first, then the remaining `*.q`/`*.k` files alphabetically — matching TorQ's `loaddir`.
A missing directory is a silent no-op. Files are loaded with a **plain `system "l"` (not `use`)**,
so their definitions land in whatever namespace their own `\d` directives choose: a bare app
query file like `code/rdb/examplequeries.q` (no `\d`) lands at **root**, callable as
`countbysym[…]` — which is the whole point (the tickerplant can't call a module-mangled `upd`,
and an operator can't call a mangled query fn). This is the same load mechanism `startcustom`
already uses for `code/processes/`.

App code loads **after** the process module's `init` (so it can reference the module's tables and
state) and **before** the `.run` hook (so an app file may define/override `` .<proctype>.run ``).

### The `.run` post-init hook

After starting the process type and loading app code, `init` calls `runhook[proctype;overrides]`:

```q
runhook:{[proctype;overrides]
  if[`norun in key overrides;if[overrides`norun;:()]];
  ns:`$".",string proctype;
  if[`run in key ns;(get `$".",(string proctype),".run")[]];
  }
```

If the process type published a `` .{proctype}.run `` function - the same
"publish at a real root name" convention `di.proc.hdb` uses for `.hdb.reload` - it gets
called automatically, with no proctype-specific knowledge anywhere in `di.torq`
itself, the launcher, or `torqx.sh`. This exists so a process type can have its own
one-shot startup action (the sample loader's `loadall` - aliased as `run:loadall` in
`code/processes/loader.q` - reads its landing directory and loads it, right after
init) without the generic launcher needing to know that loaders, specifically, need
an extra call after `init` that hdb processes don't. Skipped entirely if
`overrides[`norun]` is set - see `di/torq/bin/torqx_init.q`'s `-norun` flag.

## Usage

```q
q)tq:use`di.torq
q)r:tq.init[`hdb;`hdb;()!()]
2026.07.09D12:48:40.352242000 INFO hdb mounting hdb from :/Users/jgrant/git/TorqX-POC/hdb
2026.07.09D12:48:40.355727000 INFO hdb loaded tables: trade
q)r`proctype
`hdb
q)key r`config
`dir`connections`proctype`procname
q)key r`deps
`log`timer`handlers
q)tables[]
,`trade
```

Auto-detected identity, once the session is listening on the right port:

```q
q)system "p 5560"
q)r:tq.init[`;`;()!()]
2026.07.09D12:48:48.864626000 INFO hdb mounting hdb from :/Users/jgrant/git/TorqX-POC/hdb
2026.07.09D12:48:48.864819000 INFO hdb loaded tables: trade
q)r`proctype
`hdb
q)r`procname
`hdb
```

The `overrides` dict recognizes four keys, all optional:

| key | effect |
|---|---|
| `log` | use this module instead of `di.util.log` for the `log` dependency |
| `timer` | use this module instead of `di.timer` for the `timer` dependency |
| `handlers` | use this module instead of `di.torq.handlers` for the `handlers` dependency |
| `norun` | if truthy, skip the `.{proctype}.run` post-init hook even if one exists |

### How the launcher fits in

In practice nothing calls `tq.init` directly like the examples above - that's what
`di/torq/bin/torqx_init.q` (a tiny QINIT-loaded script) does, parsing `-proctype`/`-procname`/
`-norun` off the command line and calling `init` with them, and what `di/torq/bin/torqx.sh`
does on top of that (start/stop/restart/status across a whole `process.csv`, without
duplicating any of the identity-resolution logic above - it only reads `process.csv`
to know *which* processes exist, never to resolve *who a given session is*, which
stays exclusively `di.torq`'s job).

### Dev mode (tmux)

`torqx.sh start` normally launches each process as a background `nohup` process
redirecting to a logfile. Passing `--tmux` (or `-t`) instead runs each process inside a
detached, **attachable tmux session** - one session per process, named
`<TORQXSTACKID>-<procname>` (e.g. `torqx-poc-rdb1`) - so a developer can attach to a
live `q)` console for any process:

```
torqx.sh start rdb1 --tmux      # or the alias:  torqx.sh devstart rdb1
torqx.sh attach rdb1            # attach to the q) console (or: tmux attach -t torqx-poc-rdb1)
torqx.sh status                 # tags tmux-managed procs with "(tmux)"
torqx.sh stop rdb1              # kills the process and cleans up its tmux session
```

`devstart`/`devstop`/`devattach` are aliases for `start --tmux`/`stop`/`attach`. The
tmux path keeps the *same* `-torqxstackid/-proctype/-procname` command-line signature as
the `nohup` path, so `stop`/`status` (which discover processes via `pgrep`) work
identically regardless of how a process was started. The pane keeps a crashed process
visible (`remain-on-exit`) and still tees output to the usual logfile (`pipe-pane`). It
re-sources `setenv.sh` inside the pane (via `bash -c`, **not** a login shell - a login
shell would source the user's profile and can inject a stale `QHOME`) so the process gets
the right environment even when a tmux server is already running, and it reproduces
torqx.sh's exact `QHOME`/`QLIC` in the pane (passed through if set, forced unset otherwise)
so q's licence resolution - including the common "infer `QHOME` from the q binary's
location" setup - matches the nohup path. Starting a process (either mode) first clears any
lingering tmux session for it, so a crashed `remain-on-exit` pane never coexists with a
freshly-started process. tmux mode is for local development; production stays on
`export-systemd`.

## Known gaps (v1)

- The builtin registry has exactly one entry (`` `hdb ``) so far - every other
  proctype in a real deployment would be custom, until more `di.*` process-type
  modules exist.
- No `di.torq.depcheck`-style pre-flight dependency validation yet (next up per the
  modularisation plan).
- `autodetect`'s host-matching has no `-procfile` override and no FinSpace-specific
  host handling - deliberately out of scope, same scoping-down `di.torq.servers` applies
  to its own `process.csv` reading.

## Testing

`test.csv`/`test.q` (k4unit) deliberately use the **real** `di.util.log`/`di.timer`/
`di.torq.handlers`/`di.proc.hdb` rather than mocks - each of those is already covered by its own
module's tests, and `di.torq`'s actual job is wiring them together correctly, which
mocking them away wouldn't exercise. Only `TORQXAPPCONFIG`/`TORQXAPPHOME` are
repointed at a temp fixture (a scratch settings tree, `process.csv`, and a throwaway
custom proctype file that publishes its own `run` hook to assert on) - `TORQXHOME`
stays real, since `di.torq`'s own built-in settings and registry genuinely live
there. Covers: `reqenv` erroring on a missing var, both auto-detect failure modes
(no match, ambiguous), explicit-identity init for both a built-in and a custom
proctype, config-cascade/deps reaching the started process type correctly, the
`.run` hook firing by default and being skipped when `norun` is set, and successful
auto-detection once the ambiguity is resolved. Run in a fresh q session (mutates
`system"p"` and `TORQXAPPCONFIG`/`TORQXAPPHOME`, don't interleave with other
modules' tests):

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq
```
