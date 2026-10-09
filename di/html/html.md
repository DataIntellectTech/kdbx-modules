# di.html

WebSocket pub/sub and HTML page serving module for kdb+.

## Features

- Register kdb+ tables for live pub/sub over WebSockets
- Push updates to all subscribed browser handles via `pub`
- Serve static assets (HTML, JS, CSS) from a configurable directory using kdb's built-in HTTP handler — no separate web server required
- Browser clients subscribe via the `sub` evaluate dispatch and receive an initial snapshot on connection
- Custom per-table modifier functions to control serialisation (c.js binary or plain JSON text)
- Connections cleaned up automatically on WebSocket close (`.z.wc`) or IPC port close (`.z.pc`)

## How it works

A single q process does two jobs on the same port:

1. **Serves the HTML page** — kdb's built-in HTTP handler serves static files from the directory pointed to by `KDBHTML`. When a browser requests `http://host:port/index.html`, kdb reads and returns the file.
2. **Handles WebSocket connections** — once the page loads, the browser opens a WebSocket back to the same `host:port`. The `.z.ws` handler receives messages, dispatches via `evaluate`, and sends replies. Live updates are pushed to subscribed handles via `pub`.

You need two things:

- A **q process** started with `-p PORT`, with di.html loaded and `init` called
- **HTML/JS/CSS files** in the directory pointed to by `KDBHTML`

## Dependencies

| Key | Type | Required | Description |
|---|---|---|---|
| `` `log `` | dict | yes | Logging functions keyed on `` `info`warn`error ``, each `{[ctx;msg]}` where `ctx` is a symbol and `msg` is a string. All three are required. kx.log instances are normalised automatically. |

The HTML home directory is configured via the `KDBHTML` environment variable (not a deps key). kdb-x sets `KDBHTML` by default to the `analyst/html` directory in the kdb-x installation, which contains the KX Analyst UI. If `KDBHTML` is unset, `"html"` (relative to the working directory) is used as a fallback. Set or override `KDBHTML` before calling `init` to point at your own HTML files.

## Initialisation

```q
html.init[deps]
```

`deps` is a dictionary containing the `log` key. `init`:

- Normalises the log dependency (wraps kx.log monadic functions into the dyadic contract)
- Sets `.h.HOME` from `KDBHTML` so the default HTTP handler serves static assets
- Registers `.z.ws`, `.z.wc`, and `.z.pc` handlers — wired once only; any existing `.z.wc`/`.z.pc` handlers are preserved by wrapping
- Safe to call multiple times; handler wiring is skipped on subsequent calls

## Exported Functions

### addtables

```q
html.addtables[tablelist]
```

Registers a list of table names for pub/sub. Can be called multiple times to add new tables. Sets a default modifier per table that JSON-encodes updates before sending to subscribers.

### pub

```q
html.pub[tbl;data]
```

Publishes `data` for `tbl` to all currently subscribed handles, applying the per-table modifier before sending.

### sub

```q
html.sub[tbl;syms]
```

Subscribes the current handle (`.z.w`) to `tbl`, replacing any existing subscription that handle has to it. `syms` filters which rows the subscriber receives from `pub`: pass `` ` `` (or any list containing a null symbol) to receive all syms. Tables without a `sym` column are never filtered. Pass `` ` `` as `tbl` to subscribe to all registered tables.

Returns `(tablename; snapshot)` so the subscriber can initialise their local copy before live updates arrive. The snapshot follows tickerplant semantics: a keyed table returns its current rows, filtered by `syms`; any other table returns its empty schema.

Both arguments may be symbols or strings (a list of strings for several syms), so JSON from a browser can be passed straight through.

Browser clients call `sub` via the evaluate dispatch:

```json
{"func": "sub", "arg1": "trades", "arg2": ""}
```

`arg1` is the table name (empty string = all tables), `arg2` is the sym filter: a string, a list of strings, or an empty string for all syms.

### setmodifier

```q
html.setmodifier[tbl;fn]
```

Sets a custom modifier function for `tbl`. `fn` receives `(\`upd;tbl;data)` and must return bytes or a string to send directly to subscribers.

The default modifier uses the c.js binary protocol (kdb+ IPC-wrapped JSON). Switch to plain JSON text for clients without c.js:

```q
html.setmodifier[`trades;{.j.j `name`data!("upd";`tablename`tabledata!(x 1;x 2))}]
```

Signals an error if `tbl` has not been registered via `addtables`.

### dataformat

```q
html.dataformat[msgtype;msgdata]
```

Wraps a message into a `` `name`data `` dictionary, javascript-formatting each table in `msgdata` (a list or dictionary of tables). Useful for request/reply calls where the front end asks for several tables at once.

### evaluate

```q
html.evaluate[inputdict]
```

Extracts the `func` key from a q dictionary, calls the named function with any additional keys as arguments, and returns the result. Used internally by `.z.ws` — the handler deserialises JSON before calling this. Functions in `funcmap` (`sub`, `addtables`, `pub`, `dataformat`) are resolved first; after that, `func` must name a global lambda or projection defined by the host process (e.g. `getdata` or `.dash.getdata`).

`func` is only ever looked up as a name, never evaluated as q code. q primitives (`system`, `value`, ...), non-function globals and anything in a single-letter namespace reserved by KX (`.q`, `.Q`, `.z`, `.h`, ...) are refused with an error.

## Usage Example

```q
html:use`di.html
logging:use`di.util.log

/ set static file directory before init
setenv[`KDBHTML;"/opt/app/html"]
html.init[logging.logdict]

/ register tables
html.addtables[`trades`quotes]

/ publish from a timer or upd handler
html.pub[`trades;newdata]
```

With kx.log, pass the log instance directly — it is normalised automatically:

```q
logger:use`kx.log
kxlog:logger.createLog[]
html.init[enlist[`log]!enlist kxlog]
```

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.html
```

All exported functions are covered. The one path not unit-tested is `pub` physically delivering a message over a live WebSocket connection, which requires a real client handle.

For interactive browser testing, use the included integration test script:

```bash
q di/html/integrationtest.q -p 5678
```

This starts a process with a plain-text JSON websocket handler and plain-JSON modifiers (no c.js required). Navigate to `http://localhost:5678/test.html` to subscribe to tables and push live data via `tick[\`trades;5]` in the q session. `tick` publishes through `pub`, so each subscriber's sym filter applies.

## Notes

- The default `.z.ws` handler sends kdb+ binary IPC (`-8!`) and requires the KX c.js library in the browser. Use `setmodifier` to switch individual tables to plain JSON text for clients without c.js.
- `.z.wc` fires on WebSocket close; `.z.pc` fires on any IPC port close. Both are wired so that `sub` works over plain IPC handles as well as WebSocket connections.
- Any host-defined global function can be called by a websocket client through `evaluate`. Don't define functions in a process serving websockets that you would not want a browser to call.
