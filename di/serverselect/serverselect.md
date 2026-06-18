# di.serverselect

Module for registering backend servers and selecting them by servertype or attribute requirements. Extracted from the `.gw` namespace across TorQ's `gatewaylib.q` and `gateway.q`. Designed as the server-selection layer of a gateway — decoupled from query execution and connection management.

## Usage

```q
srvsel:use`di.serverselect

log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srvsel.init[enlist[`log]!enlist logdep]

/ register servers as they connect
srvsel.addserver[h;`rdb]
srvsel.addserverattr[h;`hdb;`date`sym!(2024.01.01 2024.01.02;`AAPL`MSFT)]

/ mark inactive on disconnect
srvsel.setserveractive[h;0b]

/ select by servertype
srvsel.getserverids[`rdb`hdb]

/ select by attribute requirements
srvsel.getserverids[enlist[`date]!enlist enlist 2024.01.01]
```

### Typical gateway integration

```q
srvsel:use`di.serverselect
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srvsel.init[enlist[`log]!enlist logdep]

/ on open - register the connecting server
.z.po:{[h] srvsel.addserverattr[h;getproctype[h];getattributes[h]]}

/ on close - mark the server inactive
.z.pc:{[h] srvsel.setserveractive[h;0b]}

/ on query - select target servers then dispatch
serverids:srvsel.getserverids[`rdb`hdb]
```

### Bulk registration from a TorQ connection table

In a TorQ stack, `.servers.SERVERS` is populated by `trackservers.q`. Pass it directly:

```q
srvsel.addserversfromtable[`rdb`hdb; .servers.SERVERS]

/ or register all process types
srvsel.addserversfromtable[`ALL; .servers.SERVERS]
```

## API

### `init[deps]`

Wire injectable dependencies. Must be called before any other function.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | Functions keyed `` `info`warn`error ``, each with signature `{[ctx;msg]}` |

Errors with prefix `di.serverselect:` if `configs` is not a dict, `log` key is missing, or `log` value is not a dict with all three required keys.

---

### `addserverattr[handle;servertype;attributes]`

Register a server with a handle, servertype, and attribute dictionary. Sets `active:1b` on registration.

| Parameter | Type | Description |
|---|---|---|
| `handle` | int | Connection handle |
| `servertype` | symbol | Process type (e.g. `` `rdb ``, `` `hdb ``) |
| `attributes` | dict | Key-value attribute pairs (e.g. `` `date`sym!(2024.01.01;`AAPL) ``) |

```q
srvsel.addserverattr[5i; `hdb; `date`sym!(2024.01.01 2024.01.02; `AAPL`MSFT)]
```

---

### `addserver[handle;servertype]`

Register a server with no attributes. Convenience wrapper over `addserverattr`.

```q
srvsel.addserver[5i; `rdb]
```

---

### `setserveractive[handle;active]`

Mark a registered server active or inactive. Call with `0b` on disconnect, `1b` on reconnect.

| Parameter | Type | Description |
|---|---|---|
| `handle` | int | Connection handle of the server to update |
| `active` | boolean | `1b` = active, `0b` = inactive |

```q
srvsel.setserveractive[5i; 0b]   / server disconnected
srvsel.setserveractive[5i; 1b]   / server reconnected
```

---

### `getserverids[att]`

Return server IDs matching the given servertype list or attribute requirement dictionary.

| Parameter | Type | Description |
|---|---|---|
| `att` | symbol list or dict | Servertype list (11h) — returns IDs grouped by type. Attribute dict (99h) — returns IDs satisfying the requirements. |

**Symbol list path** — validates that all requested types exist and are active:

```q
srvsel.getserverids[`rdb]
srvsel.getserverids[`rdb`hdb]
```

**Attribute dict path** — matches servers whose attribute dictionaries satisfy the requirements. Supports two matching strategies controlled by the reserved key `` `attributetype ``:

| `attributetype` | Behaviour |
|---|---|
| `` `cross `` (default) | Every combination of attribute values must be coverable — e.g. every date must be available for every sym |
| `` `independent `` | Each attribute value only needs to be matched by at least one server |

The reserved key `` `besteffort `` (boolean, default `1b`) controls whether a partial match is acceptable. If `0b`, an error is thrown when the requirements cannot be fully satisfied.

```q
/ cross match (default): find servers covering the full date × sym cross product
srvsel.getserverids[`date`sym!(2024.01.01 2024.01.02; `AAPL`MSFT)]

/ independent match: each date and each sym just needs one server somewhere
srvsel.getserverids[`date`sym`attributetype!(2024.01.01 2024.01.02; `AAPL`MSFT; `independent)]

/ scope to a specific servertype then apply attribute filter
srvsel.getserverids[`servertype`date!(`hdb; enlist 2024.01.01)]

/ strict mode: error if requirements cannot be fully satisfied
srvsel.getserverids[`date`besteffort!(enlist 2024.01.01; 0b)]
```

---

### `addserversfromtable[proctypes;conntable]`

Register servers from a connection table, skipping handles already active in the pool.

| Parameter | Type | Description |
|---|---|---|
| `proctypes` | symbol or symbol list | Process types to register; pass `` `ALL `` to register all |
| `conntable` | table | Must have columns: `w` (int handle), `proctype` (symbol), `attributes` (dict per row) |

```q
/ TorQ stack — pass .servers.SERVERS directly
srvsel.addserversfromtable[`rdb`hdb; .servers.SERVERS]

/ custom connection table
conntab:([] w:1i 2i; proctype:`rdb`hdb; attributes:(()!(); `date!enlist 2024.01.01))
srvsel.addserversfromtable[`ALL; conntab]
```

---

### `getserverstable[]`

Return the current registered server table.

```q
srvsel.getserverstable[]
```

Schema:

| Column | Type | Description |
|---|---|---|
| `serverid` | int (keyed) | Unique auto-assigned server ID |
| `handle` | int | Connection handle |
| `servertype` | symbol | Process type |
| `active` | boolean | Whether the server is currently active |
| `attributes` | any | Attribute dictionary registered with the server |

## Log dependency contract

`di.serverselect` requires a log dependency dictionary with keys `` `info`warn`error ``:

```q
`info`warn`error!({[ctx;msg] ...};{[ctx;msg] ...};{[ctx;msg] ...})
```

`di.log` satisfies this contract:

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)
srvsel.init[enlist[`log]!enlist logdep]
```

Context symbols used by `di.serverselect` in log calls:

| Context | Level | When |
|---|---|---|
| `` `addserverattr `` | info | Server registered |
| `` `setserveractive `` | info | Server active flag changed |
| `` `addserversfromtable `` | info | Bulk registration — count of servers being added |
