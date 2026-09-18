# di.torq.proc.discovery

The **discovery service** process type for the modular TorQ world — the `di.torq.proc.*` analogue
of TorQ's `code/processes/discovery.q` *plus* the client half of the protocol that legacy spread
across `.servers` on every process (`code/handlers/trackservers.q`: `autodiscovery`, `procupdate`,
`registerfromdiscovery`, `querydiscovery`, `retrydiscovery`, `getdetails`, and the `DISCOVERY*`
settings). All of that collapses into this one process module so that `di.torq.servers` can stay
completely generic and discovery-unaware.

It is the **sole active party**: it dials every process in `process.csv` (and, if enabled,
`nontorqprocess.csv`) through its own injected `di.torq.servers` instance, re-reads those phone
books every tick to pick up processes that were not there last time, **evicts** rows that have
left every phone book (a decommissioned process — a merely *down* one is retained and retried, as
legacy did), and **pushes** the rows it currently holds a live handle to into every subscribed
peer by calling that peer's root-published `.torq.servers.addprocs` (and
`.torq.servers.removeprocs` for the evictions). Peers never register, self-report or dial back in. A peer that wants to
be told about services dials a `discovery` row in *its* phone book (ordinary `connections` config)
and calls `.discovery.getservices[proctypes;1b]` over that handle, once.

PROCESS-tier module. Injected: `log`, `timer`, `handlers`, `servers` (all required). **No `use`
dependencies** — a leaf in the hard-dependency graph. `deps.toml` pins the injected
`di.torq.servers` at **≥ 0.5.0** (it needs `getallservers` and `removeprocs` in the injected dict,
and its peers' `.torq.servers.addprocs` / `.torq.servers.removeprocs`).

## Config

Flat keys (the proctype-module convention — a `[section]` is only used for di.torq-owned add-ons and
does not deep-merge across cascade tiers), read with a presence check and an inline default:

| key | default | meaning |
|---|---|---|
| `retryperiod` | `30` | seconds between ticks (a tick = re-read phone books → `startup` if changed → push). A single number, or text/symbol that parses as one; must be positive. |
| `tracknontorqprocess` | `true` | also read the non-TorQ phone book. Legacy's own `discovery.q` settings turn this on even though the general default is off — discovery is precisely where it matters. Boolean or text. |
| `nontorqprocessfile` | `nontorqprocess.csv` beside `process.csv` | the non-TorQ phone book (same `host,port,proctype,procname` format). A relative path resolves beside `process.csv`; absolute as given. Env-free: the directory comes from `config`processcsv`. |
| `hopentimeout` | `200` (builtin tier) | **a `di.torq.servers` key, not read here** — the `hopen` timeout (ms) for every dial the injected servers instance makes, first attempt and each 10 s retry redial alike. Discovery dials *everything*, so a host that is down (SYN timeout, not an instant refusal) would otherwise cost the servers default of 2000 ms per dead row per retry cycle, with any subscriber's sync `getservices` waiting behind it. `di/torq/settings/discovery.q` ships `hopentimeout:200` for this proctype (legacy `config/settings/discovery.q` parity); an app's `settings/discovery.toml` can override it. Hand-wired deployments (like the integration children) get servers' default unless they pass it. |
| `processcsv`, `proctype`, `procname` | stamped by di.torq | the phone book path (string, or an hsym-style symbol — a leading `:` is stripped) and this process's identity — required. **The file must exist at init** (fail fast); a file that vanishes later is a logged tick failure, retried next tick. |

**Why 30 s.** `di.torq.servers`' own dead-handle retry runs every 10 s, but that only re-dials rows it
already knows; this job re-reads files from disk and may open new connections every tick. Legacy's
`RETRY`/`DISCOVERYRETRY` defaults are both 5 minutes, but those sat beside a bidirectional
dial-back mechanism this design does not have — discovery is now the *only* way a new process is
found, so it cannot be that leisurely. 30 s is the middle ground; it is exposed so a deployment can
tune it either way.

**No `retain`/`autoclean`.** Legacy's real discovery settings retain records forever
(`RETAIN:`long$0Wp`, `AUTOCLEAN:0b`); that is carried forward as the fixed behaviour for a
*disconnect* — a row stays in the registry, reconnected by the servers retry job when its process
returns. Removal is a different event, keyed on the phone book, not on liveness: see "The tick".

