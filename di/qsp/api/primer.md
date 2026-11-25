# q under qsp: a working primer

You write q-SQL that a qsp gateway checks, rewrites for your user, and runs. qsp accepts a strict
subset of q. This primer is what to know to get a correct answer in few calls: a method, the q
that matters, the shapes qsp accepts, idioms for time-series questions, and what to do when a
query is refused or a result looks wrong. Every q example here is a single query qsp accepts;
they use the tables of qsp's example equities database (`trades`, `quotes`, `orders`), so change
the names to the ones `describe` gives you.

## 1. A method for any question

1. **Read the question literally.** Note every date, time window, instrument, grouping and unit
   it names. One date means that day only. A range needs two dates. In a follow-up turn, reset any
   date window, symbol, or filter that the new question changes rather than silently carrying over a
   prior turn's window. If a term or scope is genuinely ambiguous (e.g., own-venue vs. consolidated
   quote, per-venue vs. combined total, price-level vs. return correlation), pick the plainest
   reading and state it explicitly—or in interactive chat, ask a brief clarifying question.
2. **Know what you can read.** `describe` gives your tables, columns (with their types, bytes per
   row and, where written, what they mean), the partition column and your row filter. Its `shape`
   says which dates you can see, the time range of the latest, and the values of code columns such
   as `side` - so you need not query for them. Its `terms` are the business's own definitions:
   where the question uses one - markout, fill rate, slippage - compute it as the term says, and
   say that you did. Do not guess column names.
