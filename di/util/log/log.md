# Log

`log.q` is the default logging implementation for `di.*` modules. It writes formatted lines to
stdout and satisfies the log dependency contract expected by modules such as `di.email`. It also
provides `createlog`, a factory for rich structured logger instances with level filtering,
multiple output sinks, and configurable format templates.

## Usage

```q
logger:use`di.util.log
logger.trace[`mymodule;"entering function"]
logger.debug[`mymodule;"value is 42"]
logger.info[`mymodule;"starting up"]
logger.warn[`mymodule;"disk usage above 80%"]
logger.error[`mymodule;"connection failed"]
logger.fatal[`mymodule;"unrecoverable error, shutting down"]
```

Output format:

```
2026-04-09T12:00:00.000000000 [TRACE] [mymodule] entering function
2026-04-09T12:00:00.001000000 [DEBUG] [mymodule] value is 42
2026-04-09T12:00:00.002000000 [INFO] [mymodule] starting up
2026-04-09T12:00:00.003000000 [WARN] [mymodule] disk usage above 80%
2026-04-09T12:00:00.004000000 [ERROR] [mymodule] connection failed
2026-04-09T12:00:00.005000000 [FATAL] [mymodule] unrecoverable error, shutting down
```

## Injecting into other modules

All `di.*` modules that accept a log dependency expect a dictionary with keys `` `info`warn`error ``, each a function with signature `{[ctx;msg]}`.

```q
logger:use`di.util.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)

email:use`di.email
email.init[enlist[`log]!enlist logdep]
```

You can extend the injected dictionary with `trace`, `debug`, and `fatal` for modules that support them:

```q
logdep:`trace`debug`info`warn`error`fatal!(logger.trace;logger.debug;logger.info;logger.warn;logger.error;logger.fatal)
```

`di.util.log` has no dependencies of its own, so there's no `init` to call on it first — use
`logdict` to skip building the dict by hand. It's the dependency already wrapped as
`` `log!enlist logdict ``, ready to pass straight into any `di.*` module's `init`:

```q
mylog:use`di.util.log
email:use`di.email
email.init[mylog.logdict]
```

## createlog

`createlog` is a factory that returns an independent logger instance with level filtering, multiple output sinks, and configurable format templates. Each call to `createlog` produces a separate instance with its own state.

Instance-level functions (`trace`..`fatal`) take the same `{[ctx;msg]}` signature as the plain top-level functions, so an instance satisfies the log dependency contract directly. None of the built-in format templates have a slot for `ctx`, so it's folded into the message text as `[ctx] msg`.

```q
logger:use`di.util.log
mylog:logger.createlog[]

mylog.setlvl `warn                                  / suppress trace, debug, info
mylog.info[`mymodule;"this is suppressed"]          / returns () silently
mylog.warn[`mymodule;"this appears"]

mylog.setfmt `syslog                      / switch to syslog format
mylog.addfmt[`compact;"$l $m"]           / add a custom format
mylog.setfmt `compact

mylog.add[2i;`error`fatal]               / add stderr sink for error and fatal
mylog.remove[1i;`trace]                  / remove stdout from trace level
```

### Sinks

A sink is a handle (integer file descriptor or function) passed to `add`. If a function is provided it is called with the formatted line string. Built-in handles follow standard q conventions: `1i` is stdout, `2i` is stderr. Since a sink can be any open handle, `hopen` a real file to log to disk:

```q
fh:hopen`:/path/to/app.log
mylog.add[fh;lvls]              / route every level to the file
mylog.remove[1i;lvls]           / optionally drop the default stdout sink
mylog.info[`mymodule;"this now goes to app.log"]
```

Or use a plain function sink to capture output in memory:

```q
buf:();
capture:{[msg] buf,:enlist msg};         / function sink - captures output
mylog.add[capture;`info`warn`error]
mylog.info[`mymodule;"captured"]
buf                                      / ("2026-...captured\n")
mylog.remove[capture;`info]
```

### Format templates

Three built-in formats are available:

| Name | Template | Example output |
|---|---|---|
| `basic` (default) | `$p $l PID[$i] HOST[$h] $m` | `2026-04-09T12:00:00.000000000 INFO PID[1234] HOST[myhost] message` |
| `syslog` | `<$s> $m` | `<6> message` |
| `raw` | `$m` | `message` |

Template variables: `$p` timestamp, `$l` level, `$i` PID, `$h` hostname, `$m` message, `$s` syslog severity number.

## API

### `trace`
Parameters: `[ctx; msg]`

Write a trace-level message to stdout.

- `ctx` — symbol context tag (e.g. `` `mymodule ``)
- `msg` — string message

### `debug`
Parameters: `[ctx; msg]`

Write a debug-level message to stdout.

### `info`
Parameters: `[ctx; msg]`

Write an info-level message to stdout.

### `warn`
Parameters: `[ctx; msg]`

Write a warning-level message to stdout.

### `error`
Parameters: `[ctx; msg]`

Write an error-level message to stdout.

### `fatal`
Parameters: `[ctx; msg]`

Write a fatal-level message to stdout.

### `logdict`
A dictionary, not a function.

`` `log!enlist(`trace`debug`info`warn`error`fatal!(...))`` — the log dependency dict pre-wrapped
exactly as any `di.*` module's `init` expects `deps`, so it can be passed straight through
without building it by hand. It includes all six levels, a superset of the `info`/`warn`/`error`
contract minimum, since the underlying `createlog[]` instance computes them anyway — a module
that supports the optional extended levels gets them for free. Backed by its own independent
`createlog[]` instance, separate from the plain `trace`..`fatal` functions above.

### `createlog`
Parameters: none

Returns an independent logger instance as a dictionary of functions. Each call returns a new instance with isolated state.

Returned keys: `` `trace`debug`info`warn`error`fatal`add`remove`setfmt`getfmt`addfmt`setlvl`getlvl ``

| Function | Parameters | Description |
|---|---|---|
| `trace`..`fatal` | `[ctx;msg]` | Write a message at the given level (filtered by active level) |
| `setlvl` | `[lvl]` | Set minimum level; one of `` `trace`debug`info`warn`error`fatal `` |
| `getlvl` | `[_]` | Return current minimum level |
| `setfmt` | `[name]` | Switch to a named format template |
| `getfmt` | `[_]` | Return current format name |
| `addfmt` | `[name;template]` | Register a new named format template |
| `add` | `[handle;lvls]` | Add a sink for one or more levels; returns the handle |
| `remove` | `[handle;lvl]` | Remove a sink from a level. `handle` may be a bare handle (removes every sink registered with it) or a `(handle;fn)` pair matching what was passed to `add` (removes only that exact sink) |

## Log dependency contract

The log dependency contract used across `di.*` modules requires a dictionary:

```q
`info`warn`error!({[ctx;msg] ...};{[ctx;msg] ...};{[ctx;msg] ...})
```

`di.util.log` satisfies this contract. You can also supply any custom implementation with the same signatures.

## Testing

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.util.log
```
