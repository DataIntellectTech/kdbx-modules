# Time: embargoes and the policy clock

Most policies never mention time. A filter like `` sym in `AAPL`MSFT `` gives
the same rows whenever a query runs. This page is for rules that depend on
**when** the query runs. The usual one is an **embargo**: rows that may be
shown, but only once they are old enough.

- [Why a policy needs time](#why-a-policy-needs-time)
- [Writing an embargo](#writing-an-embargo)
- [How it is applied](#how-it-is-applied)
- [Which column to age](#which-column-to-age)
- [The span](#the-span)
- [`qsp.NOW`: writing a time rule by hand](#qspnow-writing-a-time-rule-by-hand)
- [The clock](#the-clock)
- [Things to know](#things-to-know)
- [Checking and testing an embargo](#checking-and-testing-an-embargo)
- [Reference](#reference)

The examples use the example HDB and policy (`examples/equities/hdb.q`,
`examples/equities/policy/`). Its data runs from 2026-10-05 to 2026-10-09.

## Why a policy needs time

Some data is sensitive only while it is fresh:

| reason | typical rule |
|---|---|
| **Market data licensing.** Exchanges charge for real-time prices. Data delayed by about 15 minutes is often free or much cheaper, and a user licensed only for delayed data must not see anything newer | `qsp.aged[time;0D00:15]` |
| **Information barriers.** Today's client orders and fills could be used to trade ahead of the client. Research, or anyone outside the desk, may see flow only from earlier days | `qsp.aged[date;0D]`: nothing from today |
| **Client and regulatory reporting.** Some data is released end of day, or the next day (T+1), and never intraday | `qsp.aged[date;1D]` |
| **Publishing to an outside party.** An external consumer, or an LLM answering their questions, gets history but not the live book | any of the above |

"Old enough" needs a "now" to measure from. That is the policy **clock**.

## Writing an embargo

In `grants.csv`, put `qsp.aged[column;span]` in the filter. It can be the whole
filter, or one condition of several, separated by commas as in any where
clause:

```
entity,tbl,columns,filter
research,trades,date sym time price size side,"sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D]"
delayed,quotes,*,qsp.aged[time;0D00:15]
```

It reads "only rows whose `column` is at least `span` old".

In q, build the same constraint with `qsp.f.aged`:

```q
p:qsp.grant[p;`delayed;`quotes;qsp.ALL;enlist qsp.f.aged[`time;0D00:15]]
p:qsp.grant[p;`research;`trades;`date`sym`time`price`size`side;
  (qsp.f.isin[`sym;`AAPL`MSFT`NVDA`META]; qsp.f.aged[`date;2D])]
```

## How it is applied

An embargo is not evaluated when the policy loads. When the policy loads,
qsp checks it:
- the column exists;
- its type is a date or time type;
- the span is a time span.

It is turned into a cutoff on **every query**:

1. Read the clock: `now`.
2. Subtract the span: `now - span`.
3. Cast the result to the column's own type: a date for a date column, a
   timestamp for a timestamp column, a time of day for a time column.
4. Add `column < cutoff` to the query's where clause, like any other row
   filter.

The cutoff reaches the query as a plain value. As a result:
- `explain` and the audit log show the exact cutoff a query ran with, which is
  what you need when someone asks why a row was missing;
- it is ordered like any other constraint: a date cutoff goes to the front of
  the where clause with the other date constraints, just behind one that
  bounds the date;
- the embargo moves forward by itself as time passes, and nobody edits the
  policy each day.

With the example's clock fixed at `2026.10.10D00:00`:

```q
q)qsp.explain[p;`llm1;"select from trades where date=2026.10.07"]
"(?;`trades;,((=;`date;2026.10.07);(<;`date;2026.10.08);(in;`sym;,`AAPL`MSFT`NVDA`META));0b;...)"
```

`qsp.aged[date;2D]` became `date<2026.10.08`. It is placed second, just behind
the user's own `date=2026.10.07`. Both are on the partition column, and q
narrows the partitions it reads by the first constraint only: this way it reads
one partition, not every partition before the cutoff.

## Which column to age

The cutoff is cast to the column's type, so which column you age decides what
the embargo means.

### A date, usually the partition column: whole days

`qsp.aged[date;span]` is `date < date(now - span)`. Every day that the cutoff
falls in, or after, is held back completely. With the clock at
`2026.10.10D12:00`:

| filter | becomes | last visible day |
|---|---|---|
| `qsp.aged[date;0D]` | `date<2026.10.10` | 2026-10-09: nothing from today |
| `qsp.aged[date;1D]` | `date<2026.10.09` | 2026-10-08 |
| `qsp.aged[date;2D]` | `date<2026.10.08` | 2026-10-07 |

Use it for day-level rules: nothing from today, T+1, a week's delay. On a
date-partitioned table it is an upper bound on the partitions read, not a
complete one: with `requirepartition` on, the user still names their dates
(see [Things to know](#things-to-know)).

It works in whole days, rounding towards hiding more. `qsp.aged[date;2D]` at
midday on the 10th hides the 8th, 9th and 10th: two days and a half, not
exactly two. If you need an exact delay, age a timestamp.

### A timestamp: exact

`qsp.aged[time;0D00:15]` on a timestamp column is `time < now - 0D00:15`, to
the nanosecond. With the clock at `2026.10.09D12:00`, every row of earlier
days is visible, and today's rows up to 11:45:

```
date      | n    last time
----------| -----------------------------
2026.10.08| 1500 2026.10.08D15:56:52.564...
2026.10.09| 492  2026.10.09D11:41:57.382...
```

Use it for intraday delays, such as 15-minute delayed market data.

### Date and timestamp together

`(qsp.aged[date;0D]; qsp.aged[time;0D00:15])` on a timestamp column gives
exactly the same rows as `qsp.aged[date;0D]` alone. The date rule removes
today, and every earlier row is more than 15 minutes old anyway. Each rule
does something on its own. Together, the date rule decides.

(`qsp.md` used to describe that pair as "nothing from today, and 15 minutes
behind on older days", as the original qsp's docs did. That is not what it does
on a timestamp column.)

### A time of day: only for a table that holds one day

A `time` column of type `t` (time of day) has no date. The cutoff is cast to a
time of day, so `qsp.aged[time;0D00:15]` at 12:00 becomes `time<11:45:00.000`.
It applies to **every day in the table**:

```
date       time         x
-------------------------
2026.10.08 09:00:00.000 1        <- 2026.10.08 13:00 is hidden too
2026.10.09 09:00:00.000 3
```

That is right for a table that only ever holds today, such as an RDB's. For a
table that holds several days with a time-of-day column, hold back only
today's late rows:

```
entity,tbl,columns,filter
delayed,tod,*,"(date<`date$qsp.NOW) or time<`time$qsp.NOW-0D00:15"
```

```
date       time         x
-------------------------
2026.10.08 09:00:00.000 1
2026.10.08 13:00:00.000 2
2026.10.09 09:00:00.000 3
```

That filter is not a plain comparison on the date, so it does not prune
partitions. With `requirepartition` on, the user's own date constraint does
that.

### A column that isn't a date or time

`qsp.aged[size;0D]` is refused when the grant is made or the policy loads:
`aged filter needs a temporal column - size is type "i"`. So is a column the
table doesn't have, or one whose type qsp doesn't know (register the table
from its meta, or describe it in `schema.csv`).

## The span

The span is how old a row must be. Write it as a q timespan:
- `0D` for none;
- `0D00:15` for 15 minutes;
- `1D` for a day;
- `2D12:00` for two and a half days.

A minute, second or time value also works (`00:15` is 15 minutes).

A plain number is **not** a number of days. qsp accepts anything that can be
subtracted from a timestamp, and q subtracts a plain number as nanoseconds. So
`qsp.aged[date;2]` means "at least 2 nanoseconds old". On a date column that
is "nothing from today", not "nothing from the last two days". Always write
the `D`.

A date or other non-span value is refused: `f.aged needs a timespan, e.g. 0D00:15`.

## `qsp.NOW`: writing a time rule by hand

`qsp.NOW` stands for the clock's value in a filter you write yourself. qsp
replaces it with the timestamp when each query is rewritten:

```
entity,tbl,columns,filter
# only the last 24 hours
recent,trades,*,time > qsp.NOW - 1D
```

Prefer `qsp.aged` for "at least this old". `qsp.NOW` is not cast to the
column's type, so the comparison is q's own, and for a date column that
differs:

| filter, clock at `2026.10.09D12:00` | today's rows (2026-10-09) |
|---|---|
| `qsp.aged[date;0D00:15]` → `date<2026.10.09` | hidden |
| `date < qsp.NOW - 0D00:15` | **visible**: q compares a date as midnight, and midnight is before 11:45 |

Use `qsp.NOW` for what `qsp.aged` can't say: "newer than", windows, or the
time-of-day recipe above. When you do, cast it to the column's type yourself
(`` `date$qsp.NOW ``).

## The clock

The clock is the `clock` setting: a function of no arguments that returns a
timestamp. It is "now" for `qsp.aged` and `qsp.NOW`, and nothing else uses it.

| | |
|---|---|
| default | `{[] .z.p}`: the current time in UTC |
| in `config.csv` | `clock,fn:myclock`, naming a function defined in the process |
| in q | `p:qsp.configure[p;enlist[`clock]!enlist {[] .z.P}]` |
| read it | `p[`config;`clock][]` |

### Point it at the clock your data is stamped with

An embargo compares the clock with the timestamps in your data, so the two
must agree. The default is right only for data stamped in UTC.

| your data is stamped in | clock |
|---|---|
| UTC (`.z.p`, the usual for tickerplants) | leave the default |
| the server's local time (`.z.P`) | `{[] .z.P}` |
| a particular zone | `{[] .z.P}`, with the process started in that zone, e.g. `TZ=America/New_York q ...` |
| a zone converted in q, e.g. with TorQ's `.tz` | `{[] .tz.gl[`$"America/New_York";.z.p]}` |
| a replay or simulation | `{[] replayclock[]}`, whatever your replay keeps |
| nothing: tests, demos and frozen data | a fixed time, `{[] 2026.10.10D00:00}` |

If the clock and the data disagree, the embargo is off by the difference,
and it fails in one of two ways. Take a 15-minute delay in November, when New
York is 5 hours behind UTC:

| data stamped in | clock | at 12:00 New York, the cutoff is | result |
|---|---|---|---|
| New York time | UTC (the default) | 16:45, compared with New York stamps | **nothing is held back**: every row, up to 12:00, is before 16:45 |
| UTC | New York (`.z.P`) | 06:45, compared with UTC stamps | 5 hours 15 minutes held back, not 15 minutes |

The first is a leak, and nothing will report it. Check one row by hand when you
set up an embargo (see [Checking](#checking-and-testing-an-embargo)).

`TZ` changes `.z.P` for the whole process: `TZ=America/New_York q` gives
`.z.P - .z.p` of `-0D05:00` in November. Daylight saving changes are handled
by the operating system.

### Fixing the clock

The example policy fixes its clock because its data is frozen in October 2026:

```
# config.csv
clock,fn:exampleclock
```
```q
/ defs.q
exampleclock:{[] :2026.10.10D00:00;};
```

Against the real clock every row would be weeks old and the embargo would hide
nothing. Fixed, the walkthrough shows the same rows every run. Do the same in
tests: fix the clock, and the rows an embargo shows are exact rather than a
moving target. A real policy over live data uses a real clock.

### When the clock is read

- **When the policy loads, or a grant is made.** A grant with an embargo is
  checked by working out a cutoff, which calls the clock. A clock that signals,
  or returns something other than a timestamp, is refused there:
  `the policy clock must return a timestamp`.
- **On every query whose filters use it**, during the rewrite. If the clock
  breaks after the policy loaded, every such query is refused with the same
  message. It is never treated as "no embargo". A query on a table the user
  holds without a time rule doesn't read the clock, so it isn't affected.

`clock,fn:name` takes the function **as it is when the policy loads**.
Redefining `name` afterwards does not change the clock until the policy is
reloaded (`qsp.serve qsp.fromfiles ...` again). If you want to change "now"
without reloading, for a replay or a test, have the clock read a variable:

```q
simnow:2026.10.10D00:00;
simclock:{[] simnow};        / clock,fn:simclock - reads simnow on every query
simnow:2026.10.12D00:00;     / takes effect on the next query
```

## Things to know

**An embargo is not a deny.** qsp has no deny rules. A user in two groups gets
the OR of the groups' row filters, and a grant with no filter means all rows.
If `llm1` is in `research` (embargoed) and also in a group that grants
`trades` with no filter, `llm1` sees every day: the second grant lifts the
embargo. Put the embargo on every grant the user holds on that table, or keep
embargoed users out of groups that grant the same table more widely.
`qsp.access` shows the combined filter, so check it there.

**An embargo doesn't satisfy `requirepartition`.** `date<2026.10.08` is a
constraint on the partition column, but only an upper bound: on its own it
reads every partition before the cutoff, which on a database of years is all
of them. So an embargoed user still has to bound their dates, with `date=d`,
`date in ds` or `date within d0 d1`, just as a user with no embargo does. qsp
puts the user's bounded constraint ahead of the embargo, because q narrows the
partitions it reads by the first constraint only, so `where date=d` reads one
partition. The embargo then removes that day if it is held back.

**The audit log keeps wall-clock time.** Its `time` column is `.z.p` when the
decision was taken, whatever the policy clock says. Its `rewritten` column
holds the cutoff the query ran with:

```
time                          rewritten
------------------------------------------------------------------------
2026.11.11D20:47:37.029060399 ? `trades ,((within;`date;...);(<;`time;2026.10.09D11:45:00.000000000)) ...
```

**One query, one now.** The cutoff is worked out once, when the query is
rewritten. A query that runs for a while uses the cutoff from when it started.

**Lookups and `fn:` filters can use time too.** A `fn:` filter is a q
function of the user, run on every query, so it can apply any rule, including
one based on time. It reads the time however it likes, not necessarily the
policy clock. Prefer `qsp.aged` where it can say what you mean, because `access`, `diff` and
the audit log show it plainly.

## Checking and testing an embargo

`qsp.access` and `bin/policy.q` show an embargo as written:

```
llm1     trades   `date`sym`time`price`size`side  "sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D00:00:00]" research
```

`qsp.diff`, or `bin/policy.q -was`, shows adding or removing one as a change
of rows:

```
llm1       trades   rows     "sym in `AAPL`MSFT`NVDA`META, qsp.aged[date;2D00:00:00] -> sym in `AAPL`MSFT`NVDA`META"
```

To see the cutoff a user would get right now, explain a query as them:

```q
q)qsp.explain[qsp.active[];`llm1;"select from trades where date=2026.10.07"]
```

To prove an embargo, fix the clock and check the edges: the newest row a user
can see, and the oldest they can't. Write them as tests in `tests.csv`, as the
example does for `llm1`:

```
user,query,expect,value,note
llm1,select vwap:size wavg price by sym from trades where date=2026.10.07,rows,,the last day outside the embargo
llm1,select vwap:size wavg price by sym from trades where date=2026.10.09,empty,,the last two days are embargoed
```

`bin/policy.q -test` runs them in CI ([Testing a policy](../qsp.md#testing-a-policy)).
Fix the clock in the policy that CI tests, or the edges move every day. In the
admin UI ([ui.md](ui.md)), the Lens shows the embargo on a table's real rows:
pick an embargoed user and a day inside it, and every row fades.

## Reference

| | |
|---|---|
| `qsp.aged[col;span]` | in a `grants.csv` filter: only rows whose `col` is at least `span` old |
| `qsp.f.aged[`col;span]` | the same, as a constraint for `qsp.grant` |
| `qsp.NOW` | in a filter: the clock's timestamp, substituted per query |
| `clock` setting | `{[] .z.p}` by default. In `config.csv`, `clock,fn:name` |
| cutoff | `col < $[col's type](clock[] - span)`, worked out per query |
| errors | `aged filter needs a temporal column - C is type "T"`, `aged filter on C, which is not a column of T`, `f.aged needs a timespan, e.g. 0D00:15`, `the policy clock must return a timestamp`, `fn:name is not defined in this process - ...` |

See also: [concepts.md](concepts.md) for grants, groups and how filters
combine; [../qsp.md](../qsp.md) for the full API.
