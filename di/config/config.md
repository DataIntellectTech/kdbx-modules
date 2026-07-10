# di.config

Configuration loading and cascade resolution for the modular TorQ world. This
replaces TorQ's in-process config handling (`torq.q`: `loadf`, `loadconfig`,
`loadaddconfig`, `overrideconfig`), where `di.torq` will later distribute the
resolved config to each module via that module's `init`.

## Import and init

`init` requires a `log` dependency — there is no silent fallback. Pass an
already-conforming binary `` `info`warn`error `` dict of `{[c;m]}` loggers (context
symbol, message string). The module performs **no** adaptation of the logger.

The standard logger is **`di.log`**, which exports binary `info`/`warn`/`error`
functions directly — build the dict from its exports:

```q
config:use`di.config

/ option 1: di.log — the standard logger (exports binary info/warn/error)
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)
config.init[enlist[`log]!enlist logdep]

/ option 2: any hand-rolled binary {[c;m]} logger
mylog:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});
config.init[enlist[`log]!enlist mylog]
```

A logger that is *not* already binary `{[c;m]}` (e.g. a raw monadic
[`kx.log`](https://github.com/KxSystems/logging) instance) must be wrapped by the
caller first — di.config does no wrapping: `` `info`warn`error!({[c;m]inst[`info][string[c],": ",m]};…) ``.

`init` must be called before any other function — there is no default logger.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire the injected logger. `deps` is a dict with a required `log` key — an already-conforming binary `` `info`warn`error `` dict of `{[c;m]}` functions. Errors immediately if the log dependency is missing or malformed. |
| `loadcascade` | `loadcascade[dirs;names]` | Resolve the config cascade **name-major**: for each name (least→most specific) load `dir/{name}.q` from each directory in turn. `dirs` is a string path or list of paths (low→high priority); `names` is a symbol or symbol list (least→most specific). A more specific name wins over the directory layer; within a name the later directory overrides. Missing files are skipped (logged at *info*); already-loaded files are de-duplicated. Returns the flat list of constructed paths, in load order. |
| `overrideconfig` | `overrideconfig[params]` | Apply command-line-style overrides after the cascade. `params` is a dict keyed by variable name (symbol) with string (or list-of-string) values, each parsed into that variable's **existing** type. Only already-defined, basic-typed variables can be overridden; undefined names, non-basic types, and unparseable values are logged and skipped. Returns the list of variables actually overridden. |
| `get` | `get[namespace;key;default]` | Query the resolved config store: return the value of `.{namespace}.{key}`, or `default` if unset. `namespace` and `key` are **bare** symbols (no leading dot), e.g. `get[\`rdb;\`subscribeto;\`]`. (`get` is a reserved word, so the implementation function is named `getcfg` and exported under the `get` key.) |
| `getmodule` | `getmodule[namespace]` | Return a namespace's whole resolved config as a bare-keyed value dict — the slice di.torq passes to a module's `init`. `namespace` is a bare symbol; an unconfigured namespace yields an empty dict. |

Internal helpers — `loadconfig` (the per-file loader behind `loadcascade`), `raiseerror`,
`applyoverride`, and the load-tracking state — are deliberately not exported.

`loadcascade` is the top-level entry point. A caller (e.g. `di.torq`, which resolves the
process identity and directory paths) drives it as:

```q
config.loadcascade[(kdbconfig;appconfig);`default,proctype,procname]
config.overrideconfig[`.myproc.enabled`.myproc.rows!(enlist"1";enlist"5000")]
/ then partition per module and hand each slice to that module's init:
rdbcfg:config.getmodule[`rdb]              / -> `subscribeto`hdbtypes!(...) etc.
rdb.init[rdbcfg;`log`timer!(logdep;timerdep)]
/ or read a single value with a fallback:
config.get[`rdb;`subscribeto;`trade`quote]
```

`overrideconfig` runs after `loadcascade` so command-line values win over file config.
di.config is deliberately generic — it does not read environment variables or process
identity itself; the caller (di.torq) supplies the settings directories, the ordered
name sequence, and the override params, then uses `getmodule` to partition the resolved
store per module.

### The config store

`loadcascade` loads settings `.q` files that assign into root namespaces
(`.rdb.subscribeto:...`); those resolved namespaces **are** the config store, and
`get`/`getmodule` query them (so anything `overrideconfig` changes is reflected too).
Additional config sources (env vars, k8s config maps) are out of scope for v1 but would
plug in by populating the same namespaces before the store is queried — the `get`/
`getmodule` contract stays unchanged. See the EXTENSION POINT comment in `config.q`.

> **Note:** avoid `-` in config file paths — a source-level backtick symbol literal
> containing `-` parses as subtraction (`` `:/a-b.q `` → `` `:/a `` `- b.q`), not one
> symbol. Runtime string paths (built internally by `loadcascade`) are unaffected.

## Injectable dependencies

| Injectable | Required keys | Function signature |
|---|---|---|
| `log` | `` `info`warn`error `` | `{[c;m]}` (context symbol, message string); caller passes an already-conforming binary dict — built from `di.log` (the standard logger, which exports binary `info`/`warn`/`error`) or hand-rolled. No adaptation is done in the module — a non-binary logger (e.g. a raw monadic `kx.log` instance) must be wrapped first |

## Hard dependencies

None — `di.config` is a standalone module.

## Design notes & open gaps

- **Return values are informational.** `loadcascade` returns the path(s) it *considered* — including
  files that were missing or skipped. The real effect is the side-effect load; use the return to see
  what was attempted, not what definitely loaded.
- **Missing cascade files are skipped, not errored.** The internal `loadconfig` logs a missing
  `dir/{name}.q` at *info* and skips it — absence is normal in the cascade (most `{proctype}`/
  `{procname}` files won't exist).
- **Dedup / idempotency.** `loadconfig` tracks loaded paths in `.z.m.loaded` and skips re-loads, so
  the cascade is safe to re-run and `init` is safe to call again.
- **`overrideconfig` deviates from TorQ deliberately.** Per-variable problems (undefined name,
  non-basic type, value that won't parse to the target type) are logged and skipped — a single bad
  override never aborts the batch and a null is never written into config.
- **Entry point is `loadcascade[dirs;names]`, NOT a zero-arg `load[]`.** The Plan sketches
  `di.config.load[]`, but that predates the integration design. Config loading happens once at
  startup, so a blank call buys nothing and would force the cascade inputs into hidden `.z.m` state
  (temporal coupling with `init`). Explicit args keep di.config a pure, env-free resolver: di.torq
  resolves `KDBCONFIG`/`KDBAPPCONFIG` → dirs and `proctype`/`procname` → names and passes them. (Also
  `load` is a reserved word, so the Plan's literal name is unusable anyway.) If di.torq ever wants a
  blank trigger it's a one-line wrapper on its side — not di.config's concern.
- **Config store is live namespace globals, not an explicit internal store (1a, deliberate).** Settings
  files assign globals when executed, so those namespaces *are* the store; `get`/`getmodule` read them.
  An explicit store with provenance / cross-source precedence (1b) is deferred until a second config
  source (env, k8s) exists — the `get`/`getmodule` contract is storage-independent, so that swap won't
  touch consumers. See the `EXTENSION POINT` comment in `config.q`.

Open gaps / not implemented:

- **No runtime reload.** TorQ's `reloadf` (force-reload an already-loaded file) is not ported —
  `loadconfig` always dedups. Adequate for startup; revisit if runtime config reload is needed.
- **`overrideconfig`'s null-parse guard targets scalar/vector basic types**; a string-typed (`10h`)
  config var is an uncommon edge where the per-element null check is loose.
- **No committed `di.log` integration test yet.** `di.log` (the standard logger) currently lives on
  the `feature-logging` branch and isn't merged, so a committed `use\`di.log` test would fail on this
  branch. di.config's contract match with `di.log` is **verified manually** — the real `di.log` was
  wired end-to-end with no code change (`init`/`loadcascade`/`loadconfig` all emit through it). The
  committed kx.log-wrapper test proves the same binary-`{[c;m]}`-dict contract `di.log` satisfies. Add
  a `di.log` integration test once `di.log` merges.
- **Logger storage follows the skill's single-dict pattern** (`.z.m.log[\`info][…]`), which diverges
  from `consistency.md`'s three-flat-var example (`.z.m.loginfo`/`…`). `di.log` is now built and the
  single-dict pattern is the directed one; `consistency.md` still needs reconciling to match.

## Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.config
```

## Follow-ups (deferred until other modules land)

di.config is complete for v1 in isolation. The items below are intentionally deferred;
each is keyed to the module or milestone that unblocks it. Do these **when the trigger
lands**, not before.

### When `di.log` merges to main

- **Add a committed `di.log` integration test.** Today `di.log` lives on the
  `feature-logging` branch (unmerged), so a committed `` use`di.log `` test would fail
  here — the contract match is verified manually and stood in for by the kx.log-wrapper
  emission test. Once `di.log` resolves on `QPATH`, add a test that builds
  `` `info`warn`error!(logger.info;logger.warn;logger.error) `` from `di.log` and drives
  `loadcascade` through it.
- **Re-verify only if `di.log`'s contract changes.** It isn't final/approved yet. No
  di.config code change is expected — di.config needs only binary `info`/`warn`/`error`,
  which `di.log` exports — but if those signatures change, re-run the integration drive.

### When `di.torq` is built

- **Prove the end-to-end flow.** `getmodule` is unit-tested here, but "partition per
  module and inject via `init`" only runs for real once `di.torq` exists. Add a
  multi-module integration test (under `di.torq`/`di.inttest`, not here) exercising:
  di.torq resolves `KDBCONFIG`/`KDBAPPCONFIG` → `dirs` and `proctype`/`procname` →
  `names`, calls `loadcascade`, then `overrideconfig` with the command-line params, then
  `getmodule` per module → each module's `init`.
- **Hold the env-free boundary.** di.config reads no env vars or process identity —
  di.torq owns that resolution and passes `dirs`/`names` explicitly. Do **not** add a
  zero-arg `load[]` to di.config; if di.torq wants one it wraps `loadcascade` in a line
  on its own side.

### When `di.depcheck` is built (versioning rollout)

- **Add a `version` export and `deps.q`.** No module ships these yet and `di.depcheck`
  (which consumes them) doesn't exist. When it lands, add `version:"…"` to the export and
  a `deps.q` (empty/minimal — di.config has no hard deps) as part of the coordinated
  repo-wide rollout, not a di.config-only change.

### When a second config source (env vars, k8s config maps) is needed

- **Implement the 1b explicit store.** Replace the live-namespace-globals store with an
  internal store carrying provenance / cross-source precedence, behind the unchanged
  `get`/`getmodule` contract (so consumers don't change). See the `EXTENSION POINT`
  comment in `config.q`.
