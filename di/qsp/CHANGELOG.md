# Changelog

`VERSION` follows semver. While it is 0.x, a minor version may change what a
policy permits; each such change is marked **behaviour**.

## 0.4.0 - unreleased

The contract agenticq builds on: everything an agent's tooling needs from the process that
enforces the policy. Each is general, and an existing client sees no difference.

- **Refusals as data.** `classify[m]` gives a refusal message's `code`
  (`family.reason`, the family the rule that explains it), its `kind`
  (`permission`, `shape`, `limit` or `runtime`) and its `subject`. `validate`
  and `estimate` return them, the audit log records the code, and `codes[]`
  lists them all (`core/codes.q`).
- **Context.** A gateway may send a dictionary as a fourth item of an execas
  form: `session`, `turn`, `question`, `model`, `client`, and for a query an
  agent's tooling corrected, `original` and `fixes`. It is checked, recorded in
  new audit columns, and never interpreted. A user's own login may not send it.
- **Receipts.** `(`.qsp.execasr;q;u)` returns a dictionary - `status`,
  `result`, `rewritten` and a signed `receipt`, or the refusal as data - and
  `runr` does the same in process. HMAC-SHA1 in q, tested against RFC 2202, with
  a key ring (`receiptkeys`, `newreceiptkey`, `reloadkeys`): the newest key
  signs, every key verifies. Receipts are kept (`receiptcells`, `receiptmax`)
  and returned only to their user and gateway; api calls `verify`, `receipt`,
  `reloadkeys` (`receipt/`).
- **Gateway scope.** `gateways.csv` gains `users`, a group: the gateway may name
  only its members (`scopegateway`). Naming anyone else is `users.outofscope`.
- **Asynchronous requests.** `neg[h] (`.qsp.async;id;msg)` is handled as if
  synchronous and answered with `(`.qsp.reply;id;(ok;value or refusal))`.
- **Parameterised terms.** `terms.csv` gains `params` and `example`;
  `termquery`/`runterm`, and the api call `term`, fill a term's `{name}`
  placeholders with typed arguments, never text. `checkterms` runs each with
  its example.
- **`mingroup`** (`tables.csv`, `mingroup`): with `strictcolumns` off, an
  aggregate that tests a hidden column must summarise at least this many rows
  per output row, or the group is suppressed. Other queries that test a hidden
  column of such a table are refused (`rows.mingroup`).
- **`agentgroup`** and `agentlint`: `bin/policy.q` warns when agent users can
  test hidden columns. **`exportgroup`**: `describe` reports `export`.
- `totext`, the q-SQL renderer, exported for clients that build parse trees.
- **An MCP server in q** (`mcp/mcp.q`, run by `mcp/qsp-mcp`): qsp's calls as an
  agent's tools over stdio, bound to one user or in demo mode, and a Claude Code
  skill (`skill/qsp/SKILL.md`). No Python.
- **behaviour**: `validate`'s dictionary has three more keys, and the audit log
  eleven more columns. A policy that registers the audit log as a table needs
  them in its `schema.csv`, as the example's has.

- Clearer refusals for two mistakes agents make. A column a nested select
  names, read in the outer query, whose name is also a global on the server
  was refused as `unknown or not-permitted column`; it now says the name is
  taken and to rename it (still a denial; an alias that shadows nothing runs,
  so this tells the caller nothing new). An outer `where` written after an
  unparenthesised nested select, which q reads as part of its last
  constraint, is now `a where after a value: ...` rather than `expression head
  is not a function`. A new `nesting` rule and primer entries cover both.
- `examples/equities/mkhdb.q` keeps its helpers in `.mk`: the example servers
  carried root globals named `px`, `fill`, `base` and `tick`, and an agent
  aliasing a column `px` was refused.
- `precheck` (config, `0b` by default): `run` estimates a query first and
  refuses one whose result cannot fit `maxrows` or `maxsize` before doing the
  work - `qsp: too big to run: ...` with what to change - rather than after.
- `terms.csv` in a policy directory: the business's own terms - `term`,
  `meaning`, and optionally `formula`, an example query `q`, the `tables` it
  needs and a `caveat`. `describe` returns the terms whose tables a user can
  read, so a definition never shows a hidden table, and `qsp.checkterms` (run
  by `bin/policy.q`) refuses a term whose example the policy would not run as
  any user who can read its tables. `qsp.term` builds one in q, and `scaffold`
  writes an empty `terms.csv`. The equities example defines six; the
  surveillance database's policy carries the surveillance agent's 38.
- `(`.qsp.api;`brief)`: `describe` without the rules and the function
  whitelist, which an agent holding the primer has, with their versions.
- `(`.qsp.api;`history;n)`: a user's own last `n` decisions, from the audit
  log.
- `maxqueries` (config): most queries one user may run in a minute; `0W`, the
  default, is no limit.
- `estimate` also advises when one side of a join reads more than a hundred
  times the other: usually that side unfiltered.
- `describe` gains `shape`: for each table a user may read, the partitions
  they can see, the first and last of each time column, and the values of
  each symbol column with 20 or fewer - computed as the user, so a filter or
  an embargo shows, with no audit record, cached for a minute. An agent no
  longer spends queries finding which dates exist or what `side` holds.
- The agent example's `query` returns JSON (`client.q -json`): what ran, the
  full row count, the columns and types, the first 100 rows, and whether
  those are all of them, rather than a printout cut to the console.
- **behaviour** `explain`, `runx` and a gateway's (or a user's own)
  `.qsp.execasx` show what ran as q-SQL - `select date, sym, size from trade
  where sym in allowedsyms[`carol]` - not the parse tree. The text is used
  only when parsing it gives back the tree that ran, checks aside; otherwise
  the parse tree, as before. The admin UI's renderer moved to `core/qsql.q`,
  shared, and no longer cuts long literals short, prints `!` as `lsq`, or
  reads a pivoting `exec ... by` as a select. The audit log keeps the parse
  tree.
- `qsp.estimate` (and `` (`.qsp.api;`estimate;...) ``): how big a query is
  before it runs. For each table it reads, the rows its rewritten where
  clause selects - counted as the user, so a count never includes rows the
  row filter hides - and their bytes, from `schema.csv`'s measured sizes; the
  result's rows and bytes; the limits; a verdict (`fits`, `large`, `toobig`,
  `refused`) and what to change. `describe`'s `limits` gain the timeout and
  memory cap, which every user may now know. The primer has a sizing
  section, and the rules point to `estimate`.
