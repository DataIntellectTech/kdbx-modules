# di.util.cfg

Config resolution helpers shared by `di.*` modules: the two path roots, relative-path
resolution, and coercion of settings values that arrive typed from a `.q` tier or as text
from a `.toml` one.

Each of these was duplicated across `di.*` modules (rdb, wdb, idb, tickerplant, chainedtp,
segmentedtp, gateway, housekeeping, tickerlogreplay, compression, servers, subscriptions,
permissions). One implementation now backs them all.

## API

| | |
|---|---|
`apphome[]` | `$TORQXAPPHOME` - app code and config |
`datahome[]` | `$TORQXDATAHOME`, falling back to `$TORQXAPPHOME` - runtime data |
`resolvedir[base;dir]` | resolve a possibly-relative setting to an absolute path string under `base` |
`asbool[x]` | a boolean setting |
`aslong[x]` | a long setting - errors if the value does not parse, rather than returning `0N` |
`astimespan[unit;x]` | a timespan setting - a bare number counts in `unit` (`` `second ``, `` `minute `` or `` `hour ``) |
`tosym[x]` | a symbol setting from text (TOML has no symbol type) |
`aslist[x]` | wrap an atom as a one-element list, leave a list alone |
`assym[x]` | a symbol or symbol list from text or symbols |
`astoklist[x]` | a symbol list from a space-separated string, a symbol or a symbol list |

`resolvedir` accepts a `.q` settings symbol (`` `:x ``) or a colon-less `.toml` string
(`"x"`), and leaves an absolute path alone.

`astimespan` takes the unit so each call site says what a bare number means:

```q
astimespan[`second;30]          / 0D00:00:30
astimespan[`second;"30"]        / 0D00:00:30 - bare digits as text count in the unit too
astimespan[`hour;2]             / 0D02:00:00
astimespan[`second;"0D00:05"]   / text with a D or : is read as a timespan
```

A timespan passes through and a time, minute or second atom is cast. A fraction or negative
number works. **Anything unreadable is an error**, not `0Nn`. This replaces three copies that
disagreed: one read `"30"` as 30 hours, one as 30 seconds, and housekeeping read a bare number as
nanoseconds.

`asbool` accepts a real boolean, any numeric atom (byte through float, nonzero being true),
or the text `true`/`false`, `yes`/`no`, `t`/`f`, `y`/`n`, `1`/`0` in any case. **Anything else is an
error**, including a null number and unrecognised text, not a silent `0b` or `1b`.

Two ways the old copies read a truthy setting as false, both silently: a quoted
`enabled = "true"` in a toml, and an int or short `1` in a `.q` tier. In `di.permissions`
either meant access control was off with no warning.

## Usage

Modules bind the helpers at load time, so call sites stay unqualified:

```q
cfg:use`di.util.cfg;
apphome:cfg`apphome;
datahome:cfg`datahome;
resolvedir:cfg`resolvedir;
```

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.util.cfg
```

The suite calls `setenv`, so run it in its own q session.
