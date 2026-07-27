# di.config

Configuration loading and cascade resolution for the modular TorQ world. It replaces
TorQ's in-process config handling (`torq.q`: `loadf`, `loadconfig`, `loadaddconfig`,
`overrideconfig`). `di.config` resolves a settings **cascade** over a builtin root and an
app root — reading **both** flat `name:value` `.q` files and `.toml` files — and returns
the merged configuration as **one flat dict**. `di.torq` calls it once at startup
(`config:cascade[...]`) and hands that dict to each module's `init`.

## The config model — one flat dict

`di.config` resolves config into a **returned flat dict**; it does not execute settings
files into namespaces or hold any global store. This is the shape `di.torq` consumes:

```q
config:use`di.config
cfg:config.cascade[builtinroot;approot;`rdb;`rdb1]   / -> `subscribeto`rows`... !(...)
/ di.torq stamps identity and hands the whole dict to each module's init:
cfg:cfg,`proctype`procname!(`rdb;`rdb1)
rdb.init[cfg;`log`timer!(logdep;timerdep)]
```

`cascade` and `parsefile` are **pure** — no `init`, no logger, no globals — because
`di.torq` resolves config *before* the logger dependency has been built. Only
`overrideconfig` logs (it reports skipped/rejected overrides), so it — and only it —
requires `init`.

## Precedence

The cascade is resolved over **two roots** (`builtinroot`, `approot`) × a **three-tier
name sequence** (`default` → `{proctype}` → `{procname}`). Precedence is **name-major**:

1. A more specific **name** always wins — `{procname}` beats `{proctype}` beats `default`.
2. **Within a name**, the later (app) root overrides the builtin root.
3. **Within a single tier** (one root + one name), the `.toml` file wins over the `.q`
   file on a key clash — useful mid-migration when both formats coexist.

So a key set in both `builtin/{proctype}` and `app/default` resolves to the **builtin
proctype** value, not the app default (name beats root). Effective load order, low → high
priority:

```
builtin/default(.q,.toml) → app/default → builtin/{proctype} → app/{proctype}
  → builtin/{procname} → app/{procname}   (each tier: .toml overrides .q)
```

`overrideconfig` sits on **top** of all of this — the command-line layer (see below).

> **Note — name-major, not root-major.** The KDBX-POC's own vendored `di.config` used
> *root-major* precedence (all builtin tiers, then all app tiers), where `app/default`
> would beat `builtin/{proctype}`. `di.config` deliberately keeps the **name-major** rule
> TorQ has always used; `.toml` support was layered on without changing it.

> **Note — avoid `-` in config file paths.** A source-level backtick symbol literal
> containing `-` parses as subtraction (`` `:/a-b.q `` → `` `:/a `` `- b.q`), not one
> symbol. The runtime string paths `cascade` builds internally are unaffected.

## Settings file formats