- `schema.csv` takes two optional fields, `bytes` and `description`: a
  column's size per row as `-22!` counts a result, and what it means. A
  four-field `schema.csv` still loads. `scaffold`, the admin UI's schema sync
  and `bin/policy.q -measure` (`qsp.remeasure`) measure `bytes` from a sample
  of the latest partition, read by row index; a resync keeps descriptions.
  `describe` returns both for each granted column, so an agent can size a
  query - rows times bytes - before it runs it. `qsp.measure` and
  `qsp.colinfo` do the same in q. The equities example's policy is measured
  and describes its less obvious columns.
- **behaviour** Refusals say what to change, for the mistakes LLM agents make
  most (measured on the surveillance question set):
  - a column named after a q function: q's parser says only `'assign`;
    qsp now names it - `not valid q (assign): fills is a q function, so it
    cannot name a column - rename it`;
  - a dotted temporal part - `time.minute`, `time.hh`, `date.year` - is now
    accepted, rewritten to q's cast of that name; a part q does not have is
    named, with the ones it does;
  - q's extractions `` `hh$ ``, `` `uu$ ``, `` `ss$ ``, `` `mm$ ``, `` `dd$ ``,
    `` `year$ `` and `` `week$ `` are accepted as casts, like a type name:
    a global of the same name does not change them;
  - an iterator applied by its glyph (`+\:`) and a list applied as an index
    are named instead of `<unnamed>` and `<not a function>`;
  - a keyed join (`aj`, `aj0`, `ej`, `wj`, `wj1`) on a key one side lacks is
    refused before it runs - q does not fail fast, and one ran until the
    timeout;
  - q's `stop` (the `-T` timeout) and `wsfull` (`-w`) say what they mean and
    what to narrow.
  `validate` (and `` (`.qsp.api;`validate;...) ``) returns the `rule` whose
  refusal text the reason contains, the most specific one, so a caller goes
  from a refusal to its rule's examples. The rules gain a `size` rule (the
  timeout and memory cap) and say how to name and join columns.
- A user's own login may send `` (`.qsp.execasx;q;self) `` (or `.qsp.execas`)
  naming itself, and gets what ran with the result, as a gateway does. An agent
  bound to one user - the agent example's default, `agent.sh -u USER` - logs in
  as that user and still sees the rewrite. Naming anyone else from a login that
  is not a gateway is refused, as before.