3. **Probe the shape before the answer** with cheap aggregates, never raw rows:
   ```q
   select n:count sym, t0:min time, t1:max time by date from trades where date within 2026.10.05 2026.10.06, sym=`NVDA
   ```
   ```q
   select distinct side from trades where date=2026.10.05
   ```
   This tells you the row counts (how big a full answer is), the session hours (are there rows
   before the open or after the close?), and the values of a code column such as `side` or `src`.
4. **Build the core on a small window**, check it, then widen to the question's window. Before
   anything that could be large - listing rows, joining over more than a day, a wide date range -
   call `estimate` on it (section 9).
5. **Check the result independently** before answering: totals that should add up, a count that
   should equal another count, a figure recomputed a second way. A join that left nulls, a
   window off by one minute, or a grouping at the wrong grain all show up here. Treat any `0`,
   `0.0`, `0n`, or empty result as suspicious until you confirm with a quick probe that the data
   truly has none.
6. **Answer** with the exact figures from your result (never drop a requested number in prose) in
   the units the question asked for, the q you ran, and the exact date window, grouping, and any
   definition or reading you chose.

## 2. q that matters here

- **Right to left, no precedence.** `2*price+1` is `2*(price+1)`. Write `(2*price)+1`.
  `a cross b lj c` is `a cross (b lj c)`: write `(a cross b) lj c`. Always parenthesise
  arithmetic before `<`, `>`, `=`: `(1e4*(ask-bid)%mid)<5`, never `1e4*(ask-bid)%mid<5` (which
  divides by a boolean).
- **`lj`, `ij` and `pj` require a keyed right table:** group the right select with `by`, e.g.
  `t lj select first sector by sym from instruments`, or use `ej`.
- **Commas separate where-constraints**, applied left to right, each narrowing the rows the next
  sees. Do not join constraints with `and`: `size>100 and price<5` is `size>(100 and price<5)`.
- **`&` is min and `|` is max** on numbers, and/or on booleans.
- **`%` divides.** `mod` is remainder, `div` integer division.
- **`=` compares item by item; `~` matches whole values.** In a where clause use `=`, `in`,
  `within`, `like`, `<`, `>`.
- **Vector conditional:** `?[cond;a;b]` picks per row. `$[c;a;b]` is for one value, not a column.
  Nest for several cases: `?[c1;`x;?[c2;`y;`z]]`.
- **Nulls:** `0N`, `0n`, `` ` ``. Aggregates skip nulls; `count` does not. `0^x` fills nulls with 0.
  `null x` tests.
- **Statistics:** `avg`, `med`, `dev` and `var` are population figures; `sdev` and `svar` are the
  sample ones. `wavg` is weighted: `size wavg price` is VWAP. `cor` is correlation.
- **Running and pairwise:** `sums`, `mins`, `maxs`, `deltas` (keeps the first item as it is:
  use `1_deltas x` for pure differences), `prev`, `next`, `differ` (1b where an item differs from
  the one before, and 1b for the first), `ratios`, `n mavg x`, `n msum x`.
- **Grouping helpers:** `n xbar x` rounds down to a multiple of n. `edges bin x` gives the index
  of the last edge each x reaches (-1 before the first edge). `(f;col) fby g` applies f within
  each group g, one value per row, for use in a where clause.
- **Integer division of a time:** `(`minute$time) div 60` stays a minute (`00:09`), not 9. Bucket
  hours with `0D01:00 xbar time` instead.

## 3. Shapes qsp accepts

- **Every select of a partitioned table must start its where clause with the partition column,
  bounded on both sides:** `date=d`, `date in d1 d2` or `date within d0 d1`. This applies to a
  select nested inside another or inside a join too. `date>d` is not a bound.
- **`exec` and `select[n]` cannot read a partitioned table directly** (q says `nyi`). Wrap a
  plain select:
  ```q
  select[5;>size] from select sym, time, size from trades where date=2026.10.05
  ```
  ```q
  exec first price from select price from trades where date=2026.10.05, sym=`NVDA
  ```
- **No lambdas, no local variables, no `i`.** `{x+1}`, `t:...` inside a query and `count i` are
  refused. Count a real column: `count sym`.
- **Casts take a type name or one of q's extractions:** `` `minute$time ``, `` `timespan$time ``,
  `` `float$x ``, `` `hh$time ``, `` `year$date ``. A dotted part reads the same way:
  `time.minute`, `time.hh`, `date.year`. Any other name before `$` is refused.
- **Joins:** `lj`, `ij`, `uj`, `ej`, `pj`, `aj`, `aj0` and `wj` are all accepted, between selects.
  A keyed table on the right of `lj`/`ij` comes from `select ... by key from ...`.
- **One query per call.** It must be a single q expression.
- **Parenthesise a nested select before an outer `where`.** In
  `select ... from select ... where date=d, sym=`NVDA where x>0` the last `where` joins
  `` `NVDA `` and q cannot run it. Write `select ... from (select ... where ...) where x>0`.
- **Give computed columns distinctive names.** A column named in a nested select and read in
  the outer one is refused if the name is also defined on the server; the refusal names it.
  Rename it (`px_`, `walkPx`) rather than restructuring the query.

## 4. Names a column cannot have

q will not parse a column named after a q function: `select fills:count sym ...` fails with
`'assign`, which qsp reports as `not valid q (assign)`. These are the ones that tempt:

`fills` `prev` `next` `first` `last` `count` `sum` `avg` `min` `max` `med` `dev` `var` `sdev`
`svar` `cor` `cov` `wavg` `wsum` `sums` `deltas` `ratios` `mins` `maxs` `avgs` `mavg` `msum`
`differ` `rank` `bin` `xbar` `group` `key` `value` `type` `string` `signum` `abs` `neg` `mod`
`div` `in` `within` `like` `except` `inter` `union` `cross` `where` `asc` `desc` `reverse` `all`
`any` `not` `null` `til` `raze` `flip` `enlist` `get` `set` `show` `ss` `sv` `vs` `trim` `lower`
`upper` `cut` `sublist` `fby` `aj` `lj` `ij` `uj` `wj` `ej` `pj` `each` `over` `scan` `prior`
`and` `or` `exp` `log` `sqrt` `floor` `ceiling` `reciprocal` `tables` `meta` `cols`

Safe and clear instead: `n`, `nfill`, `fill`, `fillcount`, `open`, `high`, `low`, `close`, `vwap`,
`twap`, `volume`, `mid`, `spread`, `ret`, `move`, `change`, `total`, `bucket`, `session`, `bar`.

## 5. Time

- A `time` column of type timestamp holds the date as well as the time of day.
- **Exact time-of-day windows:** compare with full timestamps or timespans.
  ```q
  select n:count sym from trades where date=2026.10.05, sym=`NVDA, time within 2026.10.05D10:00 2026.10.05D10:10
  ```
  ```q
  select n:count sym from trades where date=2026.10.05, sym=`NVDA, time within 0D10:00 0D10:10
  ```
  **Trap:** `time within 10:00 10:10` compares only the minute part, so it includes everything up
  to 10:10:59 - a silently wider window.
- **Buckets:** `0D00:05 xbar time` (five-minute bars, keeping the timestamp), `` `minute$time ``
  (one-minute buckets as a minute), `0D01:00 xbar time` (clock hours).
- **Sessions with uneven edges:** `bin` against the edges.
  ```q
  select vwap:size wavg price, volume:sum size by session:2026.10.05D09:30 2026.10.05D12:00 2026.10.05D15:30 bin time from trades where date=2026.10.05, sym=`NVDA, time within 2026.10.05D09:30 2026.10.05D16:00
  ```
  Bound the time as well as binning it: `bin` puts everything after the last edge into the last
  bucket, and the data may run past the close.

## 6. Techniques

Each is a pattern; change the table, columns, dates and instruments.

**OHLC bars, each bar's open carried from the previous bar's close**
```q
update open:open^prev close by sym from select open:first price, high:max price, low:min price, close:last price by sym, bar:0D01:00 xbar time from trades where date=2026.10.05, sym in `NVDA`META
```
`x^y` fills the nulls in y from x, so `open^prev close` takes the previous close, falling back to
the bar's own first price for the first bar.

**Time-weighted average (TWAP, time-weighted spread):** weight each value by how long it held.
```q
select twap:(next deltas time) wavg price, vwap:size wavg price by date from trades where date within 2026.10.05 2026.10.06, sym=`NVDA
```
```q
select twas:(next deltas time) wavg ask-bid by sym, src from quotes where date=2026.10.05, sym=`NVDA
```
When the series has several sources, compute durations within each source (`by sym, src`) so
one venue's quote does not end another's.

**The prevailing quote at each trade: as-of join**
```q
aj[`sym`time; select sym, time, side, price from trades where date=2026.10.05, sym=`NVDA; select sym, time, bid, ask from quotes where date=2026.10.05, sym=`NVDA]
```
`aj` takes, for each left row, the last right row at or before its time, matching the other key
columns exactly. Add `src` to the keys to match within a venue. Rows with no earlier quote get
nulls: count them (`select count sym from ... where null bid`).

**The value T later, or T earlier: as-of join against a time-shifted copy**
```q
aj[`sym`time; select sym, time, price from trades where date=2026.10.05, sym=`NVDA; select sym, time:time-0D00:01, later:0.5*bid+ask from quotes where date=2026.10.05, sym=`NVDA]
```
Shift the right side BACK by T and each row gets the value that holds T after it. Shift it
FORWARD (`time+T`) for the value T before.

**A rolling window ending at each row: cumulative sums and a shifted as-of join**
```q
select time, price, size, vwap5:(ps-ps5)%sz-sz5 from aj[`sym`time; select time, sym, price, size, ps:sums price*size, sz:sums size from trades where date=2026.10.05, sym=`NVDA; select time:time+0D00:05, sym, ps5:sums price*size, sz5:sums size from trades where date=2026.10.05, sym=`NVDA]
```
The window total is the running total now minus the running total T ago. Prefer this to `wj`:
qsp cannot see the columns `wj` computes, so a select over a `wj` result is refused.

**A complete grid with zeros where nothing happened**
```q
select sym, bar, volume:0^volume from (([]sym:enlist`NVDA) cross ([]bar:2026.10.05D09:30+0D00:01*til 30)) lj select volume:sum size by sym, bar:0D00:01 xbar time from trades where date=2026.10.05, sym=`NVDA
```
Build the grid you want (`cross` of the keys), then left-join the counts and fill with `0^`. The
parentheses around the `cross` matter: q reads right to left.

