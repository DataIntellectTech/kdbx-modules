# di.clienttracking

Tracks the client sessions connected to a KDB-X process in an in-memory session table: who
connected, from where, when, when they went away, and (once a query owner exists) how many
requests each one made and roughly how many bytes it was sent. A port of TorQ's
`code/handlers/trackclients.q` (`.clients.*`), rebuilt on `di.torq.handlers` so it never assigns a
`.z.*` handler itself.

## Features

- One row per client session, opened from `.z.po`/`.z.wo` and closed from `.z.pc`/`.z.wc`.
- Per-request usage counting (`hits`, `lastp`, and for sync queries `sz`) as a `post` watcher on
  `.z.pg`/`.z.ps`/`.z.ws`, measuring the **final** result the caller received (see
  [Design decisions](#design-decisions--rationale)).
- Sweeps that reap sessions whose handle has vanished, optionally force-close idle handles (only
  while usage counting is live — see [Configuration](#configuration)), and purge closed rows past a
  retention window.
- `enabled`/`trackusage` switches in config, matching TorQ's `.clients.enabled`/`opencloseonly`.

## Dependencies

Both dependencies are **injected** through `init`; the module `use`s nothing.

| Dependency | Key | Required | Contract |
|---|---|---|---|
| logger | `` `log `` | **yes** | dict with `` `info`warn`error ``, each `{[ctx;msg]}` — `di.util.log`'s `logdict` is ready-made |
| handler registry | `` `handlers `` | **yes** | dict with `` `register`remove`list `` — the surface `di.torq` builds from `di.torq.handlers` |

Anything else in `deps` (`` `timer ``, `` `servers `` — the rest of what `di.torq` injects) is accepted and
ignored. A missing or malformed required dependency makes `init` signal immediately; there is no
fallback.

**Why `handlers` is injected rather than `use`d.** `di.torq.handlers` owns the one root `.z.*`
binding per process, so there must be exactly one instance and its `init` must run exactly once.
That is the definition of an injected singleton in `consistency.md` ("inject cross-cutting
singletons; `use` libraries"). The modularisation plan's dependency tree lists
`di.clienttracking → di.handlers`, but that is a role grouping, not a hard import — the same
resolution already applied to `di.permissions`.

**No `deps.toml`.** The module has zero `use` dependencies, so it ships no manifest at all —
matching `di.serverselect` and `consistency.md` ("a missing `deps.toml` is a silent no-op …
adoption is incremental"). An explicit empty manifest would only be noise.

## Initialisation

```q
ct:use`di.clienttracking

/ log dep - the same shape di.torq builds (di.util.log's flat info/warn/error); logging.logdict`log
/ (its createlog-based instance) also satisfies the contract but prints in a different format
logging:use`di.util.log
logdep:`info`warn`error!(logging`info;logging`warn;logging`error)

/ handlers dep - di.torq builds this from di.torq.handlers; standalone you build it the same way
hz:use`di.torq.handlers
hz[`init][enlist[`log]!enlist logdep]
handlersdep:`register`remove`list!(hz`register;hz`remove;hz`list)

/ config carries this module's settings under a `clienttracking section; an absent section = defaults
config:enlist[`clienttracking]!enlist `maxidle`retain!(0D00:30:00;0D01:00:00)

ct.init[config;`log`handlers!(logdep;handlersdep)]
```

> If you start from `logging.logdict` instead, join it with a **multi-key** dict
> (`` logging.logdict,`handlers`timer!(handlersdep;::) ``). `logdict,enlist[`handlers]!enlist handlersdep`
> throws `'mismatch` — a one-element list of dicts is a table, and two such value sides with
> different columns cannot be joined.

`init` takes **two arguments, `config` then `deps`** — the shape `consistency.md` prescribes for
modules with per-process settings, and the one `di.permissions` (the sibling handlers consumer),
`di.subscriptions` and `di.torq.logroll` use. `config` is the whole process config dict; only its
`` `clienttracking `` section is read.

> **A two-argument `init` called with one dict does not throw** — q returns a projection. So "`init`
> didn't error" proves nothing; wire it with both arguments and assert an observable effect
> (registrations on `handlers.list`). The suite pins the arity with `2=count (value ct.init) 1`.

`init` must be called before any other function (there is no default logger). It is
**idempotent**: a re-init re-wires the dependencies and config, reclaims the same registrations
in place, and leaves the session table intact. Re-initialising with `enabled:0b` removes every
registration this module made and stops; a later enabled re-init puts them back.

> **Nothing in `di.torq` wires this module yet.** Unlike `di.querylog` (which `di.torq` switches on
> from a `[querylog]` settings section), a host process wires `di.clienttracking` itself. Until
> `di.torq` grows a `[clienttracking]` hook (a one-liner in its `init`, after `loadappcode` — the
> module already takes the standard `init[config;deps]` and `deps` is exactly what `di.torq` builds),
> an app can wire it from a `code/common/clienttracking.q` app-code file: `use` the same
> `di.torq.handlers` instance (`use` returns the loaded singleton, so the registrations land in the
> live dispatchers alongside `servers`/`pubsub`/`gateway`), build `deps` as above, and pass a
> config dict. This is how the module was smoke-tested on every process of the TorqX-POC stack.

### Configuration

All keys live under the `` `clienttracking `` section. Defaults are TorQ's **effective** ones from
`config/settings/default.q` — not the `dotz.q` fallbacks, which that file always overrides.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | boolean | `1b` | register the lifecycle observers at all. `0b` wires the log, unhooks anything a previous init registered, and stops |
| `maxidle` | timespan, or string `"nDhh:mm:ss"` (the `D` is mandatory — `"900"` is rejected, not read as 9 hours) | `0D` | force-close a live handle whose `lastp` is older than this. `0D` (the default) disables reaping — see the warning below |
| `retain` | timespan, or string `"nDhh:mm:ss"` (same rule) | `0D02:00:00` | delete a closed session this long after its `endp` |
| `trackusage` | boolean | `1b` | attach the usage watcher to `.z.pg`/`.z.ps`/`.z.ws`. `0b` is TorQ's `opencloseonly` |

The two timespans may also be given as **strings in q's `nDhh:mm:ss` literal form** (`"0D00:15:00"`,
`"1D"`) — TOML has no timespan type, so that is the only way a `.toml` settings file can carry
them. The `D` is mandatory: `"N"$` would silently read `"900"` as nine *hours* and `"15:00"` as
fifteen hours, so bare numbers are rejected. Both must be finite and non-negative (a null, `0Wn` or
negative value is rejected). Every wrong value is logged at error and signalled by name
(`di.clienttracking: init: config key maxidle must be a timespan, or its string form such as "0D00:15:00"`).
Unknown keys are ignored. A per-process section replaces the app-default section wholesale — the
config cascade does not deep-merge sections.

> **Idle reaping only runs while usage counting is live.** `lastp` advances only when the usage
> watcher counts a request, and the watcher can only attach to a query event that has an `exec`
> owner. Until it is live on at least one event (`trackusage:0b`, or no owner registered yet),
> every session would look idle and a positive `maxidle` would close *every* connection on the
> process — so `cleanup` suspends the idle-reap branch instead, and `init`/`enableusage` log a
> warning saying so. Today **no `di.torq` process type registers an `exec` owner** (the gateway,
> rdb, hdb and tickerplant all run on the built-in `.z.pg`/`.z.ps`), so on a stock TorqX stack
> `maxidle` is inert until a `di.permissions`-style owner (or `di.torq`) claims `exec`.
>
> **Even with counting live, `maxidle` reaps quiet clients.** A client that only *receives* — a
> pub/sub subscriber on a tickerplant, a wdb's control connection to a gateway — never bumps
> `lastp`. Observed on the POC stack with `maxidle` set on the gateway: the first sweep after
> counting went live force-closed `wdb1`'s idle connection, `di.torq.servers` on the wdb reopened it
> ten seconds later, and the pair would have churned every sweep. That is TorQ's `MAXIDLE`
> semantics faithfully reproduced, and why the default is `0D`. Set `maxidle` only on processes
> whose clients all make requests.

## The session table

`getclients[]` returns an **unkeyed** table (type `98h`), one row per session:

| Column | Type | Meaning |
|---|---|---|
| `w` | int (`` `g# ``) | connection handle (`.z.w` at open) |
| `ipa` | symbol | client IP, dotted-decimal |
| `u` | symbol | client user (`.z.u` at open) |
| `a` | int | client IP as the raw `.z.a` int |
| `startp` | timestamp | session open |
| `endp` | timestamp | session close; **null while open** |
| `lastp` | timestamp | last counted request (initially `startp`) |
| `hits` | long | requests counted for this session (`.z.pg`, `.z.ps` and `.z.ws`) |
| `sz` | long | total `-22!` size of the results actually **returned** — sync (`.z.pg`) requests only; see below |

Handles are reused by the OS, so the same `w` can appear in several rows over time — the open one
has a null `endp`. Compared with TorQ's `.clients.clients` the table drops `k`/`K`/`c`/`s`/`o`/`f`/
`pid`/`port` (only ever filled by the removed INTRUSIVE probe) and `errs` (see below); `hits` and
`sz` are longs.

## Exported functions

### `init[config;deps]`
Wire dependencies and config, register the observers. See [Initialisation](#initialisation).

### `getclients[]`
The session table above. Returns the live module state — copy it if you intend to mutate.

### `addclient[handle]`
Record `handle` (an int) as an open session from the current `.z` context — TorQ's `addw`. For a
handle that was open before `init` ran, or one opened by this process (`hopen`) that you want
tracked. Runs a sweep first. Signals on a non-int.

### `cleanup[]`
One sweep: stamp `endp` on any open row whose handle is no longer in `.z.W`; if `maxidle>0D` and
usage counting is live, `hclose` live handles idle longer than that and stamp them; delete closed
rows older than `retain`. Runs automatically on every open and close; exported so a host can also
drive it from a timer (a process that sees no connection churn never sweeps otherwise — a client
that goes idle after the last open/close is not reaped until the next one).

The handle a `cleanup[]` call arrives on (`.z.w`) is never reaped by that call: it is mid-request,
not idle — its `lastp` is only bumped by the usage watcher *after* the call returns. Without that
guard a stale client calling `cleanup[]` over IPC had its own handle closed under it and got
`'close handle` instead of a reply (reproduced with a real socket before the guard went in).

### `enableusage[]`
(Re)attach the usage watcher as a `post` handler on each of `.z.pg`, `.z.ps`, `.z.ws` that
currently has an `exec` owner; logs (at info — no owner is the normal state of a stock `di.torq`
process) each one it had to defer, and warns only if `maxidle` is configured but cannot run. `init` calls it when
`trackusage` is `1b`, but a `post` cannot attach before an `exec` owner exists, so **call it again
after the query owner (gateway, permissions, app code) registers**. Idempotent.

### `getapimeta[]`
This module's rows for `di.api`, one per callable export (`getclients`, `addclient`, `cleanup`,
`enableusage`). `init`, `getapimeta` and `version` are plumbing and are not listed.

### `version`
The contents of the `VERSION` file (semver string). `di.torq.depcheck` reads it from the export.

## Events managed

All through `di.torq.handlers`, under the name `` `clienttracking `` at priority `0`.

| Event | Model | Phase | Handler |
|---|---|---|---|
| `.z.po`, `.z.wo` | simple | `` ` `` | open a session row (after a sweep) |
| `.z.pc`, `.z.wc` | simple | `` ` `` | stamp `endp` on the open row for that handle (then sweep) |
| `.z.pg` | phased | `post` | bump `hits`/`lastp` and add `-22!` of the result to `sz` for `.z.w` |
| `.z.ps`, `.z.ws` | phased | `post` | bump `hits`/`lastp` for `.z.w` — no bytes, nothing is returned to the client |

`.z.pi`, `.z.pp`, `.z.ph` and `.z.pw` are not counted (TorQ did not count them either).

### Usage counting measures the final, post-transform result

`di.torq.handlers` threads a phased event `pre → exec → transform → post`
(`dispatchphased`, `handlers.q`): the transform chain rewrites the owner's result, every `post`
handler is then called with **that** value, and that same value is what the dispatcher returns to
the caller. So `sz` accumulates `-22!` of exactly what the client received — a transform that
wraps, filters or redacts the result is reflected in the byte count. The suite proves it by
registering a wrapping transform and asserting `sz` grew by the size of the wrapped result, not
the bare one. (`handlers.md` predates the transform phase and does not mention it; the
authoritative source is `dispatchphased` itself.)

## Design decisions & rationale

- **Usage counting is deferred, not eager.** A `post` cannot be registered before an `exec` owner
  exists. TorQ's `trackclients.q` had no such constraint because it wrapped whatever was in `.z.pg`
  at load time. Here `init` attaches to whichever query events already have an owner and warns
  about the rest; `enableusage[]` is exported so the host can complete the wiring after its owner
  registers. Ordering is the host's responsibility and the warning makes a miss visible.
- **`sz` counts sync results only.** kdb+ discards the return value of a `.z.ps` (async) or `.z.ws`
  handler — nothing goes back to the client — so adding `-22!` of it to `sz` (as TorQ did for all
  three events) inflates the column with bytes that were never transferred, e.g. an rdb's `upd`
  return value for every tickerplant update. Only `.z.pg` measures bytes; the other two watchers
  count hits and freshen `lastp`.
- **A handle being opened closes any open row it already has.** `.z.po` for handle `h` means the
  previous session on `h` is over, whether or not this module saw its `.z.pc` (registered late,
  disabled at the time, `addclient` called twice). The stale row is stamped closed before the new
  one is inserted, so the OS reusing a handle number can never leave two open rows both counting
  the same requests. TorQ's keyed table got this for free by overwriting; an unkeyed table has to
  do it explicitly.
- **No `errs` column.** TorQ's `hite` counted a failed request by wrapping the handler in a
  protected apply and re-signalling. A `post` runs only after a successful `exec` — a throw in
  `exec` propagates before any `post` fires — so this module cannot observe failures. Adding an
  `exec`-phase wrapper to count them would make this module the query owner, which it must not be.
  Failed requests are therefore not counted anywhere here; `di.querylog` records them.
- **Unkeyed table.** TorQ keyed on `w` and nulled it on close, so a reconnecting handle overwrote
  the previous session's history. An unkeyed table keeps one row per session; the open one is
  `null endp`.
- **INTRUSIVE mode removed.** TorQ could send each new client an async query asking for its
  `.z.K`/`.z.c`/`.z.i`/… and write the answers back. It is off by default in TorQ, is documented
  there as unsafe with non-kdb+ clients, and requires the module to issue outbound queries on
  someone else's handle. Dropped along with the eight columns only it populated.
- **`.z.p` rather than TorQ's `.proc.cp[]`.** All timestamps are UTC; there is no localtime switch.
- **`enabled` restored, defaults taken from `default.q`.** The earlier draft omitted TorQ's
  `enabled` switch and took `maxidle`/`retain` from `dotz.q` (15 min / 5 min). Every TorQ process
  loads `config/settings/default.q`, which sets `MAXIDLE:0D` ("0 means no clean up") and
  `RETAIN:0D02`, so those are the behaviour a TorQ user actually gets — and reaping-on-by-default
  would silently close every push-only subscriber (an RDB on a tickerplant) after 15 minutes.
- **`init[config;deps]` with a `` `clienttracking `` section**, following `di.permissions`,
  `di.subscriptions` and `di.torq.logroll` (`consistency.md`, "framework & DI conventions").
- **`disabled` re-init unhooks.** `di.permissions` stops without touching registrations; this
  module removes its observers and watchers so a re-init to `enabled:0b` actually stops tracking.
  The session table is kept.
- **Sweep on every open/close, no `AUTOCLEAN` switch.** TorQ's `AUTOCLEAN` defaulted to `1b`; the
  off setting was never used in shipped config and was dropped.
- **The session table is amended by name, not reassigned.** Every write goes through
  `.z.M.clients` (the module-qualified name of `.z.m.clients`), so `update`/`delete`/`upsert` amend
  in place as TorQ's `` `.clients.clients `` did. The per-request `hitpost` is the hot path: a
  by-value `.z.m.clients:update … from .z.m.clients` copies three columns of the whole table on
  every query — measured 24× slower (83 µs vs 3.4 µs per request) with 50k retained rows, and it
  grows with `retain`. Reading state is still `.z.m.clients`; only the write target uses the name view.
- **Log storage** is the three-flat-vars form (`.z.m.loginfo/logwarn/logerr`), as in
  `di.torq.handlers` and `consistency.md`'s base example. Post-`init` errors go through
  `raiseerror` (log at error, then signal); `init`'s own dependency validation signals plainly
  because the log is not wired yet.

## Known limitations

- **`'noupdate` under multithreaded input.** With a negative `\p` the `post` handler runs off the
  main thread and its global update throws `'noupdate`; `di.torq.handlers` isolates and logs it
  at warn, so usage is not counted on such processes. Session open/close still works.
- **Failed requests are not counted** — see the `errs` decision above.
- **`.z.ph` (HTTP GET) is not counted.** Its `exec` owner replaces the built-in handler wholesale
  and `.h.val` is outside `di.torq.handlers`' scope; HTTP usage is left to whoever owns that.
- **`sz` costs a serialisation walk per request.** `-22!` computes the IPC size of the result; on a
  process returning very large results, set `trackusage:0b` if that overhead matters.
- **A request from a handle with no open row is silently uncounted** (opened before `init`, or
  reaped). Use `addclient` to register such a handle.
- **No timer of its own.** Without connection churn the table is not swept; drive `cleanup[]`
  from `di.timer` if idle reaping or retention matter on a quiet process.
- **Usage counting is inert on a stock TorqX stack.** Smoke-tested on every process of the
  TorqX-POC (`tickerplant`, `hdb`, `rdb`, `wdb`, `gateway`, `feed`): sessions, `.z.po`/`.z.pc`,
  IPs and users are all tracked, but `hits` stays `0` everywhere because no `di.torq` process type
  claims an `exec` owner and a `post` cannot attach without one. Registering an owner (a
  `{value x}` passthrough via the handlers singleton, as the smoke did on the gateway) makes
  counting live immediately. Either `di.torq.handlers` needs a default-owner notion for events
  that only have watchers, or `di.torq` should claim a passthrough `exec` — a follow-up in those
  modules, not here.
- **`di.querylog` and an `exec` owner do not mix** (a `di.torq` limitation, observed here): once
  any owner claims `.z.pg`/`.z.ps` through `di.torq.handlers`, the dispatcher replaces the wrapper
  `di.querylog` installed by direct assignment and query logging on those events silently stops,
  while this module keeps counting. Reproduced on the POC gateway with `[querylog] enabled=true`.
- **A `[clienttracking]` TOML section cannot share a file with another section today** —
  `di.util.toml` builds sections with `` d,(enlist k)!enlist v ``, so a file with two sections of
  different keys throws `'mismatch` at parse time (`[logroll]` + `[clienttracking]` in one
  `hdb.toml`, say). A single-section file, or `.q` settings, work. Bug in `di.util.toml`.

## Running tests

Unit suite (hermetic — drives the real `di.torq.handlers` dispatchers with synthetic handles and
the console handle `0i`):

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.clienttracking
```

Integration suite (`test_integration.csv`) — stands up a child q process on an OS-assigned port and
runs two legs over real sockets. Inbound: the child loads and `init`s its **own** instance of the
module over IPC and this process is its client — a second `hopen` is seen as a real `.z.po` with
the right IP and user, requests are counted, a `cleanup[]` call made over an idle handle does not
close that handle, and the other idle session is force-closed. Outbound: the tracked handle to the
child is reaped as idle here. (The child hosts the instance because a process blocked in a sync
call does not accept connections, so a dial-back into the test process would deadlock.) Needs a
q/kdb-x binary reachable via `QHOME` (or `q` on `PATH`); skips cleanly if the child never comes up.
Run it in a **fresh** session (`moduletest` only loads `test.csv`):

```q
q).m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.clienttracking;`test_integration.csv]
q).m.di.0k4unit.KUrt[]
q)k4unit.getresults[]
```

Both suites pass on KDB-X `0.1.2/2025.11.17` and `5.0/2026.07.23` with
`QPATH` pointing at the modules root.
