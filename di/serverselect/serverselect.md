# Server Selection

`serverselect.q` maintains a pool of registered backend servers and selects from them by servertype or attribute requirements. Extracted from the `.gw` namespace in TorQ's `gatewaylib.q` and `gateway.q`, it provides the server-selection layer of a gateway — decoupled from query execution and connection management.

---

## Features

- Register backend servers with servertype, procname, host/port, and attribute dictionaries
- Track active/inactive state per server, updated on connect and disconnect
- Select servers using round-robin, most-recently-used, or random strategy
- Query servers by servertype list or attribute requirement dictionary
- Attribute matching supports cross-product and independent strategies with configurable best-effort mode
- Bulk registration from a TorQ-compatible connection table
- Pluggable selection strategy — override the built-in `selector` at run time via `setselector`
- Age-based purge of long-departed servers via `removeinactive`, so the registry does not grow without bound
- Injected logging — supply your own binary `` `info`warn`error `` logger via `init`; required, no default
- Injected clock — supply your own `cp` to make time-dependent behaviour testable without sleeping
- Declares its own api metadata via `getapimeta[]` for `di.torq` to register with `di.api`
- Exports `version`, read from the module's `VERSION` file, as `di.depcheck` requires

---

## Initialisation & Dependencies

`init` wires the module's injected dependencies and **must be called before any other function**. The `log` dependency is **required** — there is no fallback, and the module does not load `kx.log` itself. Initialising the logging framework is the job of the start-up script that ties the modules together, or of the user at run time.

The `log` value must **already** be a binary `` `info`warn`error!{[c;m]} `` dict — each function takes a context symbol `c` and a message string `m`. `init` performs **no** adaptation and fans the dict out into `.z.m.loginfo`/`.z.m.logwarn`/`.z.m.logerr`, called as `.z.m.loginfo[\`ctx;"msg"]`. Build it from `di.log` (the standard logger, which exports binary `info`/`warn`/`error`) or hand-roll one. A raw monadic `kx.log` instance must be wrapped by the caller first — the module will not do it.

```q
srvsel:use`di.serverselect

