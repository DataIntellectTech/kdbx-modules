# di.eodtime

End-of-day time management for TorQ-based tickerplant processes. Resolves the current trading date in a configurable roll timezone, calculates the next EOD roll timestamp in UTC, and computes a daily UTC offset used to timestamp incoming data.

---

## Dependencies

**Hard dependency:** `di.tz` - loaded automatically when the module is imported.

---

## Initialisation

```q
eodtime:use`di.eodtime
eodtime.init[`rolltimezone`datatimezone`rolltimeoffset!(`$"Europe/London";`$"GMT";0D00:00:00.000)]
```

Config keys are all optional. Passing `(::)` or an empty dict `()!()` loads the module with defaults that match TorQ's original `eodtime.q` behaviour.

| Key              | Type     | Default          | Description                                                                 |
|------------------|----------|------------------|-----------------------------------------------------------------------------|
| `rolltimezone`   | symbol   | `` `$"GMT" ``    | Timezone used for EOD roll scheduling                                       |
| `datatimezone`   | symbol   | `` `$"GMT" ``    | Timezone used for stamping incoming data                                    |
| `rolltimeoffset` | timespan | `0D00:00:00.000` | Offset from midnight for the EOD roll (e.g. `0D17:00:00.000` for a 5pm roll) |

`init` must be called before any other function is used. It computes the initial values of `d`, `nextroll`, and `dailyadj`.

Timezone values should be standard timezone identifiers in the format `"Region/City"` (e.g. `"Europe/London"`, `"America/New_York"`). The values `"GMT"`, `"UTC"` and `"Etc/GMT"` are handled as special cases returning zero offset directly, without a timezone lookup. `"GMT"` is not recognised by `di.tz` but is the default timezone in TorQ, so this ensures the module works out of the box with existing TorQ products (i.e. backwards compatible). Note: `"Etc/UTC"` is a valid argument in `di.tz`.

---

## Exported functions

### `init`
Initialises the module with the provided config. Computes initial values of `d`, `nextroll`, and `dailyadj`.
```q
eodtime.init[`rolltimezone`datatimezone`rolltimeoffset!(`$"Europe/London";`$"GMT";0D00:00:00.000)]
/ or with defaults:
eodtime.init[::]
```

### `getd`
Returns the current trading date in the roll timezone.
```q
eodtime.getd[]
/ 2025.06.01
```

### `getnextroll`
Returns the UTC timestamp of the next scheduled EOD roll.
```q
eodtime.getnextroll[]
/ 2025.06.02D00:00:00.000000000
```

### `getdailyadj`
Returns the **cached** UTC offset for the data timezone - the value stored at the last `init` or `setdailyadj` call. Used by upstream processes to stamp incoming data:
```q
.z.p + eodtime.getdailyadj[]
/ adds the stored offset to the current UTC time
```

### `getdailyadjustment`
**Recomputes** the UTC offset for the data timezone at the current time. Call this after an EOD roll to get a fresh offset - important when the data timezone observes daylight saving time, as the offset changes at the transition.
```q
eodtime.getdailyadjustment[]
/ 0D01:00:00.000000000
```

### `getroll`
Computes the UTC timestamp of the next EOD roll after UTC timestamp `p`. Returns today's roll time if the roll has not yet passed; returns tomorrow's if it has.
```q
eodtime.getroll[.z.p]
/ 2025.06.02D00:00:00.000000000
```

### `setnextroll`
Updates the stored next roll timestamp. Called by the tickerplant and segmented tickerplant after completing an EOD roll.
```q
eodtime.setnextroll eodtime.getroll[.z.p]
```

### `setdailyadj`
Updates the stored daily adjustment offset. Called by the tickerplant after an EOD roll to refresh the offset for the new day.
```q
eodtime.setdailyadj eodtime.getdailyadjustment[]
```

### `setd`
Updates the stored trading date. Called by the segmented tickerplant to advance the date after an EOD roll.
```q
eodtime.setd[1+eodtime.getd[]]
```

---

## Usage example

```q
/ load and initialise for a London-based system rolling at midnight
eodtime:use`di.eodtime
eodtime.init[`rolltimezone`datatimezone`rolltimeoffset!(`$"Europe/London";`$"GMT";0D00:00:00.000)]

/ check current state
eodtime.getd[]           / today's trading date in London time
eodtime.getnextroll[]    / next midnight UTC (23:00 UTC in summer)
eodtime.getdailyadj[]    / current UTC offset for data timestamping

/ simulate what a tickerplant does at EOD roll
eodtime.setnextroll eodtime.getroll[.z.p];
eodtime.setdailyadj eodtime.getdailyadjustment[];

/ simulate what the segmented tickerplant does at EOD roll
eodtime.setd[1+eodtime.getd[]]
```

---

## TorQ migration pattern

| TorQ pattern                                           | Module equivalent                                    |
|--------------------------------------------------------|------------------------------------------------------|
| `.eodtime.d` (read)                                    | `eodtime.getd[]`                                     |
| `.eodtime.nextroll` (read)                             | `eodtime.getnextroll[]`                              |
| `.eodtime.dailyadj` (read)                             | `eodtime.getdailyadj[]`                              |
| `.eodtime.getroll[p]`                                  | `eodtime.getroll[p]`                                 |
| `.eodtime.getdailyadjustment[]`                        | `eodtime.getdailyadjustment[]`                       |
| `.eodtime.nextroll:.eodtime.getroll[.z.p]`             | `eodtime.setnextroll eodtime.getroll[.z.p]`          |
| `.eodtime.dailyadj:.eodtime.getdailyadjustment[]`      | `eodtime.setdailyadj eodtime.getdailyadjustment[]`   |
| `.eodtime.d+:1`                                        | `eodtime.setd[1+eodtime.getd[]]`                     |

---

## Notes

- `rolltimeoffset` adjusts the roll time from midnight e.g. `0D17:00:00.000` produces a 5pm local roll.
- `getdailyadj` returns the cached offset; `getdailyadjustment` recomputes it fresh. Always call `getdailyadjustment` after an EOD roll rather than relying on the cached value.
- `"GMT"`, `"UTC"` and `"Etc/GMT"` are not in the timezone database used by `di.tz` and are handled as zero-offset shortcuts directly in this module. `"Etc/UTC"` is valid and passed through to `di.tz` normally. All other timezone values are passed through to `di.tz`.
