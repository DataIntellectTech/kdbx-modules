# di.config

Configuration loading and cascade resolution for the modular TorQ world. This
replaces TorQ's in-process config handling (`torq.q`: `loadf`, `loaddir`,
`loadconfig`, `loadaddconfig`, `overrideconfig`), where `di.torq` will later
distribute the resolved config to each module via that module's `init`.

## Import and init

`init` requires a `log` dependency — there is no silent fallback. Pass an
already-conforming binary `` `info`warn`error `` dict of `{[c;m]}` loggers (context
symbol, message string). The module performs **no** adaptation, so a raw monadic
[`kx.log`](https://github.com/KxSystems/logging) instance must be wrapped by the
caller first (this is `di.log`'s job once it ships):

```q
config:use`di.config

/ option 1: di.log (standard, once it ships) - build the binary dict from its exports
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)
config.init[enlist[`log]!enlist logdep]

/ option 2: hand-rolled binary {[c;m]} logger (works today)
mylog:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});
config.init[enlist[`log]!enlist mylog]
```

To wrap a raw `kx.log` instance yourself in the interim, fold the context into the
message per call: `` `info`warn`error!({[c;m]inst[`info][string[c],": ",m]};…) ``.

`init` must be called before any other function — there is no default logger.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire the injected logger. `deps` is a dict with a required `log` key — an already-conforming binary `` `info`warn`error `` dict of `{[c;m]}` functions. Errors immediately if the log dependency is missing or malformed. |
| `loadfile` | `loadfile[file]` | Load a single q config file (a string path) if it exists, tracking it so it is not re-loaded. Returns the path. A missing file is a logged warning, not an error; a failed load is signalled. |
| `loadconfig` | `loadconfig[dir;name]` | Load one cascade config file `dir/{name}.q` (`dir` a string path, `name` a symbol) if present. Returns the constructed path. A missing file is **normal** in the cascade, so its absence is logged at *info* and skipped (not warned). Present files load via `loadfile`. |
| `loaddir` | `loaddir[dir]` | Load every `.q`/`.k` file in a directory (a string path), honouring an optional `order.txt`. Files listed in `order.txt` load first, in that order; the rest follow. Returns the ordered list of file paths processed. A missing directory is a logged warning returning `()`. Delegates each load to `loadfile`, so already-loaded files are skipped. |
| `loadcascade` | `loadcascade[dirs;names]` | Resolve a config cascade: for each settings directory (in order) load each named file `dir/{name}.q` (in name order). `dirs` is a string path or list of paths; `names` is a symbol or symbol list. Later names and later directories override earlier ones (load order). Missing files are skipped. Returns the flat list of constructed paths in cascade order. |
| `overrideconfig` | `overrideconfig[params]` | Apply command-line-style overrides after the cascade. `params` is a dict keyed by variable name (symbol) with string (or list-of-string) values, each parsed into that variable's **existing** type. Only already-defined, basic-typed variables can be overridden; undefined names, non-basic types, and unparseable values are logged and skipped. Returns the list of variables actually overridden. |
| `get` | `get[namespace;key;default]` | Query the resolved config store: return the value of `.{namespace}.{key}`, or `default` if unset. `namespace` and `key` are **bare** symbols (no leading dot), e.g. `get[\`rdb;\`subscribeto;\`]`. (`get` is a reserved word, so the implementation function is named `getcfg` and exported under the `get` key.) |
| `getmodule` | `getmodule[namespace]` | Return a namespace's whole resolved config as a bare-keyed value dict — the slice di.torq passes to a module's `init`. `namespace` is a bare symbol; an unconfigured namespace yields an empty dict. |

`order.txt` is a plain-text file, one filename per line, naming the files that must
load ahead of the rest (e.g. to satisfy load-order dependencies).

Internal helpers (`raiseerror`, `applyoverride`) and the load-tracking state are deliberately
not exported.

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
> symbol. Runtime string paths passed to `loadfile` are unaffected.

## Injectable dependencies

| Injectable | Required keys | Function signature |
|---|---|---|
| `log` | `` `info`warn`error `` | `{[c;m]}` (context symbol, message string); caller passes an already-conforming binary dict (from `di.log` once it ships, or hand-rolled). No adaptation is done in the module — a raw monadic `kx.log` instance must be wrapped first |

## Hard dependencies

None — `di.config` is a standalone module.

## Design notes & open gaps

- **Return values are informational.** `loadfile`/`loadconfig`/`loaddir`/`loadcascade` return the
  path(s) they *considered* — including files that were missing or skipped. The real effect is the
  side-effect load; use the return to see what was attempted, not what definitely loaded.
- **Missing-file log level is deliberate.** `loadfile` logs a missing explicit path at *warn* (you
  asked for it); `loadconfig` logs a missing cascade file at *info* (absence is normal — most
  `{proctype}`/`{procname}` files won't exist); `loaddir` logs a missing directory at *warn* and
  returns `()`.
- **Dedup / idempotency.** `loadfile` tracks loaded paths in `.z.m.loaded` and skips re-loads, so the
  cascade is safe to re-run and `init` is safe to call again.
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
  `loadfile` always dedups. Adequate for startup; revisit if runtime config reload is needed.
- **`order.txt` is matched against the full directory listing** (as in TorQ), so a non-`.q`/`.k` file
  named in `order.txt` would still be prepended and load-attempted. Keep `order.txt` to q/k files.
- **`overrideconfig`'s null-parse guard targets scalar/vector basic types**; a string-typed (`10h`)
  config var is an uncommon edge where the per-element null check is loose.
- **Standard logger (`di.log`) does not exist yet.** Callers must supply a hand-rolled binary
  `` `info`warn`error `` dict in the interim; the kx.log wiring test wraps kx.log caller-side to prove
  real emission.
- **Logger storage follows the skill's single-dict pattern** (`.z.m.log[\`info][…]`), which diverges
  from `consistency.md`'s three-flat-var example (`.z.m.loginfo`/`…`). Per the skill this is the
  directed pattern, pending `consistency.md` being reconciled once `di.log` ships.

## Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.config
```
