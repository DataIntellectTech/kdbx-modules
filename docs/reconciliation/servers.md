# Reconciliation — `servers` → `di.torq.servers`

**Status:** LANDED + verified. **di.torq's full suite is now green** — servers was the last core
dep, so the whole framework tier boots end-to-end.
**Decision:** canonical = **kdbx `feature-server`** (a superset; already injected-style).
**Sides:** kdbx `origin/feature-server:di/servers` · TorqX `di/torq/servers`

## Why kdbx's implementation wins

Both are the injected connection-management capability (process.csv phone book, handle-by-type
lookup, a `.z.pc` cleanup observer + a retry timer job, idempotent init). kdbx's is the more
complete and polished:

- **Already injected-style and already correct on the handlers contract** — its init registers
  `(handlers[\`register])[\`.z.pc;\`;\`servers;0j;pcfunc]`, i.e. the **full `.z.pc`** event name and
  the `register[event;phase;nm;pri;func]` shape the reconciled `di.torq.handlers` expects. So the
  `` `pc ``→`` `.z.pc `` fix flagged during the handlers step is **already done** here.
- `raiseerror` (log-then-signal), `getapimeta` (di.api), a `cleanup` sweep for handles that vanish
  *without* a clean `.z.pc` (ungraceful peer death), the catenate-not-`insert` module-local-rewrite
  note, the "10s not 10000ms" retry-period typo guard, and careful `hopen (h;timeout)` rank notes.
- A real spawned-peer integration test (a genuinely separate licensed q) exercising connect /
  gethandle / ungraceful-kill → cleanup → retry-reconnect / waitfortype.

## The one integration change: `startup` takes the config

kdbx uses the one-arg `init[deps]` convention (config merged into deps), matching how di.torq
already calls handlers/config/depcheck — good. But its `startup[]` was **no-arg**, reading
connections from init-time config. That doesn't fit the consumer pattern: each consumer computes a
**role-specific** connection list (an rdb dials its tickerplant+hdb types, a gateway its backend
types) and passes it at startup — di.torq can't know that list at init time.

So `startup` now takes the **config** (reading `connections` + `processcsv` from it), keeping all of
kdbx's internals. This exactly matches the consumers' existing `(\`servers\`startup)[sconfig]` calls,
so **the consumers (rdb/wdb/gateway) need no changes**. `init` still handles self-identity + the
one-time `.z.pc`/retry registration; `startup` handles the (per-consumer) connections.

## Changes applied

- Placed at `di/torq/servers`; `di.servers`→`di.torq.servers`, `di.handlers`→`di.torq.handlers`,
  `di.log`→`di.util.log`; `VERSION` file (0.3.0), no `version` export (would break the `getapimeta`
  contract test — same call as toml/config/depcheck/servers).
- `startup[]` → `startup[config]`; `getapimeta`'s `startup` row updated to match.
- **di.torq wiring:** `buildserversdep` now merges config + injectables into a one-arg `init[deps]`;
  di.torq stashes the `process.csv` path into `config` (`processcsv`) after the identity stamp, so
  both servers.init and each consumer's `sconfig` carry it (keeps servers' env-free boundary).
- **Test harness fix:** the kdbx test loaded its fixtures via `di.os.abspath`, whose GNU
  `realpath -ms` fails on macOS, and still used the old flat `di/servers/test.q` path. Switched to
  the cwd-relative `system "l di/torq/servers/test.q"` (moduletest guarantees cwd=repo root) — same
  pattern as every other module test; dropped the `di.os` dependency.

## Verification

- **`di.torq.servers` k4unit: 35/35 green** (real spawned-peer integration).
- **`di.torq` k4unit: 35/35 green** — the payoff. With servers landed, di.torq boots end-to-end,
  which verifies *in one run*: the config cascade + the `overrideconfig` CLI layer, the depcheck
  pre-load VERSION graph **and** the post-load session audit (the aligned `cp` contract passes on a
  real load), the reconciled servers (one-arg init + `startup[config]` + real `.z.pc` registration
  through di.torq.handlers), and the app-code cascade + run hook.
- Full framework regression (each module in its own process): toml 60, log 4, config 58, depcheck
  120, handlers 160, servers 35, tplogmgr 12, di.torq 35 — **all green**.

The core framework tier (log · toml · config · depcheck · handlers · servers · di.torq) is
reconciled and green. Remaining D5: the library/query tier — dataaccess, serverselect, pubsub, and
the vendored asyncdispatch/eodtime/dbwrite — plus the proc modules' own suites (which need those).