- `qsp.api.primer` (and `` (`.qsp.api;`primer) ``): how to write q that qsp
  accepts, as one markdown text for an LLM agent to hold in context before
  its first query - a method, the q that matters, the shapes qsp takes, the
  names a column cannot have, time-series techniques, and a table of what
  each refusal means. It is `api/primer.md`; the equities walkthrough runs
  every q example in it. The agent example's `agent.sh` puts it in the
  system prompt.
- **behaviour** `validate` (and `` (`.qsp.api;`validate;...) ``) now makes
  every check `run` makes before it evaluates a query: `requirepartition` and
  `maxpartitions` as well as the rewrite, refusing with `run`'s message. It
  used to stop after the rewrite, so it called a full table scan, or a range
  of more partitions than `maxpartitions` allows, allowed. To count
  partitions it evaluates the value of a leading partition constraint, as
  `run` does; it still records nothing. `maxrows`, `maxsize` and checks on
  values a query computes still need the query to run.
- The agent rules (`qsp.api.rules`) point to the other calls where they help:
  `validate` for the partition checks and refusals, `explain` for the row
  filter, the `functions` call for the whitelist, and each rule's `refusal`
  text for matching a refusal to the rule that explains it.
- **behaviour** A symbol on either side of `#` or `_` is no longer refused.
  q never reads one as a global's name there - `3#`t` is `` `t`t`t ``, and
  `` `a#`t `` and `` `a _ `t `` are type errors - so the check refused
  queries without protecting anything: `30#`MSFT`, which an LLM writes to
  build a grid of minutes, and `d _ `k`, which drops a key. Found by replaying
  the surveillance agent's 739 recorded queries against this version: these
  were the only ones it allowed before and refuses now.
- **behaviour** Leading constraints that compare a partition column with
  literal data are merged into one before the query runs: `date within a b`
  followed by an embargo's `date<cutoff` runs as `date in` the partitions
  both allow. q chooses partitions by the leading constraint alone, so the
  embargo used to be tested row by row in every partition of the range: on
  20 partitions of 2M rows, 5 to 7 times slower than the merged query, with
  33 to 67 MB more memory. The rows returned are unchanged. `maxpartitions`
  now counts the merged list, so a range the embargo narrows under the cap
  is allowed where it was refused. `explain` still shows the query before
  the merge; `runx` and the admin UI's What ran show it after.
- `bin/ci.sh` runs every test qsp has in one command, for CI: the unit
  tests, the example's walkthrough and its policy's tests, `bin/policy.q
  -test`, the admin UI's endpoint check and the hardening campaign. It runs
  them all, keeps each one's log, and exits 1 if any failed.
- `bin/harden.sh` runs no checks until both its servers are listening. A
  server that will not start is retried on new ports, below the ephemeral
  range, and after five tries the run stops with its log; the servers' logs
  are kept beside the report. A server that failed to start used to fail
  every check with "connection failed", and leave no log saying why.
