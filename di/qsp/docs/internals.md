# di.qsp internals

This page is for developers changing qsp. It covers what each source file
does, how the files depend on each other, and what happens to a query inside
the module, step by step, with the real values at each stage. It also lists
the rules the code relies on, and where to make the usual kinds of change.

Read [How it works](../qsp.md#how-it-works) in qsp.md first. It describes the
same behaviour from the user's side. This page names the functions behind it.

## Every file

| file | what it is |
|---|---|
| `init.q` | The module's entry point, loaded by `` use`di.qsp ``. Loads the submodules, runs the pipeline (`go`), keeps the audit log, installs the message handlers, and exports the public API. |
| `core/tree.q` | What a q parse tree looks like. Every shape qsp depends on is read from q's own parser at load. Also the refusal helpers (`chk`, `fault`), the file-handle guard, and the marker symbols. Depends on nothing. |
| `core/fns.q` | The function whitelist: `defaults`, the never-allow list, name-to-value resolution, and the guarded replacements for `not` and the sort grades. The pure functions, the argument `rules` for everything else, and the run-time symbol checks the walker wraps around computed arguments. |
| `core/order.q` | Where the row filter goes in a where clause. A pure function of the table's info and the constraints. |
| `core/walk.q` | The walker. Checks every node of a parse tree and rewrites each select so it reads only what the user may see. |
| `core/qsql.q` | A rewritten tree written back as q-SQL, with the run-time checks shown as the expressions they check: `explain`, `runx`, a gateway's `execasx` and the admin UI use it. `text` returns the q-SQL only when parsing it gives back the same tree - checks aside, a one-item vector as `enlist` - and the parse tree otherwise, so it never misstates what ran. |
| `policy/init.q` | A policy as a value. The builders (`new`, `table`, `grant`, `member`, `configure`, ...) and resolution: which columns and which row filter one user gets on one table. |
| `policy/f.q` | The row-filter builders exported as `qsp.f` (`isin`, `eq`, `aged`, ...). Each returns one constraint as a parse tree. |
| `policy/files.q` | A policy kept as a directory of CSVs: `fromfiles` (and `policyin`, the same without its schema warnings), `check`, `scaffold`, `schemadrift`. Reads the CSVs by hand and applies each row through the `policy/init.q` builders. A loaded table is registered from its live meta, and `schemadrift` reports where `schema.csv` disagrees. |
| `policy/review.q` | What a policy means: `access` (who can read what), `diff` (what a change changes), and `text`, which writes a constraint back as q. |
| `policy/suite.q` | A policy's own tests, `tests.csv`: reads and checks it (an `equals` value is parsed and evaluated only if it is plain data), and gives a test's verdict from what running it returned. `init.q` runs them (`runtests`), with the audit log off. |
| `core/codes.q` | A refusal as data: `classify` matches a message against an ordered table of patterns, first match wins, giving its `code` (`family.reason`), `kind` (`permission`, `shape`, `limit`, `runtime`) and `subject`, taken from the message. A message no pattern knows is `refusals.other`, kind `permission`. |
| `receipt/init.q` | Receipts: HMAC-SHA1 over `-33!`, the key ring (a directory of `<kid>.key` files, the newest signing), `issue` and `verify` (the bytes signed are `-8!` of every field but `sig`), and the store of receipts and small results, fetched only by a receipt's user or gateway. |
| `mcp/mcp.q` | An MCP server over stdio, a q script rather than part of the module: a client of a policed process over IPC, which loads `api` for its JSON encoding. |
| `api/init.q` | What a gateway or a query generator asks a policed process: `limits`, `memstats`, `users`, `functions`, `rules` (for an LLM agent: each rule with its reason, examples either way, and the text of its refusal), `primer` (`api/primer.md`, read on each call: how to write q that qsp accepts, as markdown for an agent's context), `access`, `describe` (one user's view of the policy, with the rules). Each takes a format last, `` `q `` or `` `json ``, which changes the encoding and never the content. `init.q` adds `version`, `validate` and `explain`, exports the lot as `qsp.api`, and serves the same calls over IPC as `` (`.qsp.api;name;...) ``. |
| `api/primer.md` | The primer `qsp.api.primer` serves: how to write q that qsp accepts, for an LLM agent's context. Its q examples are single-line ```` ```q ```` blocks over the equities example's tables, and `examples/equities/hdb.q` runs every one as `compliance1`, so a change to what qsp accepts that breaks one fails CI. |
| `admin/init.q` | The admin UI (`qsp.adminui`): its JSON API over `.z.pp` and the page from `admin/ui/` over `.z.ph`, the state of the policy it is editing (none, does not load, loads), and opening, creating (scaffold), previewing and saving one. It runs queries only through the functions `init.q` lends it. |
| `admin/ui/` | The admin UI's page: `index.html`, `style.css`, `app.js` (routing and state), `model.js` (the policy as the page reasons about it), `drawer.js`, `lib.js`, and a module per view in `views/`. Plain ES modules, no build. |
| `VERSION` | The module version (semver), read into `qsp.version`. |
| `CHANGELOG.md` | What changed in each version. A change to what a policy permits is marked **behaviour**. |
| `qsp.md` | The module's documentation: install, example, API, how it works, limits. |
| `docs/setup.md` | The walkthrough for a team setting up a policy kept as files. |
| `docs/README.md` | Index of the documentation. |
| `docs/concepts.md` | What a policy is made of, and how one user's access is worked out. |
| `docs/time.md` | Embargoes, delayed data and the policy clock. |
| `docs/ui.md` | The admin UI's guide: each view, common jobs, its JSON API. Screenshots in `docs/img/`. |
| `docs/testing.md` | qsp's own tests: the unit tests and the hardening campaign, what each covers, and how to add to them. |
| `docs/history.md` | What changed from the original qsp, and how the module did against its suites. |
| `docs/security-review.md` | The three security reviews: each finding, its verdict, root cause and fix. |
| `docs/internals.md` | This page. |
| `test.csv` | The k4unit tests. `k4unit.moduletest`di.qsp` runs them. |
| `test.q` | The tests' fixtures (`trade`, `quote`, the policy `P`, ...) and `.t.*` helpers: assertions (`.t.allow`, `.t.deny`), partitioned test databases, connecting to `test/server.q`, policy directories written from strings, and running `bin/policy.q`. Loaded by `test.csv` and `test/server.q`. |
| `test/server.q` | A process that serves `P` over IPC, for the serving tests. It exits when its last client disconnects, or after a minute. |
| `bin/ci.sh` | Every suite in one command, for CI: the unit tests, the example's walkthrough, `bin/policy.q -test` on the example's policy, the admin UI's endpoint check and the hardening campaign, on one example HDB. Runs them all, keeps each one's log, and exits 1 if any failed. |
| `bin/test.q` | Runs the tests and exits 1 if any fail, for CI. |
| `bin/policy.q` | Checks a policy directory and its `tests.csv`, and prints `access`, and optionally a `diff` against an older one. With `-test`, runs the tests against the data `-init` loads. Exits 1 if the policy would not load or a test fails. For CI and pull requests. |
| `examples/equities/README.md` | The example: its roles, how to run it and load its policy, and queries that surprise people. |
| `examples/equities/mkhdb.q` | Builds the example equities HDB: four date-partitioned tables, four splayed reference tables, fixed data. |
| `examples/equities/policy/*.csv` | The example's policy, as files: `config`, `gateways`, `grants`, `members`, `schema`, `tables`, and its tests, `tests.csv`. |
| `examples/equities/policy/defs.q` | The q the example policy names: the lookup functions its filters call, and its fixed clock. Kept with the CSVs so it is reviewed with them. `fromfiles` doesn't load it. |
| `examples/equities/setup.q` | What `hdb.q` and `demo.q` share: builds the HDB if `-db` doesn't exist, loads it, `defs.q` and the policy (`-policy DIR`, or `policy/`). |
| `examples/equities/hdb.q` | Loads the example (`setup.q`), then walks through `policy/tests.csv`, showing what each query returns and checking each test passes, the agent rules' examples, and every q example in the primer. Exits 1 if any doesn't. With `-p`, it then serves the policy. |
| `examples/equities/demo.q` | Loads the example (`setup.q`) and opens `qsp.adminui` on it. With `-check`, calls each of the admin UI's endpoints and exits 1 if one answers wrongly. |

## How the source files fit together

Every `.q` file other than `init.q` and the tests is a submodule, named
for its path: `core/walk.q` is `di.qsp.core.walk`, and a directory's
`init.q` is the directory, so `policy/init.q` is `di.qsp.policy`. They are
grouped by what they do:

| directory | modules | what they do |
|---|---|---|
| `core/` | `tree`, `fns`, `order`, `walk` | read a query's parse tree, check every node of it, and rewrite it |
| `policy/` | `policy`, `.f`, `.files`, `.review`, `.suite` | the policy value and its builders, and a policy kept as files, reviewed and tested |
| `api/` | `api` | what a gateway or a query generator asks a policed process |
| `admin/` | `admin`, and its page, `ui/` | the admin UI |

`init.q` loads them with `` use`.core.walk ``, `` use`.policy `` and so on,
and they load each other by relative name: `` use`..x `` is a module in the
same directory, and each further dot goes up one more. `core/walk.q` loads
`` use`..tree `` and `` use`...policy ``, and `policy/files.q` loads
`` use`..f `` and `` use`...core.tree ``. So the directory can be moved as a
unit. Nothing loads a file by path.

```
init.q ─────────► core.tree  core.codes  receipt  policy  core.order  core.walk  policy.f
                  policy.files  policy.review  api  policy.suite  admin
receipt/init.q ─► core.tree
admin/init.q ───► core.tree  core.fns  policy  policy.files  policy.review  api  policy.suite
api/init.q ─────► core.tree  policy  policy.review
policy/suite.q ─► core.tree  policy.files
policy/files.q ─► core.tree  core.fns  policy  policy.f
policy/review.q ► core.tree  core.fns  policy
policy/f.q ─────► core.tree  core.fns
policy/init.q ──► core.tree  core.fns
core/walk.q ────► core.tree  core.fns  policy  core.order
core/order.q ───► core.tree  core.fns
core/fns.q ─────► core.tree
core/tree.q       (nothing)
core/codes.q      (nothing)
```

There are no cycles. `core/tree.q` is the leaf, so anything about how q
represents a query goes there. The pipeline (`run`, `runx`, `rewrite`,
`runtests`) lives in `init.q`, which `admin/init.q` cannot load without a
cycle. So `adminui` lends those functions to `admin.start` as a dictionary
when it is called, and the admin UI runs every query through them.

### What runs at load

Several files work out q's own representations when they load, rather than
hard-coding them. If a future q changes a shape, qsp fails to load or refuses
queries. It never misreads a tree.

| file | detects at load |
|---|---|
| `core/tree.q` | `selop` and `updop`, the heads of `select` (`?`) and `update`/`delete` (`!`). `cnested`, whether the where slot has an extra enlist. `ascop` and `descop`, the grades behind `select[<c]` and `select[>c]`. |
| `core/fns.q` | `defaults`: every whitelisted name resolved to its function value. `neverfns`: the never-allow list as values, plus the amend and assign operators read from parse. `compose`: the iterator q puts in the head of `a<>b`. |
| `core/order.q` | `negations`: how `<>`, `<=` and `>=` appear in a parse tree (as `not` composed with `=`, `>` and `<`), so each can be ranked as the operator it stands for. |
| `core/walk.q` | `preserve`, the heads that keep their input's columns. Loading fails if fewer than nine resolve. Also `takeop`, `dropop` and `dictop` (`#`, `_` and `!`). |
| `admin/init.q` | `uidir`, the `ui/` directory beside it. It is read from the file a function of `admin/init.q` was defined in (`value`, third from last): while a module loads, `.z.f` is the script that loaded it, and a `:::` path built at run time does not resolve. |

### Module state

A policy is a value, passed in. The only globals the module keeps are:

| name | file | holds |
|---|---|---|
| `logname`, and the table it names | `init.q` | the audit log. `auditto` moves it to a root name |
| `served` | `init.q` | the policy the message handlers use |
| `installed` | `init.q` | whether `serve` has installed the handlers yet |
| `recent` | `init.q` | each user's query times in the last minute, for `maxqueries` |
| `ring`, `kept` | `receipt/init.q` | the receipt keys, read at `serve` or `reloadkeys`, and the receipts kept |
| `before` | `init.q` | each message handler as it was before the first `serve`. A query is evaluated through the `.z.pg` or `.z.ps` that was there, and `.z.pw` is called after the name check. `unserve` puts them all back |
| `Q` | `admin/init.q` | the pipeline functions `adminui` lent it |
| `dir`, `P`, `P0`, `PR`, `edited` | `admin/init.q` | the admin UI's policy: its directory, the policy (`(::)` while it does not load, with `PR` the problems), the policy as the files have it, and whether an edit has been applied to the session |
| `T`, `TP` | `admin/init.q` | the policy's tests, and the problems with `tests.csv` |
| `access`, `running`, `opened`, `before` | `admin/init.q` | whether the page answers `` `local `` or `` `public ``, whether its handlers are installed, whether it opened the port, and `.z.ph` and `.z.pp` as they were before, for `` adminui`stop `` |

Nothing is set per query. The walker passes its state down as arguments.

## What happens to a query, step by step

This follows one query through the code, using the test fixtures in `test.q`:

- `trade` has columns `date sym account size price trader pnl`.
- `llmu` is a member of `llm`.
- `llm` is granted `date sym account size price` on `trade`, with the row
  filter `enlist qsp.f.isin[`account;`A1`A2]`.

The query:

```q
qsp.run[P;`llmu;"select sum size by sym from trade where size>15"]
```

Every value shown below is what q printed when the query was traced through
the module.

### 1. Entry: `run` → `go`

`run`, `runx` and the message handlers all call `go[p;u;q]` in `init.q`. It
returns `(result;rewritten tree)`. `run` keeps the result, and `runx` also
returns the tree as text.

Over IPC, `.z.pg` and `.z.ps` are `req`, which first:

1. evaluates the message unchecked if it came from the console (`.z.w=0`);
2. refuses a login that isn't a user or gateway of the *current* served
   policy (`islogin`). `.z.pw` checked this at connection, but the policy may
   have been swapped since;
3. treats a 3-item message `(`.qsp.execas;query;user)` from a gateway login as
   a query run as `user` (`isgatewaycall`). The named user must be a user of
   the policy (`isuser`);
4. otherwise calls `run[served;.z.u;x]`.

`go` checks the policy with `chkpolicy`, which needs a dictionary with the
policy's keys. This is the only refusal that isn't recorded, since there's no
policy to read `audit` from.

### 2. Parse: `toparse`

A string goes through `parse`, never `value`. A parse tree passed in directly
skips this step and is checked like any other. Text that doesn't parse is
refused as `qsp: not valid q (...)` and recorded as an `error`.

```q
(?;`trade;,,(>;`size;15);(,`sym)!,`sym;(,`size)!,(sum;`size))
```

The parts of a query node, as the walker refers to them:

| index | slot | here |
|---|---|---|
| 0 | the head: `?` for select and exec, `!` for update and delete | `?`, a function value (type 102h) |
| 1 | the table | `` `trade ``, a name |
| 2 | the where clause, in an extra enlist on this q (`tree.cnested`) | `,,(>;`size;15)` |
| 3 | by: `0b` for none, `1b` for distinct, `()` for an exec without a by, a dictionary, or a list of names | `` (,`sym)!,`sym `` |
| 4 | the select: `()` for `*`, a dictionary, a list (exec), or a symbol list (delete) | `` (,`size)!,(sum;`size) `` |
| 5 | the limit, in `select[n]` | absent |
| 6 | the sort, in `select[n;>c]`, as `enlist (grade;expression)` | absent |

`tree.getc` takes the constraint list out of slot 2, removing the extra
enlist, and `tree.setc` puts one back in. Code that reads or writes slot 2
must go through these two functions.

### 3. The context: `walker.ctx`

`go` calls `tryrewrite`, which builds the context for this rewrite and calls
`walker.rewrite`:

```q
ctx:{[p;u;q] :([p;u;cfg:p`config;fv:value p`fns;reads:tree.basetables q]);}
```

`fv` is the whitelist's values, computed once per query. `reads` is every
table a select reads directly, here `` ,`trade ``. The walker uses it to tell
a **fault** (a name the user holds that a nested select dropped) from a
**denial** (a name the user doesn't hold).

### 4. Whole-tree checks: `walker.rewrite`

Before walking, `rewrite` refuses the query if any symbol anywhere in it
starts with `:` (`tree.hasfilehandle`). Every filesystem primitive needs a
file handle. This check also closes `hdel`, which is the same primitive as
`not`.

It then calls `walk[c;nocols;0;q]`: no names in scope, at depth 0.

### 5. Dispatching a node: `walk`

`walk[c;scope;depth;node]` returns `(rewritten node;columns it projects)`.
`scope` is the set of names a bare symbol may refer to at this point. It
checks `depth` against `maxdepth`, then picks the first rule that fits:

| test, in order | handler | what it does |
|---|---|---|
| `tree.isquery` (a list of 5+ headed by `?` or `!`) | `query` | step 6 |
| `tree.isfn` (type 100h–112h) | `walkfn` | must be on the whitelist, matched by identity (`fnok`). `fns.subst` swaps `not` for `notsafe` |
| a symbol atom | `walksym` | a name. It must be in `scope`, or `notinscope` refuses it, naming whether it is a table, a fault, or unknown |
| a symbol vector of 2+ | `walkcall` | a call by name: the first item must be in `calls`. Each argument is walked |
| a dictionary | refused | |
| a general list | `walklist` | under two items, it is literal data. Otherwise it is an application: `walkhead` checks the head, and each argument is walked at `depth+1`. Then `guarded` checks every symbol q could resolve as a global: by `fns.rules` for a function head, refusing a literal symbol now and wrapping a computed argument in a run-time check. An expression head is wrapped in `fns.fnarg`. Pure functions, and column-name arguments, are left alone |
| anything else | `literal` | data, which projects nothing. It may not contain a registered table's name, or a function at any depth (`hasfn`): `eval` hands back a one-item list's item unevaluated, so `(each;enlist value;...)` would hand `each` a function the walker never checked |

`walkhead` accepts a function value (through `walkfn`), a symbol (through
`headsym`: a name in `calls`, or a column in scope, since `price where size>1`
parses as `` (`price;...) ``), or a list, which it walks. q writes `a<>b`
with the head `(';~:;=)`, which is a list. Anything else is refused.

`walklist` rebuilds a list only if something in it changed. Rebuilding a
general list of symbols would collapse it into a symbol vector, which q
evaluates differently. It also asks `exprcols` which columns the result
projects, which matters only in a table slot (step 6b).

### 6. A select: `query`

Our tree is a query, so `walk` hands it to `query[c;scope;depth;q]`, which
deals with each slot in turn.

**a. Kind.** `isupd` is whether the head is `!` (update or delete). Here it
is `0b`.

**b. The table slot: `tableslot`.** An atom goes to `basetable`, and a list
goes to `exprtable`. A symbol vector (in-place `` update ... from `t ``) is
refused.

`basetable` refuses an update/delete straight onto a table when `selectonly`
is on, a table not in `tabs`, and a table the user holds no columns on. It
returns:

```q
base  | 1b
tn    | `trade
vcols | `date`sym`account`size`price      / pol.columnsfor[P;`llmu;`trade]
slot  | `trade
```

`pol.columnsfor` gets the user's entities (`entitiesfor`: `llmu`, then `llm`,
following membership until nothing changes), selects their grants on the
table, and takes the union of the columns, in schema order.

`exprtable` walks an expression such as a nested select or a join with **no
names in scope**, since it runs before any column is bound. It keeps the
projected names that `safename` accepts. A projected name that shadows a
global function the user wasn't granted is dropped. An expression that isn't
a query and projects nothing is refused, with `exprerror` saying why.

**c. Scopes.** Two sets of names:

```q
refcols:  `date`sym`account`size`price   / where may use these. All 7 columns if strictcolumns is off
outscope: `date`sym`account`size`price   / by and select may use these, plus `i if rowindex is on
```

Before any of this, `query` checks the where slot is `()` or, as parse
writes it, a one-item list holding the constraints (`iswhere`). `byclause`
and `selectclause` refuse an application where a clause belongs, and an
exec's slot must be one item. A functional form written as text parses with
its clauses as code that builds them (`(enlist;(enlist;=;,`a;1))`), which q
runs before `?` sees the result, so the walker would check something other
than what runs. Those shapes are refused with `funcform`.

**d. Where.** `walkall[c;refcols;depth;tree.getc q 2]` walks each user
constraint. `(>;`size;15)` goes to `walklist`: the head `>` is a whitelisted
function value, `` `size `` is in scope, and `15` is literal. Nothing changes.

**e. By: `byclause`.** A dictionary is walked by value in `outscope`. A bare
list of names (`exec ... by sym`) is checked name by name and kept as written,
so q still returns a dictionary. `0b`, `1b` and `()` pass through. Anything
else is refused. Here it returns the slot unchanged and `` bycols:,`sym ``.

**f. Select: `selectclause`.** This dispatches on the slot's shape:

| shape | handler | result |
|---|---|---|
| dictionary | `selectdict` | each value walked in `outscope`. The output columns are the by columns plus the keys, or for an update the input's columns plus the keys |
| `()` | `selectstar` | for a table: `vcols!vcols`, or `last` of each with a by. This is where `select *` becomes an explicit projection |
| empty symbol vector | inline | `delete from t where ...`: delete rows |
| one-item list holding a symbol vector | inline | `delete a b from t`: delete columns |
| one-item general list | `execlist` | an exec's expression, walked. `pivotcols` reads the output keys of `exec k!v by x`. Any other general list is code building the clause (a functional form), refused |

Here `(sum;`size)` is walked, `sum` is whitelisted, and the select outputs
`` `sym`size ``.

**g. The policy's row filter: `pol.filterfor`.** Only for a base table:

1. `rawfilter`: each of the user's grants on the table gives a constraint
   list. A lambda filter is called with the user here, and `normfilter`
   refuses any result that isn't a constraint list. If any grant has no
   filter, the user sees all rows and the result is `()`. One grant gives
   its own list. Several are combined as one constraint: the OR of each
   grant's constraints ANDed.
2. `resolve`: markers become literals. `qsp.USER` becomes `` enlist`llmu ``.
   `qsp.NOW` becomes the clock's timestamp. `(<;c;(agedmark;c;span))` becomes
   a cutoff cast to the column's type (`cutoff`).

```q
pf: ,(in;`account;,`A1`A2)
```

**h. The table slot, rewritten.** A select over a base table keeps the slot
`` `trade ``. An update or delete over a base table (`selectonly` off) is
moved onto `(?;tn;setc pf;0b;vcols!vcols)`, a select pinned to the grants, so
it never writes the real table. A slot that is an expression keeps its
rewritten form. The selects inside it already carry their own filters.

**i. Ordering: `ord.place`.** For a select over a base table, the policy
filter is merged into the user's constraints using the table's info
(`pol.info`: columns, types, attributes, partition column):

1. With `placement` `` `first `` or `` `last ``, return `pf,w` or `w,pf`.
2. If any policy constraint isn't `movable`, the policy filter goes first:
   `pf,w`.
3. Otherwise, take the user's constraints up to the first one that isn't
   movable. Sort those together with the policy's, and leave the rest in the
   order written, after them.

A constraint is **movable** if it is `(op;column;value)`, `op` is a plain
comparison (`= in < <= > >= within <> like`), and `value` names no column
of the table, holds no nested select, and doesn't use `i`; or if it is `&`,
`|` or `not` over movable constraints (`iscompound`). Its result for a row
then doesn't depend on any other row, so moving it can't change the answer.
Two comparisons that look plain are not movable:

- `~` is not on the list. It matches the whole column and returns one
  boolean, so it aggregates.
- a literal list on the right of `= < <= > >= <>`, more than two values for
  `within`, or anything but one string for `like` (`literal`, `oneshape`). q
  compares row by row against a list, and signals `'length` unless the list
  is as long as the rows in front of it: moved ahead of the row filter, that
  counts the hidden rows. A value the user computes can't be shaped here, so
  `ord.guardvalues` (called from `query`, before placement) wraps it in
  `fns.scalar`, `fns.pair` or `fns.pattern`, which refuse a list as it runs.

The sort key (`crank`, `sort`) is, lowest first: rank, then policy before
user, then position, as a table sort so no count of constraints spills one
key into the next. The ranks are:

| rank | constraint |
|---|---|
| 0 | on the partition column |
| 1, 2, ... | on a column with an attribute from `attributerank`, using an operator its index can serve (`p` `u` `g`: `= in`; `s`: those plus ranges) |
| 50 | any other movable constraint, including every `&`, `\|` and `not` |
| 900 | not movable. Never sorted, since the prefix stops before one |

Here `trade` has no partition or attributes, so both constraints rank 50 and
the policy's goes first:

```q
((in;`account;,`A1`A2);(>;`size;15))
```

On a table partitioned by `date` with `` `p# `` on `sym`:

```
where size>50, sym=`600, date=2010.01.05
  -> date=2010.01.05, sym=`600, account in `A1`A2, size>50
where size=max size, date=2010.01.05
  -> account in `A1`A2, size=max size, date=2010.01.05
```

In the second query, `size=max size` isn't movable, so it and everything
after it keep their place. The date constraint no longer leads, so with
`requirepartition` on, this query would be refused.

**j. Reassembly.** `tree.setc` puts the constraints back into slot 2, and the
by and select slots take their rewritten forms. If the query has a limit or a
sort, `extras` walks the limit with no names in scope. It walks the sort in
the read columns, or with a by in the output columns, and swaps the grade for
`fns.ascsafe` or `fns.descsafe`. `query` returns the node and its output
columns.

The rewritten tree:

```q
(?;`trade;,((in;`account;,`A1`A2);(>;`size;15));(,`sym)!,`sym;(,`size)!,(sum;`size))
```

### 7. Partition check: `partitioncheck`

This is the only check that limits the work before anything runs, and it
applies only when `requirepartition` is on. `scanned` lists each select over a
base table in the *rewritten* tree (`tree.basequeries`) whose constraints
don't prune its partition column (`ord.prunes`: the *leading* constraint is a
movable one that bounds that column on both sides, with `=`, `in` or
`within`). q narrows the partitions it reads only by the constraint that leads,
so `where size=max size, date=d` and even `where sym=`a, date=d` read every
partition, and `where date>=a, date<=b` reads every partition from `a`. A
one-sided range, an embargo's `date<cutoff` included, is open-ended, and
`date<>d` reads all partitions but one. To make the bounding constraint lead,
`order.crank` ranks it ahead of any other constraint on the partition column. Each such table is refused, naming the column it needs:
`full table scan: trade needs a constraint on `date - date=d, date in ds or date within d0 d1`. It is recorded as
`denied`. When the query does bound the column but not first (`buried`), only
the policy filter can have put something ahead of it - `placement` `` `first ``,
or a filter that could aggregate - and the refusal says that instead: no query
can prune that table for that user.

Next, `settle` prepares the tree to run. `pin` computes the value of each
leading partition constraint, when `maxpartitions` is set, so the partitions
counted are the partitions read. Then `fold` merges the leading run of
constraints that compare the partition column with literal data
(`ord.partfixed`) into one: `(in;date;the partitions of .Q.pv they select
together)`. q chooses partitions by the leading constraint alone and tests
any other constraint on the partition column row by row, in every partition
the first one chose. So an embargo, `date<cutoff`, placed after the user's
`date within a b`, would read and test every row from `a` to `b`. Folded,
the query reads only the partitions both allow. Every row of a partition
holds the partition's value in that column, so the result is the same. A
constraint that computes over the column, such as `date=max date`, is not
literal and is left as written, as is a single partition constraint.
`explain` shows the tree before `settle`; `runx` shows it after.

`partitionlimit` applies `maxpartitions` next, whether or not
`requirepartition` is on. For each base query, `partsread` counts the
partitions it would read: all of `.Q.pv` if it doesn't prune, or else the
leading constraint evaluated with the partition column bound to `.Q.pv`.
`date within 0001.01.01 9999.12.31` bounds the column, so it passes
`requirepartition`, and is caught here. Counted after `fold`, an embargo
narrows the count as it narrows the read.

### 8. Evaluate

`eval` runs the rewritten tree. Only the rewritten tree is ever evaluated. If
q signals, the query is recorded as an `error`. The exception is a signal from
one of the run-time symbol checks the walker placed in the tree (`fns.nosym`,
`fnarg`, `castarg`, `fbyarg`, `wjagg`, `findsafe`): its message starts
`qsp: `, and it is recorded as `denied`.

```
sym| size
---| ----
aaa| 30
bbb| 70
```

### 9. Bound the result: `sizecheck`

The result is refused if its serialised size (`-22!`) exceeds `maxsize`, or
if it has more than `maxrows` rows (`rows`): a table's rows, a list's items, or
the longest column of a dictionary or list of columns. It is recorded
as `denied`. The query has already run, so these limits bound what is
returned, not the work done.

### 10. Record: `record`

With `audit` on, `go` appends a row to the audit log with the time, user,
query text, rewritten tree, and decision, then trims the log to its newest
`auditmax` rows:

```
user query                                             decision reason
----------------------------------------------------------------------
llmu "select sum size by sym from trade where size>15" allowed  ""
```

### How a refusal travels

Every check is `tree.chk[condition;message]`, which signals
`'qsp: message`. No check returns a refusal as a value. `go` traps each
stage, and `refuse` cleans the message, records it, and signals it again. The
stage sets the decision:

| stage | trap in `go` | recorded as |
|---|---|---|
| parse | `@[{(1b;toparse x)};...]` | `error` |
| rewrite | `@[tryrewrite[p;u];...]` | `error` if `tree.isfault`, else `denied` |
| partition check | returns a message | `denied` |
| evaluate | `@[{(1b;eval x)};...]` | `error` |
| result bound | returns a message | `denied` |

A **fault** is signalled with `tree.fault`, which starts the message with a
`\001` byte. No denial can start with that byte. `tree.clean` removes it
before anyone sees the message. This marks a fault without setting any state.

`rewrite`, `explain`, `validate` and `fullscans` call `walker.rewrite`
directly. They clean the message but don't record anything, and they stop
after step 6.

## The same steps on other queries

Each output below is `qsp.explain[P;user;query]`, or the refusal it signals.

`select *` becomes the granted columns:

```q
"select from trade"
(?;`trade;,,(in;`account;,`A1`A2);0b;`date`sym`account`size`price!`date`sym`account`size`price)
```

An update over a select runs over the select, which is pinned to the grants:

```q
"update size:0 from select from trade"
(!;(?;`trade;,,(in;`account;,`A1`A2);0b;`date`sym`account`size`price!`date`sym`account`size`price);();0b;(,`size)!,0)
```

A sort is walked, and its grade replaced (step 6j):

```q
"select[5;>size] from trade"
(?;`trade;...;5;,({$[0>type x;'"qsp: a sort must be by a column, not an atom";idesc x]};`size))
```

`<>` is `not` composed with `=`, and `not` is replaced with `notsafe`:

```q
"select from trade where size<>3"
... ((';{$[11h=abs type x;'"qsp: not cannot be applied to a symbol";not x]};=);`size;3)
```

A lambda filter (user `alice`, group `desk`) is called and its result
written in as literals:

```q
(?;`trade;,,(in;`sym;,`aaa`bbb);0b;`date`sym`size!`date`sym`size)
```

A `qsp.USER` lookup (user `carol`, group `call`) stays a call, with the user
as a literal:

```q
(?;`trade;,,(in;`sym;(`allowedsyms;,`carol));0b;`date`sym`size!`date`sym`size)
```

Some refusals, and the step that gives each:

| query | message | from |
|---|---|---|
| `select pnl from trade` | `unknown or not-permitted column: pnl` | `walksym` → `notinscope` (denied) |
| `select price from select sym from trade` | `price is not in scope here - the inner select/update does not project it` | `notinscope` → `tree.fault` (error) |
| `select system "ls" from trade` | `function not permitted: system` | `walkfn` |
| `select from trade where {x} size` | `function not permitted: <unnamed>` | `walkfn`: a lambda is never on the whitelist |
| ``select from `:/tmp/x`` | `file handle symbols are not permitted` | `walker.rewrite`, before the walk |

## Rules the code relies on

Keep these true when you change anything:

1. **Fail closed.** Every handler ends with a refusal for shapes it doesn't
   recognise (`tree.chk[0b;...]`). Add a case for a new shape. Never let an
   unknown shape fall through to `literal`.
2. **Refuse by signal.** Never return a refusal as a value. A caller that
   forgets to check it would run past it.
3. **Match functions by identity.** Parse trees hold function values, not
   names, so the whitelist, never list and joins are compared with `~`. Never
   compare by name.
4. **Read shapes from q.** If code needs to know how q represents something,
   get it from `parse` at load (`core/tree.q`, `core/order.q`) and refuse to load if
   that fails. Don't write the shape out by hand.
5. **Keep a policy a value.** Builders return a new policy, and no query sets
   a global. The audit log and the served policy are the only exceptions.
6. **Change a list only if something changed.** See `walklist` and
   `walkcall`. Rebuilding a general list of symbols turns it into a symbol
   vector, which q evaluates as a call.
7. **Move only movable constraints.** If a constraint's result can depend on
   other rows, moving it changes the answer. The policy filter's place is a
   security property, not only a performance one.
8. **Start private symbols with `\001`.** Markers and sentinels (`agedmark`,
   `gone`, the fault prefix) start with `\001`. A `\000` would truncate the
   symbol to the null symbol.
9. **Resolve markers at rewrite.** The tree that runs holds only literals and
   whitelisted calls, never a reference to qsp, and the audit log records the
   values used.

## Making common changes

A change to what qsp does is documented in [../qsp.md](../qsp.md), the
reference, where each rule is stated once. This page, `concepts.md` and
`setup.md` link to it rather than restating the rule; update them only where
they explain or walk through the change.

| change | where | also |
|---|---|---|
| whitelist a function by default | the `catalog` call that builds `defaults` in `core/fns.q` | `catalog` refuses anything on the never list. Add attack tests for anything it can reach |
| forbid a function outright | `nevernames` in `core/fns.q` (or `operators`, if it has no name) | list it under [What is never allowed](../qsp.md#what-is-never-allowed) |
| guard a primitive by argument type | a wrapper like `notsafe` in `core/fns.q`, added to `subfrom`/`subto` | if the wrapper can appear in a filter, `review.fname` must name it, or `access` shows a lambda |
| let a new head stand in a table slot | `preserve` or `exprcols` in `core/walk.q` | it must keep exactly its input's columns. If unsure, it projects nothing |
| a new query shape | `query` and its slot handlers in `core/walk.q` | if it changes slot positions, detect them in `core/tree.q` |
| a new config setting | `defaultconfig` in `policy/init.q`. `settingok` checks its type | `files.literal` reads it from `config.csv`, and `scaffold` writes its default, with no change needed in either unless it holds a function. Document it in qsp.md's [Configuration](../qsp.md#configuration) |
| a new filter builder | `policy/f.q` | `review.text` must write it back as something `files.filter` reads back. The `access` round-trip test checks this |
| a new policy file | `files` and `applyfiles` in `policy/files.q`, with a `...row` function | `scaffold` should write it. Add it to the file table in qsp.md and setup.md |
| a new message handler | `install` in `init.q` | refuse anything you don't police |
| a new kind of test expectation | `expects`, `rowproblem` and `verdict` in `policy/suite.q` | the `expect` table in qsp.md's [Testing a policy](../qsp.md#testing-a-policy), and `EXPECTS` in `admin/ui/views/tests.js` |
| a new admin UI call | a function taking the page's `args` dictionary, added to `calls` in `admin/init.q` | if it runs a query, run it through `Q` (``Q[`runx]``, ...), never by evaluating text. Add it to the API table in [ui.md](ui.md#the-json-api), and test it through `.z.pp` (`.t.post` in `test.q`) |
| a new admin UI view | a module in `admin/ui/views/` exporting `render(el, ctx)`, returning a cleanup function if it starts timers or listeners, and an entry in `VIEWS` in `admin/ui/app.js` (`always: true` if it works without a policy) | describe it in [ui.md](ui.md) |
| a policy file the admin UI edits | `csvfiles` in `admin/init.q`, and `FILES`, `HEADERS` and `ABOUT` in `admin/ui/views/edit.js` | |

Every change needs tests in `test.csv`, in the section for its area
([testing.md](testing.md) says what each covers). The
sections are marked by `comment` rows. Fixtures and helpers go in `test.q`.
Run the tests with:

```sh
QPATH=${QPATH}:/path/to/kdbx-modules q di/qsp/bin/test.q -q
```

## Debugging

The submodules can be loaded on their own, as `test.q` does, to call their
internals directly:

```q
qsp:use`di.qsp
qt:use`di.qsp.tree; qp:use`di.qsp.policy; qw:use`di.qsp.walk; qo:use`di.qsp.order
qp.columnsfor[P;`llmu;`trade]                 / step 6b
qp.filterfor[P;`llmu;`trade]                  / step 6g
qo.place[qp.info[P;`trade];P`config;qt.getc (parse q) 2;qp.filterfor[P;`llmu;`trade]]  / 6i
qsp.explain[P;`llmu;q]                        / the whole rewrite, as text
qsp.validate[P;`llmu;q]                       / (allowed;reason), without running q
```

The admin UI's handlers can be called in the process, which is how the tests
drive them. `.t.post` in `test.q` does this:

```q
qsp.adminui ([access:`local;port:0;dir:"/path/to/policy"])   / port 0: install the handlers, open no port
.j.k last "\r\n\r\n" vs .z.pp enlist "api ",.j.j `call`args!(`run;`user`query!("llm1";"select from venues"))
.z.ph enlist "views/map.js"                                  / a file of the page, as HTTP
```

In the browser, the developer tools' console shows a view's errors, and the
network tab every `/api` call with its JSON. The page's files are read from
`admin/ui/` on every request, so an edit to one shows on reload, without restarting
q.

`-3!` and `.Q.s1` cut their output to the console width (`\c`). `render` in
`init.q` widens it for the audit log and `explain`. Do the same, or use
`\c 50 2000`, before comparing long trees by eye.

Where the code works around a KDB-X quirk, such as a reserved word that can't
be a dictionary-literal key (`files` in `policy/files.q`) or a `\000` byte that
truncates a symbol (the markers in `core/tree.q`), a comment says so. Read it
before "simplifying" the line.
