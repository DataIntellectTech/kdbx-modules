# di.util.log

A minimal stub logging provider - satisfies the `info`/`warn`/`error` dependency
contract documented in `kdbx-modules/consistency.md` (a dict with three functions,
each `{[ctx;msg] ...}`).

This is a placeholder. The TorQ Modularisation Plan lists a real `di.util.log` (wrapping
`kx.log`) as Sprint 1 work; this stub exists so every other module that depends on
logging - which is nearly all of them - has something real to inject today, without
waiting on that work. Swap it out later: any module built against the DI contract
doesn't need to change, only whatever builds the `log` dependency dict (`di.torq`'s
`buildlogdep`) needs to point at the new module name instead.

## Design

```q
fmt:{[level;ctx;msg] (string .z.p)," ",(upper string level)," ",(string ctx)," ",msg}
info:{[ctx;msg] -1 fmt[`info;ctx;msg]; }
warn:{[ctx;msg] -1 fmt[`warn;ctx;msg]; }
error:{[ctx;msg] -2 fmt[`error;ctx;msg]; }
```

Every message is `<timestamp> <LEVEL> <ctx> <msg>`. `info`/`warn` write to stdout
(`-1`), `error` writes to stderr (`-2`) - the same out/err split legacy TorQ's own
`.lg.o`/`.lg.e` make (torq-developer skill, Rule L2), so existing log-watching habits
and tooling still work. `fmt` itself is not exported - only the three level functions
are part of the public contract; nothing outside this module should need to build a
log line itself.

## Dependency

None. `di.util.log` is Tier 1 / standalone - it's the thing other modules depend *on*, not
a consumer of anything else.

## Usage

```q
q)lg:use`di.util.log
q)lg.info[`hdb;"mounting hdb"]
2026.07.09D12:37:56.931480000 INFO hdb mounting hdb
q)lg.warn[`servers;"failed to open connection"]
2026.07.09D12:37:56.931538000 WARN servers failed to open connection
q)lg.error[`loader;"boom"]
2026.07.09D12:37:56.931547000 ERROR loader boom
```

In practice nothing calls `di.util.log` directly like this - `di.torq`'s `buildlogdep`
builds the `log` dependency dict (`` `info`warn`error!(lg`info;lg`warn;lg`error) ``)
once per process and passes it down through `init[config;deps]` to every module that
needs it.

`ctx` is conventionally the calling module's own name as a symbol (`` `hdb ``,
`` `servers ``, ...), not the log level or anything about the call site - it exists so
a human reading a log file (or a future real `di.util.log` filtering by it) can tell which
module a line came from.

## Known gaps (stub, not the real di.util.log)

- No log levels / filtering - every call always prints, there's no `-loglevel` guard.
- No file output - stdout/stderr only, no `out_`/`err_` file convention yet.
- No JSON format, no `.lg.ext`-style extension hook (torq-developer skill, Rules L3/L4).
- No in-memory `logmsg` table or pub/sub publishing of log lines (Rule L2).

All deferred to whenever the real `di.util.log` (Sprint 1 of the modularisation plan) lands.

## Testing

`test.csv` (k4unit) confirms each level function doesn't throw, including with a null
`ctx` and an empty message. Run with:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.util.log
```
