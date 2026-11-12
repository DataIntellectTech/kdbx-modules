# Setting up permissions for a team

This walks a team from a running q process with no permissions to a policed
one. The policy is kept as CSV files, so it is edited in a spreadsheet,
reviewed in a pull request, and checked in CI. You need to know q to set up
the process. You do not need q to read or change who can see what.

The worked example throughout is `examples/equities/policy/`, the policy for a
small equities HDB. To see it working, run `q di/qsp/examples/equities/hdb.q`.
That builds the HDB, loads the policy, and shows what each role can and can't
read. See [the example's README](examples/equities/README.md). To start from it
rather than from a scaffold, copy the directory to where your team keeps its
policies.

## What you are deciding

For every table, three things:

1. **Who.** Users, gathered into groups. Grant to groups, not to people.
2. **Which columns.** Anything not listed is invisible. A query that names it
   is refused, and `select from t` returns only the visible columns.
3. **Which rows.** A where clause, added to every query on that table. Leave
   it empty for all rows.

Everything you don't grant is refused. You never write a deny rule.

## 1. Scaffold from the process

Start the process with its data loaded (an RDB, an HDB, or a gateway with its
tables). Then, from its console, scaffold into the directory where the team
will keep the policy, usually a checkout of the repository that reviews it:

```q
qsp:use`di.qsp
qsp.scaffold["/path/to/policies/hdb";`]   / ` for every table, or a list: `trade`quote
```

Give an absolute path. A relative one is relative to the process's working
directory, and an HDB's working directory is the database itself. q loads
every directory in a database as a table, so a policy directory there would
stop the database loading (`'parse` on its first CSV). `scaffold` refuses to
write into a database or a partition of one, and says which. If an older
version wrote one there, move it out before restarting the HDB.

The policy doesn't belong in the module's directory either. That directory is
code: an upgrade replaces it, and every process that loads the module shares
it.

This writes the policy directory:

| file | holds |
|---|---|
| `tables.csv` | every table, and its partition column |
| `schema.csv` | every column, with its type and attribute, so the policy can be checked without the data |
| `grants.csv` | one row per table listing **all** its columns, with the entity left blank |
| `config.csv` | every setting at its default |
| `members.csv`, `gateways.csv`, `functions.csv` | headers only |

The scaffold grants nothing. A grant row with a blank entity doesn't load, so
someone has to fill it in or delete it. `scaffold` never overwrites an
existing policy.

Keep one policy directory per kind of process. An RDB and an HDB hold
different tables, so each gets its own scaffold.

## 2. Decide the groups

[docs/concepts.md](docs/concepts.md) explains users, groups, grants and how
they combine, in more depth than this guide.

Before touching `grants.csv`, write down the groups and what each one is for.
In the example:

| group | for | sees |
|---|---|---|
| `research` | an external analyst, or an LLM | prints and quotes for four names, no account or trader, nothing from the last two days |
| `quant` | quant research | all market data and depth of book, no client or trader |
| `sales` | salespeople | their region's clients: those accounts' trades, orders and details. No trader |
| `desk` | desk heads | their own desk's orders and its traders' fills |
| `refdata` | every role but compliance | instruments and venues |
| `compliance` | compliance | everything, including qsp's decision log |

A user in several groups gets the **union** of their columns and the **OR** of
their row filters. Two narrow groups can therefore add up to something wider
than either. If a user must see only the overlap of two groups, make a third
group for exactly that.

## 3. Fill in grants.csv

```
entity,tbl,columns,filter
# research: four names, no account or trader, nothing from the two most recent days
research,trades,date sym time price size side,"sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D]"
quant,trades,date sym time src price size side notional,
# sales: their region's accounts, looked up per user on every query
sales,trades,date sym time price size side account notional orderID,account in coveredaccounts qsp.USER
compliance,trades,*,
```

**columns** are space-separated, or `*` for all of them.
- `*` includes columns added to the table later, once the policy is reloaded.
- A list does not, so name the columns when you want new ones hidden until
  someone decides about them.

**filter** is a q where clause:

| write | means |
|---|---|
| *(blank)* | every row |
| `account in `A1`A2` | only those accounts |
| `sym in `VOD`MSFT, size>100` | both. A comma means AND, as in any where clause |
| `(side=`buy) or size<1000` | either |
| `qsp.aged[time;0D00:15]` | only rows at least 15 minutes old. Age the partition column too (`qsp.aged[date;0D]`) and the embargo prunes partitions. An aged partition column also counts as the date constraint `requirepartition` asks for |
| `account in coveredaccounts qsp.USER` | a lookup run with every query. `qsp.USER` is the user the query runs as, even through a gateway |
| `time < qsp.NOW - 0D01` | relative to the policy clock. See [docs/time.md](docs/time.md) for which column to age, and pointing the clock at the time your data is stamped in |
| `fn:deskfilter` | the q function `deskfilter`, called with the user on every query. It returns a list of constraints (see `qsp.f`). Use this when a where clause can't express the filter |

Filters are parsed, never evaluated, when the policy loads. A name in a filter
must be a column of the table or something defined in the process, so a
misspelt column is caught at load.

There is one row per group and table. A second row would replace the first
without anyone noticing, so it's refused. To combine two conditions, use `or`
in one filter.

Spreadsheets quote a cell that contains a comma, and double any quotes inside
it. qsp reads that format, along with Windows line endings, Excel's UTF-8 byte
order mark, and the empty cells a spreadsheet pads rows with. A quoted cell
must end on the line it starts on. A row with too few or too many cells is an
error, not padded or cut short. Lines starting with `#` are comments.

## 4. Put people in groups

`members.csv` takes `user,entity`. The entity is a group, and a group can sit
inside another group:

```
user,entity
llm1,research
sales_na,sales
sales_emea,sales
# groups in a group: every role but compliance also gets what refdata gets
research,refdata
sales,refdata
```

Nest a group only when the two share no tables, as `refdata` doesn't here.
Where they share one, the union and OR above apply. Put `sales` inside
`research`, for example, and every salesperson would see the four research
names traded by every client, with the `account` column, because research's
row filter would be ORed with theirs.

`gateways.csv` lists logins that may run a query **as any other user**. A
gateway authenticates the end user and passes their name along. Add a login
here only for a service you trust as much as the policy itself. `diff`
reports every change to this file.

## 5. Settings

For anything an LLM or other generator talks to, set at least:

```
setting,value
requirepartition,1b
maxrows,1000000
```

Write values as q literals: `1b`, `` `first ``, `` `p`g ``. A function is
written `fn:name`. Start the process with `-T` (query timeout) and `-w`
(memory cap) as well. Those two bound the work a permitted query can do, and
can't be set from inside the process.

`functions.csv` (`action,name`) adjusts the function whitelist:
- `allow`/`deny` add a q function to the whitelist or remove one.
- `call` lets a function of yours be called by name.
- `joincall` lets it stand where a table would.

`call` is trust: qsp checks the call, not what the function does.

## 6. Check it

```sh
q di/qsp/bin/policy.q -dir policy -init defs.q
```

It reports every problem with its file and line, or prints who can read what:

```
user     tbl      columns                                               rows                                                     via
--------------------------------------------------------------------------------------------------------------------------------------------
llm1     trades   `date`sym`time`price`size`side                        "sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D00:00:00]" research
llm1     venues   `src`mic`name`country`ccy                             "all rows"                                               refdata
sales_na accounts `account`client`clientType`region                     "account in coveredaccounts[`sales_na]"                  sales
sales_na trades   `date`sym`time`price`size`side`account`notional`orderID "account in coveredaccounts[`sales_na]"                sales
...
```

A broken policy exits 1, so run this in CI. CI needs no data: tables that
aren't loaded are described by `schema.csv`. If the policy names functions
(`fn:` filters, a `fn:` clock, functions in `functions.csv`), load their
definitions with `-init`. Keep them in the policy directory, so a change to
them is reviewed with the grants that call them. The example keeps them in
`examples/equities/policy/defs.q`, which `hdb.q` loads too, so the process and
CI load the same definitions:

```sh
q di/qsp/bin/policy.q -dir di/qsp/examples/equities/policy -init di/qsp/examples/equities/policy/defs.q
```

A `fn:` setting is checked at load, so without `-init` the example fails with
`config.csv:6: fn:exampleclock is not defined in this process`. A lookup
called in a filter, like `coveredaccounts`, is not checked. It runs only when
a query does, so a misspelt one passes the check, and every query its grant
covers then fails with `qsp: <name>`. After changing a lookup, run a query
through it.

## 7. Review a change

A pull request against a policy should show what it does, not just which
cells it changed:

```sh
q di/qsp/bin/policy.q -dir policy -was main-checkout/policy -init defs.q
```

```
user       tbl      change   detail
--------------------------------------------------------------------------------------------------------
                    gateways "+gw2"
