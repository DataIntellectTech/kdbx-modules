# di.html

WebSocket pub/sub and HTML page serving module, extracted from TorQ.

## Overview

This module does two things:

1. **Pub/sub over WebSockets** — allows browser clients to subscribe to kdb+ tables and receive live updates as data is published.
2. **HTML page serving** — reads HTML files from a configured directory and serves them over HTTP, optionally replacing server/port placeholders so the page can connect back to itself.

## Usage

```q
html:use`di.html
log:use`di.log

/ minimal setup - the log dependency is required
/ homedir defaults to the KDBHTML env var (else "html")
logdep:`info`warn`error!(log.info;log.warn;log.error)
html.init[enlist[`log]!enlist logdep]

/ register tables for pub/sub
html.addtables[`trades`quotes]

/ publish data to subscribers
html.pub[`trades;newdata]
```

This mirrors the original TorQ deployment: set `KDBHTML`, initialise, register tables.

## init

```q
html.init[configs]
```

`configs` is a dictionary. The `` `log `` key is required — `init` signals an error if it is missing or does not contain `` `info`warn`error `` functions. Only recognised keys are picked up:

| Key | Type | Description | Default |
|---|---|---|---|
| `` `log `` | dict | **Required.** Logging functions with keys `` `info`warn`error ``, each called as `(ctx;msg)` — e.g. from `di.log` | — |
| `homedir` | string | Path to the directory containing HTML files | `KDBHTML` env var, else `"html"` (TorQ behaviour) |
| `` `handlers `` | dict | Handler registry with key `` `register `` | Assigns `.z.ws`, `.z.wc` and `.z.pc` directly |

```q
/ override config explicitly
html.init[`homedir`log!("/opt/app/html";logdict)]
```

`init` also sets `.h.HOME` to `homedir` (protected, skipped if `.h` is unavailable) so the default HTTP handler serves static assets (css/js/img) from the same directory — the equivalent of TorQ's `KDBHTML` behaviour.

## Exported functions

### addtables

```q
html.addtables[tablelist]
```

Registers a list of table names for pub/sub. Can be called multiple times to add new tables. Sets a default modifier that JSON-encodes updates before sending to subscribers.

### pub

```q
html.pub[tbl;data]
```

Publishes `data` for `tbl` to all currently subscribed handles.

### sub

```q
html.sub[tbl;syms]
```

Subscribes the current handle (`.z.w`) to `tbl`. Pass `` ` `` as `syms` to receive all data. Pass `` ` `` as `tbl` to subscribe to all registered tables. Returns `(tablename; current data)` so the subscriber can initialise their local copy of the table.

### wssub

```q
html.wssub[tbl]
```

Calls `sub[tbl;`` ` ``]`. Pass `` ` `` as `tbl` to subscribe to all registered tables. Returns nothing.

### end

```q
html.end[eodval]
```

Broadcasts an end-of-day message to all subscriber handles.

### dataformat

```q
html.dataformat[msgtype;msgdata]
```

Wraps a message into a `` `name`data `` dictionary, javascript-formatting each table in `msgdata` (a list or dictionary of tables). Used by host data functions that the front end requests over the websocket, e.g. TorQ's monitor `start` call returning several tables at once.

### readpage

```q
html.readpage[filename]
```

Reads the file at `homedir/filename` and returns its contents as a string. Returns an error message string if the file is not found.

### readpagereplaceHP

```q
html.readpagereplaceHP[filename]
```

Reads the file at `homedir/filename` and replaces `MYKDBSERVER` and `MYKDBPORT` tokens with the process's current IP address and port. Used to serve self-referencing HTML pages over HTTP.

### evaluate

```q
html.evaluate[inputdict]
```

Takes a q dictionary (already deserialised from JSON), extracts the `func` key, calls the named function with any additional keys as arguments, and returns the result. Used internally by the `.z.ws` handler — the handler does the JSON deserialisation before calling this function.

## WebSocket handler

The module registers a `.z.ws` handler that receives bytes from the browser, deserialises them to a q dict, calls `evaluate`, JSON-encodes the result, and sends it back. Subscriptions are cleaned up when a connection closes via both `.z.wc` (websocket) and `.z.pc` (IPC), as in TorQ — `sub` can also be called over a plain IPC handle. In the direct-assignment path (no `handlers` config) any existing `.z.wc`/`.z.pc` handlers are preserved by wrapping, and the wiring happens only once across repeated `init` calls.

## Logging

The module logs at three points:

- On `init`: confirms the module started and which `homedir` was set
- On `readpage`: warns if a requested file is not found
- On `evaluate`: logs at error level when a WebSocket-invoked function fails (the error is also re-thrown to the caller)

There is no built-in default logger — the `log` dict must be injected via `init`, typically from `di.log`. Internally the loggers are stored on `.z.m` as `lginfo`/`lgwarn`/`lgerr` (not `log`, which is a q built-in) and every call site invokes them through `.z.m`.

## Example with custom log and handlers config

The `log` functions are called as `(ctx;msg)` and the `handlers` registry's `register`
is called as `(.z event name; label; handler)`.

```q
/ wire up logging on top of the kx.log module
/ kx.log loggers take a single message, so wrap them to the (ctx;msg) shape
logger:use`kx.log
kxlog:logger.createLog[]
logdict:`info`warn`error!(
  {[c;m] kxlog.info[(string c),": ",m]};
  {[c;m] kxlog.warn[(string c),": ",m]};
  {[c;m] kxlog.error[(string c),": ",m]})

/ wire up handlers via a host-provided registry
/ a real registry composes handlers so several modules can share .z.ws / .z.wc / .z.pc
/ omit this key entirely to have the module assign .z.ws / .z.wc / .z.pc directly
hnddict:enlist[`register]!enlist {[zname;label;fn] zname set fn}

/ initialise html module
html:use`di.html
html.init[`homedir`log`handlers!("/opt/app/html";logdict;hnddict)]
```

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.html
```

All exported functions are covered. The one path not unit-tested is `pub` physically
delivering a message over a live WebSocket connection, which requires a real client
handle.
