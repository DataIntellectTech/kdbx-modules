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
- Injected logging — supply your own logger (a `kx.log` instance or bespoke) via `init`; required, no default

---

## Initialisation & Dependencies

`init` wires the module's injected dependencies and **must be called before any other function**. The `log` dependency is **required** — there is no fallback, and the module does not load `kx.log` itself. Initialising the logging framework is the job of the start-up script that ties the modules together, or of the user at run time.

The injected logger is normalised by `normlog` to a binary `` `info`warn`error!{[c;m]} `` dict — each function takes a context symbol `c` and a message string `m`, called as `.z.m.log[\`info][\`ctx;"msg"]`. Pass **either** form:

| Form | What to pass | Behaviour |
|---|---|---|
| `kx.log` instance | the full `(use\`kx.log)[\`createLog][]` dict | detected by its `getlvl`/`sinks`/`fmts` keys; its monadic functions are wrapped to `{[c;m]}`, folding the context in as a `"ctx: msg"` prefix |
| bespoke logger | a `` `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) `` dict | already binary — passed through unchanged |

```q
srvsel:use`di.serverselect

/ option 1: wire in kx.log (the standard logger; typically done once in the start-up script)
/ pass the WHOLE instance so normlog can detect and wrap it - do NOT strip it to a 3-key dict
srvsel.init[enlist[`log]!enlist (use`kx.log)[`createLog][]]

/ option 2: a bespoke binary logger {[c;m]} (context symbol, message string)
mylog:`info`warn`error!(
  {[c;m] .my.log.info  string[c],": ",m};
  {[c;m] .my.log.warn  string[c],": ",m};
  {[c;m] .my.log.error string[c],": ",m});
srvsel.init[enlist[`log]!enlist mylog]
```

`init` throws with prefix `di.serverselect:` if `deps` is not a dictionary, is missing the `` `log `` key, or the `log` value is not a dictionary exposing `` `info`warn`error ``. All other `di.serverselect:` error conditions are logged via `.z.m.log[\`error]` (with the function as context) before being signalled.

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

---

## Functions

### Registration

| Function | Description |
|---|---|
| `addserverfull[h;pname;st;hp;att]` | Register a server with full details: handle, procname, servertype, hpup, attributes |
| `addserverattr[h;st;att]` | Register a server with servertype and attributes; procname and hpup default to null |
| `addserver[h;st]` | Register a server with no attributes |
| `setserveractive[h;active]` | Mark a server active (`1b`) or inactive (`0b`) |
| `addserversfromtable[proctypes;conntable]` | Bulk-register from a connection table, filtered by proctype |
| `getserverstable[]` | Return the full registered server table |

`addserversfromtable` skips handles that are already active. Pass `` `ALL `` as `proctypes` to register all process types. The `conntable` must have columns `w` (int handle), `proctype` (symbol), `attributes` (dict per row); `procname` and `hpup` are optional.

```q
/ register on connect
srvsel.addserverattr[h; getproctype[h]; getattributes[h]]

/ mark inactive on disconnect
srvsel.setserveractive[h; 0b]

/ bulk registration from TorQ connection table
srvsel.addserversfromtable[`rdb`hdb; .servers.SERVERS]
```

---

### Query and Selection

| Function | Description |
|---|---|
| `getservers[nameortype;lookups;req]` | Return active servers matching a servertype or procname filter, with per-attribute match scoring |
| `selector[servertable;selection]` | Pick one row from a server table using a selection strategy |
| `getserverbytype[ptype;col;sel]` | Return one column value for a servertype using the given strategy; updates `lastp` and `hits` |
| `gethandlebytype[ptype;sel]` | Convenience projection of `getserverbytype` returning `handle` |
| `gethpbytype[ptype;sel]` | Convenience projection of `getserverbytype` returning `hpup` |

`getservers` returns a table including an `attribmatch` column — a dictionary of `attrname!(complete_match_bool;matched_values)` per attribute key in `req`. When `lookups` is not `` ` ``, `nameortype` must be `` `servertype `` or `` `procname ``; any other value throws (and logs) a `di.serverselect:` error rather than silently falling through to a `procname` lookup.

All `di.serverselect:` error conditions — including the input-type checks on `addserverfull`/`setserveractive` and the connection-table column check on `addserversfromtable` — are logged via `.z.m.log[\`error]` before being signalled.

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

Pass a dictionary of attribute requirements. Servers whose attribute dictionaries satisfy the requirements are returned.

```q
/ cross match (default): every date must be available for every sym
srvsel.getserverids[`date`sym!(2024.01.01 2024.01.02; `AAPL`MSFT)]

/ independent match: each date and sym just needs one server somewhere
srvsel.getserverids[`date`sym`attributetype!(2024.01.01 2024.01.02; `AAPL`MSFT; `independent)]

/ scope to a specific servertype then apply attribute filter
srvsel.getserverids[`servertype`date!(`hdb; enlist 2024.01.01)]

/ strict mode: error if requirements cannot be fully satisfied
srvsel.getserverids[`date`besteffort!(enlist 2024.01.01; 0b)]
```

##### Attribute matching strategies

| `` `attributetype `` | Behaviour |
|---|---|
| `` `cross `` (default) | Every combination of attribute values must be coverable by a single server |
| `` `independent `` | Each individual attribute value only needs to be matched by at least one server |

The reserved key `` `besteffort `` (boolean, default `1b`) controls whether a partial match is acceptable. Set to `0b` to throw if requirements cannot be fully satisfied.

---

## Example

```q
/ load and initialise - init must be called before any other function
/ pass the whole kx.log instance; normlog wraps it to the binary {[c;m]} contract
srvsel:use`di.serverselect
srvsel.init[enlist[`log]!enlist (use`kx.log)[`createLog][]]

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

### Integration test

`integration.q` is an end-to-end narrative test that drives every exported function through a realistic gateway lifecycle (register → activate/deactivate → query → select → bulk-register → error handling) and prints a `PASS`/`FAIL` summary. Run it directly:

```bash
QPATH=/path/to/kx/mod:/path/to/kdbx-modules q integration.q
```

It exits with a non-zero code equal to the number of failed assertions (`0` when all pass).