- Layout: the submodules are grouped in directories, as other modules lay
  theirs out. `core/` (`tree`, `fns`, `order`, `walk`) checks and rewrites a
  query; `policy/` (`init.q`, `f`, `files`, `review`, `suite`) is the policy
  and what is done with it; `api/` and `admin/` (with the page, now
  `admin/ui/`) are directory modules. `testserver.q` is `test/server.q` and
  `setup.md` is `docs/setup.md`. `` use`di.qsp `` and everything it exports
  are unchanged. The submodules `di.qsp.tree`, `fns`, `order` and `walk` are
  now `di.qsp.core.*`, and `f`, `files`, `review` and `suite` are
  `di.qsp.policy.*`; `di.qsp.policy`, `di.qsp.api` and `di.qsp.admin` keep
  their names.

## 0.3.0 - 2026-11-13

- New: a policy's own tests. `tests.csv` beside the policy holds queries, the
  users they run as, and what qsp must do: return rows, none, either, refuse
  (with text the refusal contains), or return exactly a q literal.
  `qsp.tests`, `qsp.checktests` and `qsp.runtests` read, check and run them;
  `bin/policy.q -test` runs them for CI and fails the build on a failure. The
  example's walkthrough is now its `tests.csv`, and the explorer has a Tests
  view, "+ test" to collect new ones, and What-if runs them against an edit.

- New: `qsp.adminui`, a web page for writing, testing and exploring a policy,
  served by any process with data loaded (`` `local ``, `` `public ``, `` `stop ``,
  or a dictionary of access, port and dir). It sets a policy up - creating it
  from the loaded tables or opening a directory - and edits it, with forms for
  grants and memberships, a preview (`qsp.check`, `qsp.diff`, the tests), and
  save. It maps who reaches what, lays each user's view over a table's real
  rows, runs q as any user with the rewrite shown, generates probes, runs the
  policy's tests, and shows the files with the defining lines lit. It answers
  this machine only unless `` `public ``, and refuses a process serving a
  policy. The example's `demo.q` opens it; `setup.q` is what it and `hdb.q`
  share.

- **behaviour** A query runs only as a user of the policy: a name in
  `members` or `grants` that isn't a group. `run`, `runx`, `rewrite`,
  `explain`, `validate` and `fullscans` refused nothing about `u` before, so
  `qsp.run[p;`nobody;q]` ran any query that read no table, a group's name ran
  with the group's grants, and `` `a`b `` ran with both users' grants. The
  served process already turned such logins away at `.z.pw`; now the
  in-process entry points do too, with `qsp: not a user of this policy`,
  recorded as `denied`. A gateway login sending a query as itself gets the
  same refusal.
- **breaking** Every `qsp.api` call takes a format last, `` `q `` or
  `` `json ``: `qsp.api.describe[p;u;`json]`. Over IPC the format is optional
  and follows the arguments. `` `json `` is the same content as one JSON
  string, with `0W` and null symbols as `null`.
- **breaking** `qsp.api.rules` is a table written for an LLM agent: each rule
  with its reason, queries it accepts and refuses, and the text of its
  refusal. It covers q's right-to-left precedence, comparisons, iterators,
  computed symbols, joins, sorting and `exec` on a partitioned table, and how
  to read a refusal, as well as the config. `examples/equities/hdb.q` runs
  every example.
- **breaking** `describe` gives column types by name (`` `date``,
  `` `char[]``) rather than as type characters, and the api's `validate`
  gives `([allowed;reason])` rather than `(allowed;reason)`.
  `qsp.validate` is unchanged.
- New over IPC and on `qsp.api`: `rules`. New on `qsp.api`: `version`,
  `access`, `validate` and `explain`, matching the IPC calls.