- **`.q`** — plain `name:value` lines. Split on the first `:`; the RHS is run through
  `value`, so `` `:hdb ``, `` `trade`quote ``, `` `symbol$() `` all work. Blank lines and
  `/`-comment lines are skipped. These are **flat** files (one process's config), **not**
  the namespaced, executable settings files legacy TorQ `\l`-loaded.
- **`.toml`** — delegated to **`di.toml`**, loaded lazily (only when a `.toml` file is
  actually present). TOML has no symbol type, so every TOML string comes back as a q
  string, never a symbol — consumers that need a symbol normalise at the point of use
  (`` `$ `` is a no-op on an already-a-symbol value).

## Import and init

`cascade` and `parsefile` need no `init` and no logger — call them directly:

```q
config:use`di.config
cfg:config.cascade["/opt/torqx/di/torq/settings";"/opt/app/settings";`rdb;`rdb1]
```

`overrideconfig` logs, so wire a `log` dependency via `init` first — there is no silent
fallback. Pass an already-conforming binary `` `info`warn`error `` dict of `{[c;m]}`
loggers (context symbol, message string); the module performs **no** adaptation.

```q
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
[`kx.log`](https://github.com/KxSystems/logging) instance) must be wrapped by the caller
first — di.config does no wrapping.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `cascade` | `cascade[builtinroot;approot;proctype;procname]` | Resolve the settings cascade over the two roots × the `default`/`{proctype}`/`{procname}` name sequence and **return one flat dict**. Pure — no `init`, no logger, no globals. Precedence is name-major with `.toml > .q` within a tier (see above). A key set nowhere is simply absent; an all-missing cascade returns an empty dict. |
| `parsefile` | `parsefile[path]` | Parse a single settings file into a flat dict. A `.toml` path is delegated to `di.toml` (loaded lazily, behind the guard rail below); a `.q` path is flat `name:value` lines. A missing file (either extension) → empty dict. An existing `.toml` file with no `di.toml` on `QPATH` signals a clear error naming the file. Pure. |
| `overrideconfig` | `overrideconfig[config;params]` | Apply the **command-line override layer** on top of a resolved config dict — the top tier of the cascade. `di.torq` parses the process command line (`.Q.opt .z.x`) and calls this after `cascade`, so launch-time flags (e.g. `-loglevel info`, `-rows 5000`) win over the settings files. `config` is the dict from `cascade`; `params` is a dict keyed by setting name (symbol) with string (or list-of-string) values, each parsed into that setting's **existing** type. Only keys already present with a basic type are overridden; unknown keys, non-basic types, and unparseable values are logged and skipped. Returns the **updated config dict**. Requires `init`. |
| `init` | `init[deps]` | Wire the injected logger for `overrideconfig`. `deps` is a dict with a required `log` key — an already-conforming binary `` `info`warn`error `` dict of `{[c;m]}` functions. Errors immediately if the log dependency is missing or malformed. |
| `getapimeta` | `getapimeta[]` | This module's API metadata — one `(name;public;descrip;params;return)` row per exported function, for `di.torq` to register with `di.api`. |

Internal helpers — `parsetier` (per-tier `.q`+`.toml` merge), `applyoverride`,
`parsefailed`, and `hexchars` — are deliberately not exported.

## Injectable dependencies

| Injectable | Required keys | Function signature |
|---|---|---|
| `log` | `` `info`warn`error `` | `{[c;m]}` (context symbol, message string). Caller passes an already-conforming binary dict — built from `di.log` or hand-rolled. No adaptation is done in the module. Needed only by `overrideconfig`. |

## Hard dependencies

None mandatory. `cascade`/`parsefile` gain a **lazy, soft dependency on `di.toml`**: it is
`` use``d only when a `.toml` file is actually encountered, so the `.q`-only path needs
nothing. **di.toml does not need to be in the repo (or on `QPATH`) for di.config to load or
run** — it is required only at the moment a `.toml` settings file is actually parsed.

### The `.toml` guard rail

`parsefile` guards the di.toml load so a missing module produces a clear, actionable error
rather than a cryptic `notfound`. The order is deliberate:

1. **Check the file exists first.** A missing file (either extension) → empty dict. So a
   missing `.toml` tier *never* triggers the di.toml requirement — the internal
   `parsetier`/`cascade` probe `base,".toml"` on every tier, and absent tiers cost nothing.
2. **Then, only for a `.toml` file that actually exists, require di.toml.** The internal
   `requiretoml` helper attempts `` use`di.toml `` under protected evaluation; if it is not
   found, it signals a clear error **naming the offending file**:
   ```
   'di.config: cannot parse TOML file '/path/to/x.toml' - the di.toml module was not found
    on QPATH; a di.toml module is required to parse .toml settings (underlying: notfound: di.toml)
   ```
3. **Parse.** With di.toml resolved, the file is delegated to it.

Because this signal happens at config-resolution time — *before* the logger dependency is
wired — it surfaces via the raised error (which aborts startup with the reason), not via the
injected logger.

### Contract di.config expects from di.toml

A di.toml module must export a **`parsefile`** function taking a settings-file path string
and returning a **flat dict** of `setting → value`:

```q
(use`di.toml)[`parsefile] "/path/to/settings.toml"   / -> `dir`rows!(":appdb";100)
```

TOML has no symbol type, so di.toml returns every TOML string as a **q char string** (never
a symbol); di.config applies no coercion, so consumers that need a symbol normalise at the
point of use (`` `$ `` is a no-op on an already-a-symbol value).

> **⚠️ `di.toml` is not yet in kdbx-modules** — it currently lives only in the KDBX-POC and
> lands here with the PoC merge (a di.toml module is in development against the contract
> above). Until it is on `QPATH`, the `.toml` half of a tier is **dormant** in this repo: a
> `.toml` file that exists but cannot be parsed raises the guard error above; the `.q` path
> works standalone. Full `.toml` resolution is verified in the PoC (where `di.toml` is
> vendored); this repo's suite covers the guard's error path (di.toml absent) and the
> file-exists-before-delegation ordering.

## Design notes & open gaps

- **Returned dict, not a global store.** Resolution is a pure function returning a dict.
  There is no queryable config store and no per-namespace `getmodule` — `di.torq` passes the
  whole resolved dict to every module and each reads the keys it cares about. A missing key
  is a caller bug (surfaced as a q null on an inline index), not something the config layer
  silently papers over — every setting is expected to be booted with a default in the
  `default` tier.
- **Retired: the executable-namespaced `.q` path.** An earlier revision also shipped a
  `loadcascade`/`loadconfig`/`getmodule` path that `\l`-loaded namespaced, code-bearing `.q`
  settings files (`.rdb.subscribeto:...`) into root namespaces and sliced them per module.
  That parallel model was **removed** in favour of the single flat-dict cascade `di.torq`
  actually consumes. If runtime config reload or an in-process store is ever needed, that is
  a deliberate, separately-designed addition — not a silent revival of the globals path.
- **`overrideconfig` is the command-line layer, applied by `di.torq` — not a manual step.**
  It mirrors TorQ's `overrideconfig`/`override[]`, which TorQ runs at startup off
  `.Q.opt .z.x` so launch-time flags beat the settings files. di.config just does the
  type-aware apply onto the resolved dict (which is why it stays env-free and never reads
  `.z.x` itself). It deviates from TorQ deliberately on error handling: per-setting problems
  (unknown name, non-basic type, value that won't parse to the target type) are logged and
  skipped — a single bad override never aborts the batch and a null is never written.
- **`overrideconfig` parse-failure detection is type-aware.** Most basic types parse to a
  null on a bad value, which `applyoverride` rejects via a null check. Boolean (`1h`) and
  byte (`4h`) are the only in-scope basic types with **no null** — `"B"$"bad"` yields `0b`,
  `"X"$"gg"` yields `0x00`, both non-null — so a bad value would slip past a null check and
  silently corrupt config. `parsefailed` handles these two explicitly (boolean must be
  `"0"`/`"1"`; byte must be even-length hex); anything else is rejected and logged, never
  written.
- **String-typed (`10h`) settings are overridable — as text, no parse.** A char-string
  setting's override value *is* already a string, so `applyoverride` takes it as-is rather
  than casting it (any string is valid; there is no parse-failure case). This matters because
  TOML has no symbol type, so a `.toml`-origin setting like `dir = ":appdb"` or
  `loglevel = "info"` comes back as a string — without this, such settings could not be
  command-line-overridden at all, whereas their `.q`-origin symbol equivalents (`` dir:`:appdb ``)
  could. di.config stays policy-free: it preserves whatever type the setting already had
  (string in, string out; symbol in, symbol out), leaving symbol-vs-string normalisation to
  the consumer as everywhere else.
- **The sentinel merge key.** `cascade`'s accumulator is seeded with a sentinel
  `` (enlist`)!enlist(::) `` key so its value list stays general from the first merge — a
  same-typed value list coalesces to a typed vector that `,:` then refuses to widen (e.g.
  adding a `` `symbol$() `` key to a dict whose values so far were all plain symbols). The
  sentinel is dropped before the dict is returned.
- **Logging uses the three-flat-var convention** — `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`,
  called as `.z.m.loginfo[\`ctx;"msg"]` — matching `consistency.md` and `di.compression`. The
  injected `log` value is still the same `` `info`warn`error `` dict; `init` fans it out into
  the three module-local vars.

## Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.config
```

The `.toml` path is exercised in the KDBX-POC (where `di.toml` is vendored), not here —
see the hard-dependencies note above.

## Follow-ups (deferred until other modules land)

di.config is complete for v1 in isolation. The items below are intentionally deferred;
each is keyed to the module or milestone that unblocks it.

### ⚠️ Logging call convention — NOT set in stone (ask before changing)

di.config uses the **three-flat-var** convention (`.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`),
matching `consistency.md` and `di.compression`, but the project hasn't finalised this versus
the **single-dict** form (`.z.m.log[\`info][…]`). **Before changing di.config's logging — or
wiring logging in another module — stop and ask the user which convention is authoritative.**
Switching is mechanical (storage + call sites only; the injected input contract is identical).

### When `di.toml` lands in kdbx-modules (with the PoC merge)

- **Add committed `.toml` tests.** Today `di.toml` is not on this repo's `QPATH`, so a
  committed `.toml`/mixed-tier test would fail here (verified in the PoC instead). Once
  `di.toml` resolves, add tests covering: a `.toml` tier parsed into the dict, `.toml`
  winning over `.q` within a tier, and a mixed `.q`+`.toml` cascade.

### When `di.log` merges to main

- **Add a committed `di.log` integration test.** The contract match (binary
  `` `info`warn`error `` dict) is verified manually and stood in for by the kx.log-wrapper
  emission test. Once `di.log` resolves on `QPATH`, add a test that builds the dict from
  `di.log` and drives `overrideconfig` through it.

### When `di.torq` is built

- **Prove the end-to-end flow.** Add a multi-module integration test (under
  `di.torq`/`di.inttest`, not here) exercising: `di.torq` resolves `KDBCONFIG`/`KDBAPPCONFIG`
  → roots and `proctype`/`procname` → identity, calls `cascade`, then `overrideconfig` with
  the command-line params, then hands the resolved dict to each module's `init`.
- **Hold the env-free boundary.** di.config reads no env vars or process identity — di.torq
  owns that resolution and passes the roots and identity explicitly.

### When `di.depcheck` is built (versioning rollout)

- **Add a `version` export and `deps.q`.** When `di.depcheck` lands, add `version:"…"` to the
  export and a minimal `deps.q` (di.config has no hard deps) as part of the coordinated
  repo-wide rollout, not a di.config-only change.
