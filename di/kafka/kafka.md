# di.kafka

Kafka consumer and producer interface for kdb+ processes. Wraps the `kafkaq` native C shared library to provide consumer initialisation, producer initialisation, topic subscription, and message publishing. Incoming messages are delivered to a configurable `kupd` callback in the root namespace.

---

## Features

- Connect kdb+ processes to a Kafka broker as consumer, producer, or both
- Subscribe to topics and receive messages via a configurable callback function
- Publish byte vectors to topics with optional message keys
- Graceful disabled mode on unsupported platforms - all native functions are replaced with informative stubs
- Message handler (`kupd`) configurable at init or updated live via `setkupd`
- Compatible with any logging implementation via the injected `log` dependency

---

## Dependencies

**Native library:** `kafkaq.so` (Linux) or `kafkaq.dll` (Windows). Must be present on the host. Path is provided via the `libpath` config key or derived from the `KDBLIB` environment variable.

**Injected:** `log` - required. Pass `info`, `warn`, and `error` log functions via the `deps` argument to `init`. See `di.log` or the Confluence documentation for the expected function signatures.

---

## Initialisation

```q
log:use`di.log
log.init[logconfig]
logdep:enlist[`log]!enlist `info`warn`error!(log.info;log.warn;log.error)

kafka:use`di.kafka
kafka.init[`enabled`libpath!(1b;`$/opt/TorQ/lib/l64/kafkaq);logdep]
```

All config keys are optional. Passing `(::)` or `()!()` as config applies defaults.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | boolean | `1b` on `l64`, `0b` on all other platforms | Whether to load the native library. On a non-`l64` host the module loads in disabled mode unless explicitly overridden. |
| `libpath` | symbol | derived from `KDBLIB` env var | Path to the kafkaq library **without** file extension. If `KDBLIB` is not set, provide this explicitly. |
| `kupd` | function | logs message via injected logger | Message handler called by the C library on Kafka message receipt. Signature: `{[key;bytes]}`. |

The `log` dependency is **required**. `init` throws if it is absent, `(::)`, or missing any of `info`/`warn`/`error`.

`init` must be called before any other function is used. It is safe to call multiple times.

---

## Functions

### `init`
```q
kafka.init[config;deps]
```
Initialises the module. Loads the native library when `enabled:1b` and the library is found. Sets the global `kupd` callback for the C library.

### `initconsumer`
```q
kafka.initconsumer[`localhost:9092;`fetch.wait.max.ms`fetch.error.backoff.ms!`5`5]
```
Initialises a Kafka consumer and connects to the broker.

### `initproducer`
```q
kafka.initproducer[`localhost:9092;`queue.buffering.max.ms`batch.num.messages!`5`1]
```
Initialises a Kafka producer and connects to the broker.

### `cleanupconsumer`
```q
kafka.cleanupconsumer[(::)]
```
Disconnects and frees the consumer object, stopping the subscription thread.

### `cleanupproducer`
```q
kafka.cleanupproducer[(::)]
```
Disconnects and frees the producer object.

### `subscribe`
```q
kafka.subscribe[`mytopic;0]
```
Starts the subscription thread for a topic on a given partition. Messages are delivered to `kupd`.

### `publish`
```q
kafka.publish[`mytopic;0;`;`byte$"hello world"]
kafka.publish[`mytopic;0;`mykey;`byte$"hello world"]
```
Publishes a byte vector to a topic and partition with an optional symbol key.

### `setkupd`
```q
kafka.setkupd[{[k;x] upd[`kafkadata;(enlist k;enlist x)]}]
```
Updates the message handler after `init` without requiring a full reinitialisation. Also updates the global `kupd` in the root namespace if the module is enabled.

`init` must be called before `setkupd`.

> **Warning:** Avoid calling `setkupd` while a subscription is active. The Kafka C library delivers messages on a background thread and may invoke the old handler after the swap.

---

## Usage example

```q
log:use`di.log
log.init[logconfig]
logdep:enlist[`log]!enlist `info`warn`error!(log.info;log.warn;log.error)

myhandler:{[k;x]
  upd[`kafkadata;(enlist .z.p;enlist k;enlist "c"$x)];
  };