Security fixes, from a third review (see
[docs/security-review.md](docs/security-review.md#third-review-13-nov-2026)):

- No atom may be applied. q applies an int as a handle: `` (0+0i)"text" ``,
  `` 0 each enlist "text" `` and `` '[first;0i]"text" `` evaluated text
  unpoliced, and a negative handle wrote to stdout or stderr. A literal is
  checked as the tree is walked, whatever applies it.
- Data that q applies may hold no function but the pure ones, at any depth: a
  list, dictionary or column is indexed at depth and applies the function it
  reaches. `` (each;count)[0;`f;x] `` called any function, and
  `` (?;count)[0;`t;();0b;()] `` read any table.
- `wj` and `fby` refuse an aggregation pair written as symbols, `` `f`c ``,
  which q applies by name; `wj` refuses a symbol for its table.
- A select written as a tree may not use `` `symbol$() `` or an empty
  dictionary as its select or by clause: q reads either as every column. A
  delete's column list is a delete's only, so `` enlist `f`c `` in an exec is
  walked as the call it is. A delete names granted columns only.
- **behaviour** An exec projects columns to a select over it only when it is a
  table: with a named by, and named columns or a pivot. `` `a`b!t `` projects
  nothing, as it is a dictionary; `n!t` and `k!v` still do. A name the result
  did not carry resolved to a global - on an HDB, `sym` is the enum domain.
- A select written as a column, `select x:(count select from t) from u`, or
  in a by clause, is a read like any other: `requirepartition`,
  `maxpartitions` and `fullscans` see it, and file handles are refused inside
  select and by clauses.
- `maxpartitions` computes the leading partition constraint once, and the
  query reads exactly the partitions counted. A constraint that need not give
  the same answer twice, `1?2` say, could select one partition to count and
  every partition to read.

Fixes, from the same review:

- `qsp.f.eq[c;qsp.USER]` compared the column with a one-item list, and every
  query under the grant failed with `length`. `qsp.USER` in a symbol list,
  `qsp.f.isin[c;(qsp.USER;`x)]`, made a mixed list and failed with `type`. A
  marker in a filter's constants is now a value; as a call's argument,
  `` `deskof`qsp.user ``, it is still quoted.
- `access` (and `diff`, and the api's `describe`) write every row filter as q
  that parses: `enlist `a` rather than k's `,`a`, a list of strings rather
  than `refused: type`, and the user rather than the marker's raw bytes.
- `raze`, `sums`, `any`, `all`, `deltas`, `prev` and the other iterator-derived
  functions on the pure list may be applied by `each` and the like; they were
  refused for being derived.
- `` `a _ d `` and `` `c # d ``: `#` and `_` take a key or column list first, and
  never read a table by the name on their right.
- `$[`int]`, `$` projected on a type, is refused for what it is rather than
  with `length`.
- **behaviour** With `selectonly` off, an update or delete straight onto a
  partitioned table is refused. q signals `par` for it, and qsp's rewrite read
  every partition.
- `select` by every column the user can see, which q signals `rank` for, is
  refused with a message that says why.
- A gateway forwarding a query that is one name, `` (`.qsp.execas;`sym;`u) ``,
  is a gateway call: q stores that message as a symbol vector.

## 0.2.0 - 2026-11-13

Security fixes, from the hardening campaign and two reviews
(see [docs/security-review.md](docs/security-review.md)):

- A symbol a query computes is checked wherever q would resolve it as a
  global: applied, or handed to `each`, `?`, `$`, `!`, the joins, `xasc` and
  the rest. Before, `(`$"secret")`col` read any table, and iterators, `fby`
  and functional exec could call any function.
- A function quoted in a one-item list, or anywhere else in literal data, is
  refused. `(each;enlist value;...)` sent as a tree ran `value`.
- **behaviour** A functional form whose clauses are code that builds them,
  `?[t;();0b;(enlist`x)!enlist(f;`col)]`, is refused: the walker checked the
  code, q ran what it built, and a column the user was not granted was read.
  Write it as select; a functional form with plain-data clauses still runs.
- **behaviour** `~` is never moved ahead of the row filter, and a comparison
  moves only with one value on its right. Both leaked: what a hidden row
  holds, and how many hidden rows there are. A computed list on the right of
  `=`, `<` and the rest is refused (`use in for a list`).
- **behaviour** A filter function's empty result refuses the query. It used
  to mean every row, so a lookup that did not know the user opened the table.
  Return `qsp.ALL` for every row.
- An update or delete's where clause sees only the granted columns, whatever
  `strictcolumns` says; it runs over the pinned select.
- A row filter that is an and, or, or not of comparisons (`f.notin`,
  `f.both`, `f.either`, a user in two filtered groups) no longer forces itself
  ahead of the user's date constraint.
- Within a rank, the policy's constraints sort ahead of the user's however
  many the user writes.
- A constraint whose expression reads a column through its head,
  `sym=(sym where time=min time)[0]`, is no longer moved ahead of the row
  filter, where it saw hidden rows.
- `.z.pm` (HTTP methods other than GET and POST) is refused, and console input
  from a remote handle (qcon) is policed.

Partitions:

- **behaviour** `requirepartition` needs a constraint that bounds the
  partition column on both sides (`=`, `in`, `within`) and leads. A one-sided
  range, an embargo's `date<cutoff` included, no longer counts, and `~` does
  not.
- New `maxpartitions` setting: refuse a query that would read more
  partitions than this, counted against `.Q.pv` before it runs.
- The refusal names the real cause when the row filter has to lead.

Serving and the API:

- `serve` keeps the message handlers it found and evaluates the rewritten
  query through them, so a query log or client tracking loaded first still
  sees every policed query. `unserve[]` puts them back.
- New `qsp.api`, served over IPC as `` (`.qsp.api;name;...) ``: `version`,
  `limits`, `memstats`, `users`, `functions`, `access`, `describe` (one
  user's tables, columns, types, row filters, functions and rules, for a
  query generator), `validate`, `explain`. `` `.qsp.limits `` answers as it did
  in the original qsp.
- `maxrows` applies to lists and dictionaries of columns, not only tables.
- A gateway naming a user that is not a symbol is refused, and logged.

Files:

- New `schemadrift[dir]`; `fromfiles` warns when `schema.csv` and a loaded
  table disagree.

Tests: `bin/test.q` fails when no tests ran. `bin/harden.sh` checks results
against a hand-written model of the policy and exits non-zero on a failure.

## 0.1.0

The original qsp, restructured as a KDB-X module.
