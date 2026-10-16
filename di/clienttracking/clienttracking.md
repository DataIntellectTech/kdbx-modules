# di.clienttracking

Tracks the client sessions of a process in `.clients.clients`: who connected, when, how many
queries they sent, how many failed and how many bytes they were sent.

## Surface

| Name | What |
|---|---|
| `.clients.clients` | session table, keyed on `w`: `ipa u a k K c s o f pid port startp endp lastp hits errs sz` |
| `.dotz.liveh` / `.dotz.livehn` / `.dotz.liveh0` | live-handle checks, defined if absent (di.torq.servers defines them too) |

Everything else is module-private: `po`/`wo` record a new connection/websocket, `pc` marks a closed one
(`w` null, `endp` set), `hit`/`hite` count a query and its result bytes / a failed query, `cleanup` marks
dead handles, closes idle ones and purges old closed rows, `addw[w]` records a handle by hand.

## Settings

Required in `config`; `di/torq/settings/default.q` declares them all:

| Key | Default | Meaning |
|---|---|---|
| `clientsenabled` | `1b` | track connections |
| `clientsopencloseonly` | `0b` | track connections but not queries |
| `clientsintrusive` | `0b` | ask each new kdb+ client for `k K c s o f pid port`; don't use with non-kdb+ clients |
| `clientsautoclean` | `1b` | not read |
| `clientsretain` | `` `long$0D02 `` | nanoseconds to keep a closed row |
| `clientsmaxidle` | `` `long$0D `` | nanoseconds of idleness before a handle is closed; 0 means never |

## init[config;deps]

Requires `handlers` (`di.torq.handlers`). It:

1. signals if any setting is missing, then applies them;
2. registers `pc` on `.z.pc`, whether or not `enabled`;
3. when `clientsenabled`, registers `po` on `.z.po`, `wo` on `.z.wo` and `pc` on `.z.wc`;
4. when `clientsenabled` and not `clientsopencloseonly`, wraps `.z.pg`, `.z.ps` and `.z.ws` directly (not through
   `di.torq.handlers`) with `{hit[@[x;y;hite]]}` around the current handler.
   An unset `.z.pg`/`.z.ps` is taken as `value`, and an unset `.z.ws` as an echo.

Call `init` once: a second call wraps the query handlers again. An exec owner registered on those
events through `di.torq.handlers` afterwards replaces the wrap.

## Behaviour to know

- `hits`, `errs` and `sz` count async (`.z.ps`) and websocket (`.z.ws`) messages too, including the
  bytes of results that are never sent back.
- A closed row keeps its key with `w` set to null, so several closed rows share a null key.
- A handle closed by the `clientsmaxidle` sweep still has a null `endp`, so the same sweep drops its row
  instead of marking it.
- The private `unregistered[]` reads a `CLIENTS` table that doesn't exist, and fails.
- `hits` and `errs` are ints.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.clienttracking
```

`test.q`/`test.csv` start four server peers, each configured from the settings file plus overrides
(defaults, `clientsopencloseonly`, disabled, and `clientsintrusive` with a one-second `clientsmaxidle`
and `clientsretain`), and connect to them. The tests cover the settings, the table, the init checks,
the stored settings, connection rows, hits, bytes and errors, closing and `addw`, websocket rows, both
settings modes, the intrusive reply, idle closing and the retain purge.
