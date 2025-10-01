# `usage.q` – External Usage Logging for kdb+

A utility library for logging external queries and connections to a kdb+ session. It captures metadata such as execution time, memory usage, user information, command content, and errors.

> **Note:** Initialising this library **overwrites `.z` message handlers** with wrapped versions for logging.

---

## :sparkles: Features

- Tracks external usage: connections, queries, authentication.
- Logs to memory (in-table) and/or disk (append-only file).
- Supports filtering via ignore lists.
- Captures execution times, arguments, system info, and result sizes.
- Pluggable `ext` function for custom log sinks.
- Flush/parse logs from memory or file.

---

## :label: Usage Table Schema

Logs are stored in `usage` with the following columns:

| Column | Type      | Description                               |
|--------|-----------|-------------------------------------------|
| time   | `timestamp` | Time of the event                       |
| id     | `long`     | Unique ID for the request                |
| extime | `timespan` | Execution duration (if applicable)       |
| zcmd   | `symbol`   | `.z` command (`pg`, `ph`, `pw`, etc.)    |
| status | `char`     | `b` = before, `c` = complete, `e` = error |
| a      | `int`      | Remote IP address                        |
| u      | `symbol`   | Remote user                              |
| w      | `int`      | Connection handle                        |
| cmd    | `string`   | Formatted query/argument to handler      |
| mem    | `list`     | Partial memory stats from `system "w"`   |
| sz     | `long`     | Size of result in bytes                  |
| error  | `string`   | Error message (if applicable)            |

---

## :gear: Configuration

Depending on the desired behaviour, config variables can be set **before running** `init`:

```q
localtime    : 1b                   // Log using local time or UTC (default: 1b, local)
logdir       : "/path/to/logs";     // Path to log directory
logname      : "rdb";               // Identifier used in log file name: usage_{logname}_{timestamp}.log
logtimestamp : {.z.Z};              // Function to give log name timestamp suffix (default: {[] :.z.D;})
logtodisk    : 1b;                  // Log to disk (default: 0b)
logtomemory  : 1b;                  // Log to memory table (default: 1b)
level        : 2;                   // Logging level (0–3, see below) (default: 3)
ignore       : 1b;                  // Enable log-skipping for configured functions (default: 1b)
ignorelist   : enlist `upd;         // Functions to skip logging (in .z.ps only)
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
| `logauth`          | Log user/password validation                         |
| `logconnection`    | Log connection open/close                            |
| `logquery`         | Log before/after a query                             |
| `logqueryfiltered` | Like `logquery`, but skips if in `ignorelist` |
| `logdirect`        | Low-level: log a completed request                   |
| `logbefore`        | Low-level: log query start                           |
| `logafter`         | Low-level: log query completion                      |
| `logerror`         | Low-level: log query failure                         |

### :rocket: Initialisation

The package is initialised by calling the nullary function `init[]` which calls the `inithandlers` and `initlog` functions, overriding the `.z.*` message handlers 
and initiates the in memory logs/ on disk logs if enabled.

| Function              | Description                                                                                                              |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------|
| `inithandlers` | Wrap `.z.*` message handlers for logging                                                                                 |
| `initlog`      | Create file handle if `logtodisk` is set. Will fail if `logdir` or `logname` have not be configured |
| `init`         | Run full initialisation                                                                                                  |


---

## :memo: Log File Output

- Log files are created as: `usage_{logname}_{timestamp}.log`
- Format: pipe-delimited strings with same columns as `usage`

Use `readlog` to parse logs from disk:

```q
usage.readlog["logs/usage_rdb_2025.06.25.log"]
```

---

## :hammer_and_wrench: Utilities

| Function               | Description                                                                                       |
|------------------------|---------------------------------------------------------------------------------------------------|
| `flushusage[t]` | Remove records older than `t` (timespan) ago from memory                                          |
| `ext[x]`        | Optional extension hook for each record written (`x` is a list of column data for `usage`) |
| `nextid[]`      | Generate next usage ID                                                                            |
| `meminfo[]`     | Get partial system memory stats                                                                   |
| `formatarg`     | Format incoming `.z` argument for logging                                                         |

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

- You can override `ext` to forward records to a pub/sub topic, REST endpoint, etc.
- The in-memory logging table can be disabled by setting `logtomemory:0b`.
- This module is compatible with kdb+ 3.0 or later.

---

## :test_tube: Example

```q
// Set up logging to disk and memory in usage.q
localtime:1b;
logdir:"logs";
logname:"rdb";
logtodisk:1b;
logtomemory:1b;
ignorelist,:(`upd; ".hb.checkheartbeat[]");
```

```q
// Include usage package in a process
usage: use `usage
usage.init[]

// View dictionary of functions
usage

init      | `.m.usage.export.init[]
getusage  | `.m.usage.export.getusage[]
readlog   | `.m.usage.export.readlog[]
flushusage| `.m.usage.export.flushusage[]
ext       | `.m.usage.export.ext[]
nextid    | `.m.usage.export.nextid[]
meminfo   | `.m.usage.export.meminfo[]
formatarg | `.m.usage.export.formatarg[]



// Check usage table for synchronous user queries
select from usage.getusage[] where zcmd=`pg
time                          id  extime               zcmd status a          u     w  cmd                                                                   mem                           sz  error
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
2025.07.04D11:57:59.474947647 194                      pg   b      2130706433 kdbNoob 14 "tables[]"                                                            8273600 67108864 67108864 0 0     ""
2025.07.04D11:57:59.475151569 194 0D00:00:00.000009790 pg   c      2130706433 kdbNoob 14 "tables[]"                                                            8274560 67108864 67108864 0 0 71  ""
2025.07.04D11:58:05.535593991 196                      pg   b      2130706433 kdbNoob 14 "select from quote where sym in (\"AAPL\";\"MSFT\"), time>.z.p-00:05" 8274912 67108864 67108864 0 0     ""
2025.07.04D11:58:05.536083945 196 0D00:00:00.000001382 pg   e      2130706433 kdbNoob 14 "select from quote where sym in (\"AAPL\";\"MSFT\"), time>.z.p-00:05" 8275440 67108864 67108864 0 0     "type"
2025.07.04D11:58:19.986818174 200                      pg   b      2130706433 kdbNoob 14 "select from quote where sym in `AAPL`MSFT, time>.z.p-00:05"          8277664 67108864 67108864 0 0     ""
2025.07.04D11:58:19.987270684 200 0D00:00:00.000026848 pg   c      2130706433 kdbNoob 14 "select from quote where sym in `AAPL`MSFT, time>.z.p-00:05"          8278208 67108864 67108864 0 0 118 ""
```
