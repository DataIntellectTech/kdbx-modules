# di.proc.hdb

The built-in `hdb` process type: mounts a historical database directory and exposes a
remotely-triggerable reload. This is the plan's `di.proc.hdb` process type, started by
`di.torq` through the same `init[config;deps]` convention as every other built-in or
custom proctype - there's nothing hdb-specific about how it gets launched, only about
what it does once launched.

## Design

### `resolvedir[dir]`

Resolves a possibly-relative `dir:` setting to an absolute handle. An absolute path
(one starting with `/`) is used as-is; a relative one is joined against
`TORQXDATAHOME` - where runtime data lives (the hdb is data, not code/config), falling
back to `TORQXAPPHOME` when unset - not `TORQXHOME` (the `di.torq` framework checkout),
since hdb data is something an app owns, not something the framework
ships. This exists specifically so `reload[]` isn't sensitive to whatever working
directory the process happened to start in: a relative `dir:` always resolves to the
same absolute path regardless of *when* it's resolved, which matters because
`reload[]` can be triggered by a remote IPC call long after startup, potentially from
a context where the original cwd assumption wouldn't hold.

### `init[config;deps]`

Requires a `log` dependency (nothing else - `di.proc.hdb` doesn't register timers or
`.z.*` handlers of its own, so it has no need for `timer`/`handlers`). Resolves
`config`dir` via `resolvedir`, mounts it with `` system "l ",dir ``, and logs the
tables that ended up loaded.

The last thing `init` does is publish `reload` at a real root-level name,
`` set[`.hdb.reload;reload] ``. This is necessary, not stylistic: `use`-loading a
module (as `di.torq`'s `startbuiltin` does) compiles this file's code into a private,
mangled namespace (something like `.m.di.0hdb.*`), so a bare `.hdb.reload[]` call from
a *different* process over IPC would otherwise hit an undefined-function error - the
real function only exists under its mangled name, which no other process could
possibly know. Publishing the real function at a plain root name sidesteps that;
`.z.m` inside the published `reload` function still correctly resolves to `di.proc.hdb`'s
own private state regardless of what name it was called through. This is the exact
same pattern legacy TorQ uses for `endofday`/`reload` at root (torq-developer skill,
Rule E3) - and it's the mechanism the sample loader process (in `TorqX-POC`) actually
exercises: it opens a connection to the running hdb process (via `di.torq.servers`) and
calls `` .hdb.reload[] `` on it remotely after loading new data, rather than
restarting the hdb process outright.

### `reload[]`

Re-runs the exact same `` system "l ",dir `` mount. Whatever was already loaded is
replaced by whatever's on disk now - this is a full remount, not an incremental
update.

## Dependency

`log` only.

## Config

| key | meaning |
|---|---|
| `dir` | the hdb directory to mount - relative (resolved against `TORQXDATAHOME`, falling back to `TORQXAPPHOME`) or absolute |

## Usage

```q
q)hdb:use`di.proc.hdb
q)lg:use`di.util.log
q)logdep:`info`warn`error!(lg`info;lg`warn;lg`error)
q)hdb.init[(enlist`dir)!enlist`$":/tmp/di_hdb_readme_demo";enlist[`log]!enlist logdep]
2026.07.09D12:41:24.703763000 INFO hdb mounting hdb from :/tmp/di_hdb_readme_demo
2026.07.09D12:41:24.703897000 INFO hdb loaded tables: widgets
q)tables[]
,`widgets
q)delete widgets from `.
q).hdb.reload[]
2026.07.09D12:41:24.703928000 INFO hdb reloading hdb from :/tmp/di_hdb_readme_demo
q)tables[]
,`widgets
```

In the real sample app, none of this is called directly - `di.torq`'s `init` builds
`config`/`deps` from the settings cascade and calls `hdb.init[config;deps]` itself
when `proctype` is `` `hdb ``; the interesting part is what happens *after* startup,
when another process calls the published `.hdb.reload[]` over a real connection
(see `di.torq.servers`'s docs for how that connection gets made).

## Known gaps (v1)

- No `di.sort` dependency yet. The plan lists `di.sort` as a hard dependency for
  re-applying attributes (`` `g# ``/`` `p# ``) after a reload - legacy TorQ's own
  post-EOD attribute reapplication (torq-developer skill, Rule S6) has no equivalent
  here yet, so a reload that changes column types/order could lose attributes a query
  path depends on.
- One directory, one mount - no partitioned multi-database layout beyond what a plain
  `` \l `` already gives you.

## Testing

`test.csv`/`test.q` (k4unit) cover: init failing without a `log` dependency, init with
an absolute `dir` (sidesteps needing `TORQXAPPHOME` at all), the published
`.hdb.reload[]` actually remounting after a table is dropped, and init with a relative
`dir` to exercise `resolvedir`'s `TORQXAPPHOME` join. Run in a fresh q session (this
suite calls `setenv`, so don't interleave it with other modules' tests in one shared
process):

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.proc.hdb
```
