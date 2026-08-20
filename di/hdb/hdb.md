# di.hdb

The historical database process type. Mounts a partitioned database directory and exposes a
remotely-triggerable `reload`, so a process that has just persisted a new partition can make this
one pick it up without a restart.

Ported from TorQ's `code/hdb/hdbstandard.q` — the whole of it, two functions and 184 bytes — with
the process defaults from `config/settings/hdb.q`.

This is the smallest process-tier module in the modularisation plan. That is not a licence to be
thin: with a surface this small there is nowhere for a wrong decision to hide, and the one decision
it does have — the shape of `reload` — is the one that determines whether it interoperates with the
`di.rdb` already in review at all. That decision is documented first, below, because a future
maintainer needs to know *why* `reload` is unary-at-root, not merely that it is.

## Usage

```q
q)logging:use`di.log
q)hdb:use`di.hdb
q)hdb.init[logging.logdict,enlist[`hdbdir]!enlist `:/data/hdb]
2026.08.19D10:02:23.563 INFO [init] di.hdb initialised - hdbdir /data/hdb
q)hdb.start[]
2026.08.19D10:02:23.563 INFO [start] mounted /data/hdb - 2 partition(s), 1 table(s): trade
q)select count i by date from trade
q)hdb.getattributes[]
partition| 2026.08.18 2026.08.19
tables   | ,`trade
```

After `start[]` the process answers a remote `reload`:

```q
/ what di.rdb sends at end of day, and what the default .z.ps applies
q)value (`reload;2026.08.19)
```

`init` takes **one flat dict** carrying dependency and config keys side by side — the call shape
`di.torq` wires every module with. When passing more than one extra key, join `logdict` with a single
multi-key dict; joining it to a *chain* of single-key dicts throws `'mismatch`, because both value
sides are tables.

## Exports

| Function | Signature | Description |
|---|---|---|
| `init` | `[deps]` | wire the injected logger and resolve `hdbdir`; publish the root entry point. Does **no** I/O |
| `start` | `[]` | mount the configured database |
| `reload` | `[date]` | remount, then warn if the notified partition did not arrive. Also published at bare root |
| `getattributes` | `[]` | `` `partition`tables `` — the snapshot a gateway caches for this process |
| `status` | `[]` | `` `started`hdbdir`partitions`tables `` |
| `teardown` | `[]` | remove the root entry point. Does **not** unload the database |
| `version` | | module version string, read from `VERSION` |
| `getapimeta` | `[]` | api metadata rows for `di.torq` to register with `di.api` |

`init`, `getapimeta` and `version` are framework plumbing and carry no `getapimeta` row.

## Dependencies

**Injected: `log` only. Hard: none.**

`log` is required and never defaulted — `init` throws immediately if it is missing or malformed. All
three of `` `info ``, `` `warn `` and `` `error `` are genuinely called (info on mount, warn on a
partition that did not arrive, error through `raiseerror`), so all three are required rather than
only the ones `init` itself uses.

`deps.q` is present and **empty**, which is deliberate — see below and `deps.q` itself.

### Why the plan's `di.hdb -> di.sort` edge does not exist

The modularisation plan's tier table and its hard-dependency diagram both list `di.sort`. Two
separate reasons that edge is not real:

1. `di.sort` is not a mergeable module. PR #102 closed without merging, and its functionality lives
   inside the merged `di.dbwrite`. The identical correction was already applied to `di.rdb`.
2. More fundamentally, **nothing in the source references it**. Neither `hdbstandard.q` nor TorqX's
   `di/hdb/hdb.q` mentions `.sort`, `.save`, `.gc` or `di.dbwrite` at all. Attributes are applied at
   *write* time by whichever process calls `di.dbwrite.savedown`; an hdb only mounts what is already
   on disk, attributes included, as a side effect of loading. The plan's "applies attributes"
   describes what a caller **observes**, not an action this module performs.

### Why there is no `di.servers`, `di.timer` or `di.handlers` dependency either

- **`di.servers`** — `config/settings/hdb.q` sets `.servers.CONNECTIONS:()`. The hdb makes zero
  outbound connections; it is dialled, it does not dial. (`di.idb`, which the plan correctly lists as
  needing `di.servers`, is the contrasting case.)
- **`di.timer`** — nothing here is scheduled. Confirmed absent from both the legacy source and the
  TorqX prior art.
- **`di.handlers`** — this module assigns no `.z.*` handler, and unlike `di.rdb` it has no reason to
  observe one. `di.rdb` needs a `.z.pc`-driven resubscribe because it holds multi-message state (a
  subscription) that can silently desynchronise from a connection's up/down status. `di.hdb` has no
  equivalent: every operation is one-shot, so no per-client state can be stranded by a disconnect;
  it opens no connections of its own, so nothing it depends on can silently drop; and
  `getattributes` is pulled *by* a remote caller, whose connection lifecycle is that caller's
  problem, not this module's.

## Config

| Key | Required | Default | Meaning |
|---|---|---|---|
| `hdbdir` | **yes** | *none* | the database directory to mount. Accepts `` `:hdb ``, `` `hdb ``, `":hdb"` or `"hdb"` |

A **relative** `hdbdir` is resolved to an absolute path at `init`, against the working directory as
it is at that moment. This is not cosmetic — see the relative-path defect below.

`hdbdir` is normalised before it is stored: surrounding whitespace is trimmed (a `.toml` or `.q`
settings value can arrive padded), and on Windows backslashes become forward slashes, because a q
hsym is forward-slash on every platform — `` `:c:/data/db `` is how kdb+ names a Windows path.

A path **containing a space** is rejected at `init`, with the reason. This is not a preference:
kdb+'s `` \l `` cannot load such a path at all — bare, `"quoted"` and back`\ `slashed forms all throw
a bare `'nyi`, while the identical database without the space loads (measured, with a control). It is
called out at configuration time rather than left to surface as an unexplained `'nyi` at `start[]`,
or later at the first reload. It matters most on Windows, where `C:/Program Files/…` and a user
directory containing a space are entirely ordinary.

`hdbdir` is the only config key this module has. `config/settings/hdb.q`'s other settings are other
modules' business: `loadprocesscode` is a framework concern, and `.servers.CONNECTIONS`/`STARTUP`
belong to `di.servers`.

## Behaviour

### Startup

`init` is **pure configuration and performs no I/O** — it validates the dependency, coerces and
validates `hdbdir`, and publishes the root entry point. `start[]` is what mounts. The split is worth
keeping even though it is lighter than `di.rdb`'s (which blocks on a tickerplant): mounting is real
I/O that can genuinely fail — a missing directory, a corrupt splayed table — and separating it keeps
`init` unit-testable with no database on disk at all. The test suite exercises exactly that: its
first scenario calls `init` against a directory it has just deleted, and asserts it succeeds.

This is the deliberate departure from TorqX, whose `init` mounts inline and so cannot be tested
without a real database.

Config values are coerced into locals and validated **before any write lands**, so a rejected
re-init cannot leave the module half-configured. That includes the injected `log` dict's *values*,
not just its keys — see the defects section.

**Mounting changes the process's working directory.** `` \l `` on a database directory chdirs into
it; that is q's behaviour, not this module's choice, and legacy relies on it (`hdbstandard.q` mounts
with a bare `` system"l ." ``). Two things follow. A relative `hdbdir` would resolve differently on
the second mount than the first, which is why `init` pins it. And any code sharing the process that
resolves relative paths after `start[]` resolves them against the database directory — the test
suite keeps all its fixtures on absolute paths for exactly this reason.

### Reload

`reload[date]` remounts the whole database — `` system"l ",path ``, a full remount, not an
incremental update — then checks that the partition the caller named actually arrived.

That check is the only thing this module has that can detect the failure it is least able to notice
on its own: an `hdbdir` that mounts **successfully** and then silently serves the wrong data. It is a
**warning**, not an error, because an hdb legitimately serving a subset of history — or one fronted
by a writer that persisted somewhere else — must not be broken by being told about a partition it
does not carry.

The check runs only when it can mean something. A **null** date — `` reload[] ``, or an explicit
`0Nd`, which is itself type `-14h` — carries the same information as no date at all: remount, check
nothing. And a database whose partitions are not dates (`.Q.pf` of `` `int ``, `` `month `` or
`` `sym ``) cannot be asked whether a *date* arrived, so the module says so at info level rather than
comparing incomparable types. Both were defects; see below.

The mount itself is a protected apply, logged and re-signalled through `raiseerror`. An unprotected
`` system"l" `` throws an OS message naming neither the module nor the config key the path came from
(measured: `"/missing/path. OS reports: No such file or directory"`), and that bare string is exactly
what a calling rdb sees.

### Teardown

`teardown` withdraws the root entry point and nothing else. It does **not** unload the database: q
has no unmount, and dropping the mounted tables would destroy the process's whole reason for
existing. A torn-down `di.hdb` still answers queries; it just no longer answers a remote reload.
It is idempotent — `dropifours` checks the name is still ours before deleting it — so a shutdown path
may call it twice.

## Design decisions and divergences

### `reload` is UNARY and lives at BARE ROOT — the finding this module turns on

**Four independent producers agree** that an hdb reload is a date sent to a bare root `reload`:

| Producer | Call | Resolves to |
|---|---|---|
| `TorQ code/processes/rdb.q:77` | `hdbmessage:{[d](`reload;d)}`, async, applied by the default `.z.ps` | `reload[date]` |
| `TorQ code/processes/wdb.q:479` | `reloadfunc: @[{(1b;`. `reload x)};d;…]`, async | `reload[date]` |
| `TorQ code/processes/wdb.q:482` | `syncreloadfunc: @[h;({(1b;`reload x)};d);…]`, sync | `reload[date]` |
| **shipped `di.rdb`** `rdb.q:947` | `hdbmessage:{[date] :(`reload;date)}` via `di.asyncutil.postback` | `reload[date]` |

TorqX's `di/hdb/hdb.q` instead ships `reload:{[] …}`, published as `.hdb.reload` via
`` set[`.hdb.reload;reload] ``, and its own `di/proc/rdb` calls it as a bare `".hdb.reload[]"` string.
That is internally consistent within TorqX and matches **none** of the four above. Building `di.hdb`
that way would have been silently incompatible with the `di.rdb` already in review.

**Silently is the operative word, and the mechanism is not the one that was originally predicted.**
The expectation was that a strictly-niladic `reload` called with a date would throw `'rank`. Measured
on KDB-X `0.1.2/2025.11.17`, it does not:

```q
g0:{[] `ranok}
g0[1]                             / -> `ranok    -- the extra argument is silently DISCARDED, no 'rank
f1:{[date] $[date~(::);`null;`got]}
f1[]                              / -> `null     -- f[] applies with date bound to (::); it RUNS
f1[2026.08.19]                    / -> `got
value (`reload;2026.08.19)        / -> `got      -- di.rdb's literal message shape
```

So a TorqX-shaped `di.hdb` wired to the shipped `di.rdb` would have logged a *successful* reload on
every end of day while throwing the date away, with nothing on either side to say so. That is a
quieter failure than the crash originally imagined, and a worse one — a crash is at least loud.

The measurements also show the choice is not a trade-off. Because `f[]` applies a unary function with
its argument bound to `(::)`, a **unary `reload` still answers a niladic-convention `reload[]` call**,
provided it tolerates a null date — which it does. Unary strictly dominates: it can use the date and
loses no caller.

Legacy's own `reload` is bracket-less (`reload:{ … }`), which accepts and ignores extra arguments by
q's implicit-parameter rule. That is an artefact, not a design, and is not reproduced as though it
were a feature.

### `hdbdir` is required with no default — stricter than `di.rdb`

`di.rdb` defaults `hdbdir` to `` `:hdb `` (`rdb.q:119`). `di.hdb` deliberately does not, and the
asymmetry is the point: for an rdb, a wrong `hdbdir` means **writing** to the wrong — probably
empty — directory, which is annoying and loud. For an hdb it means **mounting** and then silently
serving whatever happens to be at that path: wrong query results that look like right ones. There is
no default that is safe to guess, so the module refuses to guess one.

A null or empty value is rejected for the same reason. `hsym `$""` is a bare `` ` ``, whose
`1_string` is `""`, and `` system"l " `` then throws a bare `'nyi` naming nothing at all (measured).
Rejecting it in `init` is what lets the message name the offending key.

The **type** is checked before the value is coerced, for the same reason again. `ashsym` stringifies
whatever it is handed, and it fails two different ways — measured against the shipped helper:

| `hdbdir` | `ashsym` gives | how it fails |
|---|---|---|
| `42` | `` `:42 `` | **silently wrong** — accepted as a path |
| `2026.08.19` | `` `:2026.08.19 `` | **silently wrong**, and looks like a real directory name |
| `3.5` | `` `:3.5 `` | **silently wrong** — any atom that stringifies gets through |
| `("aa";"bb")` | — | loud but **anonymous**: a bare `'type` from inside `ashsym` |
| `` `:a`:b `` | — | same bare `'type` |
| `` enlist `:hdb `` | — | same bare `'type` |

The first group is the dangerous one: a plausible-looking directory nobody asked for, which the
process would then mount and serve. The second is merely unhelpful — it throws, but names neither
the module nor the offending key. `init` therefore requires a symbol atom or a string
(`-11 -10 10h`) and names the key when it is neither.

Note `("a";"b")` is **not** one of these cases: it is the char vector `"ab"`, and is legitimately
accepted as the relative path `ab`. "One directory" is the operative phrase, not "not a list".

`di.rdb`'s `ashsym` (`rdb.q:51-55`) had the identical hole and has been fixed the same way, as its
own separate change — see `rdb.md`.

### Path resolution copies `di.rdb`'s `ashsym`, not TorqX's `resolvedir`

TorqX's `hdb.q` resolves a relative `dir` against `TORQXDATAHOME`, falling back to `TORQXAPPHOME` —
environment variables specific to TorqX's own sample-app deployment and established nowhere in
`kdbx-modules`. `di.rdb` had already solved the identical problem (coercing a directory-like config
value that may arrive as a symbol from a `.q` settings file or a string from a `.toml` one) with
`ashsym` (`rdb.q:51-55`), no environment variable involved. `di.hdb` is a sibling of `di.rdb` in the
same pipeline, so it matches that precedent.

Legacy's `` system"l ." `` relies on the process's working directory being the hdb root, which no
`use`-loaded module can assume. Hence the explicit, resolved, absolute path throughout.

### `getattributes` ships; its transport does not

`getattributes[]` is a faithful port of legacy's `.proc.getattributes` (`hdbstandard.q:6`), but it is
**not published at root** in v1.

Legacy's only caller was `code/handlers/trackservers.q:137-141,178`, where `addhw`/`retryrows`
remotely evaluate `.proc.getattributes[]` on the far side of *every* new connection and cache the
result. In the new module world that mechanism has no equivalent: the real `di.servers` (PR #120) has
no `attributes` column, no `getdetails`, and never remote-evals anything on connect. `di.rdb` solves
the same problem in the opposite direction, **pushing** `` (`setattributes;procname;proctype;attrs) ``
to its gateways (`rdb.q:998`) — a path an hdb cannot use, because it makes zero outbound connections.

So the data ships and the transport does not. `di.torq` can call `getattributes[]` and publish it
under whatever process-identity convention it settles on — the same declare-here/register-there
layering `getapimeta` already uses. Building the root publication now would mean `di.hdb`
unilaterally claiming the `.proc` namespace against a convention that has no consumer yet, which is
the same class of mistake as building `reload` to TorqX's shape.

`getattributes` also guards its partition read, which legacy does not. Legacy writes
`@[value;.Q.pf;.Q.PV]`; the `.Q.PV` fallback is the third argument of a protected apply and so is
evaluated **eagerly**, and on a flat (splayed, non-partitioned) database neither `.Q.pf` nor `.Q.PV`
exists — both throw (measured). Nesting the fallback inside its own trap is what makes the guard
actually guard.

### Root `reload` is contended with `di.rdb`

`di.rdb` publishes a unary root `reload` of its own (`rdb.q:209`). A process co-hosting both would
lose one of them, decided by publish order. `di.hdb` carries `di.rdb`'s `publishroot` warning for
exactly this — it logs when the name already holds something this module did not install.

This is **documented rather than designed around**. Changing the shared root-name convention would
mean editing `di.rdb` too, and real TorQ deployments always run the rdb and the hdb as separate
processes, so the collision is not reachable in a normal stack. It is recorded because this pipeline
may well be assembled in configurations the codebase has not been run in before.

### Errors are logged before they are signalled

Every post-`init` domain error goes through `raiseerror`, which logs at `error` and then signals.
`init`'s own dependency validation is the one exception — the logger is not wired yet.

This earns its place here more than in most modules. `di.asyncutil.postback` wraps the remote
evaluation of `` (`reload;date) `` in its own error trap (`asyncutil.q:29-30`) and hands the message
back to `di.rdb` as an opaque `"error: server fail: …"` string, which `reloadreply` then logs; TorQ's
`wdb.q:482` `syncreloadfunc` captures it the same way. So the throw **is** seen by the caller —
`postback` is fire-and-forget for *delivery*, and its success vector means "on the wire" rather than
"reloaded", but a failure is not invisible, just unhelpful. What `raiseerror` adds is that what the
caller sees names the module, the function and the path.

## Defects found by smoke testing and fixed

The suite was green at 54 assertions before this pass. None of these were caught by it, and none were
visible by reading the code — each was found by driving the module at inputs and database shapes the
suite did not cover. All four are fixed, each with its own regression scenario (`S9`–`S13`).

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | A relative `hdbdir` starts fine, then **every** `reload` fails with `failed to mount hdb` — an hdb that can never pick up a partition, failing first at the roll | mounting **chdirs** the process into the database, so the same relative path resolves against a different directory the second time | `init` pins a relative `hdbdir` to an absolute path at configuration time |
| 2 | `reload[2026.08.19]` against an **int-partitioned** hdb throws a bare, unlogged `'type` — *after* the remount has already succeeded, so the caller is told a reload failed that in fact worked | `date in pv` compares a date against a long vector | the membership check is gated on the partition domain being dates; otherwise it is skipped and noted at info |
| 3 | An `init` rejected on its log dict **bricks the module**: the new `hdbdir` and a poisoned logger are already written, and every later call — `teardown` included — dies with a bare `'length` | `log`'s *keys* were validated but not its *values*, so a data-valued dict passed every guard and `init` threw from its own closing log call, after the writes | the three values must be applicable (type ≥ `100h`), checked before any write |
| 4 | `reload[0Nd]` warns `partition  is not present` — naming no partition, because `string 0Nd` is `""` | `0Nd` is itself type `-14h`, so a bare type test called it a real partition | a null date takes the same path as no date |

| 5 | A Windows-style absolute `hdbdir` (`c:/data/hdb`) would be resolved to `<cwd>/c:/data/hdb` — a plausible directory nobody asked for | the relative-path fix in row 1 shipped with a POSIX-only leading-`/` test | "absolute" is decided platform-explicitly; both branches are tested from Linux |
| 6 | An `hdbdir` containing a space failed at `start[]` with a bare `'nyi` naming nothing | kdb+ cannot load such a path by any escaping | rejected at `init`, with the reason |

Two of the four (1 and 2) are wrong-answer bugs reported to the *caller*: the reload happened and the
caller was told it had not. The `postback` path (see below) turns those into an opaque
`"error: server fail: type"` on the rdb side, which is why they would have been slow to diagnose in
production and why neither would ever have shown up in a single-process test.

The remaining probes found no defect and are recorded here so they are not re-run needlessly: a
`par.txt` multi-location database mounts, reloads and reports its partitions correctly; a path with a
trailing slash, a relative `` `:. ``, and whitespace- or newline-padded strings all mount; an
`hdbdir` naming a file, a non-date partition directory, and a corrupt splayed column all fail through
`raiseerror` with the module, function and path named; an empty directory mounts and reports nothing;
`reload[a;b]` is a loud `'rank`; and a repeated `start`, `teardown` or same-config `init` is a no-op.

## Portability

These modules ship to clients on whatever platform they run, so the module hardcodes no path, no port
and no platform assumption.

- **No ports, no connections.** `di.hdb` opens none — `config/settings/hdb.q` sets
  `.servers.CONNECTIONS:()`. There is no `hopen`, no `` \p ``, and no `.z.*` network handler anywhere
  in the module. Nothing to make configurable, which is why there is no `port` config key.
- **No hardcoded paths.** `hdbdir` is required with no default and is the only path the module knows.
- **Path resolution branches on the platform explicitly**, via `` iswindows:.z.o in `w32`w64 `` — the
  same test `di.os.iswindows` uses. "Absolute" means different things: a leading `/` on POSIX, a drive
  letter (`c:/data`) or a UNC share (`//host/share`) on Windows. A POSIX-only test resolved
  `c:/data/hdb` to `<cwd>/c:/data/hdb` — a plausible-looking directory nobody asked for, which is
  exactly the silent wrong mount this module exists to prevent.
- **The platform is a parameter, not a global read.** `isabspath[win;p]` and `resolvepath[win;cwd;p]`
  take `win` and `cwd` as arguments and are called with `iswindows` and `system"cd"` from `init`. That is deliberate: it is the only way the Windows branch gets exercised
  at all before a client on Windows runs it, and the suite tests both branches from Linux by reaching
  the internals as `.m.di.0hdb.*`. Untestable portability code is portability code that does not work.
- **`system` is used twice, both unavoidable and both portable.** `system"l …"` *is* the mount — the
  operation this module exists to perform. `system"cd"` reads the working directory; it is q's own
  `` \cd `` handler rather than a shell fork, it tracks `` \cd `` where `` getenv`PWD `` goes stale,
  and it is what `di.os.pwd` uses.
- **The test suite is portable too**, and drives every filesystem operation through `di.os`
  (`mktempdir`, `mkdir`, `deldir`, `exists`, `cd`) rather than `rm -rf`, `mkdir -p` and a hardcoded
  `/tmp`. Note this is **not** a module dependency: `di.hdb` itself needs none, `deps.q` is what
  `di.depcheck` reads, and a `use` in a test row is not a shipped coupling.

### Why there is no `di.os` dependency either

`di.os` is the repo's home for cross-platform path handling, and it is a legitimate dependency for
`di.wdb`, `di.reporter`, `di.housekeeping`, `di.filealerter`, `di.dqc` and `di.dqe`. It is **not** one
here, and the modularisation plan's tier table agrees — it gives `di.hdb` no `di.os` edge.

The whole of what this module would use it for is pinning a relative `hdbdir` to an absolute path.
That is `isabspath` and `resolvepath`: about a dozen lines of pure q, no subprocess, tested on both
platform branches. Taking the edge would gate this module's review on a change to a module carried by
58 branches, and would buy nothing this module needs — `di.os.abspath` additionally canonicalises
`.`, `..` and duplicate separators, which mounting does not require because q's `` \l `` resolves them
itself.

Worth recording for whoever revisits this: wiring `di.os` up was tried, and `os.abspath` turned out to
have two defects — it shelled out to `realpath -ms` (GNU-only flags, so it failed outright on macOS)
and interpolated the path unquoted (so `"/tmp/with space/hdb"` came back silently truncated to
`"/tmp/with"`). Those are fixed in `di.os` separately, on their own merits and with their own tests;
they are not a reason for this module to take the edge, and this module does not wait on them.

## Known gaps

- **`getattributes` has no consumer yet** and is not root-published. Gateway-tier work — see above.
- **Partition and table staleness across databases — `status[]` and `getattributes[]` can report a
  database this process no longer means to serve.** `partitions[]` reads `value .Q.pf`, which is
  process-global and is not cleared when a *different* database is mounted; and q has no unmount, so
  the previous database's tables stay resident and keep answering queries. Pointing `init` at a new
  `hdbdir` therefore leaves both reporting the **old** database until `start[]` remounts. Not fixable
  in the module. What is fixed is the module's own contribution to it: a re-init that changes
  `hdbdir` now clears `started` and warns, so `status[]` no longer claims the new database is mounted
  when it is not. The test suite also has to order its scenarios around `.Q.pf` — the flat-database
  scenario runs before any partitioned mount and the int-partitioned one runs last, which is the only
  way to test both guards in one process.
- **`system"l"` cannot take a path containing spaces** — a kdb+ limitation legacy shares, and no
  escaping form avoids it. `init` now rejects such an `hdbdir` up front with the reason rather than
  letting it surface as a bare `'nyi`; see Portability. The gap is that such a database cannot be
  served at all, which is a real constraint on Windows deployments in particular.
- **`teardown` cannot unload the database.** q has no unmount; see Behaviour.
- **`.dqe.notifyhdb` is a dangling legacy reference.** `code/processes/dqe.q:100,117,142` calls
  `.dqe.notifyhdb[.os.pth .dqe.dqedbdir]'[hdbs]`, apparently intending a reload that takes a
  *directory*, but no such function is defined anywhere in TorQ (only the unrelated
  `.finspace.notifyhdb`). Recorded so a later sprint reads it as the latent defect it is, rather than
  as a contract `di.hdb` failed to honour.

## Module-namespace notes

A source-level bare identifier in module code is rewritten at load into this module's private
namespace, so it can never reach root. Therefore:

- the root table list is `` tables[`.] ``, never a bare `tables[]`;
- the root entry point is installed with an explicit `` @[`.;nm;:;f] ``, never a bare assignment;
- `` system"l …" `` is a **runtime** system call, unaffected by the rewrite — it mounts into root,
  which is exactly what a queryable hdb needs.

Note also that guards use **nested `if`s, never `and`**. q evaluates both sides of `and` eagerly, and
the combined form `(-14h=type date) and not date in pv` died with a bare `'type` on the very null-date
`reload[]` call that check exists to tolerate (measured, and caught by the test suite).

## Testing

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.hdb
```

73 assertions (60 `true`, 13 `fail`) across 30 fixture/scenario `before` rows, all inline in
`test.csv` under a `.t.` namespace — there is no `test.q`, so nothing depends on the process's
working directory. That last point is load-bearing rather than tidy: mounting chdirs the process,
so every fixture path is absolute.

k4unit runs **every `before` row before any assert** (`k4unit.q:62-79`), preserving only the relative
order of `run`/`true`/`fail`, so each scenario runs in a `before` row and captures its outcome into a
`.t.S*` dict that the asserts read. Two orderings are load-bearing and commented as such in the file:

- `S0` must precede any `init` — it is the only chance to observe the pre-init guards.
- `SF` (the flat-database scenario) must precede any *partitioned* mount, for the `.Q.pf` staleness
  reason under Known gaps.
- `S12` (the int-partitioned scenario) must be **last**, for the same reason in the other direction:
  mounting it sets `.Q.pf` to `` `int `` process-wide and no later date-partitioned scenario would
  survive it.

Coverage: the pre-init guards on every export; one `fail` row per `init` validation guard including
both empty-`hdbdir` shapes and a log dict whose values are data; all four `hdbdir` input forms
resolving identically; `init` succeeding against a directory that does not exist; `start` mounting;
`reload` picking up a partition written after `start` **driven by `di.rdb`'s literal
`` value (`reload;date) `` message**; the partition-missing warning; `reload[]` and `reload[0Nd]`
with a null date; a failed mount being logged *and* signalled; `getattributes` on a flat database;
teardown/re-teardown/re-start/re-init safety; and one scenario per defect in the table above — a
rejected `init` leaving no half-configured state (`S9`), a null date (`S10`), a re-init that moves
`hdbdir` (`S11`), an int-partitioned database (`S12`) and a relative `hdbdir` surviving the chdir
that mounting performs (`S13`).

Note for anyone extending the suite: `abs` is a reserved word (`.Q.res`) and cannot be used as a
local name in a test row — it throws `'assign` at parse time and aborts the whole run.

`di.depcheck` passes cleanly (0 failures, 0 warnings) with `di.hdb` loaded.