**Per-group statistics in a where clause: fby**
```q
select n:count sym by sym from trades where date=2026.10.05, abs[price-(avg;price) fby sym]>2*(dev;price) fby sym
```

**Changes within a series and inter-arrival times:** compare with the item before, within each series.
```q
select changed:sum chg, total:count sym by sym from update chg:(differ bid)|differ ask by sym, src from select sym, src, time, bid, ask from quotes where date=2026.10.05, sym=`NVDA
```
```q
select avgGapMs:avg 1e-6*1_deltas time by sym, src from quotes where date=2026.10.05, sym=`NVDA
```
Group by every column that identifies a series (here `sym` and `src`) when applying `differ`,
`prev`, `deltas` or `next`, or one venue's row runs into another's; use `1_deltas` to drop the
leading timestamp.

**Nearest quote (before or after) to a trade:** combine a backward `aj` and a forward `aj` (using negated time) and pick whichever quote timestamp is closer.
```q
select time, price, nearestBid:?[(null bt)|((not null at)&(at-time)<time-bt);abid;bbid], gapMs:1e-6*(0W^time-bt)&0W^at-time from aj[`sym`nt; update nt:neg time from aj[`sym`time; select sym, time, price from trades where date=2026.10.05, sym=`NVDA; select sym, time, bt:time, bbid:bid from quotes where date=2026.10.05, sym=`NVDA]; select sym, nt:neg time, at:time, abid:ask from quotes where date=2026.10.05, sym=`NVDA]
```
Keep the original quote timestamp under a separate name (`bt`, `at`) on each right side—`aj` overwrites the join key `time` with the left side's time, so `time-time` would always be `0D`.

**Walking a 5-level order book for a target quantity Q:** clamp each level's take to the remaining size (`0|rem`), then take the size-weighted average price.
```q
select sym, time, px:(f1*ask1)+(f2*ask2)+(f3*ask3)+(f4*ask4)+f5*ask5, filled:f1+f2+f3+f4+f5 from update f5:asize5&0|r4 from update r4:r3-f4 from update f4:asize4&0|r3 from update r3:r2-f3 from update f3:asize3&0|r2 from update r2:r1-f2 from update f2:asize2&0|r1 from update r1:5000-f1 from update f1:asize1&5000 from select sym, time, ask1, asize1, ask2, asize2, ask3, asize3, ask4, asize4, ask5, asize5 from depth where date=2026.10.05, sym=`NVDA
```
Divide `px` by `filled` for the walk VWAP, and check `filled<Q` for snapshots that cannot fill the full quantity.

