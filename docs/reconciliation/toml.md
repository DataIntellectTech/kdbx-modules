# Reconciliation — `toml` → `di.util.toml`

**Status:** RECOMMENDED (landed in working tree; awaiting `feature-toml` author sign-off)
**Decision:** canonical = **kdbx `feature-toml` implementation**; TorqX `di.util.toml` retired.
**Sides:** kdbx `origin/feature-toml:di/toml` · TorqX `di/util/toml`

## Why kdbx's implementation wins

Both were built to the same scoped-down spec (the TorQ-FSP settings survey — identical
supported/unsupported feature lists, both policy-free: TOML strings → q char strings, never
symbols). kdbx's is the more robust and more framework-integrated:

- **Escape-aware in-string masking** (`instrmask`) correctly handles `\"` *inside* a string.
  TorqX's `firstunquoted` used `mod[;2]sums s="\""`, which miscounts an escaped quote as
  toggling string state — so a `#`/`,`/`=` after an escaped quote could be misread.
- **Fail-loud throughout:** validates bare-key charset, rejects dotted keys, **detects duplicate
  keys/sections** (a real TOML error — TorqX silently last-wins), rejects malformed arrays,
  unterminated arrays, unparseable scalars, and non-string input. TorqX could yield silent nulls.
- **Single-pass `unescape`** resolves `\\` adjacent to an escape char correctly; TorqX used an
  ordered `ssr` chain that mishandles that case.
- **`getapimeta`** — callable-API metadata for `di.torq` to register with `di.api`. TorqX had none.
- Its test.csv (60 checks) is materially stronger, and already asserts the `[dependencies]`
  deps.toml contract that `di.depcheck.readdeps` consumes, plus the `getapimeta` contract.

TorqX's only edges were narrow: a `VERSION` file/`version` export, the hierarchy-correct error
prefix, and `parsefile` returning `()!()` on a missing file. First two are grafted below; the
third is a deliberate design difference (see Follow-ups).

## Changes applied on placement

- Placed at **`di/util/toml`** (the `di.util.*` tier), not flat `di/toml`.
- `di.toml` → `di.util.toml` throughout (error-message prefixes, comments, docs, `use\`di.util.toml`,
  fixture load path `di/util/toml/test.q`).
- Added a **`VERSION`** file (`0.1.0`) so `di.depcheck`'s manifest walk (which reads VERSION from
  disk) has a version to compare. **Not** added `version` to the export dict on purpose — that
  would break kdbx toml's `getapimeta` contract test (exports-except-`getapimeta` must equal the
  documented API). VERSION-on-disk is sufficient for depcheck.
- Verified: **`di.util.toml` k4unit 60/60 green** on `feature-torqx`.

## Follow-ups / author review notes

- **`parsefile` on a missing file SIGNALS** (kdbx: fail-loud, caller guards existence) vs TorqX's
  `()!()`. Kept kdbx's behaviour. **Downstream:** `di.torq.config`'s cascade probes optional
  `.toml` tiers and currently relies on the empty-dict return (config.q:43-45). When `config` is
  reconciled, its `parsefile` wrapper must guard `.toml` existence the same way it already guards
  `.q` (`if[0=count key hsym\`$path; :()!()]`) — kdbx's own `feature-config` reportedly already
  does this. Tracked as a note for the **config** reconciliation step; no live consumer on the
  branch depends on it yet.
- `feature-toml` can be closed as superseded once its author confirms nothing else on the branch
  depends on the flat `di/toml` path. Work carried with attribution to the original author.
