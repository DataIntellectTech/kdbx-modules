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
`totimespan[x]` | a timespan setting - a bare number is seconds, text goes through `"N"$` |
`tosym[x]` | a symbol setting from text (TOML has no symbol type) |
`aslist[x]` | wrap an atom as a one-element list, leave a list alone |
`assym[x]` | a symbol or symbol list from text or symbols |
`astoklist[x]` | a symbol list from a space-separated string, a symbol or a symbol list |

`resolvedir` accepts a `.q` settings symbol (`` `:x ``) or a colon-less `.toml` string
(`"x"`), and leaves an absolute path alone.

`totimespan` reads text with `"N"$`, so `"30"` is 30 hours while a bare `30` is 30 seconds,
and a type it does not handle gives `0Nn`. These are kept as they were in the copies this
module replaces.

`asbool` accepts a real boolean, any numeric atom (byte through float, nonzero being true),
or the text `true`/`false`/`1`/`0` in any case. **Every other type is an error**, not a
silent `0b`.

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