kafka:use`di.kafka
kafka.init[`enabled`libpath`kupd!(1b;`$/opt/TorQ/lib/l64/kafkaq;myhandler);logdep]

kafka.initconsumer[`localhost:9092;()!()]
kafka.subscribe[`trades;0]

kafka.initproducer[`localhost:9092;()!()]
kafka.publish[`trades;0;`;`byte$"test message"]

kafka.cleanupconsumer[(::)]
kafka.cleanupproducer[(::)]
```

---

## Global side effect

When `enabled:1b` and the library loads successfully, `init` sets `kupd` in the **root namespace**:

```q
@[`.;`kupd;:;.z.m.kupd]
```

This is an unavoidable consequence of the native C library's design - kafkaq is compiled to call `kupd` by name in the root namespace. `setkupd` also updates the global when enabled.

---

## Disabled mode

When `enabled:0b` - either because the platform default resolved to `0b` or it was explicitly set - every native function (`initconsumer`, `initproducer`, `cleanupconsumer`, `cleanupproducer`, `subscribe`, `publish`) is a stub that throws:

```
'kafka not enabled
```

This is the expected behaviour when kafka is not set up. It distinguishes "kafka isn't configured" from a genuine broker or argument error.

If `enabled:1b` and the library file is not found, `init` logs an error and continues rather than throwing - the process stays alive and all functions remain as stubs. This matches TorQ's original behaviour: a missing native library degrades the module to disabled rather than halting the process.

> **Note:** If kafka silently isn't working after `init` with `enabled:1b`, check the injected logger's error output. `init` logs the missing library path but does not throw - there is nothing to catch.

---

## TorQ migration

| TorQ pattern | Module equivalent |
|---|---|
| `enabled:@[value;\`enabled;.z.o in \`l64]` | `kafka.init[\`enabled!enlist 1b;logdep]` |
| `kupd:{[k;x]...}` defined in settings | `kafka.init[\`kupd!enlist{[k;x]...};logdep]` |
| default `kupd` prints bytes to stdout (`-1 \`char$x`) | default `kupd` routes through injected logger - override with `kupd` config key if stdout behaviour is needed |
| `.kafka.initconsumer[s;o]` | `kafka.initconsumer[s;o]` |
| `.kafka.initproducer[s;o]` | `kafka.initproducer[s;o]` |
| `.kafka.cleanupconsumer[(::)]` | `kafka.cleanupconsumer[(::)]` |
| `.kafka.cleanupproducer[(::)]` | `kafka.cleanupproducer[(::)]` |
| `.kafka.subscribe[t;p]` | `kafka.subscribe[t;p]` |
| `.kafka.publish[t;p;k;m]` | `kafka.publish[t;p;k;m]` |

---

## Manual verification (requires kafkaq.so and Kafka broker)

```q
/ verify lib loads
kafka.init[`enabled`libpath!(1b;`$/path/to/l64/kafkaq);logdep]

/ verify consumer and subscription
kafka.initconsumer[`localhost:9092;()!()]
kafka.subscribe[`test;0]

/ verify publish
kafka.initproducer[`localhost:9092;()!()]
kafka.publish[`test;0;`;`byte$"hello from kdb+"]

/ cleanup
kafka.cleanupconsumer[(::)]
kafka.cleanupproducer[(::)]
```

---

## Notes

- `enabled` defaults to `1b` only on `l64` hosts; everywhere else it defaults to `0b`. Pass `enabled:1b` explicitly to force-enable on a platform where a native library build is available.
- The `log` dependency is required with no fallback. This differs from TorQ, which has no equivalent concept of injected logging - this module requires it for consistency with other `di.*` modules.
- The default `kupd` routes through the injected logger rather than TorQ's original raw stdout write (`-1 \`char$x`). Override with the `kupd` config key if stdout behaviour is needed.
