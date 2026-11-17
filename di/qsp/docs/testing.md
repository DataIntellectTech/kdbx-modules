# Testing qsp

This page is for developers changing qsp, and for CI. A policy's own tests -
`tests.csv`, run with `bin/policy.q -test` - are in
[Testing a policy](../qsp.md#testing-a-policy) instead.

## Running everything

`bin/ci.sh` runs every suite below, in one command:

```sh
di/qsp/bin/ci.sh [-o OUTPUT_DIR]    # default di/qsp/ci-output
```

It builds the example HDB once, then runs the unit tests, the example's
walkthrough (`hdb.q`), `bin/policy.q -test` on the example's policy, the admin
UI's endpoint check (`demo.q -check`) and the hardening campaign. Every suite
runs even if one before it failed, so one run shows everything broken. It
prints a pass or fail per suite, keeps each suite's output in
`OUTPUT_DIR/<suite>.log`, and exits 1 if any suite failed. It takes about
10s. It needs `q` on `PATH` and, for the unit tests, `di.k4unit`: run it from
a kdbx-modules checkout, or put one on `QPATH`.

```sh
QPATH=$QPATH:/path/to/kdbx-modules di/qsp/bin/ci.sh
```

## The suites

qsp has two suites of its own, and CI should run both, the unit tests first:

| | `bin/test.q` (k4unit, `test.csv`) | `bin/harden.sh` |
|---|---|---|
| asks | does each piece of qsp do what it says? | does the example deployment hold against a hostile client? |
| against | small fixtures in process, and one IPC server (`test/server.q`) | a fresh 5-day equities HDB served with the example policy over IPC |
| covers | the whole API, including policy files, policy tests, the admin UI's handlers, `access`, `diff` and the CLI | what a client can reach: grants, logins, limits, audit, attacks |
| takes | about 2.5s | about 10s |
| exits | 1 if any test fails | 1 if any check fails |

A fix belongs in both: a unit test pins it on the smallest data that shows it,
and a harden check proves it holds in a real deployment.

The example adds two more, which CI can run against its HDB:
`examples/equities/hdb.q` exits 1 if any of the policy's own tests
(`policy/tests.csv`, see [Testing a policy](../qsp.md#testing-a-policy)) or the agent
rules' examples go other than expected, and `examples/equities/demo.q -check`
calls each of the admin UI's endpoints and exits 1 if one answers wrongly.
Your own policy's tests run with `bin/policy.q -test`.

## Unit tests

The unit tests are k4unit tests in `test.csv`, as every kdbx-modules module has. With
kdbx-modules on the search path:

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.qsp
```

or, for CI, `bin/test.q` runs them and exits 1 if any fail:

```sh
QPATH=${QPATH}:/path/to/kdbx-modules q di/qsp/bin/test.q -q
```

Most of the assertions cover enforcement, against the
in-process API and a real IPC server with a gateway login (`test/server.q`):

| Area | Covers |
|---|---|
| the policy value | builders return new policies, config refuses typos, refresh, revoke, unmember, droptable |
| rows and columns | `select *`, aggregates, exec, by, nested selects, updates over selects, joins, `fby`, `distinct` |
| the attack surface | 41 attempts to reach hidden columns, other tables, globals, the filesystem, handles, assignment and `eval`, each refused, with checks that nothing ran or changed |
| symbols computed at run time | a computed symbol applied, handed to `each`, `over` or `fby`, or used to read, sort or enumerate a global; a computed file handle; non-pure functions under an iterator, a composition or a computed head; and the legitimate forms that must still run (`` `int$x ``, `?[c;`a;`b]`, `` `size xdesc ``, `cols select ...`) |
| sorts and limits | `select[n;>c]`: hidden columns, functions and atoms in a sort are refused. A sort over a `by` uses the output |
| more query shapes | delete, exec pivots, take and key, `reverse` `sublist` `xcols` `xcol`, every join, subqueries in where, the never list, `rowindex` |
| entitlements and resolution | lambda filters, `USER` lookups, failing lookups, several groups at once, an aggregating policy filter |
| a partitioned database | constraint ordering by partition and attribute, `placement`, aged filters, `NOW`, `fullscans`, `requirepartition` (a partition constraint that does not lead, `date<>d`, a one-sided or split range, an embargo with no date of its own) |
| the audit log and serving | every decision kind, `auditto`, gateways, logins (`.z.pw` refuses unknown names and group names, and keeps a `.z.pw` defined before `serve`), a gateway naming a non-user, a string or a list of users, async, HTTP GET and POST (401 without a known user), websockets, policy swap |
| who a query runs as | a name the policy doesn't know, a group's name, a list of names or a string, refused by `run`, `rewrite` and `validate` as well as at login |
| values q applies | an int applied as a handle, data holding a function indexed at depth, a symbol pair to `wj` or `fby`, select and by clauses built by hand, a select written as a column, a partition constraint computed twice |
| the api | each call in process and over IPC, in `` `q `` and `` `json `` (infinities and null symbols as null), the format told apart by position, the agent rules following the config |
| a policy's tests | every kind of expectation and each failure, `equals` on enumerated symbols, a malformed `tests.csv` with every problem by line, tests not recorded in the audit log |
| the admin UI | its handlers in process: open, run, a refusal, a test, preview, save, create from the loaded tables, the page's files and nothing else, refusing a process that serves a policy, and stop putting the handlers back |

The rest cover policy files, scaffold, access, diff and `bin/policy.q`,
including every way a policy directory can be wrong:
- **The directory and files:** missing, empty, a file where a directory should
  be, misspelt or wrongly-cased file names, unreadable, binary garbage, and
  20 runs of random bytes.
- **How the CSV is written:** Windows line endings, a UTF-8 byte order mark,
  quoted cells, short and long rows, padded rows, and unterminated quotes.
- **What the rows say:** every row-level mistake in each file, every filter
  form and every bad one, and a failed reload that leaves the served policy in
  place.
- **Examples:** `examples/equities/hdb.q` builds its HDB and every one of its
  policy's tests passes, and `examples/equities/policy/` loads with no data,
  given its `defs.q`.
- **Scale and tools:** a 2000-grant, 5000-member policy, a scaffold
  round trip, a scaffold refused inside a database (date, int, splayed and
  segmented, and a relative path from an HDB's working directory), the property that every filter `access` shows loads back as the
  same filter, and the CLI's exit codes.

## The hardening campaign

`bin/harden.sh` builds the example HDB in a temporary directory, serves it with
the example policy (plus harmless canaries: a planted function, an unregistered
table, a marker file), and attacks it over IPC as each of the example's users:

```sh
di/qsp/bin/harden.sh [-o OUTPUT_DIR]    # default di/qsp/harden-output
```

It writes `results.csv` and `report.md`, with every failure detailed, and
the two servers' logs, `server1.log` and `server2.log`. It runs no checks
until both servers are listening. A server that exits at startup (a port
already taken, say) is retried on new ports, and after five tries the run
stops with its log and exits 1. The checks are in five suites: `permissions`, `logins_transport`, `limits`,
`audit` and `attacks`. An attack passes only if the canary function did not
run, no file was created or deleted, and no secret value came back.

The expected results are never taken from qsp. The queries checked against a
value are in `bin/harden/cases.q`, each written once. `bin/harden/mkexpected.q`
runs each one, unchanged, in a process that never loads qsp. It runs them over
each user's view of each table, written by hand from the policy's spec. To add
a case, add a row to `cases.q` and a `check_case` (or `check_gw`, through the
gateway) to `bin/harden/runner.q`. If a case reads a table the user has no view
of, `mkexpected.q` fails rather than producing an empty expected result.
[docs/security-review.md](security-review.md) records what the campaign
found and how each finding was fixed.