**No `DISCOVERYREGISTER` / `CONNECTIONSFROMDISCOVERY` / `SUBSCRIBETODISCOVERY` / `DISCOVERY` list.**
All of those were consumer-side or self-referential settings in legacy's shared `.servers`; with
discovery as the sole active party there is nothing to configure on a consumer.

## Initialisation

`init[config;deps]` (two-arg, the process-module convention — `di.torq.startbuiltin` calls it so):

1. validates every dep and its contract shape with a plain signal (the logger is not wired yet) —
   `servers` must carry `` `startup`getallservers`removeprocs `` (exactly the keys this module
   calls; that is di.torq.servers ≥ 0.5.0), `config` must carry `processcsv`/`proctype`/`procname`, the phone book
   must exist, `retryperiod` must be a single positive number;
2. stores the deps and the flat config in `.z.m`, and forgets what it has seen/pushed/queued so the first
   tick below re-reads and re-logs;
3. one-time registrations, guarded by a `registered` flag so re-init is idempotent:
   a `.z.pc` observer (`register[`.z.pc;`;`discovery;0j;pcfunc]` — a *simple* event, coexisting
   with di.torq.servers' own observer in the same fan-out) that drops a departed subscriber, and
   the `discoverytick` timer job (`addjob[`discoverytick;tick;();retryperiod;1;jobopts]`, mode 1 =
   seconds) with **`disableonfail` off** — di.timer's default would silently disable the job after
   one failing run, and one bad cycle must never stop discovery for good. A **re-init** (di.torq
   never does one; a test or an operator might) refreshes deps and settings but cannot re-register
   the job — a changed `retryperiod` is warned about rather than silently ignored;
4. publishes the IPC surface at real root names — `set[`.discovery.getservices;…]`,
   `set[`.discovery.getsubs;…]` — because `use` loads the file into a private namespace;
5. runs `tick[]` **once, synchronously**, so peers are found at startup rather than one period later.

```q
/ what di.torq does (startbuiltin), shown by hand
disc:use`di.torq.proc.discovery
disc.init[config;`log`timer`handlers`servers!(logdep;timerdep;handlersdep;serversdep)]
```

## The tick

`tick` is the job body (protected: `@[tickbody;::;tickfail]`, the failure logged at error). Each
cycle:

1. **`readbooks`** — read *every* phone book first: `process.csv`, and `nontorqprocess.csv` when
   tracking is on and the file exists (its absence is warned **once**, not every tick, and again
   only if it appears and vanishes again). A read that fails — file gone, a **0-byte file caught
   mid-rewrite**, wrong header — raises here and the whole tick is abandoned (logged, retried next
   tick) **before anything is evicted or dialled**, so a bad read can never masquerade as
   "everything is gone". A garbage or short *line* parses to a row of nulls and is simply
   undialable.
2. **`evict`** — every registry row whose `(procname;proctype)` is **listed in no phone book any
   more** has been decommissioned: it is removed through the injected `removeprocs` (which closes a
   live handle — removal is not a disconnect) and queued, per subscriber and filtered to what that
   subscriber asked for, to be sent as `(`.torq.servers.removeprocs;rows)`. The diff is
   **stateless** — registry vs. files, every tick — so it is right after a re-init too, and it
   needs no bookkeeping of "what I listed last time". *Listed* means present in a file at all,
   dialable or not: a port-0 row is not a decommission. **Sanity guard:** `process.csv` must list
   this discovery's own `(procname;proctype)` row (di.torq starts it from that row) or nothing is
   evicted that tick (warned once) — a file caught **header-only** by a line-by-line writer parses
   cleanly and lists nothing, and without the guard would decommission every process and close
   every subscriber's handles for one tick (observed live against the POC stack before the guard).
   A removal may name a row a subscriber never held (a row that was never live is never pushed) —
   `removeprocs` ignores unknown rows, so that is a logged no-op on the subscriber. A port *move* is not an eviction either
   (same name/type still listed) — `mergerows`' replace rule handles it. The `hpup` in the removal
   is the registry's own (whatever servers' `formathp` built), so it is the exact triple servers
   dedups on — a subscriber's row matches whether it came from a discovery push or from the
   subscriber's own phone book with the same host/port.
3. **`dialfrom`** each book — keep the **dialable** rows (a row with no host, no identity, or no port / port 0 — the loader
   convention — would only fail every retry; such rows are counted in the log and never handed to
   servers), and **only if those rows changed since the last tick** ask the injected servers to
   `startup` for *every distinct proctype among them* (the legacy `` `ALL `` translation lives here,
   so `di.torq.servers` needs no `` `ALL `` sentinel). `startup` is repeat-safe since servers 0.4.0
   — known rows skipped, new rows dialled — and its own 10 s retry job reopens dead ones, so an
   unchanged file has nothing to gain from another call, and skipping it keeps "N rows already
   known" out of the log every tick. The rows are recorded as seen only **after** `startup`
   returns: servers re-reads the file itself, and if that second read catches a rewrite and
   throws, the next tick retries rather than treating the change as handled. A garbage or short *line* parses to a row of nulls and is
   dropped as undialable; a file with the wrong header — or a **0-byte file caught mid-rewrite** —
   is a clear logged error for that tick, recovered on the next. Both files fold into the one
   `SERVERS` registry — nothing is special about a non-TorQ row.
4. **push** — build the *live view* (every registry row with a non-null handle, minus rows of this
   process's **own proctype**), and for each subscriber whose handle is still open send it its
   slice — its requested proctypes, or everything for `` `ALL `` — as an async
   `(`.torq.servers.addprocs;rows)` — **after** any removals still queued for it, sent as
   `(`.torq.servers.removeprocs;rows)` and cleared only once sent. Empty slices are not sent. The
   live push goes **every tick** (idempotent on the consumer; self-healing) but is **logged only
   when** the live view, the subscriber set or their wants changed, so a steady state is silent; a
   removal is an *event*, sent once. A subscriber with bytes still queued on its handle from an
   earlier tick (`.z.W[h]`, a peer that has stopped reading) is skipped with a warning rather than
   risked blocking on — its removals stay queued for the next tick (async sends sit in `.z.W` until
   the event loop flushes them, which is why the check is once per subscriber per tick, not per
   send). A push that throws is logged at warn and that subscription — and its queue — dropped
   (the handle is gone).

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `init` | `init[config;deps]` | Wire deps + config, register the observer and the job, publish the root names, run the first tick. Idempotent. |
| `getservices` | `getservices[proctypes;subscribe]` | The live services of the given proctypes (a symbol or non-empty list without nulls; `` `ALL `` for every proctype) as `procname`/`proctype`/`hpup` rows, right now. With `subscribe=1b` the **calling handle** is recorded so every later tick pushes its slice; a repeat call replaces the earlier subscription. A *local* call with `subscribe=1b` still answers but records nothing (there is no remote handle to push to) and says so in the log. Also at root as `.discovery.getservices`. |
| `getsubs` | `getsubs[]` | Current subscriptions — one `handle`/`proctypes` row per subscribed handle. Also at root as `.discovery.getsubs`. |
| `getapimeta` | `getapimeta[]` | Api metadata for `getservices`/`getsubs` (plumbing omitted), for di.torq to register with di.api. |
| `version` | | from the `VERSION` file (0.1.0). |

Internal: `tick`/`tickbody`/`tickfail`, `dialfrom`, `dialable`, `dialnontorq`, `readprocs`,
`liveview`, `wanted`, `pushall`/`pushto`/`pushfail`, `recordsub`, `pcfunc`, `raiseerror`, the
coercions (`assym`/`asstr`/`asbool`/`aslong`/`aspath`, `dirof`/`resolvefile`); state `subs`,
`registered`, `jobperiod`, `seen`, `lastpush`, `warnedntfile`, `jobopts`, and the config values.

**Deliberately no `register`.** Legacy's niladic self-announce entry point does not survive the
unidirectional model — nothing ever calls it, because discovery reads identity straight out of the
phone books rather than needing a peer to self-report. It was not forgotten.

## Wire contract

| direction | call | where it lives |
|---|---|---|
| consumer → discovery | `h(`.discovery.getservices;proctypes;1b)` — subscribe (or `0b` for a one-shot answer) | published by this module at root on the discovery process |
| consumer → discovery | `h(`.discovery.getsubs;`)` — inspect subscriptions | same |
| discovery → consumer | `(neg h)(`.torq.servers.addprocs;rows)` — async push, `rows` a `procname`/`proctype`/`hpup` table | published by `di.torq.servers.init` at root on **every** process that runs it, whether or not anything pushes |
| discovery → consumer | `(neg h)(`.torq.servers.removeprocs;rows)` — async removal of exact rows (a decommissioned process) | same (servers ≥ 0.5.0) |

The pushed rows land in the consumer's `SERVERS` as *known, not connected* (`w:0Ni`) — its own
servers retry job opens them on its normal 10 s cycle, exactly as for a phone-book row whose first
dial failed (legacy `procupdate` parity). `addprocs` dedups on the same merge rule as `startup`
and drops the consumer's own row, so a consumer can hold the same process in its phone book *and*
learn it from discovery without a duplicate, and is never told to dial itself.

A removal deletes the consumer's exact matching row and **closes its handle** — the process is
gone from the deployment, not merely down. If the consumer's own phone book still lists that
process (a different `process.csv` from discovery's), the row stays gone until the consumer's own
`startup` runs again (at its next restart): for the proctypes it subscribed to, discovery is the
authority. In the normal single-app deployment both read the same `process.csv`, so the row has
left the consumer's book too.

`hpup` is whatever `di.torq.servers.formathp` built from the phone book — it does not translate
`localhost` to a real hostname (legacy did), so a `localhost` phone-book row is only dialable by a
same-box consumer. Inherited from servers; noted there too.

## Design record

**Unidirectional, and why.** Legacy discovery is bidirectional because discovery and every consumer
share the same `.servers` module, so "dial back in and `register`" is free. Here it is not: a
consumer-side discovery mechanism would mean discovery-aware code and config in `di.torq.servers`
— the opposite of the premise that servers stays a generic connection registry. So discovery does
all the dialling and pushes; the only thing a consumer needs is a generic push target, which every
process already has. One direct consequence: legacy's real discovery instance sets `RETRY:0D00` —
it never retries its own dead connections, because every other process's own retry logic dialled
back in. That safety net does not exist here, so the injected servers' retry job (and this module's
tick) is load-bearing in a way legacy's never was. Do not copy legacy's `RETRY:0D00`.

**Live rows only.** In legacy a row reached discovery's registry only by self-registering (alive at
the time) or from process.csv at startup, and `getservices` never filtered on liveness. Under the
unidirectional model *every* phone-book row is known from tick one whether or not it is up, so
"everything known" would just relay the phone book — a consumer that wants that has process.csv.
Discovery hands out what it can actually reach (legacy's own doc line: "only gives out
information on registered services"). A consumer therefore never dials dead hosts it learned from
discovery; a new process is announced within one tick of discovery connecting to it (found by
discovery's servers retry, ≤ 10 s, then pushed on the next tick, ≤ `retryperiod`). Once pushed, a
process that later dies is the consumer's own retry job's concern, exactly as today.

**Merge rule (in servers 0.4.0, relied on here).** Exact `(procname;proctype;hpup)` = skip; same
`hpup` *or* same `(procname;proctype)` = replace (old handle closed, row deleted). Legacy only
replaced on `hpup` and left a ghost row when a port moved — that ghost was retried forever.
Before 0.4.0 servers' `startup` had **no** dedup at all: every call appended a fresh row per
phone-book entry, unnoticed because every consumer called it exactly once. This module calls it
every tick, twice — it is the reason that fix exists.

**Non-TorQ processes: no separate table.** With a dedup-safe `startup`, `nontorqprocess.csv` is
just a second phone book in the same format pointed at the same registry. Legacy carried a
separate `nontorqprocesstab` and hpup-exclusion logic because its `startup` was not safe to
re-run.

**Subscriptions are real, not incidental.** `subs` (handle → proctypes) is legacy's own
`subs:(`int$())!()`: only subscribed handles are ever pushed to — it is not a broadcast to every
connected peer, however the one-line design sketch might read. A consumer that never calls
`getservices` receives nothing. The `.z.pc` observer forgets a departed subscriber; a consumer that
reconnects (a new handle) re-subscribes by calling `getservices` again — a consumer-side
responsibility, deliberately, so servers stays discovery-unaware.

**Periodic push instead of connect-triggered.** Legacy pushed to subscribers only inside `register`
(i.e. when a peer connected in), so a *change* (a process gone and back on a new port) was never
propagated. Pushing the live view on every tick propagates changes for free; `addprocs`' dedup
makes the repetition a no-op on the consumer (and, since servers 0.5.0, a silent one).

**Eviction, and why it is keyed on the phone book.** Neither legacy nor servers ≤ 0.4.0 ever
*removed* a row: `startup`/`addprocs` only add, and with retain-forever a process permanently
taken out of `process.csv` sat in discovery's registry (`w:0Ni`, retried every 10 s) and in every
subscriber it had been pushed to, indefinitely — a phantom that grew without bound. Retain-forever
is right for a *disconnect* (that is what retry is for) and wrong for a *decommission*, and the
only signal that distinguishes them is the phone book: a listed process that is down is retained;
an unlisted process is gone. So eviction diffs the registry against the books every tick, and
relies on `readbooks` failing *before* the diff so a mid-rewrite file never reads as empty.
Removal has to propagate to subscribers or the phantom just moves one hop downstream — hence
`removeprocs` is a servers primitive that is both root-published (discovery tells a subscriber)
and injected (discovery evicts from its own registry, which it cannot reach across the module
boundary). That asymmetry with `addprocs` (root-published only) is deliberate.

**Attributes stay out.** `attributes`/`attributematch` are `di.serverselect`'s domain end to end.
Even in legacy `.gw.servers` (with attributes) is a separate table from `.servers.SERVERS`, kept in
sync via the `addprocscustom`/`connectcustom` hooks — discovery's own push never carried reliable
attributes; they came from a separate self-report handshake. This module staying attribute-free
matches the boundary legacy's working code already drew.

**Redundancy.** Run more than one discovery process. Each is fully independent (its own dial-out,
registry and push cycle); they dial each other (proctype `discovery` is not excluded from
`startup`) but never hand each other out. A consumer wanting resilience lists several `discovery`
rows in its phone book and calls `getservices` on whichever is live — legacy's `querydiscovery`
razed every live discovery's answer together, a consumer-side concern.

**Legacy defects not carried forward.** `discovery.q`'s `register` closed any *other* row sharing
the caller's hpup by index — racy against `cleanup` running inside the same call; the `.z.pc` chain
was built by direct assignment (`.dotz.set` of a closure over the previous handler) rather than a
fan-out registry; `getservices` ran `cleanup[]` as a side effect of a query; `retryrows` executed
`.proc.getattributes` on every reconnected peer. None of that has an analogue here.

**Coercions.** A setting may arrive as a real value (`.q`/`.toml` cascade) or as text (a raw
`-flag` override, as the integration children pass them): `aslong` parses text or a symbol with
`"J"$` (a lower-case `"j"$` on a string casts each *character* to its code — the `retryperiod`
bug the integration suite caught first time), `asbool` accepts booleans, numbers (non-zero) and
the text `true`/`1`/`1b` (note a one-character string literal is a char *atom* — `"1"` in a list
of alternatives never matches a string; it has to be `enlist "1"`), `aspath` takes a string or an
hsym-style symbol.

**Nothing module-local inside a qsql.** Inside a `use`-loaded module a qsql cannot resolve a
module-local function name and a `$[..]` inside one throws `'rank`; every qsql here reads only
locals and builtins (see di.torq.servers 0.4.0 for the measurement).

## Known gaps

- `hpup` for a `localhost` phone-book row is only usable on the same box (servers' `formathp`).
- A subscription is keyed on a handle: a consumer that reconnects must call `getservices` again
  (the shipped subscriber child does so at startup, so a restart re-subscribes; the OS may hand the
  new connection the same fd number the dead one had — harmless, because the `.z.pc` observer
  dropped the old subscription first).
- No push acknowledgement — the push is async; a peer without `.torq.servers.addprocs` /
  `.torq.servers.removeprocs` (not running di.torq.servers ≥ 0.5.0) silently ignores it.
  `di.torq.depcheck`'s manifest walk on the consumer side is the guard.
- A decommission that happens while **no** discovery instance is running is never announced: a
  subscriber keeps the phantom until it restarts (a fresh registry) — a restarted discovery has
  nothing to diff it against. Run more than one instance (the redundancy model above).
- A removal queued for a subscriber that disconnects before it is delivered is dropped with the
  subscription; its re-subscription is a fresh handle and, if the subscriber restarted, a fresh
  registry.
- Deleting a phone book *file* (rather than truncating it) is a decommission of everything only it
  listed; an editor that deletes-then-recreates would evict and re-add within two ticks (the 0-byte
  truncate-then-write pattern is safe — that read fails and the tick is abandoned).
- A registry row that disappears *without* the phone book changing (an operator calling
  `removeprocs` on the discovery process directly) is not re-dialled until the file changes or
  discovery restarts — change detection is keyed on the file, deliberately, so an ambiguous phone
  book is warned about once rather than every tick.
- Eviction is disabled (warned once) while `process.csv` does not list this process — a discovery
  run against a phone book that omits its own row never evicts.
- The consumer side lives in **di.torq ≥ 0.6.0** (torq.md "Discovery auto-subscribe"): a process
  opts in with `discoverywant` (or `discovery` in `connections`), di.torq dials discovery for it and
  subscribes generically, re-subscribed every 10 s so a reconnect self-heals, and a discovery
  instance never subscribes to a sibling. No proc module calls `getservices` itself.
- **A discovered backend is not routed to by `di.torq.proc.gateway` until the gateway's own EOD
  reload or a restart — independent of discovery.** The gateway registers its backends into
  di.serverselect only at init and at EOD reload-end (`registerbackends`, gateway.q), so *any*
  backend that connects after gateway init — a plain rdb restart mid-session on a stock POC, or a
  boot-order dial failure that the 10 s retry later recovers — sits live in the gateway's servers
  registry but absent from its routing table. Found while integrating discovery against the POC
  (the gateway held a live `rdb1` handle and routed only to `hdb` after a plain `torqx.sh start`);
  not caused by discovery and not fixed here — raised with the gateway's owner as its own item.
- A row of a *mixed* proctype (one dialable, one port-0 row of the same type) is still dialled by
  servers' `startup` for the undialable member — only a type with **no** dialable rows is withheld.
  The real fix is a dialable-row filter inside `di.torq.servers.startup` (recommended; not applied
  here as it is not needed for discovery to run).

## Running tests

Unit suite (mocked deps + one plain-q peer carrying a recording `.torq.servers.addprocs`; the
subscription is recorded against the test's own open handle because a single k4unit run cannot
service a peer's call back into it — measured, it deadlocks):

```q
/ from the repository root, in a fresh q session, with this repo on QPATH
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.discovery      / 260 checks
```

Integration suite (`test_integration.csv`, 9 scenarios): real child kdb-x processes — the
discovery service on the real `di.util.log`/`di.timer`/`di.torq.handlers`/`di.torq.servers`,
plain-q backends, real subscriber children on `di.torq.servers`, two discovery instances side by
side, a port-0 row and a garbage line in a real phone book, a backend dying and returning, a
backend **decommissioned** from `process.csv` while still running (evicted from discovery and from
an `` `ALL `` subscriber, which closes its handle; back when the line is restored), a subscriber
dying and returning, a non-TorQ file appearing after startup and being deleted, and a genuine
`di.torq` boot through `torqx_init.q` with a `discovery.toml` cascade (which also proves the
builtin settings tier hands servers `hopentimeout` 200), and di.torq's generic auto-subscribe
end to end (a config-only consumer subscribed on two instances that never subscribe to each
other; a restarted instance re-subscribed unaided). Every child is killed by the `after`
row. Skips cleanly if no child can be started.

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.torq.proc.discovery;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]
```
