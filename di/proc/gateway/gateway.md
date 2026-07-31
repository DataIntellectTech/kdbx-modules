# di.proc.gateway

A query gateway: the single point a client queries, which routes the query across backend
processes (rdb, hdb, …), joins the per-backend results, and replies. Thin **orchestration glue**
over three modules:

| Module | Role | Origin |
|---|---|---|
| `di.torq.servers` | discover + connect to the backend processes | TorqX |
| `di.serverselect` | registry of backends + servertype/attribute routing | vendored (kdbx-modules) |
| `di.asyncdispatch` | async scatter-gather: queue → dispatch → collect → join → reply | vendored (kdbx-modules) |

Ported from the `.gw` orchestration in `TorQ/code/processes/gateway.q`; the engine and routing
are the two vendored modules, so di.proc.gateway itself is small.

## Dependencies

- **Injected** (from di.torq): `log`, `timer`, `handlers`.
- **Hard** (`use`-imported): `di.torq.servers`, `di.serverselect`, `di.asyncdispatch`.

Both vendored modules take the **binary `{[c;m]}`** log dep — the same contract di.torq injects —
so di.proc.gateway passes the injected `log` straight through (no adapter, unlike di.dbwrite).

## Config

```toml
backendtypes = "rdb hdb"   # proctype(s) to connect to and route queries across (default `rdb`hdb)
synccallsallowed = false   # allow deferred-sync execquery (passed to di.asyncdispatch)
errorprefix = "error: "    # prefix on error strings returned to clients
```

## Client API (published at root `.gw.*`)

- `.gw.asyncexec[query;servertypes]` — run `query` on one backend of each servertype, `raze` the
  results, reply to the client. Deferred-sync: the client does
  `neg[h](`.gw.asyncexec;query;`rdb`hdb); h[]`.
- `.gw.asyncexecjpt[query;servertypes;join;postback;timeout]` — full control: custom join function,
  postback wrapper (`()` for none), and per-query timeout.

`servertypes` is a **symbol list** (e.g. `` `rdb`hdb ``) or an **attribute dict** (routed via
di.serverselect — see the scope note). `query` is any value passed to `value` on the backend
(a q string, or a `(func;args…)` parse tree).

## EOD reload gate (published at root `.gw.reload`)

The wdb calls `(`.gw.reload;`reloadstart)` before moving its partition into the hdb and
`(`.gw.reload;`reloadend)` after the hdb/rdb have reloaded (di.proc.wdb's `informgateway` already sends
these — building this module makes that loop live). While gated, new queries are rejected with a
retry message so none straddle the rdb-drop / hdb-reload window; `reloadend` clears the gate and
refreshes the backend registry.

## How it wires together (init)

1. init di.serverselect + di.asyncdispatch with the injected `log`.
2. point asyncdispatch's **server source** at serverselect (`setavailableservers`), so serverselect
   is the single registry and asyncdispatch dispatches against it.
3. publish asyncdispatch's result/error callbacks at `.gw.addserverresult`/`.gw.addservererror` and
   `setcallbacks` to them (the vendored asyncdispatch bakes these into the shipped executor, so
   backends need no cooperating code — see the patch note in di.asyncdispatch).
4. connect to `backendtypes` via di.torq.servers and register them into serverselect.
5. register `.z.po`/`.z.pc` callbacks via the handlers dep (client tracking; backend/client
   disconnect cleanup + serverselect deactivate). `.z.ps` `exec` defaults to `value`, so client
   async calls and backend async replies dispatch without extra wiring.
6. publish `.gw.*` entry points; schedule asyncdispatch housekeeping (`checktimeout`,
   `removequeries`, `removeinactive`, `removeclients`) on the injected timer.

## Not included (v1) / notes

- **Attribute routing needs backend attribute reporting.** di.serverselect can route by an attribute
  dict (e.g. which servers hold a date range), but backends must report those attributes and
  di.torq.servers/di.proc.rdb/di.proc.hdb don't yet — so v1 registers backends with **empty attributes** and
  attribute-dict queries degrade/err until that plumbing lands. Servertype-list routing is the v1
  happy path.
- **No per-backend query serialisation.** With the server source pointed at di.serverselect (which
  has no `inuse` state), asyncdispatch doesn't hold one-query-per-backend. Fine for POC volumes;
  backends serialise internally.
- **Deferred:** di.dataaccess (typed `getdata` + map-reduce date-splitting), pure-synchronous
  `syncexec`, permissions, kxdash. **Removed:** finspace.

## Testing

`test.csv` (k4unit) covers the dependency contract (init errors without log/timer/handlers) and the
export surface. The full client → gateway → scatter-gather → rdb+hdb → join → reply flow (and the
EOD reload gate with the wdb) is proven in the **TorqX-POC end-to-end**
(`torqx.sh start tickerplant1 hdb feed1 rdb1 wdb1 gateway1`).

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.proc.gateway
```
