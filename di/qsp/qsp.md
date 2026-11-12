# di.qsp — qSQL security policy, as a KDB-X module

Row- and column-level permissioning for q written by something you do not
trust: an LLM, a notebook, a reporting tool.

A query is **parsed, never evaluated**, and every node of its parse tree must be
explicitly permitted. The tree is then **rewritten** to pin the caller's row
filter and column projection before it runs. Anything qsp does not understand is
refused, so q syntax it has never seen fails closed.

```q
qsp:use`di.qsp

p:qsp.policy[]
p:qsp.table[p;`trade;::]                                     / read its meta
p:qsp.grant[p;`llm;`trade;`date`sym`size;enlist qsp.f.isin[`account;`A1`A2]]
p:qsp.member[p;`alice;`llm]

qsp.run[p;`alice;"select sum size by sym from trade"]        / A1/A2 rows only
qsp.run[p;`alice;"select pnl from trade"]                    / 'qsp: unknown or not-permitted column: pnl
qsp.explain[p;`alice;"select from trade"]                    / what would actually run

qsp.serve p                                                  / police every IPC query
```

A team setting up permissions keeps the policy as CSV files instead. They
edit it in a spreadsheet, review it in a pull request, and check it in CI.
**[setup.md](setup.md)** walks through it from an empty process.

More documentation is in [docs/](docs/README.md):
- **[docs/concepts.md](docs/concepts.md)**: what a policy is made of (users,
  groups, grants, filters, gateways) and how one user's access is worked out.
- **[docs/time.md](docs/time.md)**: embargoes, delayed data and the policy
  clock.
- **[docs/internals.md](docs/internals.md)**: for developers changing qsp.
  What every file does, and one query traced step by step through the code.

## Try it

[examples/equities/](examples/equities/README.md) builds a small equities
HDB, loads a filled-in policy for it, and walks through what each role can and
can't read:

```sh
q di/qsp/examples/equities/hdb.q            # walk through, then exit
q di/qsp/examples/equities/hdb.q -p 5100    # ...then serve it
```

Its [README](examples/equities/README.md) describes the roles, how to load the
policy in a process of your own, and the queries that surprise people, such as
`select[n]` on a partitioned table.

## Install

The module is the `di/qsp/` directory, laid out as in
[kdbx-modules](https://github.com/DataIntellectTech/kdbx-modules). Put the
directory holding `di/` on the module search path:

```sh
export QPATH=${QPATH}:/path/to/qsp-mod        # then: qsp:use`di.qsp
```

The submodules reference each other relatively, so the directory can be
copied into a kdbx-modules checkout unchanged.

No dependencies beyond KDB-X. The tests use `di.k4unit` from kdbx-modules.
`qsp.version` is the contents of `VERSION`.

## How it works

### The objects, and what each controls

Everything qsp decides comes from a **policy**: a plain q dictionary that you
build with the functions below, or load from CSV files. qsp never keeps a policy
in globals. You pass one to `run`, or install one with `serve`.

| Policy key | Shape | Controls |
|---|---|---|
| `tabs` | table → partition column | Which tables a query may read. Any other table is refused as unknown. The partition column decides where the row filter goes and what `requirepartition` asks for. |
| `schema` | `([]tbl;col;typ;att)` | The columns each table has. `qsp.ALL` grants all of them. A filter may name only these, and with `strictcolumns` off a where clause may too. The types give `f.aged` its cutoff type, and the attributes rank constraints. |
| `grants` | `([]entity;tbl;columns;rows)` | Which columns and rows of a table each user or group may read. `rows` is `()`, a list of constraints, or a lambda called with the user. |
| `members` | `([]user;entity)` | Which groups a user is in. Groups can contain groups. |
| `fns` | name → function value | The whitelist: every function a query may apply. It starts from `fns.defaults`. |
| `calls` | symbols | Your own functions, which a query may call by name. |
| `joincalls` | symbols | The subset that may stand where a table would, like a join. |
| `gateways` | symbols | Logins that may run a query as another user. |
| `config` | dictionary | The settings, as listed under [Configuration](#configuration). |

Three more things belong to the running module, not to a policy:

| Object | Read with | Controls |
|---|---|---|
| the served policy | `qsp.active[]` | The policy every IPC query is checked against. `qsp.serve p` replaces it in one assignment. |
| the message handlers | `.z.pw` `.z.pg` `.z.ps` `.z.pi` `.z.ph` `.z.pp` `.z.ws` | Set by the first `serve`. Only the served policy's users and gateway logins can connect. Sync and async messages go through `run`. HTTP and websockets are refused. The local console is not policed. |
| the audit log | `qsp.audit[]`, `qsp.audittable[]` | Every decision `run` took, kept in a global table. `auditto` names that global. |

### Who a query runs as

| Entry point | The user is |
|---|---|
| `qsp.run[p;u;q]` / `runx` in your own code | `u`, as you pass it |
| a sync or async IPC message to a served process | `.z.u`, the login |
| `` (`.qsp.execas;q;u) `` from a login in `gateways` | `u`, named by the gateway |
| the process's own console (`.z.w=0`) | nobody: it is evaluated unchecked |

