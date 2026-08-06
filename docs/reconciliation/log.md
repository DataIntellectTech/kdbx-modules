# Reconciliation — `log` → `di.util.log`

**Status:** LANDED + verified (119 k4unit green; full framework regression green).
**Decision:** canonical = **kdbx `main`'s `di/log`** (PR #90). Our interim stub is **retired**.
**Sides:** kdbx `origin/main:di/log` · TorqX `di/util/log` (stub)

> **Supersedes the first pass (2026-08-04).** That pass concluded there was *no competing
> implementation*: `origin/feature-logging` was an empty placeholder and no `di/log` existed on any
> branch, so TorqX's stub was placed as-is with the real implementation left as a future sprint.
> That is no longer true — **PR #90 landed a real structured logger on `main` on 2026-08-05**,
> alongside four other merges (toml #116, eodtime #108, config #113, dbwrite #95). This record
> replaces the earlier one; the follow-up it described ("real implementation, its own sprint") is
> now **done upstream**, not outstanding.

## Why main's implementation wins

No contest — ours was explicitly an interim stub (`.z.p LEVEL ctx msg` to stdout/stderr, three
functions, 8 lines) whose own header said "real `di.util.log` wraps kx.log; swap later". Main's is
the real thing:

- **`createlog[]` factory** returning independent logger instances: six levels
  (`trace debug info warn error fatal`) with level filtering, multiple named format templates
  (`basic`/`syslog`/`raw`, plus `addfmt` for custom), and add/remove of multiple **sinks** per level
  (each a `(handle;sender)` pair, so mixed types never collide).
- **printf-style messages** — `fmtmsg` accepts either a plain string or `(fmtstring;args…)` with
  `%s`/`%r`/`%%`, arity-checked against the format string.
- **rfc5424 syslog severities**, os-aware newline, `$p/$l/$i/$h/$m/$s` format substitution.
- **`logdict`** — a ready-made `` `log!(6 levels) `` dict designed to drop straight into any
  `di.*` module's `init[deps]`.

## Drop-in for the injected contract

The crux: main's module-level `trace/debug/info/warn/error/fatal` are plain `{[ctx;msg]}` binary
functions — **exactly** the contract di.torq injects. `di.torq.buildlogdep` does
`` lg:use modname; `info`warn`error!(lg`info;lg`warn;lg`error) `` ([torq.q:67](../../di/torq/torq.q#L67)),
so it picks up the new module unchanged, and `di.torq.depcheck`'s `contracts` entry for
`di.util.log` (`` `info`warn`error ``) is satisfied — verified live, `checkcontract` returns `()`.

**No consumer changed.** Not one of the ~20 `di.util.log` reference sites needed an edit.

## Naming: kept at `di.util.log` (the toml precedent)

Main ships this flat as `di.log`; we keep the hierarchical `di.util.log` and rename on the way in —
identical treatment to `di.util.toml`, which also now sits flat on main as `di/toml`. Deliberately
*not* the `di.serverselect` treatment (kept flat), because unlike serverselect this name is already
load-bearing across the branch: it is di.torq's **default log module**
(`modname:$[`log in key overrides;overrides`log;`di.util.log]`), a key in depcheck's `contracts`
dict, the subject of a depcheck version assertion, and the referent of a dozen error messages.

The rename is a safe plain substitution — `di.log` is not a substring of `di.util.log` — applied
with a `(?!\w)` guard so nothing else absorbs it. Only `test.csv` (1 line) and `log.md` (7) carried
the name; `log.q` itself never mentions it.

> Worth flagging for RFC phase 5: toml, config, log, eodtime and dbwrite are now all **flat on
> main** while this branch carries hierarchical copies of the first three. The flat↔hierarchy
> divergence this creates is exactly what phase 5 exists to resolve, but it is now growing on the
> main side rather than only on ours.

## Changes applied

Placed at `di/util/log`, replacing all four stub files with main's, plus:

- **`VERSION` kept at 0.1.0** — deliberately *not* bumped. Nothing pins it (no `deps.toml`
  declares `di.util.log`), the module has never shipped outside this branch, and
  [depcheck/test.csv:48](../../di/torq/depcheck/test.csv#L48) asserts the live module reports
  `found 0.1.0`. Holding the number keeps that assertion honest at zero churn.
- **`version` export added** to `init.q` — safe here: this module has no `getapimeta` and no test
  asserting an exact export set (unlike di.util.toml / di.torq.config / di.torq.servers, where the
  contract test forced VERSION-file-only).

## One behavioural change to note

Our stub sent `error` to **stderr** (`-2`); main's `logline` sends **every** level to stdout
(`-1`) — confirmed empirically (an error line still appears with `2>/dev/null`). Low impact in
practice: `torqx.sh` redirects both streams to the same per-process log file, and the systemd units
send both to the journal. But it is a real change, and "errors belong on stderr" is worth raising
with the author rather than patching locally.

## Verification

- **`di.util.log` k4unit: 119/119 green** (was 4/4 for the stub) — instance isolation, level
  filtering, format templates incl. custom, multi-sink add/remove, printf substitution, invalid
  level/format rejection.
- **Live probe:** `version` reads `"0.1.0"`; the three injected functions are all binary and emit
  the new structured line (`2026.08.06D… [INFO] [myctx] …`); `checkcontract` returns `()`;
  `logdict` is `` `log ``→ all six levels.
- **Full framework regression, each in its own process:** toml 60, **log 119**, config 58,
  depcheck 120, handlers 160, servers 35, tplogmgr 12, serverselect 129, di.torq 35 — **all green**.
  di.torq's 35 are the end-to-end ones, so the whole stack now boots on the real logger.

## Follow-ups

- `origin/feature-logging` (still an empty placeholder) can now simply be **closed** — the work it
  was reserved for landed as #90.
- Raise the stderr question above with the author.
