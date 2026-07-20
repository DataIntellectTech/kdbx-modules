# di.api

Registration and metadata for a process's public API functions. Each entry describes one callable
function — its name, whether it is public, and human-readable description / parameters / return
text. The registry is the single source of truth (there is no live-namespace scan, because module
code does not live in scannable root namespaces).

**Registration model:** di.torq collects the api metadata from each module at startup and registers
it here centrally via `add`. di.api has no dependency on other modules, and other modules do not
depend on di.api.

> **Status: v1 complete.** Registry (`add`/`getapi`) and query surface (`find`/`f`/`p`) are in
> place. The live-namespace-introspection tools from TorQ's `.api` (`search`, `whereami`, `mem`,
> `fullapi`'s namespace scan, `exportconfig`) are intentionally **not** ported — see "Not ported".

## Initialisation & Dependencies

`init` must be called before any other function. The `log` dependency is **required** — there is no
fallback, and the module does no adaptation. The `log` value must already be a binary
`` `info`warn`error!{[c;m]} `` dict (context symbol, message string), built from `di.log` or
hand-rolled; a raw monadic `kx.log` instance must be wrapped by the caller first.

```q
api:use`di.api
logger:use`di.log
api.init[enlist[`log]!enlist `info`warn`error!(logger.info;logger.warn;logger.error)]
```

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | Functions `info`,`warn`,`error` — each binary `{[c;m] ...}` (context symbol, message string) |

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[deps]` | Wire the injected logger and start with an empty registry. Errors immediately if the `log` dependency is missing or malformed. |
| `add` | `add[name;public;descrip;params;return]` | Register (or overwrite) one api entry. `name` is a symbol (the registry key), `public` a boolean; `descrip`/`params`/`return` are description text. Re-adding the same `name` updates it in place. |
| `getapi` | `getapi[]` | Return the full registry as a keyed table (keyed on `name`, columns `public`/`descrip`/`params`/`return`). |
| `find` | `find[s;p]` | Return registry entries whose name matches pattern `s` (a symbol — `` ` `` matches all, else a `*s*` substring — or a string glob) and whose `public` flag is in `p` (`1b` public-only, `01b` all). Case-insensitive; returns an unkeyed table. |
| `f` | `f[s]` | `find[s;01b]` — all matching entries, public and non-public. |
| `p` | `p[s]` | `find[s;1b]` — public matching entries only. |
| `getapimeta` | `getapimeta[]` | Return **this module's own** api metadata — one `(name;public;descrip;params;return)` row per exported function — for di.torq to collect and register. Every module exposes this (the module-owned metadata convention). Names are bare (the module's own); di.torq applies process-wide qualification when registering. |

### Registry schema

```q
([name:`u#`symbol$()] public:`boolean$(); descrip:(); params:(); return:())
```

## Not ported from TorQ's `.api` (deliberate)

TorQ's `.api` marries a registry with **live introspection of the root namespaces** (`\v`/`\f` scans,
grepping function definitions, sizing variables). That half does not fit the module world: module
code lives in each module's private `.z.m`, not in scannable root namespaces, so those tools would
see only a process's top-level glue, not the module logic they exist to inspect. Accordingly:

| TorQ function | Why not ported |
|---|---|
| `u` | "public, excluding `.q`/`.Q`/`.h`/`.o`" — only filtered primitives out of the live scan; this registry holds only registered module functions, so `u` == `p`. |
| `search` / `s` | Greps live function *definitions* across root namespaces — cannot see module-private code. |
| `whereami` | Reverse-looks-up a function value to its name via the root scan — returns nothing for a function that lives inside a module (i.e. the usual error-trap case). |
| `fullapi` (namespace scan) | The scan-and-left-join-`detail` model does not apply; `getapi`/`find` serve the registry directly. |
| `mem` / `m` | Memory sizing belongs to `di.memstats`. |
| `exportconfig` / `exportallconfig` / `torqnamespaces` | A faithful port needs config **values** (di.config `getmodule`) joined with **descriptions** (di.api `getapi`/`find`). di.config and di.api are both standalone and don't depend on each other, so the join belongs in **di.torq** (it has both). It is a **di.torq-era task**, not a di.config change: di.config's `getmodule` already returns per-namespace values; the missing piece is pairing them with the api descriptions across namespaces. |

## Hard dependencies

None.

## Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.api
```
