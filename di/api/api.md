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

## Design decisions

- **Registry-only, no live scan.** The core departure from TorQ. Module functions live in private
  `.z.m`, invisible to `\v`/`\f`, so a live-namespace scan would report a process's top-level glue as
  its API, not the module logic. The registry is populated explicitly instead and is the single
  source of truth (see "Not ported" for the TorQ functions this drops).
- **Module-owned metadata (`getapimeta`).** Rather than a central hand-maintained list, each module
  declares its own API as data — one `(name;public;descrip;params;return)` row per export — and
  `di.torq` collects and registers them via `add`. Names in `getapimeta` are **bare** (the module's
  own); `di.torq` applies process-wide qualification. `di.api` dog-foods this: `getapimeta` documents
  its own seven exports, and a test asserts every `export` name has a matching row.
- **Metadata is a compact row literal, not resident data.** `getapimeta` is built with the
  row-oriented `flip cols!flip(rows)` idiom — one self-contained line per function — rather than five
  parallel column-lists, so it stays terse and a function can't drift out of column alignment. It
  costs the module nothing at runtime: it's a *function*, materialised once when `di.torq` calls it
  at startup, then registered centrally; the module keeps no resident copy. This is the form the
  modularisation skill mandates for every module.
- **`find` unifies the query surface.** `f` and `p` are just projections `find[;01b]` / `find[;1b]`,
  so there is one matching implementation. Symbol patterns become `*substring*`, `` ` `` matches all,
  and strings pass through as globs — all case-insensitive.
- **Minimal, registered surface.** The public API is small and every entry is something `di.torq`
  will actually register. TorQ's introspection helpers are dropped, not stubbed (below).

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
