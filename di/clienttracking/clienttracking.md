# di.clienttracking

Tracks the client sessions of a process in `.clients.clients`: who connected, when, how many
queries they sent, how many failed and how many bytes they were sent.

## Surface

| Name | What |
|---|---|
| `.clients.clients` | session table, keyed on `w`: `ipa u a k K c s o f pid port startp endp lastp hits errs sz` |
| `.clients.po[result;W]` / `.clients.wo[result;W]` | record a new connection / websocket |
| `.clients.pc[result;W]` | mark a closed connection: `w` becomes null, `endp` is set |
| `.clients.hit[x]` / `.clients.hite[x]` | count a query and its result bytes / count a failed query, then re-signal |
| `.clients.cleanup[]` | mark dead handles, close idle ones (`MAXIDLE`), purge old closed rows (`RETAIN`) |
| `.clients.addw[w]` | record handle `w` by hand |
| `.clients.unregistered[]` | see below |
| `.dotz.ipa` / `.dotz.liveh` / `.dotz.livehn` | host name lookup and live-handle checks, defined if absent |

## Settings

A `clients` section of the process config, set onto `.clients.<name>`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `1b` | track connections |
| `opencloseonly` | `0b` | track connections but not queries |
| `INTRUSIVE` | `0b` | ask each new kdb+ client for `k K c s o f pid port`; don't use with non-kdb+ clients |
| `AUTOCLEAN` | `1b` | not read |
| `RETAIN` | `` `long$0D02 `` | nanoseconds to keep a closed row |
| `MAXIDLE` | `` `long$0D `` | nanoseconds of idleness before a handle is closed; 0 means never |

## init[config;deps]

Requires `handlers` (`di.torq.handlers`). It:

1. applies the `clients` section;
2. registers `.clients.pc` on `.z.pc`, whether or not `enabled`;
3. when `enabled`, registers `.clients.po` on `.z.po`, `.clients.wo` on `.z.wo` and `.clients.pc` on `.z.wc`;
4. when `enabled` and not `opencloseonly`, wraps `.z.pg`, `.z.ps` and `.z.ws` directly (not through
   `di.torq.handlers`) with `{.clients.hit[@[x;y;.clients.hite]]}` around the current handler.
   An unset `.z.pg`/`.z.ps` is taken as `value`, and an unset `.z.ws` as an echo.

Call `init` once: a second call wraps the query handlers again. An exec owner registered on those
events through `di.torq.handlers` afterwards replaces the wrap.

## Behaviour to know

- `hits`, `errs` and `sz` count async (`.z.ps`) and websocket (`.z.ws`) messages too, including the
  bytes of results that are never sent back.
- A closed row keeps its key with `w` set to null, so several closed rows share a null key.
- A handle closed by the `MAXIDLE` sweep still has a null `endp`, so the same sweep drops its row
  instead of marking it.
- `.clients.unregistered[]` reads a `CLIENTS` table that doesn't exist, and fails.
- `hits` and `errs` are ints.

## Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.clienttracking
```

`test.q`/`test.csv` start four server peers (defaults, `opencloseonly`, disabled, and `INTRUSIVE`
with a one-second `MAXIDLE` and `RETAIN`) and connect to them. The tests cover the table and
defaults, connection rows, hits, bytes and errors, closing and `addw`, websocket rows, both
settings modes, the `INTRUSIVE` reply, idle closing and the `RETAIN` purge.
