# di.torq.proc.discovery

TorQ's discovery service (`code/processes/discovery.q`) repackaged as a kdb-x module: a
one-to-one port, nothing added, nothing dropped. The process dials every process in
`process.csv` once at start up, records the processes that register with it, answers
`getservices` queries, and pushes each new registration to the processes subscribed to its
proctype.

Discovery is the server half of a protocol whose client half lives in `trackservers.q`. That
half is `di.torq.servers` (0.4.0+), ported at the same legacy root names — see
[servers.md](../../servers/servers.md#discovery-protocol-ported-from-trackserversq).

## Line map

| discovery.q | here |
|---|---|
| l.8 `.servers.startup[]` | `init`: `.servers.startup config` |
| l.11 `subs` | `subs` (module state) |
| l.13–23 `register` | `register`, published at root `register` (peers call `` `..register ``) |
| l.27–30 `getservices` | `getservices`, published at root `getservices` |
| l.33 `addw` each live handle | `init` |
| l.37 `.servers.autodiscovery` push | `init` |
| l.40 `.z.pc` drops from `subs` | `init`, via `handlers[`register]` |

**Conversions:**
- `.lg.e` becomes the injected `log[`error]`.
- `.dotz.set[`.z.pc;...]` becomes an observer registered with the injected `handlers`.
- The module is `use`-loaded, so `register`/`getservices` are published at root with `set`.
- `subs` lives in module state (`.z.m.subs`).

## How the protocol runs

1. Discovery starts, runs `.servers.startup` with `connections:`ALL`, and dials every non-discovery
   row of `process.csv`.
2. It calls `addw` on each live handle, which fetches `.servers.getdetails[]` (name, type,
   attributes). Then it sends `.servers.autodiscovery` to each peer.
3. A peer with `discoveryretry>0` runs `retrydiscovery`:
   - it connects to discovery;
   - it sends `` `..register `` if `discoveryregister`;
   - if `connectionsfromdiscovery`, it calls `getservices[connections;subscribetodiscovery]`
     synchronously and adds the rows returned, without connecting to them. `retry` dials them later.
4. `register` records the caller, removes any other row on the same host:port, and pushes the
   caller's row as `.servers.procupdate` to each handle subscribed to its proctype or `` `ALL ``.
5. When a subscriber disconnects, `.z.pc` removes it from `subs`.

Behaviours of legacy worth knowing (kept as is):
- The pushed row is added by the subscriber's `addprocs` without connecting. `retry` dials it later.
- A re-push of a row the subscriber already has changes nothing: the attribute `lj` is filtered
  by the same "not already known" condition.
- A restarted discovery only dials `process.csv`. A peer outside it comes back through its own
  `discoveryretry` timer.

## Dependencies

`deps.toml` pins `di.torq.servers` 0.4.0 (the legacy `.servers.*` root names). `init` requires
the injected `log` and `handlers`.

## Config

`di/torq/settings/discovery.q` is legacy `config/settings/discovery.q`:
- `connections:`ALL`;
- `discoveryregister` / `connectionsfromdiscovery` 0b;
- `tracknontorqprocess` 1b;
- `discoveryretry:0D`;
- `hopentimeout:200`;
- `retry:0D00`;
- `retain` `0W`;
- `autoclean:0b`;
- `debug:1b`.

## Usage

Proctype `discovery` is a di.torq built-in:

```
torqx -proctype discovery -procname discovery1
```

## Testing

`test.q` + `test.csv` (30 checks) stub the `.servers.*` names discovery calls and spawn two real
q peers, so `.z.w`/`.z.W` run over genuine handles. They cover:
- init validation;
- each legacy line in `init`;
- `getservices` filtering and `cleanup`;
- subscribe, register with duplicate removal, and the `procupdate` push;
- the `.z.pc` prune.

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.torq.proc.discovery
```