A gateway message from a login not listed in `gateways` is treated as an
ordinary query, and refused. A gateway may only name a user of the policy (see
[Logins](#logins)).

qsp takes the login name as given. It **authorises** (given who you are, what
you may see) but does not **authenticate** (prove who you are). See
[Logins](#logins).

### What happens to a query

`run` takes a policy, a user and a query, which is a string or a parse tree. It
passes the query through a fixed sequence of steps. The first step that refuses
it stops it, records the decision in the audit log, and signals `'qsp: ...`:

| Step | What happens | A refusal is recorded as |
|---|---|---|
| 1. check the policy | Anything that is not a policy dictionary is refused. | not recorded: there is no policy to record under |
| 2. parse | A string is parsed with `parse`, never `value`. Text that is not q stops here, with q's error. | `error` |
| 3. file handles | A symbol starting with `:` anywhere in the tree is refused. Every filesystem primitive needs one. | `denied` |
| 4. walk and rewrite | Every node of the tree is checked against the policy and the user's grants, and each select is rewritten to read only what the user may see. See below. | `denied`, or `error` for a fault |
| 5. partition check | With `requirepartition` on, a query that would read every partition of a table is refused, naming the table and column. | `denied` |
| 6. evaluate | Only the rewritten tree is evaluated. If q signals, this is where. | `error` |
| 7. bound the result | The result is checked against `maxsize` (serialised bytes) and `maxrows`. | `denied` |
| 8. record | `allowed`, with the rewritten tree. | |

[docs/internals.md](docs/internals.md#what-happens-to-a-query-step-by-step)
follows one query through these steps in the code, function by function,
with the parse tree at each stage.

The other entry points stop part way. `rewrite` and `explain` run steps 1 to
4 and return the rewritten tree, or its text. `validate` runs 1 to 4 and
returns `(allowed;reason)`. Neither evaluates nor records anything, so neither
applies the partition check or the result limits: use `fullscans` for the
first. `runx` runs every step, and also returns what ran, as text.

A **fault** is a step-4 refusal that withholds nothing. The user holds the
column, but an inner select did not carry it through
(`select price from select sym from trade`). It is recorded as an `error`
rather than a `denied`, so the log never shows an entitled user being denied
something.

### What the user can see

The grants are resolved per user, per table, every time a query is rewritten:

1. **Entities.** The user, every group they are in, and every group those
   groups are in. A cycle is harmless.
2. **Columns.** The union of every column the entities are granted on the
   table, in schema order. `qsp.ALL` is every column in `schema`.
3. **Rows.** Each grant's filter is a list of constraints, ANDed. A lambda
   filter is called with the user here. The grants' filters are then ORed, and
   one grant with no filter means all rows. A lambda that signals, or returns
   something that is not a constraint list, refuses the query. It never
   falls back to no filter.
4. **Markers.** `qsp.USER` becomes the user as a symbol literal. `qsp.NOW`
   becomes the clock's timestamp, and `f.aged` becomes a cutoff cast to its
   column's type. The tree that runs therefore holds only literals, and the
   audit log shows the values applied.

`qsp.columnsfor[p;u;t]` and `qsp.filterfor[p;u;t]` return steps 2 and 4 for
one table. `qsp.access` returns them for every table, with the filter written
back as a where clause.

### What the rewrite does to a select

The walker visits every node of the tree. A select, exec, update or delete is
taken apart slot by slot:

| Slot | Checked against | Rewritten to |
|---|---|---|
| table | A registered table, which the user must hold at least one column of. Or an expression, walked with no names in scope, that projects columns the select can name (see below). | Unchanged for a select. An update or delete is moved onto `select <granted columns> from t where <row filter>`, so it never writes the real table. |
| where | The user's own constraints, which may name only granted columns. With `strictcolumns` off, they may name any column of the table. | The policy's row filter merged in, ordered as described in [Where the row filter goes](#where-the-row-filter-goes). |
| by | The granted columns (plus `i` with `rowindex` on). | Unchanged. |
| select | The granted columns (plus `i` with `rowindex` on). | `select *` becomes an explicit list of the granted columns. |
| limit, `select[n]` | No column names at all. | Unchanged. |
| sort, `select[>c]` | The granted columns without a `by`. With a `by`, the columns the select returns, because that is what q sorts. | The grade swapped for a guarded `iasc`/`idesc`. |

For a select over a table expression, the "granted columns" are the columns
that expression projects. Every expression in every slot is also walked by
the node rules below, so `not` is guarded wherever it appears.

The other nodes are checked like this:

| Node | Rule |
|---|---|
| function value (`sum`, `lj`, `+`) | on the whitelist, matched by identity. `not` is swapped for a guarded version |
| symbol atom | a **name**: it must be a column in scope here. A table name is refused anywhere but a table slot |
| symbol vector of 2+ | q evaluates `` `f`a`b `` as a call, so it must be in `calls`, and its arguments are walked |
| general list | an application: the head must be permitted, and the arguments are walked. A symbol q could resolve as a global is checked (see [Symbols computed at run time](#symbols-computed-at-run-time)) |
| `()` or a one-item list | literal data, which q does not evaluate. It may not hold a table name |
| lambda, projection, dictionary | refused |
| anything else | literal data |

A table expression is walked before any column is bound, so nothing in it
can name a column. The select above it may name only the columns the
expression is known to project:

| Head | Projects |
|---|---|
| a nested select | its own output columns |
| `lj` `ij` `uj` `pj` `ej` `aj` `aj0` `wj` `wj1`, a `joincall` | every column of their table arguments |
| `` `a`b# `` / `` `a`b_ `` | those columns, or the rest |
| `n#`, `xasc` `xdesc` `xcols` `asc` `desc` `reverse` `distinct` `ungroup` `sublist` `!` | their input's columns |
| anything else (`xcol`, `meta`, `cross`, `,`, a `call`) | nothing, so a select over it is refused |

A projected name that matches a global the user was not granted, such as a
process function, is dropped. A query therefore cannot alias a column to a
function's name and then call that function.

Here is one query, as written and as it runs for a user granted
`date sym account size price` on accounts `A1` and `A2`:

```q
q)qsp.explain[P;`llmu;"select sum size by sym from trade where size>15"]
"(?;`trade;,((in;`account;,`A1`A2);(>;`size;15));(,`sym)!,`sym;(,`size)!,(sum;`size))"
q)qsp.explain[P;`llmu;"select from trade"]
"(?;`trade;,,(in;`account;,`A1`A2);0b;`date`sym`account`size`price!`date`sym`account`size`price)"
```

### Where the row filter goes

q applies constraints left to right. If a user constraint ran before the policy
filter, `where size=max size` would be computed over hidden rows, and an empty
answer would reveal that the largest trade is hidden. If the partition
constraint does not lead, every partition is read. qsp moves only constraints
that **cannot aggregate**: a plain comparison of a column with something that
names no column of the table. It ranks them partition column first, then
indexed columns (by attribute and operator), then the policy filter, then the
rest. Anything that could aggregate keeps its place, after the policy filter.
A policy filter that could itself aggregate goes before everything the user
wrote.

```
select sum size by sym from trade where size>50, sym=`600, date=2010.01.05
  -> date=2010.01.05, sym=`600, account in ..., size>50
```

`placement` overrides this. `` `first `` puts the policy filter first and
leaves the user's order alone, and `` `last `` puts it last. `` `last `` is the
fastest, and it permits exactly the inference described above.

### What is never allowed

These can't be whitelisted, whatever a policy says: `value`, `get`, `set`,
`system`, `hopen`, `hclose`, `hcount`, `read0`, `read1`, `save`, `load`,
`rsave`, `rload`, `dsave`, `parse`, `eval`, `reval`, `show`, `exit`, `getenv`,
`setenv`, `insert`, `upsert`, `key`, `hsym`, `ssr`, `enum`, `fkeys`, `view`,
`views`, and the amend and assign operators.

Some primitives are safe or dangerous depending on their argument, and qsp
guards those separately:

- `not` and `hdel` are the **same primitive** (`~:`). File-handle symbols are
  refused anywhere in a query, and `not` is swapped for a wrapper that refuses
  a symbol argument.

### Symbols computed at run time

q treats a symbol **atom** as the name of a global when it applies one, or
hands one to a function that reads a table by name. `` (`$"f")[1] `` calls `f`.
`` cols`t ``, `` `k xasc`t ``, `` f each`t ``, `` 2?`t ``, `aj`, `lj` and `fby`
read the global `t` (and `xasc` sorts it in place). `` `sym?`x `` extends the
database's enumeration, and with a file handle on the left it writes a file.
The walker checks every name *written* in a query, but a symbol the query
*computes* (`` `$"t" ``, `` first `a`t ``, the output of `cols`) only exists
once the query runs.

So qsp checks arguments fail-closed. A short list of **pure** primitives
(comparison, arithmetic, aggregation, string and set functions, `in`, `like`,
`xbar` and so on) has been verified never to resolve a symbol and never to
apply a function it is given. Their arguments are left alone. For every other
function, including anything added with `allowfunction`:

- a literal symbol where q would resolve one is refused when the query is
  rewritten, and a computed argument is wrapped in a check that refuses a
  symbol atom as the value is produced. Column-name arguments are left alone:
  `` `sym xasc t ``, `` `a`b#t ``, `` aj[`sym`time;t;q] ``.
- the left of `` $ `` must be a type name (`` `int$x ``), not an enumeration
  domain. `x?y` refuses a symbol on the left, and from an atom on the left, a
  symbol on the right.
- a function that `each`, `over`, `scan`, `prior`, `peach`, `fby`, `wj` or an
  iterator applies must be pure. `` cols each `t`u `` is refused.
- an expression in the head of an application, like `` (sym where x)[0] ``, may
  index data or apply a pure function. A symbol or any other function is
  refused.

A refusal by one of these run-time checks is recorded as `denied`.
- The grades of `select[<c]` and `select[>c]` are the primitives behind
  `hopen` and `hclose`. On an atom, `select[<5000]` would open a connection.
  They are swapped for `iasc`/`idesc` wrappers that refuse an atom.

## The model: a policy is a value

Every builder takes a policy and returns a new one. Nothing writes a global.

```q
p0:qsp.policy[]
p1:qsp.grant[qsp.table[p0;`trade;::];`analyst;`trade;qsp.ALL;()]
/ p0 is untouched; both can be used at once
```

That gives you, without any extra machinery:

- **Atomic reload.** `qsp.serve p2` swaps the served policy in one assignment.
  No query can observe a policy that is half cleared and half rebuilt.
- **Testability.** Build a policy, then assert on `qsp.run[p;u;q]`. No setup or
  teardown of hidden state, and several policies can sit side by side.
- **Projections.** `r:qsp.run[p]` gives you `r[`alice;"select ..."]`.
- **Inspectability.** It is a dictionary of tables. Query it like any other
  data.

### Building a policy

| Call | Does |
|---|---|
| `policy[]` | an empty policy (denies everything), with the default whitelist and config |
| `table[p;t;spec]` | register a table. `spec` is `::` (read meta, attributes and partition column from the live table), a `meta` table (for a process where `t` is not loaded), or a symbol list of columns |
| `partition[p;t;c]` | name the partition column of a table described by hand |
| `refresh[p]` | re-read every table loaded in this process. A column added since registration stays invisible until you do. |
| `droptable[p;t]` | unregister a table, and its grants |
| `grant[p;e;t;cols;rows]` | grant entity `e` columns (`qsp.ALL` or a symbol list) and rows of `t`. Replaces `e`'s previous grant on `t`. Refuses a column `t` doesn't have, and a filter that names something that is neither a column nor defined |
| `revoke[p;e;t]` | remove one |
| `member[p;u;e]` / `unmember` | put a user in a group, or a group in a group |
| `allowfunction[p;names]` / `denyfunction` | widen or trim the function whitelist |
| `allowcall[p;names]` | let a function of yours be called by name |
| `allowjoincall[p;names]` | ...and let it stand in a select's table slot, like a join |
| `denycall[p;names]` | remove a function from both call lists |
| `gateway[p;logins]` | logins that may run a query as another, named user |
| `configure[p;dict]` | change settings (see below) |

Several grants on one table **union** their columns and **OR** their row
filters, the usual RLS/CLS behaviour. Two narrow grants can therefore combine
into something wider than either. If you need strict pairing, give the user
exactly one group.

### Keeping a policy in files

| Call | Does |
|---|---|
| `scaffold[dir;tables]` | write a starting policy for `tables` (`` ` `` for all) into `dir`: every table, partition column and column, and one grant row per table with **no entity**, so nothing is granted until someone decides. Never overwrites, and refuses to write into a database or a partition of one, since q would load the policy directory as a table and the database would fail to load |
| `check[dir]` | every problem with the policy in `dir`, as `([]file;line;error)`. Empty means it loads |
| `fromfiles[dir]` | the policy in `dir`, the same value the builders return. Refuses, listing every problem, if there are any |

```
tables.csv     tbl,partition                  required
grants.csv     entity,tbl,columns,filter      required: columns "a b c" or *; filter a where clause
members.csv    user,entity
gateways.csv   login
functions.csv  action,name                    allow | deny | call | joincall
config.csv     setting,value                  q literals; a function as fn:name
schema.csv     tbl,col,typ,att                for tables not loaded in this process
```

The files are applied in that order, each row to the policy built so far,
through the same builders. A filter cell is a q where clause, parsed (never
evaluated) at load: `` sym in `VOD`MSFT, size>100 ``. It can also use
`qsp.USER`, `qsp.NOW` and `qsp.aged[time;0D00:15]`, or `fn:name` to call a q
function with the user. `bin/policy.q` runs the check and the review from the
command line, for CI (see [setup.md](setup.md)).

### Reviewing a policy

| Call | Returns |
|---|---|
| `access[p;users]` | what each user (`` ` `` for everyone) can read: `([]user;tbl;columns;rows;via)`. The rows are written back as a where clause, in the same form a `grants.csv` filter takes |
| `diff[old;new]` | one row per change, as `([]user;tbl;change;detail)`. `change` is `gains`, `loses`, `columns` (`+col -col`) or `rows` (`before -> after`) for a user. It is `config`, `gateways`, `functions`, `calls` or `joincalls` (with a null user) for the whole policy |

Both work on any policy value. Lookups and `fn:` filters are called as a query
would call them, so they show the answer as of now.

```q
q)qsp.access[P;`llmu`alice`carol]
user  tbl   columns                      rows                         via
--------------------------------------------------------------------------
llmu  trade `date`sym`account`size`price "account in `A1`A2"          llm
llmu  quote `sym`bid`ask                 "all rows"                   llm
alice trade `date`sym`size               "sym in `aaa`bbb"            desk
carol trade `date`sym`size               "sym in allowedsyms[`carol]" call
```

### Row filters

`rows` is `()` (no restriction), a list of constraints (ANDed), or a unary
lambda taking the user and returning either, called on every query. Build
constraints with `qsp.f`:

| | |
|---|---|
| `f.eq` `f.ne` `f.lt` `f.le` `f.gt` `f.ge` | comparisons |
| `f.isin[`account;`A1`A2]` / `f.notin` | membership |
| `f.inrange[`size;10 100]` | `within` |
| `f.matches[`sym;"A*"]` | `like` |
| `f.aged[`time;0D00:15]` | only rows at least 15 minutes old, cast to the column's type |
| `f.both[a;b]` / `f.either[a;b]` | combine two |

Two markers may appear in a hand-written filter. Both are resolved to plain
literals when the query is rewritten, so the tree that runs never refers to
qsp, and the audit log records what was applied:

- `qsp.USER` is the user the query runs as, e.g. `(in;`sym;(`allowedsyms;qsp.USER))`.
  It is a lookup left in the tree and evaluated as the query runs. Never key a
  filter on `.z.u`: behind a gateway, that is the gateway.
- `qsp.NOW` is the policy clock, e.g. `(<;`time;(-;qsp.NOW;0D00:15))`.

A static filter is validated when the grant is made: every name it reads must
be a column or defined in the process, and it may use nothing on the never
list.

Aging the partition column turns an embargo into partition pruning:
`qsp.f.aged[`date;0D]` means nothing from today, and today's partition is never
read. It works in whole days. `qsp.f.aged[`time;0D00:15]` on a timestamp column
is an exact 15-minute delay. Paired with the date rule it adds nothing, as
every earlier row is more than 15 minutes old. On a time-of-day column it
applies to every day the table holds. [docs/time.md](docs/time.md) covers which
column to age, the span, `NOW` and the clock.

### Configuration

`configure` refuses an unknown key or a value of the wrong type. A typo must
not quietly open a policy up.

| Setting | Default | |
|---|---|---|
| `selectonly` | `1b` | the innermost table access must be a select. Off, an update or delete straight onto a table runs over a pinned select, and still writes nothing |
| `strictcolumns` | `1b` | where clauses may only use visible columns. Off, they may filter on hidden ones, which lets a caller probe their values |
| `placement` | `` `auto `` | where the row filter goes: `` `auto `` ranks constraints, `` `first `` / `` `last `` override |
| `attributerank` | `` `p`u`g`s `` | index attributes, best first |
| `rowindex` | `0b` | may the virtual column `i` be used in select and by (never in where). `i` is a row's place in the whole table, so its gaps show where hidden rows are |
| `clock` | `{[] .z.p}` | "now", for `f.aged` and `NOW`; must return a timestamp. Point it at the clock your data is stamped with: `{[] .z.P}` for local time. See [docs/time.md](docs/time.md#the-clock) |
| `maxdepth` | `24` | parse tree nesting limit |
| `maxsize` | `200000000` | max result bytes (checked after evaluation) |
| `maxrows` | `0W` | max result rows (checked after evaluation): a table's rows, a list's items, the longest column of a dictionary |
| `requirepartition` | `0b` | refuse a query that would scan every partition: one whose leading constraint, as rewritten, does not narrow the partition column with `=`, `in`, `<`, `within` and the like. **Turn this on for anything an LLM talks to.** |
| `audit` | `1b` | record every decision |
| `auditmax` | `10000` | rows kept in the audit log |

## Enforcing it

| Call | Returns |
|---|---|
| `run[p;u;q]` | the result of `q` as user `u`. Signals `'qsp: ...` on refusal. `q` is a string or a parse tree. |
| `runx[p;u;q]` | `(result; what ran, as text)`, for a caller that must show its user what the query became |
| `rewrite[p;u;q]` | the safe parse tree. Evaluates nothing. |
| `explain[p;u;q]` | the same, as text |
| `validate[p;u;q]` | `(allowed;reason)`. Evaluates and records nothing, and so does not apply `requirepartition`, `maxrows` or `maxsize` |
| `fullscans[p;u;q]` | the tables `q` would read every partition of |
| `columnsfor[p;u;t]` / `filterfor[p;u;t]` | what a policy resolves to for one user |

Every refusal is a signal starting `qsp: `. None is a return value, so a
caller that forgets to check can't run past one. The message names what was
refused (a column, a function, the table and column a full scan needs), so a
query generator can repair its query.

## Serving it

```q
qsp.serve p             / installs the message handlers; refuses HTTP and websockets
qsp.serve p2            / swap the policy, atomically
qsp.active[]            / the policy being served
```

| Handler | Does |
|---|---|
| `.z.pw` | logins: admits only the served policy's users and gateway logins (see [Logins](#logins)) |
| `.z.pg`, `.z.ps` | sync and async messages: `run` under the served policy, as `.z.u` or as the user a gateway names |
| `.z.pi` | console input: evaluated unchecked, as the console is not policed |
| `.z.ph`, `.z.pp` | HTTP GET and POST: refused |
| `.z.ws` | websockets: refused |

The local console (`.z.w=0`) is **not** policed. Whoever holds the console
holds the data.

**Gateways.** A gateway authenticates the end user and then queries over its own
login, so it forwards the caller explicitly:

```q
h (`.qsp.execas;"select from trade";`alice)      / or qsp.gatewaywrap[q;u]
h (`.qsp.execasx;"select from trade";`alice)     / (result; what ran)
```

This is honoured only for logins named with `qsp.gateway`. From any other login
it is an ordinary call, and is refused. The leading symbol is matched, never
resolved, so the wire format needs no global to exist and is unchanged from the
original qsp. A gateway's own login holds no grants unless you give it some.
The user it names must be a user of the policy. A name the policy doesn't know,
or a group's name, is refused and recorded as `denied`:
`qsp: not a user of this policy: `sales`.

### Logins

qsp trusts `.z.u`, the name a client logged in as. q accepts any name, with any
password, unless something checks it. So `serve` installs a `.z.pw` that admits
only:
- the **users** of the served policy: every name in `members` or `grants` that
  isn't a group. A group is any name that has members. This is
  `qsp.access`'s list of users.
- its **gateway logins**.

A name the policy doesn't know is refused at connection (`'access`, or
`401 Unauthorized` over HTTP). So is a **group's name**: without this check,
logging in as `sales` would get the sales group's grants. The served policy is
read on every connection, so swapping it changes who can connect. Every message
is checked again as well, in case the policy changed after the connection
opened.

`.z.pw` checks **names, not passwords**. Real authentication has to come from
the process, and composes with it:

| | how it combines |
|---|---|
| `-u file` / `-U file` | q checks the password file first. `.z.pw` runs only for a login that passes |
| a `.z.pw` of your own (LDAP, Kerberos, SSO) | define it **before** the first `serve`. qsp keeps it and calls it after the name check, so it sees only names the policy knows |
| a gateway that authenticates its users | list its login in `gateways`. It names each user per query, and the name must be a user of the policy |

A name that is granted directly but has no members row counts as a user. qsp
can't tell it from a group nobody is in yet, so give each group at least one
member, or name it so it can't be a login.

## The audit log

Every `run` records time, user, the query (as text), the **rewritten parse
tree** (lossless, and `eval`-able), and the decision with its reason:

| `decision` | |
|---|---|
| `` `allowed `` | it ran and returned |
| `` `denied `` | a permission decision: a column, table, function, write, limit or full scan |
| `` `error `` | nothing was withheld: the text was not q, q could not evaluate a permitted query, or the caller holds a column an inner select did not carry through |

```q
q)select user,query,decision,reason from qsp.audit[]
user query                               decision reason
---------------------------------------------------------------------------------------------
llmu "select pnl from trade"             denied   "qsp: unknown or not-permitted column: pnl"
llmu "select sum size by sym from trade" allowed  ""
```

The log is kept only while the policy's `audit` setting is on, and is trimmed
to its newest `auditmax` rows.

```q
select from qsp.audit[] where decision=`denied
qsp.auditto`auditlog            / keep it under a global name of your choosing...
p:qsp.table[p;`auditlog;::]     / ...so an auditor can be granted it like any table
p:qsp.grant[p;`audit;`auditlog;qsp.ALL;()]
```

## Limits

- **qsp bounds the result, not the work.** `requirepartition` is the one check
  that runs before evaluation. Run policed processes with `-T` (timeout) and
  `-w` (memory cap): those are the real resource controls.
- **qsp doesn't authenticate.** It checks that a login is a user of the
  policy, not that the client is who it claims. Use `-U` or your own `.z.pw`
  (see [Logins](#logins)).
- **`allowcall` is trust, not validation.** qsp checks the call site, not the
  body of the function you expose.
- **Grants union.** See above.
- **`strictcolumns` off and `rowindex` on each leak something by design.** The
  first lets a caller filter on a column they cannot read. The second shows
  the positions of rows they cannot see.

## Layout

[docs/internals.md](docs/internals.md#every-file) describes every file in
full, and how the source files depend on each other.

```
di/qsp/init.q        the pipeline (parse, rewrite, pre-check, eval, bound), audit, serving
di/qsp/policy.q      a policy as a value; what it resolves to per user
di/qsp/files.q       a policy kept as a directory of CSVs: fromfiles, check, scaffold
di/qsp/review.q      access and diff; filters written back as q
di/qsp/walk.q        the walker and rewriter
di/qsp/order.q       where-clause ordering - pure in (table info; constraints)
di/qsp/fns.q         the function whitelist, never-allow list, guarded substitutes
di/qsp/tree.q        parse-tree shapes, detected from q's own parser at load
di/qsp/f.q           row filter builders (exported as qsp.f)
di/qsp/VERSION       the module version, exported as qsp.version
di/qsp/qsp.md        this file
di/qsp/setup.md      the walkthrough for a team
di/qsp/docs/         README.md (the index), concepts.md (what a policy is made of), time.md
                     (embargoes and the clock), internals.md (the code, for developers)
di/qsp/test.csv      the k4unit tests
di/qsp/test.q        their fixtures and helpers; testserver.q, the process they police over IPC
di/qsp/bin/          policy.q: check and review a policy directory, for CI and pull requests
                     test.q: run the tests, exiting non-zero on failure
di/qsp/examples/     equities/: an example HDB (mkhdb.q), its policy (policy/, with defs.q for the
                     q it names), and a walkthrough of each role that serves it with -p (hdb.q)
```

## Tests

The tests are k4unit tests in `test.csv`, as every kdbx-modules module has. With
kdbx-modules on the search path:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.qsp
```

or, for CI, `bin/test.q` runs them and exits 1 if any fail:

```sh
QPATH=${QPATH}:/path/to/kdbx-modules q di/qsp/bin/test.q -q
```

There are 387 assertions. The first 222 cover enforcement, against the
in-process API and a real IPC server with a gateway login (`testserver.q`):

| Area | Covers |
|---|---|
| the policy value | builders return new policies, config refuses typos, refresh, revoke, unmember, droptable |
| rows and columns | `select *`, aggregates, exec, by, nested selects, updates over selects, joins, `fby`, `distinct` |
| the attack surface | 41 attempts to reach hidden columns, other tables, globals, the filesystem, handles, assignment and `eval`, each refused, with checks that nothing ran or changed |
| sorts and limits | `select[n;>c]`: hidden columns, functions and atoms in a sort are refused. A sort over a `by` uses the output |
| more query shapes | delete, exec pivots, take and key, `reverse` `sublist` `xcols` `xcol`, every join, subqueries in where, the never list, `rowindex` |
| entitlements and resolution | lambda filters, `USER` lookups, failing lookups, several groups at once, an aggregating policy filter |
| a partitioned database | constraint ordering by partition and attribute, `placement`, aged filters, `NOW`, `fullscans`, `requirepartition` |
| the audit log and serving | every decision kind, `auditto`, gateways, logins (`.z.pw` refuses unknown names and group names, and keeps a `.z.pw` defined before `serve`), a gateway naming a non-user, async, HTTP GET and POST (401 without a known user), websockets, policy swap |

The other 165 cover policy files, scaffold, access, diff and `bin/policy.q`,
including every way a policy directory can be wrong:
- **The directory and files:** missing, empty, a file where a directory should
  be, misspelt or wrongly-cased file names, unreadable, binary garbage, and
  20 runs of random bytes.
- **How the CSV is written:** Windows line endings, a UTF-8 byte order mark,
  quoted cells, short and long rows, padded rows, and unterminated quotes.
- **What the rows say:** every row-level mistake in each file, every filter
  form and every bad one, and a failed reload that leaves the served policy in
  place.
- **Examples:** `examples/equities/hdb.q` builds its HDB and every step of
  its walkthrough goes as expected, and `examples/equities/policy/` loads with
  no data, given its `defs.q`.
- **Scale and tools:** a 2000-grant, 5000-member policy, a scaffold
  round trip, a scaffold refused inside a database (date, int, splayed and
  segmented, and a relative path from an HDB's working directory), the property that every filter `access` shows loads back as the
  same filter, and the CLI's exit codes.

The module was also run against the original qsp's own suites through a
test-only shim of the old global API:

| suite | result |
|---|---|
| run | 202/204: the two "differences" are the `exec ... by` fix below |
| attack | 255/255 bypass attempts refused |
| attributes | 64/65: the module returns a typed empty dictionary where the old test expects `()!()` |
| runtime | 31/31: three assertions on the removed `.qsp.currentuser` global skipped |
| partition | 26/31: the five misses inspect the old `gwserver.q` demo script |

## Changes from qsp

**Reimagined:**
- Global mutable state became a policy **value**, with config as part of it.
  Gone with it: `clearpolicy`, `enabled`, the global settings, and the
  placeholder row the grants table needed to keep its column types.
- Tables are described with `meta` instead of `setattributes` / `settypes`.
- `USER` and `NOW` resolve at rewrite time. There is no `.qsp.currentuser`
  global, so nothing is left in the tree that a query could reach.
- Audit decisions follow from the stage that refused. A fault carries an
  unforgeable marker instead of a global flag. The log keeps the tree rather
  than a `-3!` string, which `\c` truncated.

**Dropped:** TorQ `.lg` / `.dotz` hooks, `limits`, the semantic layer, demo,
data generator and evaluation harness. They belong to an application, not the
module.

**Fixed along the way:**
- **Any login was accepted.** qsp trusted `.z.u`, and q accepts any name with
  any password by default. Logging in as `compliance1`, or as the group name
  `compliance`, gave that access. `serve` now installs a `.z.pw` that admits
  only the policy's users and gateway logins, and a gateway may name only a
  user. Passwords still need `-U` or your own `.z.pw`.
- **The sort of `select[n;>c]` was never checked.** This was found by
  reviewing test coverage, and was in the walker from this repository's first
  commit. The walker treats a one-item list as data. parse puts the sort in
  one, but q evaluates it. `select[>leakfn size]` called a global,
  `select[>pnl]` ordered rows by a hidden column, and `select[<5000]` opened a
  connection. The sort is now walked in the columns q evaluates it against,
  and its grade is guarded.
- **`scaffold` wrote into a database.** The setup guide's relative
  `scaffold["policy";...]`, run from an HDB console, put `policy/` inside the
  HDB, which then failed to load. It now refuses a database or a partition of
  one, and the guide gives an absolute path.
- `exec ... by sym` was normalised to a keyed table. It now returns q's own
  dictionary shape.
- `select distinct` was refused. It is now permitted.
- The `` `$"\000..." `` markers were all the null symbol, because a symbol
  stops at a NUL byte.
- A refused function is now named in the refusal (`function not permitted:
  system`), so a query generator can repair the query.
- `qsp.f.notin` builds a two-item constraint (`not` and its argument), which
  the filter check refused. It now loads like any other filter. Found by the
  files suite.
