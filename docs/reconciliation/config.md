# Reconciliation — `config` → `di.torq.config`

**Status:** LANDED (module reconciled + verified). One optional follow-up: wire `overrideconfig`
into `di.torq` (see below) — a behaviour addition, held for a go-ahead.
**Decision:** canonical = **kdbx `feature-config`** (a superset). TorqX `di.torq.config` retired.
**Sides:** kdbx `origin/feature-config:di/config` · TorqX `di/torq/config`

## Why kdbx's implementation wins

Both resolve a `.q`+`.toml` settings cascade into one flat dict. kdbx's is the superset:

| Capability | TorqX | kdbx `feature-config` |
|---|---|---|
| `cascade` (2 roots × default/proctype/procname) | explicit 5-tier | **name-major with `distinct` dedup** (correct when procname==default or ==proctype) + non-null symbol validation |
| `parsefile` `.toml` | delegates to toml **without guarding existence** | **checks existence first**, then delegates — a missing `.toml` tier never triggers the toml dep |
| `overrideconfig` (command-line layer) | — | **type-aware override** replacing torq.q's `overrideconfig` (bool/byte null-less handling, scalar-vs-vector, string-as-is, unknown-key/non-basic-type skip, never writes a null) |
| `init` (logger), `getapimeta` (di.api), input validation | — | present |

Crucially, kdbx's existence-first `parsefile` **resolves the fail-loud-`parsefile` fork flagged in
the toml reconciliation**: because config checks the file exists before delegating, `di.util.toml`'s
signal-on-missing is never hit by the cascade. TorqX's `mergetier` (which called `parsefile` on
`.toml` tiers unguarded) would have broken against the fail-loud toml — another reason to drop it.

`di.torq` consumes config **only via `cascade`**, with the identical 4-arg signature — so adopting
kdbx config is drop-in for the orchestrator.

## Changes applied on placement

- Placed at `di/torq/config`; `di.config` → `di.torq.config` throughout; `di.toml` →
  `di.util.toml` (the reconciled toml module) in `requiretoml` + messages.
- Added a `VERSION` file; **not** a `version` export — that would break kdbx config's `getapimeta`
  contract test (`(asc key cfg)~asc getapimeta names`). depcheck reads VERSION from disk. (Same
  decision as `di.util.toml`.)
- Updated config.q's stale "di.toml … (not yet in kdbx-modules)" comment — it's present now.
- **Test update:** the test's `.toml` section assumed toml was *absent* (asserting an existing
  `.toml` *signals* for lack of a toml module). Now that `di.util.toml` is present, rewrote those
  into a real config↔toml integration: an existing `.toml` **parses** (`a`→`1j`, integer→long,
  proving the typed parse flows through). The missing-`.toml`→empty (existence-guard) case is kept.
- Verified: **58 k4unit checks green** (cascade dedup/name-major, overrideconfig type handling,
  the config↔toml integration, and the real `kx.log` emission test).

## Follow-up DONE — `overrideconfig` wired into `di.torq`

`di.torq` now applies the command-line override layer (`-somevar value`) as the top cascade tier,
closing the gap vs classic TorQ (Rule C3). In `torq.init`:

- `logdep` is now built **before** config (it has no config dependency), so config's override layer
  can log through it;
- config's logger is wired (`(cc`init)[…]`), then after `cascade`:
  `config:(cc`overrideconfig)[config; clioverrideparams .Q.opt .z.x]`;
- self-identity (`proctype`/`procname`) is stamped **after** the override, so it always wins.

A pure helper `clioverrideparams[cmdlineopts]` filters `.Q.opt .z.x`: it drops the reserved
launcher/identity flags (`proctype procname torqxstackid p norun` — consumed by the launcher and
di.torq itself) and passes the rest to `overrideconfig`, which parses each into its setting's type
and skips any that don't name a real setting. So a normal launch (all-reserved flags) is a clean
no-op; only genuine `-setting value` flags override.

**Tests:** 6 rows added to di.torq's test.csv exercising `clioverrideparams` (reserved dropped, real
setting flags kept with their `.Q.opt` string-list values, empty/all-reserved → no overrides),
accessed via the module namespace `.m.di.0torq.clioverrideparams` (the same white-box pattern the
handlers test uses; the export stays `init`/`version`). **All 6 verified green in isolation.**

**Caveat — full di.torq k4unit suite is currently inert on the branch:** `di.torq.init` `use`s
`di.torq.depcheck` and `di.torq.servers`, which are **not yet reconciled** (still contested
`feature-depcheck`/`feature-server`), so init throws `notfound: di.torq.depcheck`. The override
rows (which don't need init) and the end-to-end override behaviour will run green once depcheck +
servers land — that's the next reconciliation step.
