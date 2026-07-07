# Log

`log.q` is the default logging implementation for `di.*` modules. It writes formatted lines to stdout and satisfies the log dependency contract expected by modules such as `di.email`.

## Usage

```q
logger:use`di.log
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
logger:use`di.log
logdep:`info`warn`error!(logger.info;logger.warn;logger.error)

email:use`di.email
email.init[enlist[`log]!enlist logdep]
```

You can extend the injected dictionary with `trace`, `debug`, and `fatal` for modules that support them:

```q
logdep:`trace`debug`info`warn`error`fatal!(logger.trace;logger.debug;logger.info;logger.warn;logger.error;logger.fatal)
```

`di.log` has no dependencies of its own, so there's no `init` to call on it first — use
`defaultdict` to skip building the dict by hand. It's the dependency already wrapped
as `` `log!enlist logdict ``, ready to pass straight into any `di.*` module's `init`:

```q
mylog:use`di.log
email:use`di.email
email.init[mylog.defaultdict]
```

## createLog

`createLog` is a factory that returns an independent logger instance with level filtering, multiple output sinks, and configurable format templates. Each call to `createLog` produces a separate instance with its own state.

```q
logger:use`di.log
mylog:logger.createLog[]

mylog.setlvl `warn                        / suppress trace, debug, info
mylog.info "this is suppressed"           / returns () silently
mylog.warn "this appears"

mylog.setfmt `syslog                      / switch to syslog format
mylog.addfmt[`compact;"$l $m"]           / add a custom format
mylog.setfmt `compact

mylog.add[2i;`error`fatal]               / add stderr sink for error and fatal
mylog.remove[1i;`trace]                  / remove stdout from trace level
```

### Sinks

A sink is a handle (integer file descriptor or function) passed to `add`. If a function is provided it is called with the formatted line string. Built-in handles follow standard q conventions: `1i` is stdout, `2i` is stderr.

```q
buf:();
capture:{[msg] buf,:enlist msg};         / function sink - captures output
mylog.add[capture;`info`warn`error]
mylog.info "captured"
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

### `defaultdict`
A dictionary, not a function.

`` `log!enlist(`info`warn`error!(info;warn;error))`` — the log dependency dict pre-wrapped
exactly as any `di.*` module's `init` expects `deps`, so it can be passed straight through
without building it by hand.

### `createLog`
Parameters: none

Returns an independent logger instance as a dictionary of functions. Each call returns a new instance with isolated state.

Returned keys: `` `trace`debug`info`warn`error`fatal`add`remove`setfmt`getfmt`addfmt`setlvl`getlvl ``

| Function | Parameters | Description |
|---|---|---|
| `trace`..`fatal` | `[msg]` | Write a message at the given level (filtered by active level) |
| `setlvl` | `[lvl]` | Set minimum level; one of `` `trace`debug`info`warn`error`fatal `` |
| `getlvl` | `[_]` | Return current minimum level |
| `setfmt` | `[name]` | Switch to a named format template |
| `getfmt` | `[_]` | Return current format name |
| `addfmt` | `[name;template]` | Register a new named format template |
| `add` | `[handle;lvls]` | Add a sink for one or more levels; returns the handle |
| `remove` | `[handle;lvl]` | Remove a sink from a level |

## Log dependency contract

The log dependency contract used across `di.*` modules requires a dictionary:

```q
`info`warn`error!({[ctx;msg] ...};{[ctx;msg] ...};{[ctx;msg] ...})
```

`di.log` satisfies this contract. You can also supply any custom implementation with the same signatures.