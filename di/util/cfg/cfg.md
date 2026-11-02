# di.util.cfg

Config resolution helpers shared by `di.*` modules: the two path roots, relative-path
resolution, and coercion of settings values that arrive typed from a `.q` tier or as text
from a `.toml` one.

Each of these was duplicated across `di.torq.proc.rdb`, `.wdb`, `.tickerplant`,
`.housekeeping`, `.compression` and `di.permissions`. One implementation now backs them all.

## API

| | |
|---|---|
`apphome[]` | `$TORQXAPPHOME` - app code and config |
`datahome[]` | `$TORQXDATAHOME`, falling back to `$TORQXAPPHOME` - runtime data |
`resolvedir[base;dir]` | resolve a possibly-relative setting to an absolute path string under `base` |
`asbool[x]` | a boolean setting |
`aslong[x]` | a long setting |

`resolvedir` accepts a `.q` settings symbol (`` `:x ``) or a colon-less `.toml` string
(`"x"`), and leaves an absolute path alone.

`asbool` accepts a real boolean, any numeric atom (short/int/long/float, nonzero being true),
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
