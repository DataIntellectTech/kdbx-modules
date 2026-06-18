# Server Selection

`serverselect.q` maintains a pool of registered backend servers and selects from them by servertype or attribute requirements. Extracted from the `.gw` namespace in TorQ's `gatewaylib.q` and `gateway.q`, it provides the server-selection layer of a gateway — decoupled from query execution and connection management.

---

## :sparkles: Features

- Register backend servers with servertype, procname, host/port, and attribute dictionaries
- Track active/inactive state per server, updated on connect and disconnect
- Select servers using round-robin, most-recently-used, or random strategy
- Query servers by servertype list or attribute requirement dictionary
- Attribute matching supports cross-product and independent strategies with configurable best-effort mode
- Bulk registration from a TorQ-compatible connection table
- Injected log dependency — no hard module dependencies

---

## :memo: Dependencies

| Dependency | Required | Description |
|---|---|---|
| `log` | yes | Dict of `info`warn`error functions, each with signature `{[ctx;msg]}` |

Pass the log dependency via `init`:

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srvsel.init[enlist[`log]!enlist logdep]
```

---

## :label: Server Table Schema

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

## :gear: Configuration

`init` wires the required log dependency. It must be called before any other function.

```q
srvsel.init[enlist[`log]!enlist logdep]
```

Throws with prefix `di.serverselect:` if:
- `configs` is not a dictionary
- `` `log `` key is missing
- `log` value is not a dictionary with `` `info`warn`error `` keys

---

## :wrench: Functions

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

`getservers` returns a table including an `attribmatch` column — a dictionary of `attrname!(complete_match_bool;matched_values)` per attribute key in `req`.

`selector` supports three strategies:

| Strategy | Behaviour |
|---|---|
| `` `roundrobin `` | Pick server with the oldest `lastp` (least recently used) |
| `` `any `` | Pick a random server |
| `` `last `` | Pick server with the newest `lastp` (most recently used) |

All three return `()` if no matching server is found.

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

## :test_tube: Example

```q
/ load module
srvsel:use`di.serverselect

/ wire log dependency
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srvsel.init[enlist[`log]!enlist logdep]

/ register servers as they connect (.z.po handler)
.z.po:{[h]
  srvsel.addserverattr[h; getproctype[h]; getattributes[h]];
  }

/ mark inactive on disconnect (.z.pc handler)
.z.pc:{[h]
  srvsel.setserveractive[h; 0b];
  }

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