llm1       trades   rows     "sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D00:00:00] -> sym in `AAPL`MSFT`NVDA`META"
quant1     accounts gains    "account clientType region | all rows"
sales_emea trades   columns  "+trader"
sales_na   trades   columns  "+trader"
```

Paste that into the pull request. The approver signs off on "salespeople can
now see who traded" and "research loses its embargo", not on edited cells in
`grants.csv`. Lookups and `fn:`
filters run as they would on a query, so they show today's answer.

In q, the same two tools work on any policy value, whether built from files or
in code: `qsp.access[p;users]` and `qsp.diff[old;new]`.

## 8. Serve it

```q
qsp:use`di.qsp
/ load the data, define any lookups the policy names, then:
qsp.serve qsp.fromfiles "policy"
```

To pick up a change, run the same line again. `fromfiles` checks the whole
policy before `serve` sees it, so a broken policy is refused and the one
already being served stays in place. There is never a partly applied policy.

Tables loaded in the process are read live: columns, types, attributes and
the partition column. `schema.csv` is used only for tables the process doesn't
hold.

`serve` also controls who can connect. Only the users in the policy and the
logins in `gateways.csv` can open a connection. A group's name, such as
`sales`, is refused, and so is any name the policy doesn't know. qsp checks
names, not passwords, so add authentication in front: start the process with
`-U passwordfile`, or define your own `.z.pw` (LDAP, SSO) **before** calling
`serve`. qsp keeps it and calls it after its own check. See
[docs/concepts.md](docs/concepts.md#who-checks-that-a-user-is-who-they-say).

## 9. Confirm with real queries

From the process console, which is not policed:

```q
p:qsp.active[]
qsp.explain[p;`llm1;"select from trades where date=2026.10.07"]   / what would actually run
qsp.validate[p;`llm1;"select account from trades"]                / (allowed; reason), runs nothing
qsp.run[p;`llm1;"select from trades where date=2026.10.07"]       / runs it as llm1, and records it
qsp.audit[]                                                       / who, what they asked, what ran, why
```

`explain` and `validate` run nothing, so the audit log doesn't record them.
It records every query that runs: each one arriving over IPC once the policy is
served, and each `qsp.run` or `qsp.runx`, with who asked, what they asked,
what ran, and why anything was refused. To let an auditor
query it like any table, call `qsp.auditto`auditlog` before loading the policy
and grant `auditlog` to them, as the example does for `compliance`.

