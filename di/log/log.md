# Log

`log.q` is the default logging implementation for `di.*` modules. It writes formatted lines to stdout and satisfies the log dependency contract expected by modules such as `di.email`.

## Usage

```q
log:use`di.log
log.info[`mymodule;"starting up"]
log.warn[`mymodule;"disk usage above 80%"]
log.error[`mymodule;"connection failed"]
```

Output format:

```
2026-04-09T12:00:00.000000000 [INFO] [mymodule] starting up
2026-04-09T12:00:00.001000000 [WARN] [mymodule] disk usage above 80%
2026-04-09T12:00:00.002000000 [ERROR] [mymodule] connection failed
```

## Injecting into other modules

All `di.*` modules that accept a log dependency expect a dictionary with keys `` `info`warn`error ``, each a function with signature `{[ctx;msg]}`.

```q
log:use`di.log
logdep:`info`warn`error!(log.info;log.warn;log.error)

email:use`di.email
email.init[emailconfig;`log`send!(logdep;::)]
```

## API

### `info`
Parameters: `[ctx; msg]`

Write an info-level message to stdout.

- `ctx` — symbol context tag (e.g. `` `mymodule ``)
- `msg` — string message

### `warn`
Parameters: `[ctx; msg]`

Write a warning-level message to stdout.

### `error`
Parameters: `[ctx; msg]`

Write an error-level message to stdout.

## Log dependency contract

The log dependency contract used across `di.*` modules requires a dictionary:

```q
`info`warn`error!({[ctx;msg] ...};{[ctx;msg] ...};{[ctx;msg] ...})
```

`di.log` satisfies this contract. You can also supply any custom implementation with the same signatures.
