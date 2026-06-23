# di.kafka

Wrapper around the `kafkaq` native shared library. Provides consumer and producer
lifecycle management and a configurable message callback for kdb-x processes that
need to produce or consume Kafka messages.

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `log` | yes | `info`, `warn`, `error` — each monadic `{[msg] ...}` |

The `log` dependency must be passed to `init`. The module throws immediately if it
is absent or missing any of the three required keys. A `kx.log` instance can be
passed directly — no manual wrapping required:

```q
kxlog:use`kx.log
kafka:use`di.kafka
kafka.init[enlist[`libpath]!enlist`$/opt/kdb/lib;kxlog.createLog[]]
```

Alternatively, pass a deps dict with a `log` key for use alongside other dependencies:

```q
kafka.init[enlist[`libpath]!enlist`$/opt/kdb/lib;enlist[`log]!enlist kxlog.createLog[]]
```

## Configuration

`init[config;deps]` takes a configuration dictionary as its first argument.

| Key | Required | Description |
|---|---|---|
| `libpath` | yes (when enabled) | Root library directory — the OS-specific subdirectory and `kafkaq` filename are appended automatically (e.g. `/opt/kdb/lib` → `/opt/kdb/lib/l64/kafkaq.so`) |
| `kupd` | no | Initial message callback `{[k;x]}` — defaults to printing bytes as chars to stdout |
| `enabled` | no | Whether to load the native library. Defaults to `1b` on `l64`, `0b` elsewhere. Set to `0b` to suppress library loading on unsupported platforms — all native functions remain stubs |

## The message callback

When a subscription is active, the native `kafkaq` library delivers messages by
calling `.kupd` in the root namespace with a key (symbol) and payload (bytes).
`init` installs a forwarder at `.kupd` that delegates to the module-local callback,
which can be replaced at any time via `setkupd` without re-initialising.

> **Warning:** Avoid calling `setkupd` while a subscription is active. The Kafka
> C library delivers messages on a background thread and may invoke the old handler
> after the swap.

```q
kafka.setkupd[{[k;x] upd[`kafkadata;(enlist .z.p;enlist k;enlist "c"$x)]}]
```

## Public API

| Function | Description |
|---|---|
| `init[config;deps]` | Load the native library, wire dependencies, install the message callback |
| `initconsumer[server;optiondict]` | Initialise a Kafka consumer |
| `initproducer[server;optiondict]` | Initialise a Kafka producer |
| `cleanupconsumer[]` | Disconnect and free the consumer |
| `cleanupproducer[]` | Disconnect and free the producer |
| `subscribe[topic;partition]` | Start the subscription thread for a topic/partition |
| `publish[topic;partition;key;msg]` | Publish a byte vector to a topic/partition |
| `setkupd[f]` | Replace the message callback |

## Before `init` is called

All six native functions (`initconsumer`, `initproducer`, `cleanupconsumer`,
`cleanupproducer`, `subscribe`, `publish`) are stubs that throw:
'di.kafka: kafka not initialised - call init first

This distinguishes "init not called" from a genuine broker or argument error.

## Example

```q
kxlog:use`kx.log

kafka:use`di.kafka
kafka.init[enlist[`libpath]!enlist`$/opt/kdb/lib;kxlog.createLog[]]

/ consume messages with a custom callback
kafka.setkupd[{[k;x] upd[`kafkadata;(enlist .z.p;enlist k;enlist "c"$x)]}]
kafka.initconsumer[`localhost:9092;`fetch.wait.max.ms`fetch.error.backoff.ms!`5`5]
kafka.subscribe[`trades;0]

/ publish a message
kafka.initproducer[`localhost:9092;`queue.buffering.max.ms`batch.num.messages!`5`1]
kafka.publish[`trades;0;`;`byte$"hello world"]

/ cleanup
kafka.cleanupconsumer[]
kafka.cleanupproducer[]
```

## TorQ migration

| TorQ pattern | Module equivalent |
|---|---|
| `enabled:@[value;\`enabled;.z.o in \`l64]` | pass `enabled:0b` in config to suppress library loading |
| `kupd:{[k;x]...}` defined in settings | pass `kupd` key in config to `init`, or call `setkupd` after |
| default `kupd` prints bytes to stdout | default `kupd` prints bytes to stdout — same behaviour |
| `.kafka.initconsumer[s;o]` | `kafka.initconsumer[s;o]` |
| `.kafka.initproducer[s;o]` | `kafka.initproducer[s;o]` |
| `.kafka.cleanupconsumer[(::)]` | `kafka.cleanupconsumer[]` |
| `.kafka.cleanupproducer[(::)]` | `kafka.cleanupproducer[]` |
| `.kafka.subscribe[t;p]` | `kafka.subscribe[t;p]` |
| `.kafka.publish[t;p;k;m]` | `kafka.publish[t;p;k;m]` |

## Global side effect

`init` sets `.kupd` in the root namespace as a forwarder into module state:

```q
`.kupd set {[k;x] .z.m.kupd[k;x]}
```

This is an unavoidable consequence of the native C library's design — `kafkaq` is
compiled to call `kupd` by name in the root namespace.

## Manual verification (requires kafkaq.so and a Kafka broker)

```q
kxlog:use`kx.log

kafka.init[enlist[`libpath]!enlist`$/path/to/lib;kxlog.createLog[]]

kafka.initconsumer[`localhost:9092;()!()]
kafka.subscribe[`test;0]

kafka.initproducer[`localhost:9092;()!()]
kafka.publish[`test;0;`;`byte$"hello from kdb+"]

kafka.cleanupconsumer[]
kafka.cleanupproducer[]
```

## Running tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.kafka
```