## When it doesn't load

| message | means |
|---|---|
| `no entity - name a user or group, or delete the row` | a scaffolded grant nobody has decided on yet |
| `no column X in T` | a misspelt or removed column in `columns` |
| `filter names X, neither a column of T nor defined` | a misspelt column in a filter, or a lookup that isn't loaded. Use `-init` in CI |
| `X is already granted T on line N` | two rows for the same group and table. Merge them with `or` |
| `fn:X is not defined in this process - load the q that defines it first ...` | a `fn:` filter or setting whose function isn't loaded. `\l` its file before `fromfiles`, or pass it to `bin/policy.q` with `-init` |
| `T is not loaded in this process and schema.csv does not describe it` | re-run `scaffold` where the table lives, or add its columns to `schema.csv` |
| `not a literal: auto - a symbol is written `` `auto `` | config values are q literals |
| `filter is not valid q` | usually an unbalanced bracket or quote. Test the clause in `select from t where ...` |
| `expected 4 fields (...), found 3` | a missing or extra comma. Quote a cell that contains one |
| `unterminated quote` | a quoted cell that doesn't close on the same line |
| `unknown file - a policy directory holds only ...` | a misspelt file name, such as `member.csv` or `Grants.csv`. It would otherwise be ignored |
| `filter uses system, which is never permitted` | a filter calls something no query may call |
