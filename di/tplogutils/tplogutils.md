# `tplogutils` – Tickerplant Log Check & Repair Utilities for kdb+/q

A small utility module for **checking** and **best‑effort repairing** tickerplant-style log files by scanning raw bytes for update-message boundaries, attempting to deserialize candidate messages, and writing any recoverable messages into a new `*.good` logfile.

> **Note:** As currently implemented, recovery is keyed off the signature of `(`upd;`trade;...)` (see **Configuration**). If your logs contain other tables or message shapes, you may need to adapt the signature constants.

---

## :sparkles: Features

- Check whether a logfile should be used as-is or repaired (based on the logic in `check`).
- Repair a corrupt logfile by extracting messages that can be successfully deserialized.
- Chunked scanning to avoid loading large files into memory.
- Adaptive read sizing when no valid messages are found in a chunk.
- Produces a new `<logfile>.good` output file (append-only write during recovery).
- Includes a test suite (`test.q`, `test.csv`) that generates valid/corrupt logs and validates recovery outcomes.

---

## :file_folder: Directory contents

- `init.q` – module implementation (constants + `check`, `repair`)
- `tplogutils.md` – documentation (you can replace/rename to `README.md` if desired)
- `test.q` – tests + helpers for creating valid/corrupted logs
- `test.csv` – test manifest for your project’s test harness

---

## :inbox_tray: Loading

### KDB-X (supports `use`)
If you are using KDB-X (where `use` exists), load the module using the symbol that matches your `QPATH` layout.

If your `QPATH` includes the `di` directory (e.g. `~/kdbx-modules/di`), a common pattern is:

```q
tplogutils:use`tplogutils
```

---

## :gear: Configuration

These constants are defined at the top of `init.q`:

| Name       | Type        | Description |
|------------|-------------|-------------|
| `HEADER`   | byte list   | Template bytes used to build a deserialisable message header. |
| `UPDMSG`   | char list   | Prefix used to detect candidate update messages within raw bytes. |
| `CHUNK`    | long        | Default chunk size (bytes) to read (10MB). |
| `MAXCHUNK` | long        | Maximum chunk size for a single read attempt (`8 * CHUNK`). |

### Current default signature

The module sets `UPDMSG` based on the serialized form of:

```q
(`upd;`trade;())
```

This means:
- it is geared toward logs containing `upd` messages for the `trade` table
- logs containing other table names or different update call shapes may not be recovered unless you adjust the signature logic

---

## :wrench: Functions

### Summary

| Function | Description |
|----------|-------------|
| `check[logfile;lastmsgtoreplay]` | Returns `logfile` if it should be used as-is per `check` logic, otherwise triggers `repair` and returns `<logfile>.good`. |
| `repair[logfile]` | Creates `<logfile>.good` and writes any recoverable messages into it. Returns the new filename. |
---

### `check`

```q
tplogutils.check[logfile; lastmsgtoreplay]
```

**Parameters**

| Parameter | Type | Description |
|----------:|------|-------------|
| `logfile` | symbol | Path to logfile as a symbol (e.g. ```:tp.log```), as used by `-11!`, `hcount`, `read1`, etc. |
| `lastmsgtoreplay` | long | Index position of the last message the caller intends to replay. |

**Behavior (as implemented)**
- inspects logfile info via `-11!(-2; logfile)`
- returns either:
  - the original `logfile`, or
  - a repaired logfile produced by `repair[logfile]`

**Returns**
- `logfile` **or** `<logfile>.good`

---

### `repair`

```q
tplogutils.repair[logfile]
```

**Purpose**
Create a “good” logfile containing only recoverable messages.

**Behavior (as implemented)**
- writes output to `<logfile>.good`
- processes the input logfile in chunks
- for each chunk:
  - searches for occurrences of the configured `UPDMSG` signature
  - splits the chunk into candidate messages
  - constructs a header for each candidate
  - attempts to deserialize each candidate
  - writes successfully decoded messages into the output logfile

**Returns**
- symbol path of the repaired logfile (e.g. ```:tp.log.good```)

---

## :rocket: Typical usage

### Repair-if-needed flow

```q
/ Load module
tplogutils:use`tplogutils

/ Decide whether to repair
log:`:tp.log
safe:tplogutils.check[log; 0j]

/ safe is either `:tp.log or `:tp.log.good
safe
```

### Always repair

```q
tplogutils:use`tplogutils

log:`:tp.log
good:tplogutils.repair log
good
```

---

## :test_tube: Tests

The module includes `test.q` and `test.csv`.

### What the tests do (high level)

`test.q` provides helpers to:
- create a valid log by writing records shaped like `enlist (`upd;`trade; rowData)`
- create a corrupt log by introducing byte-level corruption into one record
- verify that `check` and `repair` behave as expected across scenarios:
  - valid logs
  - corruption with enough valid messages
  - corruption requiring repair
  - garbage at end-of-file
  - multiple corrupt sections
  - completely corrupt logs
  - empty logs
  - sequential operations

### Running tests manually

```q
/ Load module
tplogutils:use`tplogutils

/ Load tests
\l /path/to/kdbx-modules/di/tplogutils/test.q

/ Run a few key tests
test_check_valid_log[]
test_repair_creates_good_file[]
test_repair_recovers_messages[]
test_repair_garbage_at_end[]
```

> **Note:** If the tests refer to `tplogsutil` but you loaded the module as `tplogutils`, either:
> - load the module into a `tplogsutil` variable as well, or
> - update the test references to `tplogutils`.

---

## :bulb: Notes & limitations

- **Best-effort recovery only:** The repair process only keeps messages that can be successfully deserialized by the module’s decode attempt.
- **Signature-specific:** The scan is currently tuned to the prefix of `(`upd;`trade;...)`.
- **Chunk-boundary sensitivity:** Recovery depends on being able to locate the message signature within the bytes read for a given chunk.
- **Validate output:** Always validate that `<logfile>.good` replays correctly in your environment before using it as a production recovery artifact.

---

## :package: Exported symbols

The module exports:

```q
export:([check;repair])
```

