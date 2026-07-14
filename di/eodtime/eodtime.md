# di.eodtime

End-of-day time management for kdb+ tickerplant processes. Resolves the current trading date in a configurable roll timezone, calculates the next EOD roll timestamp in UTC, and computes a daily UTC offset used to timestamp incoming data.

---

## Features

- Compute the current trading date in a configurable roll timezone, handling DST transitions automatically
- Calculate the UTC timestamp of the next EOD roll from any given UTC timestamp, with support for non-midnight roll times via `rolltimeoffset`
- Compute a live UTC offset for a configurable data timezone, refreshable after each roll to capture DST changes
- Store and expose the current trading date, next roll timestamp, and daily adjustment offset as inspectable module state
- State setters allow tickerplant and segmented tickerplant processes to advance state after a roll without re-initialising
- `"GMT"`, `"UTC"`, and `"Etc/GMT"` are handled as zero-offset shortcuts without a timezone lookup — the module works out of the box with TorQ defaults

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | `info` — binary `{[c;m]}` where `c` is a symbol context and `m` is a string. `warn` and `error` are accepted if present but never called by this module |

**Hard dependency:** `di.tz` — loaded automatically when the module is imported.

The `log` dependency must be passed to `init` inside the `configs` dict keyed on `` `log ``. The module throws immediately if `log` is absent or `info` is missing. `warn` and `error` are optional, but the dict passed in must already match the binary `{[c;m]}` contract — the module does not detect or adapt other shapes (e.g. a raw `kx.log` instance, which is monadic). If you want to use `kx.log`, load it and write your own `{[c;m]}` wrapper around it before passing it in.

Configuration keys `rolltimezone`, `datatimezone`, and `rolltimeoffset` are all optional — omit any or all of them and the module falls back to sensible defaults (GMT timezone, midnight roll). See Initialisation for full details.

---

## Initialisation

`init[deps]` takes a single dictionary combining the `log` dependency with any configuration overrides.

| Key | Required | Description |
|---|---|---|
| `` `log `` | yes | Log dep — at minimum `info` function `{[c;m]}` |
| `` `rolltimezone `` | no | Timezone for EOD roll scheduling. Default: `` `$"GMT" `` |
| `` `datatimezone `` | no | Timezone for stamping incoming data. Default: `` `$"GMT" `` |
| `` `rolltimeoffset `` | no | Offset from midnight for the EOD roll (e.g. `0D17:00:00.000` for a 5pm roll). Default: `0D` |

`init` must be called before any other function. It computes the initial values of `d`, `nextroll`, and `dailyadj`. Calling getters before `init` returns uninitialised defaults (`0Nd`, `0Wp`, `0D`) which will produce wrong results in downstream processes.

Timezone values should be standard identifiers in `"Region/City"` format (e.g. `"Europe/London"`, `"America/New_York"`). `"GMT"`, `"UTC"`, and `"Etc/GMT"` are zero-offset shortcuts handled directly without a `di.tz` lookup. Note: `"Etc/UTC"` is valid and passed through to `di.tz` normally.

---

## Exported Functions

### `init[deps]`
Initialise the module. Validates the log dependency, applies config, and computes initial values of `d`, `nextroll`, and `dailyadj`.
```q
eodtime.init[`log`rolltimezone`datatimezone`rolltimeoffset!(logdep;`$"Europe/London";`$"GMT";0D)]
/ or with defaults only:
eodtime.init[enlist[`log]!enlist logdep]
```

### `getd[]`
Return the current trading date in the roll timezone.
```q
eodtime.getd[]
/ 2025.06.01
```

### `getnextroll[]`
Return the UTC timestamp of the next scheduled EOD roll.
```q
eodtime.getnextroll[]
/ 2025.06.02D00:00:00.000000000
```

### `getdailyadj[]`
Return the **cached** UTC offset for the data timezone — the value stored at the last `init` or `setdailyadj` call.
```q
eodtime.getdailyadj[]
/ 0D01:00:00.000000000
```

### `getdailyadjustment[]`
**Recompute** the UTC offset for the data timezone at the current time. Call after an EOD roll to get a fresh offset — important when the data timezone observes DST.
```q
eodtime.getdailyadjustment[]
/ 0D01:00:00.000000000
```

### `getroll[p]`
Compute the UTC timestamp of the next EOD roll after UTC timestamp `p`. Returns today's roll time if the roll has not yet passed; tomorrow's if it has.
```q
eodtime.getroll[.z.p]
/ 2025.06.02D00:00:00.000000000
```

### `setnextroll[x]`
Update the stored next roll timestamp. Called by the tickerplant after completing an EOD roll.
```q
eodtime.setnextroll eodtime.getroll[.z.p]
```

### `setdailyadj[x]`
Update the stored daily adjustment offset. Called by the tickerplant after an EOD roll to refresh the offset for the new day.
```q
eodtime.setdailyadj eodtime.getdailyadjustment[]
```

### `setd[x]`
Update the stored trading date. Called by the segmented tickerplant to advance the date after an EOD roll.
```q
eodtime.setd[1+eodtime.getd[]]
```

---

## Usage Example

```q
/ log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
/   logging:use`di.log
/   eodtime.init[logging.logdict]
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

/ load and initialise for a London-based system rolling at midnight
eodtime:use`di.eodtime
eodtime.init[`log`rolltimezone`datatimezone`rolltimeoffset!(logdep;`$"Europe/London";`$"GMT";0D)]

/ check current state
eodtime.getd[]           / today's trading date in London time
eodtime.getnextroll[]    / next midnight UTC (23:00 UTC in summer)
eodtime.getdailyadj[]    / current UTC offset for data timestamping

/ at EOD roll - tickerplant advances state
eodtime.setnextroll eodtime.getroll[.z.p];
eodtime.setdailyadj eodtime.getdailyadjustment[];

/ at EOD roll - segmented tickerplant advances date
eodtime.setd[1+eodtime.getd[]]
```

---

## Running Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.eodtime
```

The test suite injects a no-op mock logger and a capturing logger that records `(level;msg)` pairs for assertion. It covers: dependency validation (non-dict deps throws; missing `log` key throws; non-dict log value throws; missing `info` key throws; `info`-only log dict succeeds); config defaults and overrides; `getroll` with GMT and non-GMT roll timezones including DST transitions (London winter vs summer, and an overnight DST-transition rollover); `getdailyadjustment` with UTC shortcuts and DST-aware timezones; state setters (`setnextroll`, `setdailyadj`, `setd`) and their corresponding getters; and a six-level log dict (matching `di.log`'s `logdict` shape) accepted as-is by `init`.

---

## Notes

- `rolltimeoffset` adjusts the roll time from midnight — e.g. `0D17:00:00.000` produces a 5pm local roll
- `getdailyadj` returns the cached offset; `getdailyadjustment` recomputes it live. Always call `getdailyadjustment` after an EOD roll rather than relying on the cached value
- `"GMT"`, `"UTC"`, and `"Etc/GMT"` are zero-offset shortcuts not passed to `di.tz`. `"Etc/UTC"` is valid and passes through normally
- Only `info` is required in the log dep — `warn` and `error` are accepted if present but never called by this module. The dep must already match the binary `{[c;m]}` contract; the module does not adapt other shapes