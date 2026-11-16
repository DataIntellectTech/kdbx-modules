# Changelog

`VERSION` follows semver. While it is 0.x, a minor version may change what a
policy permits; each such change is marked **behaviour**.

## Unreleased

- **behaviour** A symbol on either side of `#` or `_` is no longer refused.
  q never reads one as a global's name there - `3#`t` is `` `t`t`t ``, and
  `` `a#`t `` and `` `a _ `t `` are type errors - so the check refused
  queries without protecting anything: `30#`MSFT`, which an LLM writes to
  build a grid of minutes, and `d _ `k`, which drops a key. Found by replaying
  the surveillance agent's 739 recorded queries against this version: these
  were the only ones it allowed before and refuses now.

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
