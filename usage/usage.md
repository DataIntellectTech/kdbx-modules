# `usage.q` – External Usage Logging for kdb+

A utility library for logging external queries and connections to a kdb+ session. It captures metadata such as execution time, memory usage, user information, command content, and errors.

> **Note:** Initialising this library **overwrites `.z` message handlers** with wrapped versions for logging.

---

## :sparkles: Features

- Tracks external usage: connections, queries, authentication.
- Logs to memory (in-table) and/or disk (append-only file).
- Supports filtering via ignore lists.
- Captures execution times, arguments, system info, and result sizes.
- Pluggable `.usage.ext` function for custom log sinks.
- Flush/parse logs from memory or file.

---

## :label: Usage Table Schema

Logs are stored in `.usage.usage` with the following columns:

| Column   | Type      | Description                               |
|----------|-----------|-------------------------------------------|
| time     | `timestamp` | Time of the event                       |
| id       | `long`     | Unique ID for the request                |
| exTime   | `timespan` | Execution duration (if applicable)       |
| zcmd     | `symbol`   | `.z` command (`pg`, `ph`, `pw`, etc.)    |
| status   | `char`     | `b` = before, `c` = complete, `e` = error |
| a        | `int`      | Remote IP address                        |
| u        | `symbol`   | Remote user                              |
| w        | `int`      | Connection handle                        |
| cmd      | `string`   | Formatted query/argument to handler      |
| mem      | `list`     | Partial memory stats from `system "w"`   |
| sz       | `long`     | Size of result in bytes                  |
| error    | `string`   | Error message (if applicable)            |

---

## :gear: Configuration

Depending on the desired behaviour, config variables can be set **before running** `.usage.init`:

```q
.usage.logdir  : "/path/to/logs";       / Path to log directory
.usage.logname : "rdb";                 / Identifier used in log file name: usage_{logname}_{timestamp}.log
.usage.logtimestamp : {.z.Z};           / Function to give log name timestamp suffix (default: {[] :.z.D;})
.usage.enabled : 1b;                    / Enable logging (default: 1b)
.usage.logtodisk : 1b;                  / Log to disk (default: 0b)
.usage.logtomemory : 1b;                / Log to memory table (default: 1b)
.usage.LEVEL : 2;                       / Logging level (0–3, see below) (default: 3)
.usage.ignore : 1b;                     / Enable log-skipping for configured functions (default: 1b)
.usage.ignorelist : enlist `upd;        / Functions to skip logging (in .z.ps only)
```

Log level meanings:

| Level | Description                                     |
|-------|-------------------------------------------------|
| 0     | Disable all logging                             |
| 1     | Only errors                                     |
| 2     | + connection open/close, query complete         |
| 3     | + query begin events                            |

---

## :wrench: Functions

### :pencil2: Logging Functions

| Function                  | Description                                          |
|---------------------------|------------------------------------------------------|
| `.usage.logauth`          | Log user/password validation                         |
| `.usage.logconnection`    | Log connection open/close                            |
| `.usage.logquery`         | Log before/after a query                             |
| `.usage.logqueryfiltered` | Like `logquery`, but skips if in `.usage.ignorelist` |
| `.usage.logdirect`        | Low-level: log a completed request                   |
| `.usage.logbefore`        | Low-level: log query start                           |
| `.usage.logafter`         | Low-level: log query completion                      |
| `.usage.logerror`         | Low-level: log query failure                         |

### :rocket: Initialisation

The package is initialised by calling the nullary function `.usage.init[]` which calls the `usage.inithandlers` and `.usage.initlog` functions, overriding the `.z.*` message handlers 
and initiates the in memory logs/ on disk logs if enabled.

| Function              | Description                                                                                                              |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------|
| `.usage.inithandlers` | Wrap `.z.*` message handlers for logging                                                                                 |
| `.usage.initlog`      | Create file handle if `.usage.logtodisk` is set. Will fail if `.usage.logdir` or `.usage.logname` have not be configured |
| `.usage.init`         | Run full initialisation                                                                                                  |


---

## :memo: Log File Output

- Log files are created as: `usage_{logname}_{timestamp}.log`
- Format: pipe-delimited strings with same columns as `.usage.usage`

Use `.usage.readlog` to parse logs from disk:

```q
.usage.readlog["logs/usage_rdb_2025.06.25.log"]
```

---

## :hammer_and_wrench: Utilities

| Function               | Description                                                                                       |
|------------------------|---------------------------------------------------------------------------------------------------|
| `.usage.flushusage[t]` | Remove records older than `t` (timespan) ago from memory                                          |
| `.usage.ext[x]`        | Optional extension hook for each record written (`x` is a list of column data for `.usage.usage`) |
| `.usage.nextid[]`      | Generate next usage ID                                                                            |
| `.usage.meminfo[]`     | Get partial system memory stats                                                                   |
| `.usage.formatarg`     | Format incoming `.z` argument for logging                                                         |

---

## :arrows_counterclockwise: Overridden `.z` Handlers

The following `.z` handlers are wrapped automatically (with custom handler function staying preserved):

- `.z.pw` – password check → `logauth`
- `.z.po`, `.z.pc`, `.z.wo`, `.z.wc` – connection open/close → `logconnection`
- `.z.ws`, `.z.pg`, `.z.ph`, `.z.pp`, `.z.exit` – queries → `logquery`
- `.z.ps` – query (with filtering) → `logqueryfiltered`

Default handlers will be defined if not previously set.

---

## :bulb: Notes

- You can override `.usage.ext` to forward records to a pub/sub topic, REST endpoint, etc.
- The in-memory logging table can be disabled by setting `.usage.logtomemory:0b`.
- This module is compatible with kdb+ 3.0 or later.

---

## :test_tube: Example

```q
/ Set up logging to disk and memory
.usage.logdir:"logs";
.usage.logname:"rdb";
.usage.logtodisk:1b;
.usage.logtomemory:1b;
.usage.ignorelist,:(`upd; ".hb.checkheartbeat[]");
\l usage.q
.usage.init[]

/ Check usage table for synchronous user queries
select from .usage.usage where zcmd=`pg
time                          id  exTime               zcmd status a          u     w  cmd                                                                   mem                           sz  error
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
2025.07.04D11:57:59.474947647 194                      pg   b      2130706433 kdbNoob 14 "tables[]"                                                            8273600 67108864 67108864 0 0     ""
2025.07.04D11:57:59.475151569 194 0D00:00:00.000009790 pg   c      2130706433 kdbNoob 14 "tables[]"                                                            8274560 67108864 67108864 0 0 71  ""
2025.07.04D11:58:05.535593991 196                      pg   b      2130706433 kdbNoob 14 "select from quote where sym in (\"AAPL\";\"MSFT\"), time>.z.p-00:05" 8274912 67108864 67108864 0 0     ""
2025.07.04D11:58:05.536083945 196 0D00:00:00.000001382 pg   e      2130706433 kdbNoob 14 "select from quote where sym in (\"AAPL\";\"MSFT\"), time>.z.p-00:05" 8275440 67108864 67108864 0 0     "type"
2025.07.04D11:58:19.986818174 200                      pg   b      2130706433 kdbNoob 14 "select from quote where sym in `AAPL`MSFT, time>.z.p-00:05"          8277664 67108864 67108864 0 0     ""
2025.07.04D11:58:19.987270684 200 0D00:00:00.000026848 pg   c      2130706433 kdbNoob 14 "select from quote where sym in `AAPL`MSFT, time>.z.p-00:05"          8278208 67108864 67108864 0 0 118 ""
```