**Buckets of equal volume**
```q
select start:first time, end:last time, volume:sum size by bucket:3&floor 4*(sums size)%sum size from trades where date=2026.10.05, sym=`NVDA
```
`sums size` is the running volume; dividing by the day's total and flooring `4*` gives quarters,
and `3&` keeps the final row in the last bucket.

**Correlation of two series on aligned bars**
```q
select r:cor[ra;rm] from select ra:-1+a%prev a, rm:-1+m%prev m from (select a:last price by bar:0D00:01 xbar time from trades where date=2026.10.05, sym=`NVDA) ij select m:last price by bar:0D00:01 xbar time from trades where date=2026.10.05, sym=`META
```
`ij` keeps the bars both series traded in. Correlate returns or changes (`1_deltas`), not price
levels, unless levels are asked for.

**One column per instrument: pivot with exec ... by**
```q
exec (`NVDA`META)#sym!close by date:date from select close:last price by date, sym from trades where date within 2026.10.05 2026.10.06, sym in `NVDA`META
```

**An average over a population, members with none included:** start from the population and
left-join the counts, so a member with no rows counts as 0 rather than disappearing.
```q
select avgn:avg 0^n by side from (select orderID, side from orders where date=2026.10.05) lj select n:count sym by orderID from trades where date=2026.10.05
```

**Basis points and percent:** `1e4*x%ref` is bps, `100*x%ref` is percent. Report what the
question asked for; if it did not say, say which you used.

## 7. When a query is refused or fails

| You see | It means | Do this |
|---|---|---|
| `not valid q (assign): fills is a q function...` | A column is named after a q function | Rename the column it names (section 4) |
| `not valid q (dup names for cols/groups x)` | The select lists x, and its `by` returns x too | Drop x from the select list: `select n:count i by x from t` |
| `not valid q (...)` | q could not parse the query | Check brackets, quotes, and right-to-left order |
| `not found when the query ran: x` | q could not find x while running a query qsp allowed: usually a join key missing from the left table, or a column an inner select did not keep | Keep every key of a keyed join's right side as a column of its left side. Joins chain right to left: in `a lj b lj c`, `c` is joined onto `b` first |
| `unknown or not-permitted column: x` | x is not a column you are granted, or a column computed inside `wj` | Check `describe`; avoid post-processing `wj` |
| `x.y: y is not a part q takes after a dot` | A dotted part q does not have | Use the parts it lists, or cast |
| `full table scan` | A select of a partitioned table does not start with a two-sided bound on the partition column | Put `date=d`, `date in ...` or `date within d0 d1` first, in every nested select too |
| `too many partitions` | The date range reads more partitions than the gateway allows | Narrow the range, or aggregate per day in smaller ranges |
| `nyi` | `exec` or `select[n]` directly on a partitioned table | Wrap a plain select (section 3) |
| `casts to an enumeration` | A cast to a name that is neither a type nor an extraction | Cast to a type (`` `minute$ ``), extract (`` `hh$ ``), or bucket with `xbar` |
| `function not permitted: \: (each-left...)` | A lambda, a local assignment, an iterator applied by its glyph (`+\:` in a `wj` window), or a function off the list | Use a built-in; build `wj` windows as two lists, or use the cumulative-sum technique |
| `x is a column this query names, but that name is taken on this server` | A nested select's computed column shares a name with something on the server | Rename that column in both places |
| `a where after a value: ...` | An outer `where` written after an unparenthesised nested select | Put the nested select in parentheses (section 3) |
| `expression head is not a function: ...` | A list placed before its argument, which q reads as indexing | Index with `@` or brackets, or restructure |
| `aj: the right side has no column time to join on` | A key of a keyed join is missing from one side, often renamed | Keep the key columns, under their names, on both sides |
| `lj requires a keyed right-hand table` | `lj`/`ij`/`pj` right side is an unkeyed select | Group the right select with `by <keycol>`, e.g. `select first col by keycol from ...`, or use `ej` |
| `result exceeds the maximum permitted row count` / `size` | The result is larger than the gateway returns | Aggregate, or take the first rows with `select[n]` over a select |
| `type` | Mixed types: a symbol where a number is expected, a timestamp compared with a date | Check the column types in `describe`; cast |
| `length` | Two lists of different lengths combined | Usually a where clause comparing a column with a list: use `in` |
| `stop: the query ran longer than the timeout` / `wsfull: ...memory` | The query read or joined too much | Narrow the dates and instruments, filter both sides of a join first, aggregate before joining |

**Wrong without an error:** nulls from an as-of join with no earlier row; a minute-part time
comparison (section 5); `differ` or `deltas` across series that should be separate (e.g. across
venues `src` before pooling); `bin` with rows after the last edge; `deltas` keeping the first
value; correlating raw price levels instead of returns (`-1+p%prev p` or `1_deltas p`); reporting
`min pnl` instead of peak-to-trough drawdown (`min pnl-maxs pnl`); a count of rows where a count
of distinct keys was meant; or a suspicious `0.0`, `0n`, or `1973` timestamp. Section 1's
independent check is how you catch these.

## 8. Reading results

A client may show only part of a large result. Aggregate to the grain the question asks for, or
take a few rows with `select[n]` over a select to inspect, and use `count` to know the full size.
Never answer from a truncated listing as if it were complete.

## 9. Sizing a query

A query's size is its rows times the bytes of the columns it returns. `describe` gives each
column's bytes per row - a date is 4, a float 8, a symbol whatever its text is - and the limits:
`maxrows` and `maxsize` refuse a result that is too big, after the work is done, and the timeout
(`timeout_s`) and memory cap stop a query that does too much work. `estimate` does the arithmetic
before anything runs: for each table the query reads, the rows its where clause selects (counted
as you, with your row filter) and their bytes; the result's rows and bytes; and a verdict -
`fits`, `large` or `toobig` - with what to change. A grouped result's rows are a bound, the rows
it reads.

- **The work is in the reads, not the result.** An aggregate over a week returns a few rows and
  reads millions. A join is as big as both its sides: filter each side to what the other needs
  (the same instruments, the same window) before joining, and aggregate before a join rather than
  after.
- **A result over `maxrows`** cannot be returned at all: aggregate to the grain the question asks
  for, or take a few rows with `select[n]` over a select.
