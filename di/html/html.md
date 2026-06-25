# di.html

WebSocket pub/sub and HTML page serving module, extracted from TorQ.

## Overview

This module provides pub/sub over WebSockets — browser clients subscribe to kdb+ tables and receive live updates as data is published. The module also sets `.h.HOME` so the default HTTP handler serves static assets (HTML, JS, CSS) from the configured directory without any additional code.

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

Set `KDBHTML` before calling `init` so static files are served from the right directory.

## init

```q
html.init[deps]
```

`deps` is a dictionary. The `` `log `` key is required — `init` signals an error if it is missing or malformed.

| Key | Type | Description | Default |
|---|---|---|---|
| `` `log `` | dict | **Required.** Logging functions keyed `` `info`warn`error ``, each called as `{[msg]}` — e.g. from `di.log` | — |

The HTML home directory comes from the `KDBHTML` environment variable. If the variable is unset `"html"` is used. There is no `homedir` config key.

`init` also sets `.h.HOME` to the resolved home directory (protected, skipped if `.h` is unavailable) so the default HTTP handler serves static assets (css/js/img) from the same directory. Calling `init` multiple times is safe — the `.z.ws`/`.z.wc`/`.z.pc` handlers are wired only once.

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

### setmodifier

```q
html.setmodifier[tbl;fn]
```

Sets a custom modifier function for `tbl`. `fn` is called on every `pub` as `fn[(\`upd;tbl;data)]` and must return bytes or a string suitable to send directly to a subscriber handle.

The default modifier encodes data using the c.js binary protocol (kdb+ IPC-wrapped JSON). Use `setmodifier` to switch a table to plain JSON text — for example when subscribers are plain WebSocket clients without c.js:

```q
html.setmodifier[`trades;{-8!.j.j `name`data!("upd";`tablename`tabledata!(x 1;x 2))}]  / default (c.js binary)
html.setmodifier[`trades;{.j.j `name`data!("upd";`tablename`tabledata!(x 1;x 2))}]      / plain json text
```

Signals an error if `tbl` has not been registered via `addtables`.

### dataformat

```q
html.dataformat[msgtype;msgdata]
```

Wraps a message into a `` `name`data `` dictionary, javascript-formatting each table in `msgdata` (a list or dictionary of tables). Used by host data functions that the front end requests over the websocket, e.g. TorQ's monitor `start` call returning several tables at once.

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
- On `evaluate`: logs at error level when a WebSocket-invoked function fails (the error is also re-thrown to the caller)

There is no built-in default logger — the `log` dict must be injected via `init`, typically from `di.log`. The log functions must be monadic (`{[msg]}`) to match the `kx.log` contract. They are stored on `.z.m` as a single `log` dict and called as `.z.m.log[\`info]["message"]`.

## Example with kx.log

```q
/ wire up logging from the kx.log module
logger:use`kx.log
kxlog:logger.createLog[]
logdep:`info`warn`error!(
  {[m] kxlog.info[m]};
  {[m] kxlog.warn[m]};
  {[m] kxlog.error[m]})

/ initialise html module — set KDBHTML before calling init
setenv[`KDBHTML;"/opt/app/html"]
html:use`di.html
html.init[enlist[`log]!enlist logdep]
```

## Browser testing (development)

The default `.z.ws` handler uses kdb+ binary IPC format (`-9!`/`-8!`) and is designed to work with the KX c.js WebSocket library. For development testing without c.js, use the included `modulesetup.q`:

```bash
q di/html/modulesetup.q
```

This starts a process on port 5678 with a plain-text JSON websocket handler. Open `test.html` in a browser (or navigate to `http://localhost:5678/test.html` once the process is running) to connect and interact with the module. Run `tick[\`trades;5]` in the q session to push live data to browser subscribers.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.html
```

All exported functions are covered. The one path not unit-tested is `pub` physically
delivering a message over a live WebSocket connection, which requires a real client
handle.
