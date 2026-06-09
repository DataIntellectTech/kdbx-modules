# di.html

WebSocket pub/sub and HTML page serving module, extracted from TorQ.

## Overview

This module does two things:

1. **Pub/sub over WebSockets** — allows browser clients to subscribe to kdb+ tables and receive live updates as data is published.
2. **HTML page serving** — reads HTML files from a configured directory and serves them over HTTP, optionally replacing server/port placeholders so the page can connect back to itself.

## Usage

```q
html:use`di.html

/ minimal setup - log dep is required, handlers dep is optional
logdep:`info`warn`error!(
  {[c;m] -1 "INFO  ",(string c)," ",m;};
  {[c;m] -1 "WARN  ",(string c)," ",m;};
  {[c;m] -2 "ERROR ",(string c)," ",m;})
html.init[(enlist `homedir)!enlist "/opt/app/html";enlist[`log]!enlist logdep]

/ register tables for pub/sub
html.addtables[`trades`quotes]

/ publish data to subscribers
html.pub[`trades;newdata]
```

## init

```q
html.init[config;deps]
```

### config keys

| Key | Type | Description | Required |
|---|---|---|---|
| `homedir` | string | Path to the directory containing HTML files | Yes |

### deps keys

| Key | Description | If absent |
|---|---|---|
| `` `log `` | Logging function dict with keys `` `info`warn`error `` | **Required** — `init` signals an error |
| `` `handlers `` | Handler registration dict with key `` `register `` | Assigns `.z.wc` and `.z.ws` directly |

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

The module registers a `.z.ws` handler that receives bytes from the browser, deserialises them to a q dict, calls `evaluate`, JSON-encodes the result, and sends it back. A `.z.wc` handler cleans up subscriptions when a connection closes.

## Logging

The module logs at three points:

- On `init`: confirms the module started and which `homedir` was set
- On `readpage`: warns if a requested file is not found
- On `evaluate`: logs at error level when a WebSocket-invoked function fails (the error is also re-thrown to the caller)

The `log` dependency is required — `init` signals an error if it is absent. Internally the loggers are stored on `.z.m` as `lginfo`/`lgwarn`/`lgerr` (not `log`, which is a q built-in) and every call site invokes them through `.z.m`.

## Example with injected dependencies

The `log` dep is required and the `handlers` dep is optional; both are supplied by
the host application. The `log` functions are called as `(ctx;msg)` and the
`handlers` registry's `register` is called as `(.z event name; label; handler)`.

```q
/ wire up logging on top of the kx.log module
/ kx.log loggers take a single message, so wrap them to the (ctx;msg) shape
logger:use`kx.log
kxlog:logger.createLog[]
logdep:`info`warn`error!(
  {[c;m] kxlog.info[(string c),": ",m]};
  {[c;m] kxlog.warn[(string c),": ",m]};
  {[c;m] kxlog.error[(string c),": ",m]})

/ wire up handlers via a host-provided registry
/ a real registry composes handlers so several modules can share .z.ws / .z.wc
/ omit this dep entirely to have the module assign .z.ws / .z.wc directly
hnddep:enlist[`register]!enlist {[zname;label;fn] zname set fn}

/ initialise html module
html:use`di.html
html.init[(enlist `homedir)!enlist "/opt/app/html";`log`handlers!(logdep;hnddep)]
```

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.html
```

All exported functions are covered. The one path not unit-tested is `pub` physically
delivering a message over a live WebSocket connection, which requires a real client
handle.
