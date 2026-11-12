# Concepts: what a policy is made of

A qsp **policy** answers one question: *who can see which rows and columns of
which tables?* Every query is checked against it and rewritten to show only
what the user may see. This page explains the parts of that answer, and how
qsp combines them for one user.

- [The terms](#the-terms)
- [Nothing is allowed until it is granted](#nothing-is-allowed-until-it-is-granted)
- [Users and groups](#users-and-groups)
- [Who checks that a user is who they say](#who-checks-that-a-user-is-who-they-say)
- [Grants: columns and rows](#grants-columns-and-rows)
- [How a user's access is worked out](#how-a-users-access-is-worked-out)
- [Filters that depend on who or when](#filters-that-depend-on-who-or-when)
- [Gateways: running a query as someone else](#gateways-running-a-query-as-someone-else)
- [Functions](#functions)
- [Settings](#settings)
- [Files and code: the same policy two ways](#files-and-code-the-same-policy-two-ways)
- [What a policy does not do](#what-a-policy-does-not-do)

The examples use the example policy, `examples/equities/policy/`. Run
`q di/qsp/examples/equities/hdb.q` to see it working.

## The terms

| term | what it is | example |
|---|---|---|
| **policy** | everything below, as one q dictionary. Built in code or loaded from a directory of CSV files | `qsp.fromfiles "policy"` |
| **user** | the name a query runs as: the IPC login, or a name a gateway passes on | `llm1`, `sales_na` |
| **group** (an **entity**) | a named role. Grants go to groups, so a new person is one row in `members.csv`. "Entity" means a user or a group: either can hold a grant | `research`, `sales` |
| **member** | a row putting a user in a group, or a group in a group | `sales_na,sales` |
| **grant** | one entity's access to one table: which **columns**, and which **rows** | `sales` on `trades` |
| **filter** | the rows part of a grant: a where clause added to every query on that table. Blank means all rows | `` sym in `AAPL`MSFT `` |
| **lookup** | a q function a filter calls with the user, so the rows come from data, not a fixed list | `account in coveredaccounts qsp.USER` |
| **marker** | a `qsp.` name in a filter, replaced on every query: `qsp.USER` with the user, `qsp.NOW` with the clock, `qsp.aged[...]` with a cutoff | |
| **embargo** | a filter that shows rows only once they are old enough. See [time.md](time.md) | `qsp.aged[date;2D]` |
| **gateway** | a trusted login that may run a query as another user | `gateway` |
| **whitelist** | the q functions a query may call. Anything else is refused | `sum`, `wavg`, `xbar` |
| **settings** (`config`) | switches for how strict the whole policy is | `requirepartition`, `maxrows`, `clock` |
| **tables and schema** | which tables exist and what columns they have. Read from the live tables, or from `schema.csv` so the policy can be checked without the data | |
| **served policy** | the policy every IPC query is checked against. `qsp.serve p` installs it; `qsp.active[]` reads it | |
| **audit log** | a record of every query that ran, with who asked, what ran, and why anything was refused | `qsp.audit[]` |

## Nothing is allowed until it is granted

A policy only ever adds access. There are no deny rules.
- A table nobody is granted doesn't exist for anyone.
- A column a user isn't granted doesn't exist for them. Naming it is refused
  (`unknown or not-permitted column: account`), and `select from t` simply
  leaves it out.
- A row outside a user's filter isn't an error. It just isn't there.
- A function not on the whitelist is refused.

So a new table, column or user is invisible until someone decides otherwise.
`qsp.scaffold` writes a starting policy that grants nothing: its grant rows
name no entity, and don't load until someone fills one in.

## Users and groups

A **user** is whoever a query runs as:

| the query arrives | it runs as |
|---|---|
| over IPC, to a process running `qsp.serve` | the login, `.z.u`, which must be a user of the policy |
| from a gateway login, as `` (`.qsp.execas;query;user) `` | `user`, as the gateway names them |
| through `qsp.run[p;user;query]` in your own code | `user` |
| typed at the process's own console | nobody: the console is not policed |

A **group** is any name used as an entity in `members.csv` or `grants.csv`.
`members.csv` puts users in groups:

```
user,entity
llm1,research
sales_na,sales
sales_emea,sales
```

A group can sit inside another group. The member is then a group, not a user:

```
# every role but compliance also gets what refdata gets
research,refdata
sales,refdata
```

A user gets the grants of every group they are in, at any depth. A cycle
(a in b, b in a) is harmless.

Grant to groups, not to people. When someone joins or leaves, the change is
one row in `members.csv`, and `diff` shows exactly what they gain or lose.

**Which names are users.** A user is any name in `members.csv` or `grants.csv`
that isn't a group, and a group is any name that has members. In the example,
the users are `llm1`, `quant1`, `sales_na`, `sales_emea`, `cash_head`,
`etf_head` and `compliance1`. `research`, `quant`, `sales`, `desk`,
`refdata` and `compliance` are groups. `qsp.access[p;`]` lists exactly the
users.

Asking as a group gets you nothing useful. In your own code,
`qsp.run[p;`sales;...]` runs as a "user" called `sales`. That user gets the
sales grant, but `coveredaccounts` finds no row for `sales` in `coverage`, so
the filter matches nothing. Ask as `sales_na` or `sales_emea`. Over IPC, a
group's name can't log in at all (next section).

## Who checks that a user is who they say

There are two separate questions:
- **Authentication:** is this client really `sales_na`?
- **Authorisation:** what may `sales_na` see?

qsp does authorisation. It takes the login name, `.z.u`, as given.

q itself accepts any login name with any password unless something checks it.
Without a check, anyone who can reach the port could connect as `compliance1`
and see everything. So `qsp.serve` installs a `.z.pw` (q's login callback)
that admits only:
- **users of the served policy**, as defined above;
- **gateway logins**, from `gateways.csv`.

Anything else is refused when it connects:

```q
q)hopen `:localhost:5100:nobody:x        / not in the policy
'access
q)hopen `:localhost:5100:sales:x         / a group's name: it would get the group's grants
'access
q)hopen `:localhost:5100:sales_na:x      / a user: connects
```

Over HTTP the same check answers `401 Unauthorized`. A gateway is held to the
same rule for the users it names: `` (`.qsp.execas;query;`sales) `` is refused
with `qsp: not a user of this policy: `sales`, and recorded in the audit log.

**qsp checks names, not passwords.** The example accepts any password, so
anyone who knows a user's name can still be them. In a real process, add
authentication in front:

| use | how it fits with qsp |
|---|---|
| `-U passwordfile` on the command line | q checks the password first; qsp's check runs only for logins that pass |
| your own `.z.pw` (LDAP, Kerberos, SSO) | define it before calling `qsp.serve`. qsp keeps it and calls it after its own name check |
| a gateway that authenticates users | list its login in `gateways.csv`; it names the user on each query |

The served policy decides who can log in, so swapping in a new policy with
`serve` changes it at once. A user removed from the policy can't open a new
connection, and a connection that's already open is refused on its next query.

One edge: a name that has grants but no members counts as a user. qsp can't
tell a person granted directly from a group nobody has joined yet. Give every
group at least one member, or a name no one could log in as.

## Grants: columns and rows

A **grant** is one row of `grants.csv`: an entity, a table, the columns, and a
filter.

```
entity,tbl,columns,filter
sales,trades,date sym time price size side account notional orderID,account in coveredaccounts qsp.USER
quant,trades,date sym time src price size side notional,
compliance,trades,*,
```

- **columns** are space-separated names, or `*` for every column. `*`
  includes columns added later, once the policy is reloaded. A list doesn't,
  so new columns stay hidden until someone adds them.
- **filter** is a q where clause. Conditions separated by commas must all
  hold, as in any where clause. Blank means every row.

There is at most one grant per entity and table. In `grants.csv` a second row
is refused, because it would silently replace the first. To combine two
conditions, put both in one filter (`or`, or a comma for and).

## How a user's access is worked out

On every query, for each table it reads, qsp works out the user's access:

1. **Entities.** The user, every group they are in, and every group those
   groups are in.
2. **Columns.** The **union** of the columns those entities are granted.
3. **Rows.** Each grant's filter, joined with **OR**. One grant with no
   filter means every row.
4. **Markers.** `qsp.USER`, `qsp.NOW` and `qsp.aged` are replaced with their
   values.

The query is then rewritten so it reads only those columns, with the filter
added to its where clause. For `sales_na`:

```q
q)qsp.explain[p;`sales_na;"select notional:sum notional by account from trades where date=2026.10.09"]
"(?;`trades;,((=;`date;2026.10.09);(in;`account;(`coveredaccounts;,`sales_na)));(,`account)!,`account;(,`notional)!,(sum;`notional))"
```

The user's own `date=2026.10.09` is first, then the policy's filter, with
`qsp.USER` replaced by `` `sales_na ``.

`qsp.access` shows the result for every user and table, without running
anything:

```
user     tbl      columns                                                  rows                                     via
sales_na accounts `account`client`clientType`region                        "account in coveredaccounts[`sales_na]"  sales
sales_na trades   `date`sym`time`price`size`side`account`notional`orderID  "account in coveredaccounts[`sales_na]"  sales
sales_na venues   `src`mic`name`country`ccy                                "all rows"                               refdata
```

### Why union and OR matter

Each group adds to what a user can see. It never narrows it. Two narrow groups
can add up to something wider than either:

- **Rows from one grant, columns from another.** Suppose `sales` were inside
  `research`. Research's rows (four symbols, every account) are ORed with
  sales' rows (their region's accounts), and sales' columns include `account`.
  A North American salesperson would then see the four symbols traded by
  **every** client, account by account. (This was tested against the example
  policy: `sales_na` saw all eight accounts.)
- **A grant with no filter lifts every filter.** If an embargoed user is also
  in a group that grants the same table with no filter, they see every row,
  embargo or not.

The rules that follow from this:
- Nest a group inside another only when they share no tables, as `refdata`
  shares none with the groups it sits in.
- If a user must see only the overlap of two groups, make a third group for
  exactly that.
- Check `qsp.access`, which shows each user's combined columns and filter,
  not the rows you wrote.

## Filters that depend on who or when

A filter is parsed, never evaluated, when the policy loads. It can be:

| kind | example | evaluated |
|---|---|---|
| fixed | `` sym in `AAPL`MSFT, size>100 `` | every query, as written |
| per user, through a lookup | `account in coveredaccounts qsp.USER` | every query: `coveredaccounts` is called with the user |
| per user, in q | `fn:deskfilter` | every query: `deskfilter` is called with the user and returns constraints. Use it when a where clause can't say it |
| time-based | `qsp.aged[date;2D]`, `time > qsp.NOW - 1D` | every query, against the policy clock. See [time.md](time.md) |

`qsp.USER` is the user the query runs as, even when a gateway sent it. Never
write `.z.u` in a filter: behind a gateway, `.z.u` is the gateway.

A lookup is ordinary q over ordinary tables. In the example,
`coveredaccounts` reads a `coverage` table, so moving a salesperson to another
region is one row change. Their next query sees it, with no reload. The
lookup's own tables aren't granted to anyone, so no user can read them.

A lookup that fails, or a `fn:` filter that signals or returns something that
isn't a list of constraints, refuses the query. It never falls back to "no
filter".

## Gateways: running a query as someone else

Usually a user connects as themselves and the login decides who they are. A
**gateway** is a service that authenticates users itself, such as a web app, an
LLM front end, or a TorQ gateway, and then sends their queries over one
connection. It names the user in each message:

```q
g:hopen `:host:5100:gateway:pass
g(`.qsp.execas;"select from accounts";`sales_emea)
```

Only logins listed in `gateways.csv` may do this. The same message from any
other login is an ordinary query, and is refused. The user it names must be a
user of the policy, not a group. A gateway can claim to be any user, so list
only a service you trust as much as the policy itself.
`` `.qsp.execasx `` does the same and also returns what ran.

## Functions

A query may only call functions on the **whitelist**. The default whitelist
covers ordinary analytics, from `sum`, `avg`, `wavg` and `xbar` to `fby` and the joins. A
**never** list (`value`, `system`, `hopen`, `set`, `get`, file access and the
rest) can't be added whatever the policy says. `functions.csv` adjusts the
whitelist:

| action | does |
|---|---|
| `allow` | add a q function |
| `deny` | remove one |
| `call` | let a function of yours be called by name. qsp checks the call, not what the function does, so this is trust |
| `joincall` | also let it stand where a table would, like a join |

## Settings

`config.csv` holds settings for the whole policy. The ones that matter most:

| setting | default | |
|---|---|---|
| `requirepartition` | `0b` | refuse a query that would read every partition. Turn it on for anything an LLM talks to |
| `maxrows`, `maxsize` | `0W`, 200MB | refuse a result bigger than this |
| `strictcolumns` | `1b` | a where clause may name only visible columns. Off, a user could filter on a hidden column and so learn its values |
| `rowindex` | `0b` | allow the row index `i`. It shows where hidden rows are, so it is off |
| `clock` | `{[] .z.p}` | "now", for time-based filters. See [time.md](time.md#the-clock) |

The full list is under Configuration in [../qsp.md](../qsp.md#configuration).
Two limits can't be set from inside a process: start it with `-T` (a time
limit per query) and `-w` (a memory cap).

## Files and code: the same policy two ways

A team keeps a policy as CSV files, reviewed in pull requests. The same policy
can be built in q. Each file is applied through the matching function:

| file | q | holds |
|---|---|---|
| `tables.csv` | `qsp.table[p;t;spec]` | the tables, and their partition column |
| `schema.csv` | `qsp.table[p;t;meta]` | columns of tables not loaded in this process |
| `grants.csv` | `qsp.grant[p;entity;t;cols;rows]` | grants |
| `members.csv` | `qsp.member[p;user;entity]` | members |
| `gateways.csv` | `qsp.gateway[p;logins]` | gateway logins |
| `functions.csv` | `qsp.allowfunction`, `denyfunction`, `allowcall`, `allowjoincall` | the whitelist |
| `config.csv` | `qsp.configure[p;settings]` | settings |

`qsp.fromfiles dir` builds the policy from a directory, refusing it, with every
problem listed, if anything is wrong. `bin/policy.q` checks a directory and
shows who can read what, or what a change changes, for CI and review. See
[../setup.md](../setup.md).

## What a policy does not do

- **It doesn't check passwords.** It admits only names the policy knows. Proving
  a client is who they claim is for `-U`, your own `.z.pw`, or an
  authenticating gateway. See
  [Who checks](#who-checks-that-a-user-is-who-they-say).
- **It doesn't defend against prompt injection.** It doesn't care how a query
  was written, by a person, a notebook or an LLM. It checks what the query
  does.
- **It doesn't bound work by itself.** A permitted query can still be
  expensive. `requirepartition`, `maxrows` and `maxsize` help, and `-T` and
  `-w` are the real limits.
- **It doesn't police the console.** The process's own console runs
  unchecked, so it is where you run `qsp.explain` and read the audit log.
- **It doesn't check that answers are right.** It decides what a query may
  read, not whether the query answers the question asked.

See also: [time.md](time.md) for embargoes and the clock;
[../qsp.md](../qsp.md) for how a query is checked step by step, and the full
API.
