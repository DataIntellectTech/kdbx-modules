# di.permissions

TorQ's `.pm` (`code/handlers/permissions.q`) as a kdb-x module: client access control by
**user**, **group** (variable access) and **role** (function execution), with **virtual tables**
enforcing a where clause on a real table. The module owns the `exec` phase of every message
handler, so it decides whether an incoming request is evaluated at all.

Ported line for line. The one deliberate difference from TorQ is noted under
[Differences from TorQ](#differences-from-torq); the known weakness it inherits is under
[The lambda path](#the-lambda-path).

---

## The `.pm` namespace

The admin API and query entry points are **exported**, so callers reach them through `use`:

```q
pm:use`di.permissions;
pm[`addrole][`reader;"read only"];
```

Only the **four** names `di.torq.proc.gateway` reads by symbol are published at root:

| Root name | Read by |
|---|---|
| `.pm.allowed` | the gateway, before dispatching a query |
| `.pm.val` / `.pm.valp` | the gateway, to pick `eval`/`value` or their `reval` forms |
| `.pm.execas` | a **backend**, which the gateway sends `(`.pm.execas;query;user)` so the query is re-checked as the original user |

Those four are published on every `init`, **whether or not permissions are enabled** — the
gateway tests for them, and TorQ's `\d .pm` defines them unconditionally. Nothing else goes
into a root namespace; `test.csv` asserts `.pm` holds exactly those four.

> **Migrating TorQ permissions files.** TorQ's rule files call `.pm.addrole[...]` at root. Here
> the admin API is exported, so each call becomes `pm[`addrole][...]` after a
> `pm:use`di.permissions`. Mechanical, but it is a required rewrite — the files do not port
> verbatim. This is a deliberate trade for keeping the module out of a root namespace, in line
> with the KX module guidance.

---

## init and config

```q
pm:use`di.permissions;
logging:use`di.util.log;
pm[`init][config;`log`handlers!(logging.logdict;handlers.handlerdict)];
```

`di.torq` calls this for you behind a `[permissions]` settings section.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `0b` | register the handlers. When false, nothing is checked and no handler is bound |
| `maxsize` | `200000000` | maximum serialised size of any returned result |
| `runmode` | `1b` | `1b` check **and** evaluate; `0b` return the boolean only |
| `permissivemode` | `0b` | allow variables absent from the `access` table |
| `readonly` | `0b` | evaluate with `reval` instead of `eval` (TorQ's `writeaccess.q`) |
| `public` | `0b` | allow anonymous users with an empty password (TorQ's `-public` flag) |

`deps` keys:

| Key | Required | Description |
|---|---|---|
| `log` | yes | `` `info`warn`error `` dict of `{[ctx;msg]}`. Used for **one line at init only** — see [Logging](#logging) |
| `handlers` | yes | `di.torq.handlers` contract; the module registers as the `exec` owner |

`init` is idempotent: config and the root names are refreshed on every call, and the handler
registration is guarded by a `registered` flag.

---

## Handlers

| Event | Phase | Function | Behaviour |
|---|---|---|---|
| `.z.pg` | `exec` | `req` | sync query — checked |
| `.z.ps` | `exec` | `req` | async message — checked |
| `.z.pi` | `exec` | `consoleinput` | console — checked, empty lines excepted |
| `.z.pp` | `exec` | — | HTTP POST refused outright |
| `.z.ws` | `exec` | — | websocket access refused outright |
| `.z.pw` | `exec` | `login` | authentication |
| `.z.pc` | simple | `droppublic` | drop a public user on disconnect |

HTTP GET is **permission checked, not refused**: from KDB+ 3.5 `.z.ph` evaluates through
`.h.val`, so `init` sets `.h.val:req`, exactly as TorQ does on a modern kdb.

A local call (`.z.w=0`) is never checked, as in TorQ.

> `di.torq` binds `zpsignore` after this module, so heads in its ignore list (`upd`, `.u.upd`)
> bypass the dispatcher and are **not** permission checked. That is TorQ's intent — see the
> comment at the top of TorQ's `zpsignore.q`.

---

## Schema

Ten control tables, as TorQ's:

| Table | Contents |
|---|---|
| `user` | username, authtype, hashtype, password hash |
| `groupinfo` / `roleinfo` | group / role name and description |
| `usergroup` | user → group. A **group may be listed as a user**, so groups nest |
| `userrole` | user → role |
| `functiongroup` | function → function group |
| `function` | object, role, and a `paramcheck` lambda returning a boolean |
| `access` | object, entity (group), level (`read`/`write`) |
| `virtualtable` | virtual name, real table, enforced where clause |
| `publictrack` | anonymous user → handle |

Read access and write access are **distinct** — granting `write` does not imply `read`.

---

## Admin API

All published at root. `ALL` (`` `$"*" ``) is the wildcard: a role granted `ALL` is a superuser.

`adduser` `removeuser` `addgroup` `removegroup` `addrole` `removerole` `addtogroup`
`removefromgroup` `assignrole` `unassignrole` `addfunction` `removefunction` `grantaccess`
`revokeaccess` `grantfunction` `revokefunction` `createvirtualtable` `removevirtualtable`
`addpublic` `removepublic` `cloneuser`

Signatures and descriptions for the nine that TorQ documents are in `getapimeta[]`, which
`di.torq` registers with `di.api`. Names there are bare, as `di.torq.servers`' `getapimeta`
does it — `di.torq` qualifies them.

Guards, as TorQ's: a user may not take an existing group's name (and vice versa), and
`addtogroup` / `assignrole` require the group / role to exist.

---

## Query entry points

| Name | Signature | Behaviour |
|---|---|---|
| `req` | `[query]` | the handler entry point. Local calls bypass the check |
| `requ` | `[user;query]` | check and run as a named user |
| `cando` | `[user;query]` | would this be permitted — `1b` when disabled |
| `allowed` | `[user;parsetree]` | check only, never evaluates. Also at root |
| `execas` | `[query;user]` | run as another user. Also at root |
| `val` / `valp` | | `eval`/`value`, or their `reval` forms under `readonly`. Root only |

**`allowed` deliberately ignores `runmode` and `permissivemode`** — it is
`mainexpr[;;0b;0b]`, as in TorQ. Only `requ`/`req` honour them.

---

## Rule files

Rules are executable q, because `grantfunction` takes a lambda. `di.torq` loads them additively
from two roots, mirroring TorQ's `$KDBCONFIG` / `$KDBAPPCONFIG` cascade:

```
$TORQXHOME/di/torq/permissions/{default,<proctype>,<procname>}.q
$TORQXAPPCONFIG/permissions/{default,<proctype>,<procname>}.q
```

Every file that exists is loaded, in that order, and each simply calls the admin API:

```q
/ $TORQXAPPCONFIG/permissions/default.q
pm:use`di.permissions;
pm[`addrole][`reader;"read only"];
pm[`addgroup][`readers;"can read trade"];
pm[`adduser][`bob;`local;`md5;md5"pass"];
pm[`assignrole][`bob;`reader];
pm[`addtogroup][`bob;`readers];
pm[`grantaccess][`trade;`readers;`read];
pm[`grantfunction][`select;`reader;{1b}];
```

`use` returns the same module instance `di.torq` initialised, so a rule file is just a caller.

The framework tier ships the `systemuser` grants that let TorqX processes call each other, so an
app only declares its own users. Because the files are loaded **after** `init` and **before** the
app's own code, a failure in a rule file leaves the process fully locked down rather than open.

---

## Logging

TorQ's permissions logs **nothing** — there is a `/ todo print log to TorQ?` where a failed login
is silently dropped. This module matches that: the `log` dependency produces **one line at
init** stating whether permissions are enabled, and nothing else. Refusals are not logged.

An audit trail of denied access would be a new feature and is deliberately not added. In
practice `di.querylog` wraps `.z.*` after this module, so when query logging is enabled it
records refused queries and their errors — TorQ's `.usage.usage` behaviour.

---

## The lambda path

`lamq` handles expressions containing a lambda. It scans the root namespaces for variable names,
intersects them with the tokens of the expression, and refuses the ones the user cannot read.

**A name the scan does not return is permitted, not refused.** The check is
`rqt:rt inter pq` — only recognised names are tested. The scan walks one level of root
namespaces, so a nested module-private path such as `.m.di.0serverselect.servers` is invisible to
it and a lambda referencing one is allowed through.

This is TorQ's behaviour and is preserved deliberately, so that a port is a port. `di.api`
does not expose the `varnames`/`allns` introspection TorQ uses here (module code does not live in
scannable root namespaces), so the module carries its own private equivalents.

Tightening this — failing closed on anything introspection cannot see — is a behaviour change and
belongs in its own change, with the migration impact assessed.

---

---

## List-form IPC messages and `eval`

A **received IPC list** carries literal arguments; a **parse tree** from `parse` carries symbols
as variable *references*. The two need different evaluation, and `qexe` uses `eval` for both:

```q
eval  (value;`.wdb.savedir)   / 'No such file or directory - resolves the symbol first
value (value;`.wdb.savedir)   / `:/some/path - correct for a received message
parse "value `.wdb.savedir"   / (.:;,`.wdb.savedir)  <- a parse tree ENLISTS the literal
```

`exe` discriminates by the head's type and so picks `value` for a symbol-headed call such as
`` (`.gw.reload;`reloadstart) ``. `qexe` — the path a `.q`-keyword expression takes — does not,
so a **function-headed** message whose arguments are symbols is mis-evaluated.

The case that bites is the idb reading the wdb. Both TorQ's `code/processes/idb.q` l.70 and
`di.torq.proc.idb` send:

```q
(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition`.wdb.writedownmode)
```

Under permissions this returns the wdb's partition dictionary for `savedir`, `'type` for the
partition date and `'default` for the writedown mode. Worse, no narrow grant can authorise it
either: the check falls back to `` `$string(first e) ``, and `.q.each` is a lambda, so that
yields `` `k){x'y} `` rather than `` `each ``.

**This is TorQ's behaviour and is deliberately preserved.** TorQ hits it too — its own `idb` user
holds only `systemuser`, so a permissioned wdb would refuse it; TorQ never meets the failure
because nobody enables permissions on a wdb that has an idb.

The supported workaround is the one TorQ itself uses for its gateway, with the candid comment
*"The gateway is made an administrator as it cannot properly permission without total access"*
(`config/permissions/default.q` l.111): **give the inter-process identity a superuser role.**
TorqX-POC does this for its `torqx` user and demonstrates least privilege with a separate
`trader` user instead.

Fixing it means making `qexe` discriminate as `exe` does, which is a behaviour change and
belongs in its own change with the migration impact assessed.

## Async refusals are silent

A refusal on `.z.ps` throws on the async handler, and an async caller has nobody to reply to — so
the client blocks on its deferred-sync read instead of seeing an error, and the process logs the
throw. Anything dispatched asynchronously therefore needs its entry point granted *before* the
request reaches the callee's own checks. TorQ's gateway sends a formatted reply on refusal for
exactly this reason.

## Differences from TorQ

| | TorQ | here |
|---|---|---|
| Handler binding | wraps the previous `.z.*` value by hand via `.dotz.set` | registers as the `exec` owner through `di.torq.handlers` |
| Admin API location | root `.pm.*`, called directly by rule files | exported; rule files call `pm[`x][...]` through `use` |
| `readonly` | read from `.readonly.enabled` (`writeaccess.q`) | a `readonly` config key |
| `public` users | `-public` command-line flag via `.Q.opt .z.x` | a `public` config key |
| Rule file roots | `$KDBCONFIG` + `$KDBAPPCONFIG` | `$TORQXHOME/di/torq` + `$TORQXAPPCONFIG` |
| `.api` introspection | `.api.varnames` / `.api.allns` | private equivalents (see above) |
| `xqu` | defined, never called, identical to `isq` | dropped |

Not ported: `controlaccess.q` (a separate, mutually exclusive csv-based model — TorQ's
`permissions.q` exits if it is active) and `writeaccess.q` as a whole (its read-only mode is the
`readonly` key here).

`auth` is a dictionary keyed by authtype, with `local` (md5) and `ldap`. The `ldap` method needs
legacy `.ldap` code loaded in the process; there is no `di.ldap`, so without it the method
returns `0b`, as TorQ's does.

---

## Testing

`test.csv` / `test.q` (k4unit), 54 checks with mock `log` and `handlers`: dependency validation,
handler registration in the right phases, root publication of exactly the four gateway names
(including when disabled, and that the admin API is **not** in a root namespace), the admin
API's name-clash and unknown-entity guards, read/write access discrimination, group nesting, a
virtual table's enforced where clause, authentication, `maxsize`, `permissivemode` (and that
`allowed` ignores it), and the disabled path.

```q
k4unit:use`di.k4unit;
k4unit[`moduletest]`di.permissions;
```
