# TorqX — orientation for Claude

TorqX decomposes the TorQ kdb+ framework into standalone **`di.*` kdb-x modules** wired by
**dependency injection**, replacing the monolithic `torq.q` bootstrap with `di.torq`. It is the
framework/reference-app side of the [TorQ Modularisation Plan](https://data-intellect.atlassian.net/wiki/spaces/TK/pages/2375450629)
(design + findings: [TorqX POC status page](https://data-intellect.atlassian.net/wiki/spaces/TK/pages/2646409222)).
This repo (**`kdbx-modules`**) is the **consolidation base** per **RFC-0001** (agreed): the TorqX
orchestration / process / query tier is being merged in under the agreed namespace hierarchy. The
migration is **phased** — see [`docs/rfc-0001-torqx-kdbx-consolidation.md`](docs/rfc-0001-torqx-kdbx-consolidation.md).
New framework/process modules land in the hierarchy now; the existing flat utility modules are
renamed into it later in one coordinated change (RFC phase 5), so expect flat and hierarchical
names to coexist during the transition.

**Read `consistency.md` and `style.md` before writing module code** — they are the authoritative
conventions. This file is the map + the environment realities + the q traps that aren't obvious.

## Repo layout

Modules live under `di/`, one directory per module, resolved on `QPATH`. A module is a directory
containing `init.q` (which `\l ::`-loads its source and defines an `export:([...])` dict), plus a
`VERSION`, a `<name>.md`, `test.csv`/`test.q` (k4unit), and an optional `deps.toml`.

TorqX groups modules into a hierarchy (kdb-x resolves `di.a.b` → `di/a/b/`; a parent can be a
module *and* hold children):

- `di.proc.*` — process types: `hdb rdb wdb tickerplant gateway`
- `di.torq` (+ children) — the orchestrator and the machinery it owns:
  `di.torq.{config,depcheck,servers,handlers,logroll}`; the launcher ships at `di/torq/bin/`
  (`torqx.sh`, `torqx_init.q`)
- `di.util.*` — standalone utilities: `toml`, `log`
- flat `di.*` — the reusable library layer (`tplog subscriptions dataaccess`) and everything
  **vendored** from `kdbx-modules` branches (`asyncdispatch serverselect pubsub dbwrite eodtime`)
  or **external** (`timer tz tplogutils k4unit`). Vendored modules keep their upstream flat names
  so they re-sync cleanly — do not rename or restyle them.

## Environment

Module resolution and tests need:

- `QPATH="<TorqX>:<kdbx-modules>:$HOME/.kx/mod"` — colon-separated, first match wins; `di.a.b`
  looks for `<dir>/di/a/b/init.<ext>`. `$HOME/.kx/mod` provides KX modules incl. `kx.log`.
- `QLIC="$HOME/.kx"` — must resolve the **corporate** `k4.lic`. The community `kc.lic` has a
  connection/process cap that makes the spawn-heavy test suites fail once enough accumulate; if a
  community licence is present, rename it so `k4.lic` wins.
- `QHOME="$HOME/.kx"`.
- Running the **stack** (not needed for unit tests) also uses `TORQXHOME` (framework checkout),
  `TORQXAPPHOME`/`TORQXAPPCONFIG` (the app), `TORQXDATAHOME` (runtime data), `TORQXSTACKID`. See
  an app's `setenv.sh` (e.g. `TorqX-POC/setenv.sh`).

## Running tests (k4unit)

Run **with the repo root as the working directory** — each `test.csv` loads its fixtures with a
cwd-relative `system "l di/<path>/test.q"`.

```q
q)k4u:use`di.k4unit
q)(k4u`moduletest)`di.torq.servers      / runs the module's test.csv
q)show (k4u`getresults)[]               / KUTR table; rows with ok=0b failed
```

- Index the returned handle with **brackets** (`k4u`moduletest`) — a dot-call (`k4u.moduletest`)
  on a module you just `use`d can fail until the frame returns to top level.
- **Spawn-heavy suites** (`di.asyncdispatch`, `di.pubsub`, `di.torq.servers`, `di.torq`, …) spawn
  real child q processes on real ports. They need the corporate licence **and**, under a sandbox,
  permission to `bind()` — run them **unsandboxed**. `di.torq`'s tests also need `TORQXHOME` set.
- You **cannot** host an interactive q in a headless harness to test tty-dependent behaviour
  (`script`/`pty` make q enter the REPL and hang). Prove such logic over IPC against a real
  tty-attached process, or via deterministic stdin-inheritance.
- Known-red: `di.tplog`'s 4 corruption tests fail purely as an artefact of the shared
  `kdbx-modules` checkout's branch naming (`di.tplog` vs `di.tplogutils`); runtime is unaffected.

## Running the stack

From an app directory, after `source ./setenv.sh`:

```bash
torqx.sh start|stop|restart|status [procname|all]   # at $TORQXHOME/di/torq/bin, on PATH via setenv
torqx.sh start --tmux        # dev mode: attachable tmux session per process (devstart/devattach)
torqx.sh export-systemd      # production: one systemd --user unit per process.csv row
```

## Conventions you must know (details in `consistency.md`)

- **DI:** framework/process modules take `init[config;deps]`; store deps, call through `.z.m`.
- **Inject cross-cutting singletons (`log`/`timer`/`handlers`/`servers`); `use` libraries.**
  Injected `init`s must be idempotent.
- **Module-namespace write boundary:** a `use`-loaded module's bare *writes* (and `-11!` replay)
  land in its private namespace — maintain root tables / publish root IPC names via
  `@[`.;name;…]` / `set[`.ns.fn;…]`.
- **Versioning:** `VERSION` + per-module `deps.toml`; `di.depcheck` validates a transitive
  manifest graph at startup.

## q gotchas (these have each cost real debugging time)

- **Lambda bracket spacing:** `{[e] -2 x}` needs the space after `]`; `{[e]-2 x}` misparses.
- **`system` execs the command DIRECTLY — no shell.** No `&&`, `||`, pipes, `cd`, `~`, globs.
  Wrap in `sh -c "…"` when you need shell features.
- **Reserved-name shadowing fails, sometimes at load:** don't name a local/param `log`, `ss`,
  `sv`, `string`, `cut`, `tables`, etc. (`sv:…` throws `'sv` on load). Use `srv`, `lg`, ….
- **Parse tree: a bare symbol is a COLUMN reference.** In functional qSQL a bare `` `date `` is
  the column; a literal symbol value must be enlisted — `($;enlist`date;`time)` casts `time` to
  the *type* date.
- **Single-char string literals are atomised** at compile time (type `-10h`); `enlist` restores a
  1-char vector. Runtime-built 1-char strings are already `10h` — don't blindly `enlist` (that
  double-wraps). Only `enlist` a genuine atom: `$[0>type x;enlist x;x]`.
- **Two 1-char string literals coalesce:** `("1";"2")` becomes the 2-char vector `"12"`; use
  `(enlist"1";enlist"2")` for a 2-item list.
- **`and`/`or` do not short-circuit** and evaluate both sides eagerly — if one side can throw,
  guard with nested `if[]`, not a combined condition.
- **`` `$ ``, `string`, and casts are not idempotent** — they throw on already-converted input.
  Type-check first: `assym:{$[11h=abs type x;x;`$x]}`.
- **Right-to-left, flat precedence:** `not a or b` parses as `not[a or b]`. Fence explicitly.
- **Deferred-sync IPC is one message list:** `neg[h](`fn;a;b); h[]` — NOT `neg[h] . (`fn;a;b)`
  (that `.`-applies a monadic handle with N args → `'length`).
- **Dict coalescing:** seed an accumulator dict with `` enlist[`]!enlist(::) `` so `,:` will widen
  the value type instead of refusing.
- **Shell is zsh** (in tooling): unquoted `$var` does *not* word-split — use `find … | while IFS= read -r f` for file loops, not `for f in $files`.

## Module resolution recap

`QPATH` colon-separated, first wins; `di.a.b` → `<qpathdir>/di/a/b/init.q`. A module = a dir with
`init.q` + an `export:([…])` dict. Parents can be modules too; `use`ing a child does not load the
parent (so `di.torq` being both orchestrator and namespace parent is safe).
