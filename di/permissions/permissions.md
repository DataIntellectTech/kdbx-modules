# di.permissions

Role-based access control and authentication for a KDB-X process. It owns the `exec` phase of every
message-handling `.z.*` event via the injected `di.handlers` dependency, permission-checks each
incoming query against a user's roles and groups, and optionally enforces a whole-process read-only
mode.

Consolidates four TorQ files: `code/handlers/permissions.q` (`.pm`), `writeaccess.q` (`.readonly`),
`ldap.q` (`.ldap`), and `code/common/execas.q`. TorQ's `controlaccess.q` tiered engine is **deferred** -
see [Engine scope](#engine-scope).

---

## Features

- **Users, groups and roles.** Roles grant the right to call *functions* (gated by a paramcheck
  lambda); groups grant read/write access to *tables and variables*. Group membership is transitive -
  a group may itself be a member of another group.
- **Query interception.** Select/update/delete, bare variable references, named function calls,
  `.q`-keyword calls (including joins, whose table arguments are checked recursively) and lambda
  expressions are each classified and checked appropriately. A select is checked on its **where, by
  and columns clauses as well as its target table**, using the same predicate as a bare reference -
  see [Clause checking](#clause-checking).
- **Virtual tables.** A named view of a table with an implicit where-clause spliced into any select
  against it, so a group can be granted a filtered slice rather than the whole table.
- **Pluggable authentication.** `local` (md5 hash) and `ldap` backends, selected per user by the
  `authtype` on their user row.
- **Read-only mode.** A runtime flag that routes evaluation through `reval` instead of `eval`.
- **Result size cap.** Serialized results larger than `maxsize` are refused.
- **Anonymous access.** Optional auto-provisioning of public users, torn down on disconnect.

---

## Dependencies

| Dependency | Key | Required | Description |
|---|---|---|---|
| logger | `` `log `` | yes | dict with `info`, `warn`, `error`, each binary `{[c;m]}` - symbol context, string message |
| handlers | `` `handlers `` | yes | dict with `register` and `remove` - see `di.handlers`. A full `di.handlers` dict (which also carries `list`) is fine; only the two keys this module calls are required |
| ldap bind | `` `ldapbind `` | **no** | `{[session;dict]}` returning a dict with a `` `ReturnCode `` key (`0i` = success). Replaces the native LDAP library entirely when supplied - see [LDAP coverage](#ldap-coverage) |

**No hard dependencies on other `di.*` modules** - `deps.q` is empty and the module is standalone.

Both dependencies are **required and never defaulted**; `init` throws immediately if either is absent,
malformed, or missing keys. There is no fallback logger. That matters more here than elsewhere: legacy
`permissions.q` logs nothing at all, so every rejected login and denied query is currently silent, and
a silent fallback would make that silence look deliberate.

> **Note on `di.api`.** TorQ's `lamq` enumerated every variable in every root namespace via
> `.api.varnames`/`.api.allns`, then intersected that list with the tokens in the query. `di.api` is
> registry-only and does not expose those functions, by design - module code lives in each module's
> private `.z.m`, so a root-namespace scan would find nothing useful.
>
> This module does **not** reimplement that walk. It inverts the algorithm: tokenise the query first,
> then test only those tokens for being defined root variables. Same result, but O(tokens) rather than
> O(all names) - measured at 0.065 ms per lambda query against 2.9 ms for the walk on a process with
> 5000 root names.

---

## Initialisation

```q
perms:use`di.permissions
handlers:use`di.handlers

logdep:`info`warn`error!(
  {[c;m] -1 string[c],": INFO  ",m;};
  {[c;m] -1 string[c],": WARN  ",m;};
  {[c;m] -2 string[c],": ERROR ",m;});

handlers.init[enlist[`log]!enlist logdep];
handlersdep:`register`remove`list!(handlers.register;handlers.remove;handlers.list);

perms.init[(`log`handlers!(logdep;handlersdep)),`enabled`readonly!(1b;0b)];
```

`init` takes a **single dictionary** carrying both the dependencies and the configuration, the same
call shape every `di.*` module takes. Dependency keys (`` `log ``, `` `handlers ``, `` `ldapbind ``)
and configuration keys share one flat namespace; no configuration key collides with a dependency key,
and the dependency keys are stripped before the configuration is stored, so they never appear in
`status[]` or trigger the unrecognised-key warning.

> **Watch the join.** `` enlist[`k]!enlist somedict `` puts a *table* on the value side (a one-element
> list of dictionaries is a table), so joining two of them throws `` 'mismatch ``. Join `di.log`'s
> `logdict` with **one** multi-key dictionary rather than chaining single-key ones:
> ```q
> perms.init[logging.logdict,`handlers`enabled`readonly!(handlersdep;1b;0b)]   / works
> perms.init[logging.logdict,(enlist[`handlers]!enlist handlersdep),...]       / 'mismatch
> ```

`init` must be called before any other function. It is **idempotent**: a second call re-wires the
dependencies and config and reclaims the same handler registrations, leaving grant data intact.

When `enabled` is `0b` (the default) `init` wires the logger, logs that it is disabled, and stops - no
handlers are registered and nothing is published at root.

---

## Configuration

| Key | Default | Description |
|---|---|---|
| `enabled` | `0b` | master switch; when off, nothing is registered or published |
| `engine` | `` `rbac `` | authorization engine. Only `rbac` is implemented - `` `tiered `` is rejected |
| `maxsize` | `200000000` | maximum serialized size of any returned result |
| `runmode` | `1b` | `1b` executes the query, `0b` returns a boolean verdict only |
| `permissivemode` | `0b` | when `1b`, an object with no grants at all is readable by default |
| `readonly` | `0b` | route evaluation through `reval`, blocking writes |
| `public` | `0b` | allow anonymous users to be auto-provisioned on login |
| `ignorelist` | `()` | message heads that bypass the check on `.z.ps` - see below |
| `grantdirs` | `()` | directories holding grant files, loaded by `loadpermissions` |
| `proctype` | `` ` `` | process type, selects `{proctype}.q` in the grant cascade |
| `procname` | `` ` `` | process name, selects `{procname}.q` in the grant cascade |
| `publishroot` | `1b` | expose the legacy `.pm.*` names at root. Set `0b` if you have no legacy grant files - the module still enforces, it just leaves the root namespace untouched |
| `ldapenabled` | `0b` | enable the LDAP backend and load its native library |
| `ldaplibpath` | `""` | path to the LDAP `.so`; falls back to `$KDBLIB` |
| `ldapdebug` | `0b` | log LDAP chatter at info level |
| `ldapservers` | `` enlist `$"ldap://localhost:0" `` | LDAP server URIs |
| `ldapversion` | `3` | LDAP protocol version |
| `ldapblocktime` | `0D00:30:00` | how long a locked-out user stays locked out; null means forever |
| `ldapchecklimit` | `3` | failed attempts before lockout |
| `ldapchecktime` | `0D00:05` | window in which a repeat login skips the server |
| `ldapbuilddnsuf` | `""` | suffix used when building the bind DN |
| `ldapbuilddn` | `{"uid=",string[x],",",...}` | function building the bind DN from a username |

Unrecognised keys are **warned about**, not silently dropped. Every key is uniquely named so it
survives `di.config`'s flat cascade - note the `ldap*` prefixes, which exist because legacy ships four
separate `enabled` settings that would otherwise collapse onto one another.

> **NB Breaking config change: `ldapdebug` is now a boolean.** It was an int (`0i`); it is now `0b`.
> `init` type-checks every setting whose shape is fixed, so a caller passing `ldapdebug:1i` **will now
> fail `init`** with `config key(s) ldapdebug must be a boolean (1b or 0b)`. The value was only ever
> read as an on/off flag (`if[.z.m.config`ldapdebug;...]` in `ldap.debuglog`) - nothing graded it as a
> level - so the int type was a lie the validator now refuses. Set `ldapdebug:1b` instead.

### `ignorelist` defaults to empty, unlike TorQ

TorQ's `zpsignore.q` ships **enabled** with `` (`upd;"upd";`.u.upd;".u.upd") ``, exempting those from
permission checks on `.z.ps`. Silently exempting `upd` is not a safe default for an access-control
module, so this ships empty. **A process that receives `.u.upd`-shaped feed traffic must set it
explicitly**, or that traffic will be permission-checked and rejected:

```q
perms.init[deps,`enabled`ignorelist!(1b;(`upd;"upd";`.u.upd;".u.upd"))]
```

It is a **mixed** list - the head of an incoming message is matched against both symbol and string
forms. It applies to `.z.ps` only, matching TorQ; `.z.pg` is never exempted.

---

## Exported functions

### `init[deps]`
Wire dependencies, resolve config, and (when enabled) publish root names, load grants and register
handlers. Idempotent - see [Initialisation](#initialisation) for the full worked example.
```q
perms.init[(`log`handlers!(logdep;handlersdep)),`enabled`readonly!(1b;0b)]
/ or with defaults only (module loads but stays disabled):
perms.init[`log`handlers!(logdep;handlersdep)]
```

### `teardown[]`
Release everything `init` installed: handler registrations, `.h.val`, and the published `.pm.*` root
names. Grant data survives, so a later `init` re-registers and re-publishes cleanly.
```q
count (key `.pm) except `   / 8   - the published root names
perms.teardown[]
count (key `.pm) except `   / 0   - all removed
perms.status[][`enabled]    / 0b  - and the module reports itself disabled
```

### `allowed[user;query]`
Would this user be permitted to run this query? Never executes it.
```q
perms.allowed[`alice;"select from trade"]    / 1b - alices group is granted read on trade
perms.allowed[`alice;"select from secret"]   / 0b - no grant, and nothing was executed
```

> **`allowed` is a true predicate.** It returns a boolean and never executes the query. Three earlier
> caveats have been fixed: it now descends into `.q`-keyword joins (so it agrees with `requ` rather
> than permitting joins `requ` refuses), a forbidden lambda expression returns `0b` instead of raising,
> and it honours `permissivemode` rather than pinning it off as TorQ does (`allowed:mainexpr[;;0b;0b]`),
> so it no longer denies things `requ` permits.

### `requ[user;query]`
Permission-check a query as a user and execute it. Passes the query through untouched when the module
is disabled. This is the authority - `allowed` is the dry run.
```q
perms.requ[`alice;"select from trade"]
/ sym px
/ ---------
/ a   1
/ a   2
/ b   3

perms.requ[`alice;"select from secret"]
/ 'di.permissions: query: no read permission on [secret]
```

### `val[expr]` / `valp[expr]`
Evaluate a parse tree / a string or parse tree, under `reval` when read-only mode is on. TorQ binds
these at **load** time (`val:$[readonly;reval;eval]`), so read-only could not be toggled without a
restart; here the choice resolves per call.
```q
perms.valp "2+2"        / 4
perms.val parse "2+2"   / 4
```
Both are used by `di.gateway`, which copies the function value; neither performs a permission check on
its own - that is `requ`'s job.

### `execas[query;user]`
Run a query as another user, subject to that user's permissions.
```q
perms.execas["select from trade";`alice]
/ sym px
/ ---------
/ a   1
/ a   2
/ b   3

perms.execas["select from secret";`alice]
/ 'di.permissions: query: no read permission on [secret]
```

### `admin`
The grant-administration sub-API. `admin.wildcard` is the wildcard object (`` `$"*" ``) - grant against
it for superuser rights.

| Group | Functions |
|---|---|
| users | `adduser` `removeuser` `cloneuser` |
| groups | `addgroup` `removegroup` `addtogroup` `removefromgroup` |
| roles | `addrole` `removerole` `assignrole` `unassignrole` |
| functions | `addfunction` `removefunction` `grantfunction` `revokefunction` |
| tables | `grantaccess` `revokeaccess` |
| virtual tables | `createvirtualtable` `removevirtualtable` |
| anonymous | `addpublic` `removepublic` |

```q
perms.admin.addrole[`reader;"may select"];
perms.admin.grantfunction[`select;`reader;{1b}];
perms.admin.addgroup[`traders;"trading desk"];
perms.admin.grantaccess[`trade;`traders;`read];
perms.admin.adduser[`alice;`local;`md5;md5 "secret"];
perms.admin.assignrole[`alice;`reader];
perms.admin.addtogroup[`alice;`traders];

perms.admin.wildcard                              / `*  - the wildcard object
perms.admin.grantfunction[perms.admin.wildcard;`admin;{1b}];   / superuser: any function
```

> **Paramchecks must be functions.** They are applied to the call's parameter dict under protection,
> and any non-boolean result is coerced to `0b` - so a literal `1b` stored as a paramcheck **fails
> closed**. `grantfunction` rejects a non-function outright.

### `loadpermissions[]`
Load the grant cascade - `default` -> `proctype` -> `procname` - from every configured `grantdirs`
directory. Missing files are skipped with an info log. Called automatically by `init`; call it again to
reload after editing a grant file.
```q
perms.loadpermissions[]
/ with no grantdirs configured this logs "nothing to load" and returns
```

### `unblock[user]`
Clear a user's cached LDAP state - both a lockout and any cached successful authentication.
```q
perms.unblock[`alice]
/ a user with no LDAP record logs "no ldap login record for user alice" and returns
```

> TorQ's equivalent returns early unless the user is actually *blocked*, which leaves no way to force
> re-authentication for a user who is merely cached: after a password change their cached success
> stands until `ldapchecktime` elapses. This clears `success` too, so the next login always reaches
> the server.

### `status[]`
What the module is currently enforcing: engine, read-only state, permissive mode, run mode, maxsize,
public access, and LDAP availability. Legacy has no equivalent introspection.
```q
perms.status[]
/ enabled       | 1b
/ engine        | `rbac
/ readonly      | 0b
/ permissivemode| 0b
/ runmode       | 1b
/ maxsize       | 200000000
/ public        | 0b
/ publishroot   | 1b
/ ldapenabled   | 0b
/ ldapavailable | 0b
```
`ldapavailable` reports whether a bind is actually reachable - the native library having loaded, or an
`ldapbind` having been injected - not merely that `ldapenabled` is set.

### `version`
The module version string.
```q
perms.version   / "0.1.0"
```

Read at load time from the **`VERSION` file** in the module directory (`version:first read0`:::VERSION`
in `init.q`) rather than being hardcoded as a q literal, so a release bump touches one plain-text file.
This follows the TorqX module convention.

`version` remains in the **export dictionary**. `di.depcheck` resolves a dependency's version from its
export dict (`checkdepversion`) and reports `"... exports no version"` - failing the dependency check -
if a module omits it. Moving the *value* to a file does not move the *export*.

### `getapimeta[]`
This module's api metadata - one `` `name`public`descrip`params`return `` row per callable export, for
`di.torq` to collect and register with `di.api`. `init` and `getapimeta` are deliberately absent: they
are framework plumbing `di.torq` calls by convention rather than discovers. Needs no `init`.
```q
cols perms.getapimeta[]    / `name`public`descrip`params`return
count perms.getapimeta[]   / 33 - 11 top-level exports plus the 22 admin.* members

3 sublist select name,public,descrip from perms.getapimeta[]
/ name     public descrip
/ ---------------------------------------------------------------------
/ teardown 1b     "release handler registrations, .h.val and the publi..
/ version  1b     "module version string"
/ status   1b     "what this module is currently enforcing - engine, r..
```
The `admin.*` members carry `public:0b` - they are real callables registered in `di.api`'s full view
but kept out of the public summary, which lists `admin` itself.

---

## Input validation

Every public entry point validates its arguments and reports failures the same way as everything else
- prefixed `di.permissions:`, naming the offending argument and the expected type, and logged at
`error` before being signalled:

```q
perms.allowed["alice";"1+1"]
/ 'di.permissions: allowed: user must be a symbol, got 10h
perms.admin.grantaccess[`t;`g;`sideways]
/ 'di.permissions: grantaccess: level must be `read or `write, got `sideways
```

This matters because the alternative is a raw `'type` or `'length` thrown from a downstream `upsert` -
unprefixed, unlogged, and giving no indication which argument was wrong. **Malformed client queries
are covered too**: an unparseable string yields
`di.permissions: mainexpr: could not parse query: ...` rather than q's bare parse error, so a client
probing with garbage still leaves an audit trail.

"Every" is enforced rather than asserted: the suite drives one wrong-typed call at **each** admin
entry point and requires all of them to raise a `di.permissions:`-prefixed error, so an admin function
added later cannot quietly skip validation. It also checks that the rejection reached the injected
logger, not merely that it was thrown.

---

## Clause checking

TorQ permission-checks a select on its **target table only** (`permissions.q`'s `query` inspects
nothing but `first q[1]`). A select's where, by and columns clauses can name *other* tables, and those
executed unchecked - so a user granted any single table could read any other:

```q
/ alice is granted `open and has NO grant on `secret
select p:first secret`pin from open     / TorQ: returns 1234. here: refused
select p:count secret from open         / TorQ: returns the row count. here: refused
select from open where id in exec id from secret   / TorQ: executes. here: refused
```

This module checks every readable object named anywhere in the where, by and columns clauses, and
refuses the query unless the user has read access to each. `allowed` applies the same check, so it
agrees with `requ` rather than permitting a query `requ` would refuse.

**The predicate is `rbac.isdefinedvar` - the same one a bare reference and a lambda expression use.**
That is the point: all three paths agree on what counts as a readable object, so an object cannot be
readable through a select clause while a bare reference to it is refused. An earlier revision checked
only *table*-valued symbols, which left exactly that inconsistency:

```q
.pt.secretvec                                  / refused
select p:first .pt.secretvec from .pt.trade    / returned its contents
```

**The target table's own column names are removed first.** Inside a select, a symbol matching a column
denotes that column, not a same-named global - so checking it would deny ordinary queries. Without the
exclusion, `select id,v from open` is refused on any process that also happens to define globals `id`
or `v`; with it, that query is clean and an ungranted global of a colliding name still cannot be read
(the suite asserts both, via a `zz` column and a `zz` root global).

## Handler registration

| Event | Phase | Behaviour |
|---|---|---|
| `.z.pw` | `exec` | authenticate; dispatches on the user's `authtype` |
| `.z.pg` | `exec` | permission check, read-only selection, maxsize |
| `.z.ps` | `exec` | as `.z.pg`, plus the ignore-list bypass |
| `.z.pi` | `exec` | console input, console-formatted results |
| `.z.pp` | `exec` | HTTP POST refused outright |
| `.z.ws` | `exec` | websocket messages refused outright |
| `.z.pc` | `` ` `` | simple observer - anonymous user cleanup |
| `.h.val` | - | assigned directly; **not** a `.z.*` event |

All registrations use the stable name `` `di.permissions ``, so re-init reclaims rather than collides.

**`.z.ph` is deliberately not claimed.** HTTP GET permissioning happens via `.h.val` on kdb+ 3.5+,
which is what `permissions.q` itself does; claiming `.z.ph`'s `exec` would replace KDB-X's built-in
HTTP handler wholesale, including its response formatting.

`exec` ownership is not a preference. `di.handlers` rejects a `pre`/`post` registration when no `exec`
owner exists, and on a bare process nothing owns `.z.pg` - so a `pre`-only design cannot register at
all. It is also the only way to reproduce the three structurally different composition idioms legacy
used on `.z.pw` alone (flat replace, gate-and-call-through, AND-compose) within a single-owner model.

---

## Root-name publication

`use` mangles module code into a private namespace, so anything an evaluated config file must reach
has to be published at a real root name - the convention TorqX applies for `.gw.*`, `.u.upd` and
`.hdb.reload`.

Legacy grant files (`config/permissions/*.q`) are **executable q** calling `.pm.addrole`,
`.pm.grantfunction`, `.pm.ALL` and so on at root. `init` therefore publishes eight names - the seven
grant-script functions plus `ALL` - under `.pm`, so a legacy grant file loads unmodified:

```
.pm.ALL  .pm.adduser  .pm.addgroup  .pm.addrole
.pm.addtogroup  .pm.assignrole  .pm.grantaccess  .pm.grantfunction
```

Published **permanently during `init`**, but **only when `enabled`**, and removed by `teardown`.

> This last point diverges from TorQ, which defines `.pm.*` regardless of `enabled`. It is safe
> because `gateway.q` guards on existence (`` `.pm.valp ~ key `.pm.valp ``) and falls back cleanly, and
> it is better: a disabled permissions module should not advertise admin functions that gate nothing.

The query API (`requ`, `allowed`, `val`, `valp`, `execas`) is **not** published at root - `di.gateway`
holds a module handle and calls it in-process.

---

## Engine scope

TorQ ships two independent authorization systems. Only `permissions.q`'s **RBAC** engine is ported.
`controlaccess.q`'s tiered model (superuser/poweruser/defaultuser, host allowlisting, per-user token
lists) is deferred, and `` engine:`tiered `` is rejected with a clear message.

The evidence: **nothing outside `controlaccess.q` references `.access.*` anywhere in TorQ**, against
`.pm`'s three real external callers (`gateway.q`, `execas.q`, `apidetails.q`). Both engines ship
disabled. The `engine` config key exists from v1 so the tiered engine can land later without reshaping
this schema.

---

## Usage Example

```q
/ log dep must already match the binary {[c;m]} contract - write your own, or use di.log:
/   logging:use`di.log
/   logdep:logging.logdict
logdep:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})

/ di.handlers is INJECTED, not imported - build its dep dict and hand it over
perms:use`di.permissions
handlers:use`di.handlers
handlers.init[enlist[`log]!enlist logdep];
handlersdep:`register`remove`list!(handlers.register;handlers.remove;handlers.list);

perms.init[(`log`handlers!(logdep;handlersdep)),enlist[`enabled]!enlist 1b];

/ set up a reader who may select from trade and nothing else
trade:([]sym:`a`a`b;px:1 2 3.0);
secret:([]pin:1234 5678);
perms.admin.addrole[`reader;"may select"];
perms.admin.grantfunction[`select;`reader;{1b}];
perms.admin.addgroup[`traders;"trading desk"];
perms.admin.grantaccess[`trade;`traders;`read];
perms.admin.adduser[`alice;`local;`md5;md5 "secret"];
perms.admin.assignrole[`alice;`reader];
perms.admin.addtogroup[`alice;`traders];

/ dry run - allowed never throws, it returns a verdict
perms.allowed[`alice;"select from trade"]    / 1b
perms.allowed[`alice;"select from secret"]   / 0b

/ execute - requ returns the result, or RAISES on a refusal
perms.requ[`alice;"select from trade"]       / the three rows
/ perms.requ[`alice;"select from secret"]    / 'di.permissions: query: no read permission on [secret]
/   ^ left commented out: a refusal raises, which would stop this block. catch it if you want to run it:
@[perms.requ[`alice;];"select from secret";{[e] -1 "refused: ",e;}];

/ what is being enforced right now
perms.status[]

/ release everything on the way out
perms.teardown[];
```

From here a real process would load its grants from files rather than by hand - set `grantdirs` and
let `init` run the `default` -> `proctype` -> `procname` cascade. See
[Root-name publication](#root-name-publication) for why an unmodified TorQ grant file works unchanged.

---

## Running tests

> **Note on suite structure.** Rows share accumulated state (users, groups and grants created by
> earlier rows), so an individual assertion cannot be run in isolation and an early failure cascades -
> a property of the k4unit CSV format rather than a choice here. When debugging, read upward from the
> first failing row, not just the row itself.
>
> The suite **is** verified re-runnable: calling `moduletest` twice in one session passes both times.
> That was not true initially - grant data and LDAP cache state surviving `teardown` broke ten
> assertions on a second run, which is what surfaced the `unblock` gap documented above.

**Unit suite** (`test.csv`) - no sockets and no native library required. Run it for the current row
and assertion counts rather than trusting a figure quoted here:
```q
k4unit:use`di.k4unit
k4unit.moduletest`di.permissions
```

### LDAP coverage

`deps` accepts an **optional `ldapbind`** - a function `{[session;dict]}` returning a dict with a
`` `ReturnCode `` key. When supplied it replaces the native library outright, and the `.so` is never
resolved. This exists so the caching and lockout logic can be exercised without a directory server:

```q
fakebind:{[sess;d] enlist[`ReturnCode]!enlist 0i}      / 0i = success, anything else = failure
perms.init[(`log`handlers`ldapbind!(logdep;handlersdep;fakebind)),`enabled`ldapenabled!(1b;1b)]
```

This is a **`deps` injection, not a config value** - deps are process wiring code the module already
trusts completely (the injected `log` and `handlers` could subvert it just as thoroughly), so it adds
no trust boundary that did not already exist. Operator-editable settings files cannot reach it.

Now covered by the suite: a successful bind; the skip-the-server path (a repeat login inside
`ldapchecktime` with the same password does **not** reach the server, verified by counting calls); a
different password going back to the server; failed attempts accumulating to `ldapchecklimit` and
locking the user out; a locked-out user being refused **without** reaching the server; `unblock`
clearing a lockout; `ldapblocktime` expiry releasing one without an explicit unblock; and a bind that
throws failing closed rather than propagating.

The bind's **return shape is validated**: it must be a dictionary containing a `` `ReturnCode `` key.
This is a safety check, not tidiness - `result[\`ReturnCode]` on an integer is *handle apply* in q, so
a bind mistakenly returning `42` would attempt an IPC write to file descriptor 42. Anything of the
wrong shape now fails closed with a clear message.

> **NB Security note on the cache.** After a successful bind, a repeat login by the same user with the
> same password inside `ldapchecktime` (default 5 minutes) is served **from the cache without
> contacting the server**. That is TorQ's behaviour and it is deliberate - it exists to spare the
> directory server load - but it means **revoking an account server-side is not effective until the
> window elapses**. Set `ldapchecktime` to `0D00:00` to disable the optimisation and force every login
> to the server.

**The native path has since been verified against a real `kdbldap.so`** found on this machine: all
four symbols bind at the arities this module uses (`kdbldap_init`/2, `kdbldap_set_option`/3,
`kdbldap_bind_s`/4, `kdbldap_err2string`/1), `initialise` opens a session, a real `kdbldap_bind_s`
executes, and its failure is decoded by the native `err2string` into
`"Can't contact LDAP server"`. The lockout bookkeeping was driven by those genuine failures - three
attempts, then lockout, then refusal without contacting the server.

Still not covered, and genuinely needing a live directory: a **successful** bind, and
directory-specific behaviour such as referrals or TLS negotiation.

**Integration suite** (`test_integration.csv`) - stands up a real child q process on an OS-assigned
port and drives a real connection. It exists because **`reval`'s read-only restriction is not applied
when `.z.w=0`**: at the console `reval parse "g::1"` happily sets `g`, but over a real handle the same
call throws `'noupdate`. k4unit runs in-process at handle 0, so a unit test asserting a blocked write
would fail against correct code.

> **NB The invocation below is a workaround, not the supported interface.** `di.k4unit.moduletest`
> hardcodes the filename `test.csv` (`di/k4unit/init.q:9`) and its `KUltf`/`KUrt` primitives are not
> exported, so there is **no supported way to run a second suite in a module**. The lines below reach
> into `di.k4unit`'s private, loader-mangled namespace and will break if that mangling changes.
> **Upstream ask: a `moduletest[module;filename]` overload on `di.k4unit`**, after which this reduces
> to ``k4unit.moduletest[`di.permissions;`test_integration.csv]``.

```q
k4unit:use`di.k4unit
.m.di.0k4unit.KUltf .Q.dd[hsym`$.Q.m.mp`di.permissions;`test_integration.csv]
.m.di.0k4unit.KUrt[]
k4unit.getresults[]
```
Run it in a fresh session - running it after `moduletest` re-runs the still-loaded unit tests against
dirty module state.

> **What this suite does and does not prove.** It verifies read-only enforcement and parse-tree
> handling over a **real child process and a real IPC handle** - the things that cannot be tested
> in-process, because `reval` does not enforce at `.z.w=0`.
>
> It wires the **real `di.handlers`**, which ships alongside this module on the same branch, so it
> does exercise real phase and `exec`-ownership dispatch - not a stand-in. A minimal inline stand-in
> (a bare `set[ev;f]`) exists only as a fallback for a `QPATH` that lacks `di.handlers`.
>
> Which path ran is **asserted, not assumed**: the suite requires the child to report
> `realhandlers` as `1b`, so a silent fall-through to the stand-in **fails** the suite rather than
> passing quietly. That assertion exists because the "prefer real `di.handlers`" branch was silently
> dead for weeks - `h.init` on a function-local throws `'h.init` (module dot-sugar resolves only
> against a *global* name), and the protected apply swallowed it, so the stand-in always ran while
> the suite reported green. If you run this on a `QPATH` without `di.handlers`, expect that one row
> to fail; that is the point of it.

---

## Migrating from `.pm` / `.access`

- `.pm.allowed`, `.pm.requ`, `.pm.val`, `.pm.valp`, `.pm.execas` -> call through the module handle.
  `val`/`valp` keep the same *shape* (unary functions), so a consumer that copies the function value
  is unaffected; only the read-only decision moved from load time to call time.
- `.pm.cando` is **dropped** - it had no callers anywhere and differed from `allowed` only by parsing
  first, which `allowed` now does itself.
- Grant scripts need **no change** - the names they call are republished at root.
- `.access.*` has no equivalent; see [Engine scope](#engine-scope).
- The `-public` command-line flag is replaced by the `public` config key.
- **Rejection messages changed prefix.** TorQ emits `"pm: no read permission on [x]"`; this module
  emits `"di.permissions: <context>: no read permission on [x]"`. Any log scraping or alerting that
  greps for `pm:` needs updating - the new prefix does not contain it.
- **`.pm.*` at root is a compatibility shim, not the API.** The eight published names exist so legacy
  grant files load unmodified. New code should hold a module handle and call `perms.admin.*`; the root
  namespace looks like legacy TorQ but is a strict subset of it.

---

## Notes

- `init` must be called before any other function; every other export checks and errors clearly.
- All errors raised after `init` are logged at `error` before being signalled.
- Console input (`.z.pi`) routes through the same permission check as a network query - being local is
  not an exemption. The `.z.w=0` bypass inside the query path is what keeps the console usable.
- `.z.pp` and `.z.ws` are refused outright rather than permission-checked, matching TorQ.
- Group membership is chased to a fixed point for *authorization* checks, so nested groups work.
- **Public-user detection deliberately does not do that.** It keeps TorQ's first-row lookup
  (`` `public~(1!usergroup)[u]`groupname ``), which is correct by construction - an anonymous user is
  provisioned into exactly one group. Generalising it to a full membership check would be a privilege
  change rather than a fix: a real user who is in `public` alongside other groups would then be
  rejected when presenting a valid password, or, with an empty password, have their user row upserted
  over and their role demoted to `publicuser`. The narrower check is the safer contract.
- LDAP is entirely optional: with `ldapenabled:0b` (the default, matching TorQ's shipped settings) the
  native library is never resolved and the whole test suite runs with no `.so` present.
- **Config values are type-checked at `init`.** A mistyped setting (`maxsize:"big"`, `readonly:"yes"`,
  a non-timespan `ldapblocktime`) is rejected immediately, naming every offending key, rather than
  surfacing later as a confusing runtime error far from its cause.
- **A failed `init` installs nothing.** The one step that depends on external state - resolving the
  LDAP native library - runs before anything is published or registered, so a missing `.so` leaves the
  process untouched rather than half-configured.
- **A grant made against a virtual table's *name* survives `removevirtualtable`.** The two are
  independent objects, so `allowed` will still permit the name until the grant is revoked separately;
  execution then fails because the name no longer resolves. Revoke the grant as well as removing the
  view.
- `grantdirs` accepts a single directory as a bare string or a list of directories. `ignorelist` is a
  mixed list, matching how message heads arrive.
