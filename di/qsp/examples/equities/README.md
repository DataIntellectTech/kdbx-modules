# Example: a policed equities HDB

A small equities execution database, a filled-in policy for it, and a
walkthrough of what each role can and can't read.

```sh
q di/qsp/examples/equities/hdb.q                          # build, walk through, then exit
q di/qsp/examples/equities/hdb.q -p 5100                  # ...then serve it
q di/qsp/examples/equities/hdb.q -db /path/to/db -p 5100  # build or reuse a database there
```

Without `-db`, the database is built in `qsp-example-db` under `$TMPDIR`, or
`/tmp` if that isn't set. It is built once and reused after that. Keep it
outside `di/qsp/`, since the module directory is copied as a unit.

## Files

| file | what it is |
|---|---|
| `mkhdb.q` | Builds the HDB: `trades`, `quotes`, `orders` and `depth` partitioned by date and parted by `sym`, and `accounts`, `instruments`, `traders` and `venues` splayed. Five days, a few thousand rows a day, the same data every run. `q mkhdb.q -db DIR [-days N]` builds one on its own. |
| `policy/*.csv` | The policy, as CSV files: five roles, a reference-data group nested in four of them, seven users and a gateway login. |
| `policy/defs.q` | The q the policy names: the lookups its filters call, and its clock. It sits with the CSVs so a change to it is reviewed with the grants that call it. |
| `hdb.q` | Builds the HDB if `-db` doesn't exist, then loads it, `policy/defs.q` and the policy. It prints who can read what and runs each role's example queries. Every step says what it should do: return rows, return nothing, or be refused. The script exits 1 if any step doesn't, so it is also a test. |

## The roles

| role | users | can read |
|---|---|---|
| research | `llm1` | trades and quotes for four technology names: price, size and side, no account, trader or venue, and nothing from the two most recent days (`qsp.aged[date;2D]`) |
| quant | `quant1` | all market data, every name, including depth of book. No account or trader |
| sales | `sales_na`, `sales_emea` | their region's clients: those accounts' trades, orders and client details. No trader |
| desk | `cash_head`, `etf_head` | their own desk's orders, its traders' fills, and its traders |
| compliance | `compliance1` | everything, including qsp's audit log |

Every role but compliance is also in `refdata`, which grants `instruments`
and `venues`.

The sales and desk filters call functions defined in `policy/defs.q`
(`coveredaccounts`, `deskof`, `desktraders`). Those functions look the user
up in two small tables, `coverage` and `deskheads`, on every query. Change a
row in one of those tables and that user's next query sees the change, with
no reload.

The data is fixed in October 2026, so `defs.q` also fixes the policy clock
(`clock,fn:exampleclock` in `config.csv`) at the morning after the last day.
Against the real clock every row would be old, and the embargo would hold
nothing back. This is for the demo only: a real policy leaves the clock
alone, so delete both lines before you reuse this policy.

## Loading it in your own process

`qsp.fromfiles` reads only the CSVs. It never loads q, so load `defs.q`
yourself first. Load the database before it, since the lookups read
`accounts` and `traders`:

```q
\l /path/to/qsp-example-db
\l /path/to/di/qsp/examples/equities/policy/defs.q
qsp:use`di.qsp
qsp.serve qsp.fromfiles "/path/to/di/qsp/examples/equities/policy"
```

Or copy `defs.q` into the database root: `\l` on a database also loads the
`.q` files in it. If you do this, treat the copy as a deployment step from
the reviewed policy directory. Anyone who can write to the database could
otherwise change what every filter returns.

CI checks the policy without the data, from `schema.csv`, with the same
definitions:

```sh
q di/qsp/bin/policy.q -dir di/qsp/examples/equities/policy -init di/qsp/examples/equities/policy/defs.q
```

With `-p`, connect as any user in `policy/members.csv`, or log in as
`gateway` and send `` (`.qsp.execas;query;user) ``. The console isn't
policed: try `qsp.run[p;`llm1;"..."]` and `qsp.explain[p;`llm1;"..."]`
there. `qsp.active[]` returns nothing until `qsp.serve` has been called.

## Queries that surprise people

| query | what happens | write instead |
|---|---|---|
| `select[100] from trades where date=2026.10.09` | `'nyi`. q itself doesn't support `select[n]` on a partitioned table. | `100 sublist select from trades where date=2026.10.09` |
| `select from trades where date=last date` | refused: `full table scan: trades needs a constraint on `date`. `requirepartition` is on, and qsp can only tell a constraint prunes partitions if it compares the date with a value that names no column. | a literal date: `where date=2026.10.09` |
| `select from trades where sym=`AAPL` (as `quant1`) | refused for the same reason. It would read every partition. | add `date=...` or `date within ...` |
| `select from trades where sym=`AAPL` (as `llm1`) | allowed. The research embargo is itself a date constraint, so it prunes the partitions. | |
| `select n:count i by sym from quotes where date=...` | refused: `i` is off unless the policy sets `rowindex`. | `count sym` |

`qsp.explain` shows what would run, but it stops before the partition check.
Use `qsp.fullscans[p;user;query]` to see which tables a query would read in
full.

## Starting your own policy from this one

Copy `policy/` to where your team keeps its policies, delete the clock row
from `config.csv` and `exampleclock` from `defs.q`, and follow
[setup.md](../../setup.md).
