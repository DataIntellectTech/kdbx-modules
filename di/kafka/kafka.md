# di.kafka

Wrapper around the `kafkaq` native shared library. Provides consumer and producer
lifecycle management and a configurable message callback for kdb-x processes that
need to produce or consume Kafka messages.

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `log` | yes | `info`, `warn`, `error` — each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

The `log` dependency must be passed to `init` inside the `configs` dict. The module
throws immediately if it is absent or missing any of the three required keys.

A `kx.log` instance can be passed directly — the module normalises monadic functions
to the binary `{[c;m]}` contract automatically. Context is embedded in the output as
`"context: message"` (e.g. `"kafka: loading library /opt/kdb/lib/l64/kafkaq.so"`):

```q
kxlog:use`kx.log
kafka:use`di.kafka
kafka.init[`log`libpath!(kxlog.createLog[];`$/opt/kdb/lib)]
```

Alternatively pass a custom binary logger:

```q
logdep:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;})

kafka:use`di.kafka
kafka.init[`log`libpath!(logdep;`$/opt/kdb/lib)]
```

## Configuration

`init[configs]` takes a single dictionary combining the `log` dependency with
any configuration overrides.

| Key | Required | Description |
|---|---|---|
| `log` | yes | Binary log dep — `info`, `warn`, `error` functions each `{[c;m]}` |
| `libpath` | yes (when enabled) | Root library directory — the OS-specific subdirectory and `kafkaq` filename are appended automatically (e.g. `/opt/kdb/lib` → `/opt/kdb/lib/l64/kafkaq.so`) |
| `kupd` | no | Initial message callback `{[k;x]}` — defaults to a no-op; replace via `setkupd` |
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

| Function | Args | Returns | Description |
|---|---|---|---|
| `init[configs]` | dict | void | Load the native library, wire dependencies, install the message callback |
| `initconsumer[server;optiondict]` | symbol, symbol dict | int (consumer handle) | Initialise a Kafka consumer. `server`: broker address as symbol e.g. `` `localhost:9092 ``. `optiondict`: Kafka config options as symbol-keyed symbol dict e.g. `` `fetch.wait.max.ms`fetch.error.backoff.ms!`5`5 `` — pass `()!()` for defaults |
| `initproducer[server;optiondict]` | symbol, symbol dict | int (producer handle) | Initialise a Kafka producer. Same arg shapes as `initconsumer` |
| `cleanupconsumer[]` | — | void | Disconnect and free the consumer |
| `cleanupproducer[]` | — | void | Disconnect and free the producer |
| `subscribe[topic;partition]` | symbol, int | void | Start the subscription thread. `topic`: Kafka topic name as symbol. `partition`: partition number as int |
| `publish[topic;partition;key;msg]` | symbol, int, symbol, bytes | void | Publish to a topic. `key`: message key as symbol (use `` ` `` for no key). `msg`: payload as byte vector e.g. `` `byte$"hello" `` |
| `setkupd[f]` | binary function | void | Replace the message callback. `f` must be `{[k;x]}` where `k` is the message key (symbol) and `x` is the payload (byte vector) |

## Before `init` is called

All six native functions (`initconsumer`, `initproducer`, `cleanupconsumer`,
`cleanupproducer`, `subscribe`, `publish`) are stubs that throw:
'di.kafka: kafka not initialised - call init first

This distinguishes "init not called" from a genuine broker or argument error.

## Example

```q
kxlog:use`kx.log

kafka:use`di.kafka
kafka.init[`log`libpath!(kxlog.createLog[];`$/opt/kdb/lib)]

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
| `enabled:@[value;\`enabled;.z.o in \`l64]` | pass `enabled:0b` in `configs` to suppress library loading |
| `kupd:{[k;x]...}` defined in settings | pass `kupd` key in `configs` to `init`, or call `setkupd` after |
| default `kupd` prints bytes to stdout | default `kupd` is a no-op — install a callback via `setkupd` |
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

kafka:use`di.kafka
kafka.init[`log`libpath!(kxlog.createLog[];`$/path/to/lib)]

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