/ option 1: di.log (the standard logger) - build the dict from its exports
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)
srvsel.init[enlist[`log]!enlist logdep]

/ option 2: a bespoke binary logger {[c;m]} (context symbol, message string)
mylog:`info`warn`error!(
  {[c;m] .my.log.info  string[c],": ",m};
  {[c;m] .my.log.warn  string[c],": ",m};
  {[c;m] .my.log.error string[c],": ",m});
srvsel.init[enlist[`log]!enlist mylog]

/ a raw kx.log instance is monadic - wrap it to binary {[c;m]} before passing:
/   kxinst:(use`kx.log)[`createLog][]
/   `info`warn`error!({[c;m]kxinst[`info][string[c],": ",m]};…)
```

`init` throws with prefix `di.serverselect:` if `deps` is not a dictionary, is missing the `` `log `` key, or the `log` value is not a dictionary exposing `` `info`warn`error ``. All other `di.serverselect:` error conditions are logged via `.z.m.logerr` (with the function as context) before being signalled.

### Optional configuration

Config keys travel on the same flat dict as the dependencies. Each is type-checked at `init`, so a
misconfiguration fails loudly at startup rather than silently at first use.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `cp` | function | `{.z.p}` | Current-time function. Stamps `disconnecttime` and drives `removeinactive`. Override it to fast-forward in tests, or to run on a simulated clock, without sleeping |
| `maxcrossproduct` | long | `1000000` | Upper bound on the requirement cross product `getserverids` will build in `cross` mode, checked before building it. `0W` disables the bound. Cost is the **product** of the requirement value counts, so a gateway forwarding client-supplied requirements can get very large very cheaply |
| `clearinactivetime` | timespan | `0D01:00` | How long a disconnected server should be retained. **Not read by any function in this module** — `removeinactive` is caller-invoked, so this is the age `di.torq` passes it when it schedules the purge, mirroring how `di.dataaccess` uses `requestkeeptime`. It is here so the retention policy is configured in one place alongside everything else |

```q
srvsel.init[`log`cp`clearinactivetime!(logdep;{.z.p};0D06:00)]
```

`init` is re-callable. A re-init rewires the logger and config and **reseeds the live selection
strategy from the built-in default**, discarding anything previously installed by `setselector`. It
does **not** reset the registered server table.

Every public function guards on `init` having run, and says so:

```
di.serverselect: getserverstable: init must be called first
```

rather than surfacing a raw `.m.di.0serverselect.loginfo` and leaking the module's internal
namespace. The two exceptions are deliberate: `version` is a plain string, and `getapimeta[]` is pure
data that `di.torq` collects at startup — possibly before this module's `init` has run.

---

## Server Table Schema

Servers are tracked in the `servers` keyed table (keyed on `serverid`):

| Column | Type | Description |
|---|---|---|
| `serverid` | `int` (key) | Unique auto-assigned server ID |
| `handle` | `int` | Connection handle |
| `procname` | `symbol` | Process name (null if not provided) |
| `servertype` | `symbol` | Process type e.g. `` `rdb ``, `` `hdb `` |
| `hpup` | `symbol` | Host/port symbol e.g. `` `:host:5010 `` (null if not provided) |
| `active` | `boolean` | Whether the server is currently active |
| `lastp` | `timestamp` | Last time this server was selected |
| `hits` | `int` | Number of times this server has been selected |
| `attributes` | `any` | Attribute dictionary registered with the server |
| `disconnecttime` | `timestamp` | When the server was last marked inactive; null while active. Set from the injected `cp`, and read by `removeinactive` |

---

## Functions

### Registration

| Function | Description |
|---|---|
| `addserverfull[h;pname;st;hp;att]` | Register a server with full details: handle, procname, servertype, hpup, attributes |
| `addserverattr[h;st;att]` | Register a server with servertype and attributes; procname and hpup default to null |
| `addserver[h;st]` | Register a server with no attributes |
| `setserveractive[h;active]` | Mark **every registration on a handle** active (`1b`) or inactive (`0b`). Stamps `disconnecttime` on the active→inactive transition and clears it on reactivation |
| `setserveridactive[sid;active]` | Mark **one registration** active or inactive by `serverid`, leaving handle siblings alone |
| `removeinactive[age]` | Delete inactive servers that disconnected more than `age` ago |
| `addserversfromtable[proctypes;conntable]` | Bulk-register from a connection table, filtered by proctype |
| `getserverstable[]` | Return the full registered server table |

`attributes` must be a **symbol-keyed dictionary** (`()!()` when there are none). Note that a keyed
table is also type `99h`, so the check tests the key type rather than the value's type alone —
a keyed table, or a dictionary keyed on anything but symbols, is rejected. The same check guards
`getservers`' `req` and the nested `attrs` requirement dict. This is enforced at
registration: the column is a general list, so a non-dict used to register happily and then surface
much later, in a different function, as a raw unlogged `'type` from `attributematch`'s `key avail` —
and if the *first* registration was malformed the column took that value's type and every subsequent
well-formed registration failed too.

`addserversfromtable` requires an **unkeyed** table and skips handles that are already active. Pass `` `ALL `` as `proctypes` to register all process types. The `conntable` must have columns `w` (int handle), `proctype` (symbol), `attributes` (dict per row); `procname` and `hpup` are optional.

```q
/ register on connect
srvsel.addserverattr[h; getproctype[h]; getattributes[h]]

/ mark inactive on disconnect - stamps disconnecttime
srvsel.setserveractive[h; 0b]

/ bulk registration from TorQ connection table
srvsel.addserversfromtable[`rdb`hdb; .servers.SERVERS]

/ purge servers that disconnected over an hour ago
srvsel.removeinactive[0D01:00]
```

### Handle-level vs registration-level activation

Several registrations may share one physical handle — the same connected process advertising more
than one servertype. The two activation functions cover the two different things a caller means:

| | Keys on | Use when |
|---|---|---|
| `setserveractive[h;a]` | `handle` — affects **every** registration on it | The socket itself went away. A closed handle really does take everything on it down together, so this is what a `.z.pc` disconnect handler calls |
| `setserveridactive[sid;a]` | `serverid` — affects **exactly one** | Pulling a single servertype out of routing while its handle siblings keep serving |

Both stamp and clear `disconnecttime` identically, so a registration retired either way ages out of
`removeinactive` on the same terms. `selector`/`updatestats` already key on `serverid` precisely
because a handle may be shared; `setserveridactive` closes the same gap for activation. Like
`setserveractive`, an unmatched id is a no-op rather than an error.

```q
/ pull one servertype out of routing; the sibling on the same socket keeps serving
srvsel.setserveridactive[sid; 0b]

/ the socket dropped - retire everything on it
srvsel.setserveractive[h; 0b]
```

`setserveractive[h;0b]` only flips a flag — the row stays in the table so the server's history and
attributes survive a reconnect. Without a purge, a process that connected once and never came back
would sit in the registry forever, so `removeinactive[age]` deletes inactive rows whose
`disconnecttime` is more than `age` in the past. Active rows and rows still inside the age window are
untouched, and reactivating a server clears its `disconnecttime` so it can never be purged while up.

`age` must be a **non-null, non-negative** timespan. `0Wn` is accepted and means *retain forever* —
it short-circuits rather than reaching the comparison, because `disconnecttime+0Wn` overflows the
timestamp range (wrapping back to the year 1734), which would make every inactive row compare as aged
out. `0Nn` is rejected for the same reason (`disconnecttime+0Nn` is `0Np`, and every timestamp is
greater than null). Both are exactly the values a caller reaches for to mean "don't purge", so both
are handled explicitly rather than left to do the opposite.

`removeinactive` is **caller-invoked** — this module takes no `timer` dependency, in line with
`di.asyncdispatch.removeinactive`. `di.torq` schedules it, passing the configured
`clearinactivetime`. Both the stamping and the age comparison go through the injected `cp`, so a
caller on a simulated clock — or a test — gets consistent behaviour without sleeping.

---

### Query and Selection

| Function | Description |
|---|---|
| `getservers[nameortype;lookups;req]` | Return active servers matching a servertype or procname filter, with per-attribute match scoring |
| `selector[servertable;selection]` | Pick one row from a server table using a selection strategy |
| `getserverbytype[ptype;col;sel]` | Return one column value for a servertype using the given strategy; updates `lastp` and `hits` |
| `gethandlebytype[ptype;sel]` | Convenience projection of `getserverbytype` returning `handle` |
| `gethpbytype[ptype;sel]` | Convenience projection of `getserverbytype` returning `hpup` |
| `setselector[f]` | Replace the strategy `getserverbytype` uses to pick one row from the candidate table |

`getservers` returns a table including an `attribmatch` column — a dictionary of `attrname!(complete_match_bool;matched_values)` per attribute key in `req`. When `lookups` is not `` ` ``, `nameortype` must be `` `servertype `` or `` `procname ``; any other value throws (and logs) a `di.serverselect:` error rather than silently falling through to a `procname` lookup.

All `di.serverselect:` error conditions — including the input-type checks on `addserverfull`/`setserveractive` and the connection-table column check on `addserversfromtable` — are logged via `.z.m.logerr` before being signalled.

`selector` supports three strategies:

| Strategy | Behaviour |
|---|---|
| `` `roundrobin `` | Pick server with the oldest `lastp` (least recently used) |
| `` `any `` | Pick a random server |
| `` `last `` | Pick server with the newest `lastp` (most recently used) |

`selector` expects a non-empty table; called on an empty table it returns a row of nulls (e.g. a null `handle`). The `getserverbytype`/`gethandlebytype`/`gethpbytype` helpers guard against this and return `()` when no active server matches the requested type.

```q
/ get a handle, round-robin across rdbs
srvsel.gethandlebytype[`rdb; `roundrobin]

/ get host/port for an hdb
srvsel.gethpbytype[`hdb; `roundrobin]
```

`getserverbytype` dispatches through a **live** strategy pointer rather than calling `selector`
directly, so `setselector` can replace the choice at run time — for a weighted or load-aware policy,
say — without patching the module. `selector` itself is untouched by this: it stays exported, stays
the default, and pass it back to `setselector` to restore it.

```q
/ install a load-aware strategy
srvsel.setselector[{[servertable;selection] first `myload xasc servertable}]

/ restore the built-in default
srvsel.setselector[srvsel.selector]
```

A strategy must be **binary** — `{[servertable;selection] …}` — and return a row containing
`serverid`. `setselector` checks the arity **where the mistake is** rather than letting it throw
`'rank` from inside the module at the next `getserverbytype`. The check reads a lambda's parameter
list, and a projection's remaining arity as its underlying rank minus the arguments already supplied
— so capturing a value by trailing partial application works as expected:

```q
srvsel.setselector[{[h;servertable;selection] first select from servertable where handle=h}[myhandle]]
```

Primitives, compositions and adverb-derived functions report no arity in q, so they are **accepted**
rather than guessed at — the check declines to apply rather than rejecting a valid strategy.

`setselector` also rejects a non-function argument, and requires `init` first (it used to accept a
strategy before `init` and then have it silently overwritten by `init`'s reseed). Note that a re-init
discards a custom strategy.

---

### Server ID Lookup

```q
srvsel.getserverids[att]
```

Returns server IDs matching a servertype list or attribute requirement dictionary. Used as the primary dispatch input — pass the result to your async or sync query handler to target specific servers.

#### Symbol list path

Pass a symbol or symbol list of servertypes. Validates that all requested types are registered and currently active.

```q
srvsel.getserverids[`rdb]
srvsel.getserverids[`rdb`hdb]
```

Throws if any requested type is null, unregistered, or all-inactive.

#### Attribute dict path

Pass a dictionary of attribute requirements. Servers whose attribute dictionaries satisfy the requirements are returned. Each requirement value must be an **atom or a simple (flat) vector** of the attribute's type — a nested/general-list value (e.g. from a stray `enlist`, giving `` `date!enlist enlist 2024.01.01 2024.01.02 ``) is rejected with a clear `di.serverselect:` error rather than failing deep in the matcher.

An **atom** requirement value is promoted to a one-element list internally, so the two forms below
are equivalent and return identical results. (`getservers` always accepted an atom; before this the
`getserverids` path threw a raw, unlogged `'rank` on the same input.)

```q
srvsel.getserverids[(enlist`date)!enlist 2024.01.01]        / atom
srvsel.getserverids[(enlist`date)!enlist enlist 2024.01.01] / one-element list
```

The three control keys — `` `servertype ``, `` `besteffort `` and `` `attributetype `` — are
type-checked before matching begins, and a wrong-typed or unrecognised value is a logged
`di.serverselect:` error. They are **not** subject to the atom promotion above, so their type checks
still bite.

#### Two request shapes — flat and nested

In the **flat** form above, control keys sit alongside the attribute requirements, so those three
names are reserved: a server may legitimately *advertise* an attribute called `` `besteffort `` and
`getservers` will score it normally, but `getserverids` intercepts the name as a control key.

The **nested** form removes the collision entirely. An `` `attrs `` key holds the requirements
explicitly, leaving the rest of the dict to the controls — so an attribute may carry **any** name,
control names included:

```q
/ match a server attribute that is genuinely called `besteffort, with a besteffort CONTROL of 0b
srvsel.getserverids[`attrs`besteffort!((enlist`besteffort)!enlist enlist`EU; 0b)]

/ requirements and a servertype scope, no reserved names
srvsel.getserverids[`attrs`servertype!((enlist`date)!enlist 2024.01.01; `hdb)]
```

Both forms are supported and behave identically for non-colliding names; `attrs` is the way out when
an attribute name would clash. Atom promotion applies inside `attrs` exactly as in the flat form.

**The nested form is strict about the top level.** Only `` `attrs `` and the three control keys may
appear beside it; anything else is an error. This is deliberate asymmetry: in the flat form an
unrecognised key is simply a requirement, but in the nested form every non-`attrs` key is a control,
so an unknown one would be silently swallowed — dropping a requirement a half-migrated caller left
outside `attrs`, or ignoring a mistyped `besteffor`. The flat form cannot have that problem, so the
nested form is made strict to be no less safe.

```q
/ rejected: `date was left outside attrs and would otherwise vanish
srvsel.getserverids[`attrs`date!((enlist`sym)!enlist`AAPL; 2024.01.09)]
```

A repeated servertype is resolved **once**: `` `servertype!`hdb`hdb `` returns the matching serverids
in a single group, not two, so a caller dispatching on the result cannot query the same server twice.

```q
/ cross match (default): every date must be available for every sym
srvsel.getserverids[`date`sym!(2024.01.01 2024.01.02; `AAPL`MSFT)]

/ independent match: each date and sym just needs one server somewhere
srvsel.getserverids[`date`sym`attributetype!(2024.01.01 2024.01.02; `AAPL`MSFT; `independent)]

/ scope to specific servertypes then apply attribute filter
srvsel.getserverids[`servertype`date!(`hdb; enlist 2024.01.01)]
srvsel.getserverids[`servertype`date!(`hdb`rdb; enlist 2024.01.01)]

/ strict mode: error if requirements cannot be fully satisfied
srvsel.getserverids[`date`besteffort!(enlist 2024.01.01; 0b)]
```

##### Attribute matching strategies

| `` `attributetype `` | Behaviour |
|---|---|
| `` `cross `` (default) | Every combination of attribute values must be coverable by a single server |
| `` `independent `` | Each individual attribute value only needs to be matched by at least one server |

The reserved key `` `besteffort `` (boolean, default `1b`) controls whether a partial match is acceptable. Set to `0b` to throw if requirements cannot be fully satisfied. It governs partial satisfaction **within** a single servertype's attribute match — it is a different axis from the multi-servertype tolerance described next.

When `` `servertype `` names **several** types, each is resolved independently and a type that matches
nothing is **tolerated**, not fatal: its miss is logged at `warn` naming the type, and the query
returns whatever the other types matched. Only when *every* requested type comes back empty does
`getserverids` log at `error` and signal. This is unconditional — there is no toggle for it.

---

### Module metadata

| Export | Description |
|---|---|
| `version` | Module version string, read from the module's `VERSION` file at load |
| `getapimeta[]` | Table of `` `name`public`descrip`params`return `` rows, one per callable export |

`version` must stay in the export dictionary: `di.depcheck` resolves a dependency's version from
there and classes a missing one as a **failure**, which stops any process that declares this module
as a hard dependency from starting.

`getapimeta[]` describes the **callable** api only. `init` and `getapimeta` are deliberately omitted
— `di.torq` calls both by convention and they are startup plumbing, not part of the api surface
`di.api` should advertise. The module declares this metadata but does **not** call `di.api.add`
itself; collecting and registering it centrally is `di.torq`'s job.

---

## Design notes

Recorded from the design and adversarial-review pass, so the reasoning survives the commit.

### The attribute matcher is the risky part, and it is now tested directly

`getserverscross`, `getserversindependent`, `getserversinitial` and `buildcross` implement
combinatorial matching that cannot be verified by reading. Until this pass the whole suite reached
them only *indirectly*, through `getserverids`' end-to-end behaviour, so a fully green suite was not
evidence of correctness. `test.csv` now exercises them **directly** through the internal
`.m.di.0serverselect.` path — they are deliberately **not** exported for this; internal-path access
gives full test reachability without widening the public contract.

Verified sound, against a running module rather than by inspection: empty requirements degrading to
"any server of the type"; partial attribute coverage excluding only the servers actually missing a
key; `besteffort` `0b`/`1b` divergence; best-match ranking genuinely preferring the widest server
rather than the first candidate found; a single server covering several combinations being returned
once, not duplicated; three-way cross products; `independent` mode; duplicate identical servers;
inactive exclusion; and the empty registry.

### Three defects the review found, and how each was fixed

All three fixes sit at the **boundary** in `getserverids`. The matching engine itself is unchanged.

| | Defect | Fix |
|---|---|---|
| **F1** | A multi-servertype request aborted entirely if *any* one type matched nothing, discarding perfectly good matches from the others | Each type is now resolved under its own protected apply; a miss is logged at `warn` and returns empty, and only an all-types miss errors |
| **F2** | An **atom** requirement value threw a raw, unlogged `'rank` — while `getservers` accepted the same input happily | `normreq` promotes atom values to one-element lists before matching, so both forms behave identically |
| **F3** | `besteffort` and `attributetype` were silently ignored when wrong-typed: `besteffort:0` (int) kept the `1b` default, and an unknown `attributetype` fell back to cross matching | Both are type- and value-checked at the boundary, and a bad value is a logged error |

**F1 is a design decision, not merely a bug fix.** The evidence that tolerance was the original
intent is that `getserverids`' own all-empty guard was **unreachable** — `getserveridstype` threw
before it could ever return empty — so the guard could only have been written for a fan-out that was
expected to tolerate per-type misses. On that basis the tolerance is **unconditional**: there is no
toggle for it, and none was added. Note this is a *different axis* from `besteffort`, which governs
partial satisfaction within one servertype's attribute match; the two are name-adjacent but not the
same knob.

The accepted tradeoff: a future bug inside the engine, on the multi-type path, would surface as a
warn-and-no-match rather than a throw. The error text is preserved verbatim in the warning, and the
call still fails overall when every type misses, so nothing is silently swallowed.

**F3's placement is deliberate.** The control keys are validated in `getserverids`, *before* the
fan-out, and not inside `getserveridstype`. Because F1 wraps each per-type call in a protected apply,
an error raised deeper down would be caught and downgraded into a "this servertype did not match"
warning. A wrong-typed control key is categorically not a per-type miss and must stay loud, so the
check has to happen at the boundary.

### Error logging: raiseerror at the boundary, plain signals in the engine

Public functions route domain errors through `raiseerror`, which logs at `error` under the calling
function's name and then signals — so a failure is observable in the log, not only as a thrown
exception a caller might swallow. `init` is the exception: it signals with a plain `'` because the
logger is not wired yet while it runs.

The matching engine's internal "no match" conditions instead use `signalnomatch`, which signals
**without** logging. These are *outcomes*, not faults, and `getserverids` decides the level: `warn`
for a per-servertype miss that other types may cover, `error` via `raiseerror` only when the whole
request fails. Logging inside the engine would emit an ERROR line for every routine partial match on
a multi-servertype query, which is exactly the noise an operator greps for.

### Smoke-test findings — fixed

A second adversarial pass over the finished module found four more defects, all fixed and covered by
regression rows in `test.csv`:

| | Defect | Fix |
|---|---|---|
| **F4** | `attributes` was never validated. A non-dict registered happily, then threw a raw unlogged `'type` at *query* time from `attributematch`. If the **first** registration was malformed the column took that value's type and every later well-formed registration failed too | `addserverfull` requires a dictionary |
| **F5** | `removeinactive[0Wn]` — infinite age, i.e. "never purge" — **deleted every inactive server**, because `disconnecttime+0Wn` overflows the timestamp range and wraps to the year 1734. `0Nn` did the same via `0Np` | `0Wn` short-circuits as a no-op; null and negative ages are rejected |
| **F6** | A repeated servertype (`` `hdb`hdb ``) was resolved twice, returning the same serverids in two groups, so a caller dispatching on the result would query the same server twice. The symbol path already deduped; the two disagreed | `distinct` applied to the servertype list |
| **F7** | The single-servertype/`` `all `` path had been routed through the tolerant fan-out, replacing the engine's specific wording with a generic message and logging a spurious `warn` | That path uses `raisecaught`: logged once at `error`, re-signalled verbatim |

### Handle/serverid activation asymmetry — resolved, not deferred

`updatestats` keys on `serverid` and comments explicitly that a handle "may be shared by multiple
servers", but `setserveractive` keyed on `handle` — so there was no way to retire one registration
without taking its handle siblings down with it, and nothing in the design said whether that should
be possible. Rather than carry this as an open question into `di.torq`'s `.z.pc` wiring — the moment
it stops being hypothetical and starts firing on real connection churn — `setserveridactive` was
added. `setserveractive` is unchanged: handle-level bulk retirement is still the correct shape for a
genuine disconnect, and is still what that future handler will call.

### Second-pass constraints — all resolved

The smoke-test pass logged five constraints as "not changed"; all five have since been closed.

| Constraint | Resolution |
|---|---|
| Activation keyed on `handle`, selection on `serverid` | `setserveridactive` added; `setserveractive` unchanged |
| No `requireinit` guard | Every public entry point guards and names itself; `version`/`getapimeta` deliberately exempt |
| `setselector` arity unchecked | Checked at the call site for lambdas and projections; undeterminable types accepted rather than guessed |
| Three attribute names reserved | The nested `attrs` request shape removes the collision; the flat form is unchanged |
| Cross-product cost unbounded | `maxcrossproduct` (default 1,000,000, `0W` to disable) checked before the product is built |

Two things worth keeping in mind while reading those:

- The `` `attrs `` form is **additive**. The flat form's reserved names are unchanged, so nothing that
  worked before behaves differently — `attrs` is an opt-in escape hatch, not a migration.
- The arity check **declines to apply** rather than rejecting when q reports no arity. That is the
  deliberate trade: a primitive or composition strategy is accepted unchecked, because rejecting a
  valid strategy is worse than missing an invalid one the next call would catch anyway.

### Third-pass findings — fixed

A further smoke-test pass, aimed squarely at the code the second pass added, found three more:

| | Defect | Fix |
|---|---|---|
| **G1** | In the nested `attrs` form every non-`attrs` top-level key was treated as a control, so an unknown one was **silently swallowed** — a requirement left outside `attrs` vanished, and a mistyped `besteffor` was ignored. The flat form errors on the same input, so the new shape was *less* safe than the old one | Unknown top-level keys are rejected |
| **G2** | `selectorarity` returned null for a projection **of** a projection, so an arity-1 nested projection was accepted and would throw `'rank` later | Resolves the underlying rank recursively |
| **G3** | A **keyed table is also type `99h`**, so the F4 attributes check let one through; likewise a dictionary keyed on non-symbols, which reached the matcher and produced a raw `'length` | `requiredict` tests the key type, and is shared by `attributes`, `attrs` and `getservers`' `req` |

G1 is the one worth remembering: it was introduced *by the fix for F11*, in the same class of bug F3
existed to eliminate. A new request shape inherits none of the old shape's safety properties for free.

### q gotchas worth not rediscovering

- **`$` inside q-sql is the dyadic cast operator, not the `cond` special form.** An inline
  `update disconnecttime:$[a;0Np;.z.m.cp[]] from ...` throws `'rank`. `setserveractive` hoists the
  conditional out of the `update` for this reason.
- **`type` is `99h` for a keyed table as well as a dictionary**, and the empty dict `()!()` keys on an
  empty *general* list (`0h`), not on an empty symbol vector. A "symbol-keyed dictionary" check that
  tests only `11h=type key d` therefore rejects the most common value there is.
- **A strategy function passed to `setselector` is invoked from inside the module**, where a bare
  name resolves against the module's own `.z.m` rather than the caller's root namespace. Capture any
  value the strategy needs by projection rather than reading it from a global — `integration.q`'s
  pinned-handle strategy does this, and reads as `'type` if you don't.

---

## Example

```q
/ load and initialise - init must be called before any other function
/ pass an already-binary `info`warn`error logger (from di.log or hand-rolled)
srvsel:use`di.serverselect
logger:use`di.log
srvsel.init[enlist[`log]!enlist `info`warn`error!(logger.info;logger.warn;logger.error)]

/ register servers as they connect / mark inactive on disconnect
/   on connect:    srvsel.addserverattr[h; getproctype[h]; getattributes[h]]
/   on disconnect: srvsel.setserveractive[h; 0b]

/ bulk register from TorQ stack on startup
srvsel.addserversfromtable[`rdb`hdb; .servers.SERVERS]

/ get server IDs for a query by servertype
serverids:srvsel.getserverids[`rdb`hdb]

/ get server IDs by attribute requirement
serverids:srvsel.getserverids[`date`sym!(enlist 2024.01.01; enlist `AAPL)]

/ get a handle directly (round-robin across rdbs)
h:srvsel.gethandlebytype[`rdb; `roundrobin]

/ inspect registered server pool
srvsel.getserverstable[]
```

---

## Testing

Both test suites require KDB-X (the `use` module system). Set `QPATH` so `di.*` and `kx.*` modules resolve — it must include this repository and the `kx` module directory:

```bash
export QPATH=/path/to/kx/mod:/path/to/kdbx-modules
```

### Unit tests (k4unit)

`test.csv` is a k4unit manifest covering every exported function. Run it from a q session (or script):

```q
k4unit:use`di.k4unit;
k4unit.moduletest`di.serverselect;   / prints the results table; "All tests passed" on success
```

The `before` rows load the module and `init` it with a no-op logger, so the tests run standalone with no external logging framework.

Beyond the public api, the suite reaches the matching engine directly on the internal
`.m.di.0serverselect.` path (`getserveridstype`, `getserversinitial`, `buildcross`) and overrides
`.m.di.0serverselect.cp` to fast-forward the clock for the `removeinactive` tests rather than
sleeping. A capturing logger is injected where the *level* of a message is the thing under test —
notably that a tolerated per-servertype miss logs at `warn` and emits no `error` line.

### Integration test

`integration.q` is an end-to-end test that drives every exported function against **real backend processes**. It spawns a fleet of child `q` listeners, opens genuine IPC handles to them, and exercises a realistic gateway lifecycle (register → query → select → **route a live query to the selected handle** → bulk-register → disconnect → error handling → init). Because the handle returned by `gethandlebytype`/`getserverids` is actually queried, the assertions prove queries reach the *expected* backend process — e.g. round-robin alternates between the live rdbs, attribute selection routes to the hdb whose attributes match, and a killed/deactivated server drops out of selection. Run it directly:

```bash
QPATH=/path/to/kx/mod:/path/to/kdbx-modules q integration.q
```

It exits with a non-zero code equal to the number of failed assertions (`0` when all pass), and prints a `PASS`/`FAIL` summary.

The test is self-contained — no helper files: child backends are bare `q` listeners whose identity and `ping` api are injected over IPC, and the test launches and tears them down itself (cleanup is guaranteed via `.z.exit`, even on failure). It additionally requires:

- a `q` on `PATH` to launch the child listeners (override with `$QBIN`);
- some free TCP ports. There are **no hardcoded ports**: the test derives a base from its own pid (so concurrent runs don't collide) and scans upward for ports that are actually free. Set `$SSPORT` to pin the base if you need a known range.
