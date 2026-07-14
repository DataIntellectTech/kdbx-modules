# di.kafka

Wrapper around the `kafkaq` native shared library. Provides consumer and producer lifecycle management and a configurable message callback for kdb-x processes that need to produce or consume Kafka messages.

---

## Features

- Wrap the `kafkaq` native C library and expose consumer and producer lifecycle management as clean kdb-x functions
- Provide a configurable message callback via `setkupd` - the native library always delegates through the current callback without requiring re-initialisation
- Gracefully degrade on non-l64 platforms - all native functions remain as informative stubs when `enabled:0b`
- Distinguish "module not initialised" from genuine broker or argument errors via descriptive stub error messages with `di.kafka:` prefix

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info`, `warn`, `error` - each binary `{[c;m]}` where `c` is a symbol context and `m` is a string |

The `log` dependency must be passed to `init` inside the `deps` dict. The module throws immediately if it is absent or missing any of the three required keys. All three are required since the module calls `info`, `warn`, and `error`. The dict passed in must already match the binary `{[c;m]}` contract - the module does not detect or adapt other shapes (e.g. a raw `kx.log` instance, which is monadic). If you want to use `kx.log`, load it and write your own `{[c;m]}` wrapper around it before passing it in.

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` dependency with any configuration overrides.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Binary log dep - `info`, `warn`, `error` functions each `{[c;m]}` |
| `` `libpath `` | no, if `KDBLIB` is set | Root library directory. Falls back to `$KDBLIB` if omitted. The OS-specific subdirectory and `kafkaq` filename are appended automatically - for example, a root of `/opt/kdb/lib` resolves to `/opt/kdb/lib/l64/kafkaq.so` on Linux |
| `` `kupd `` | no | Initial message callback `{[k;x]}` - defaults to a no-op; replace via `setkupd` after init |
| `` `enabled `` | no | Whether to load the native library. Defaults to `1b` on `l64`, `0b` elsewhere. Set to `0b` to suppress library loading on unsupported platforms - all native functions remain stubs |

If `libpath` is omitted and `KDBLIB` is not set in the environment, `init` throws - there is no further fallback.

`init` must be called before any native functions are used. Before `init` is called, all six native functions (`initconsumer`, `initproducer`, `cleanupconsumer`, `cleanupproducer`, `subscribe`, `publish`) are stubs that throw:
'di.kafka: kafka not initialised - call init first

This distinguishes "init not called" from a genuine broker or argument error.

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log dependency, applies config, loads the native library, and installs the root `.kupd` forwarder.
```q
kafka.init[`log`libpath!(logdep;`$/opt/kdb/lib)]
```

### `initconsumer[server;optiondict]`
Initialise a Kafka consumer. `server`: broker address as symbol. `optiondict`: Kafka config options as a symbol-keyed symbol dict - pass `()!()` for defaults.
```q
kafka.initconsumer[`localhost:9092;`fetch.wait.max.ms`fetch.error.backoff.ms!`5`5]
```

### `initproducer[server;optiondict]`
Initialise a Kafka producer. Same argument shapes as `initconsumer`.
```q
kafka.initproducer[`localhost:9092;`queue.buffering.max.ms`batch.num.messages!`5`1]
```

### `cleanupconsumer[]`
Disconnect and free the consumer object, stopping the subscription thread.
```q
kafka.cleanupconsumer[]
```

### `cleanupproducer[]`
Disconnect and free the producer object.
```q
kafka.cleanupproducer[]
```

### `subscribe[topic;partition]`
Start the subscription thread for a topic and partition. Messages are delivered to the callback set via `setkupd`.
```q
kafka.subscribe[`trades;0]
```

### `publish[topic;partition;key;msg]`
Publish a byte vector to a topic and partition. `key`: message key as symbol (use `` ` `` for no key). `msg`: payload as byte vector.
```q
kafka.publish[`trades;0;`;`byte$"hello world"]
```

### `setkupd[f]`
Replace the message callback invoked when a subscribed message arrives. `f` must be `{[k;x]}` where `k` is the message key (symbol) and `x` is the payload (byte vector). The root `.kupd` forwarder always delegates to the current value so the swap takes effect immediately.
```q
kafka.setkupd[{[k;x] upd[`kafkadata;(enlist .z.p;enlist k;enlist "c"$x)]}]
```

---

## Usage Example

```q
/ log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
/   logging:use`di.log
/   kafka.init[logging.logdict]
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

kafka:use`di.kafka
kafka.init[`log`libpath!(logdep;`$/opt/kdb/lib)]

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

---

## Running Tests

### Unit tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.kafka
```

34 tests. Runs on any kdb-x machine - no TorQ installation or native library required. Covers dependency validation, `enabled:0b` platform skip, stub behaviour for all six native functions, `setkupd` and the `.kupd` forwarder, and a six-level log dict (matching `di.log`'s `logdict` shape) accepted as-is by `init`.

### Integration tests

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.kafka;`test_integration.csv]
.m.di.0k4unit.KUrt[]
```

7 tests. Runs on any kdb-x machine where `KDBLIB` is set and `kafkaq` is present at the resolved path - TorQ deployments set this up automatically via `setenv.sh`, but it's not a strict requirement. A non-TorQ user with their own `kafkaq.so` build can run these tests by exporting `KDBLIB` themselves to point at it:

```bash
export KDBLIB=/path/to/your/kafkaq/lib
```

If `KDBLIB` is not set or `kafkaq.so` is not present at the resolved path, the file exits cleanly and nothing fails.

When the library is present, the tests confirm that `kafka.init` loads `kafkaq.so` successfully and that all six native function bindings are type `112h` (C function) in module state. This proves the library loaded and `bindfunctions` ran correctly. End-to-end testing of consumer and producer operations requires a running Kafka broker and is outside the scope of automated tests.

---

## Notes

- `libpath` is only required when `enabled:1b` (the default on l64) and `KDBLIB` is not set in the environment. Pass `enabled:0b` to initialise without loading the native library - useful for testing or non-l64 deployments
- `setkupd` takes effect immediately via the forwarder pattern - the native library always calls `.kupd` in the root namespace, which delegates to whatever `.z.m.kupd` currently holds. However, messages in-flight from the C background thread may briefly invoke the previous handler after the swap. Avoid calling `setkupd` while a subscription is active
- `init` sets `.kupd` in the root namespace as an unavoidable consequence of the native C library's design - `kafkaq` is compiled to call `kupd` by name in the root namespace
- All three log keys (`info`, `warn`, `error`) are required - unlike `di.eodtime`, this module calls all three
- Manual verification requires a running `kafkaq.so` and a Kafka broker. A minimal end-to-end test once those are available: initialise with a real `libpath`, call `initconsumer`, `subscribe`, `initproducer`, `publish`, verify the callback fires, then `cleanupconsumer` and `cleanupproducer`