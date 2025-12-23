# Log module reference

This module is based off the base kdb-x logging module provided by KX

The kdb-x logging module is a simple logging framework. 

For the purpose of documenting, the coded examples provided here assume the logging library has been loaded into the namespace `.logger`, and a logging instance has been created under the `.log` namespace like so: 

```q
.logger:use`di.log
.log:.logger.createLog[]
```

But remember, under the kdb-x module framework this can be loaded into a project under any name desired.

## Instance Creation

The logging module supports multiple independent log instances within a single q process. This is achieved using a factory design pattern: the module exposes a single function, `createLog`, which returns a fully initialized, independent, logger instance.

```q
.logger.createLog[]
```

This returns a dictionary containing all logging APIs, state and accessors so multiple loggers can operate independently. 

This is useful when a single q process has multiple sections, and a particular section needs to be debugged. E.g.

```q
q).logger:use`di.log;
q)\d .foo
q.foo)logger:.logger.createLog[];
q.foo)f:{logger.trace "trace from foo"};
q.foo)\d .bar
q.bar)logger:.logger.createLog[];
q.bar)f:{logger.trace "trace from bar";logger.warn "warn from bar"};
q.bar)\d .
q).foo.f[]; // expect no output since default log level is info
q).bar.f[]; // expect output since there is a warn log
2025.10.23D11:09:47.645765308 warn PID[94486] HOST[a-lptp-p2myzzg4] warn from bar
q).foo.logger.setlvl `trace; // change foo log level to trace
q).foo.f[]; // shows trace
2025.10.23D11:10:18.631553544 trace PID[94486] HOST[a-lptp-p2myzzg4] trace from foo
q).bar.f[]; // still only shows warn since log level wasn't chanted for bar
2025.10.23D11:10:34.057420473 warn PID[94486] HOST[a-lptp-p2myzzg4] warn from bar
```

## Logging APIs

To log to a particular level, run with `.log.xxxx`, where `xxxx` is one of:

<a id="log-levels"></a>

- `trace`
- `debug`
- `info`
- `warn`
- `error`
- `fatal`

These can each be called in the following ways
>**Note:** Referencing `info` in the following examples but this extends to each of the above APIs

### Simple Logging

```q
.log.info[message]
```

Where `message` is either
- A string
- A general list (see [variable logging](#variable-logging))

```q
q).log.info "Hello World!"
2025.10.13D12:37:12.911621911 info PID[658720] HOST[a-lptp-p2myzzg4] Hello World!
```

### Variable Logging

Dependent on di.printf module - this has been derived from KX's [`printf`](https://github.com/KxSystems/printf) module. 

Variables can be included in log messages using arguments in junction with format specifiers.

```q
.log.info (message;arg1;arg2;...)
```

Where `arg1`,`arg2`,...  are the variables to be formatted in the message. The number of arguments depends on the number of format specifiers are in the message string.

```q
q).log.info ("myvar: %r";`foo)
2025.10.30D10:22:19.124336219 info PID[1937319] HOST[a-lptp-p2myzzg4] myvar: `foo
q).log.info ("var1: %s, var2: %r";`foo;123)
2025.10.30D10:22:38.850194514 info PID[1937319] HOST[a-lptp-p2myzzg4] var1: foo, var2: 123
q).log.info ("var1: %r, var2: %s";"\t tab";"\t tab")
2025.10.30D10:22:52.071370289 info PID[1937319] HOST[a-lptp-p2myzzg4] var1: "\t tab", var2:      tab
q).log.info ("formatted float: %08.3f";3.1415926536)
2025.10.30D10:23:34.987634986 info PID[1937319] HOST[a-lptp-p2myzzg4] formatted float:    3.142
```

## Log Levels

Log levels specify at which severity to report.

### Get Level

_Get the current log level_

```q
.log.getlvl[]
```

Returns the current log `level` (symbol)

```q
q).log.getlvl[]
`info
```

### Set Level

_Set the log level_

```q
.log.setlvl[level]
```

Where `level` is an [available log level](#log-levels)

```q
q).log.info "hi"
2025.10.13D11:39:51.014213515 info PID[489737] HOST[a-lptp-p2myzzg4] hi
q).log.setlvl `error
q).log.info "you can't see me"
```

## Formats

Formats dictate how a log message is formatted. 

### Replacement Rules

The following are the replacement rules for a formatter:

| Pattern | Replacement                  | Notes                           |
|---------|------------------------------|---------------------------------|
| $a      | .z.a                         | IP address                      |
| $c      | .z.c                         | cores                           |
| $f      | .z.f                         | file                            |
| $h      | .z.h                         | host                            |
| $i      | .z.i                         | PID                             |
| $K      | .z.K                         | version                         |
| $k      | .z.k                         | release date                    |
| $o      | .z.o                         | OS version                      |
| $u      | .z.u                         | user ID                         |
| $d      | .z.d                         | UTC date                        |
| $D      | .z.D                         | local date                      |
| $n      | .z.n                         | UTC timespan                    |
| $N      | .z.N                         | local timespan                  |
| $p      | .z.p                         | UTC timestamp                   |
| $P      | .z.P                         | local timestamp                 |
| $t      | .z.t                         | UTC time                        |
| $T      | .z.T                         | local time                      |
| $z      | .z.z                         | UTC datetime                    |
| $Z      | .z.Z                         | local datetime                  |
| $l      | log level of this message    |                                 |
| $m      | user provided log message    |                                 |
| $w      | " " sv string system"w"      | current memory usage            |
| $s      | syslog level of this message | converts `info to 6 for example |

### Provided Formats

This module provides off the shelf the following formats:

- __basic__
```q
"$p $l PID[$i] HOST[$h] $m\r\n"
```

- __syslog__
```q
"<$s> $m\r\n"
```

- __raw__ 
```q
"$m\r\n"
```

>**Tip:** Use the raw format in junction with `.j.j` to log json
>
> ```q
> q).log.setfmt `raw
> q).log.info .j.j `foo`bar!til 2
> {"foo":0,"bar":1}
> ```

### List Formats

_List registered formats_

```q
.log.fmts[];
```

Returns a dictionary, where the keys are the names of the registered format, and the values are the format rules.

```q
q).log.fmts[]
basic | "$p $l PID[$i] HOST[$h] $m\r\n"
syslog| "<$s> $m\r\n"
raw   | "$m\r\n"
```

### Set Format

_Set log format_

```q
.log.setfmt[name]
```

Where `name` is a registered format, visible in `.log.fmts[]`.

```q
q).log.info "hi"
2025.10.13D11:16:34.445967945 info PID[408461] HOST[a-lptp-p2myzzg4] hi
q).log.setfmt `syslog
q).log.info "hi"
<6> hi
q).log.setfmt `raw
q).log.info .j.j `foo`bar!til 2
{"foo":0,"bar":1}
```
### Get Format

_Check current log format_

```q
.log.getfmt[]
```

Returns the current format as a symbol

```q
q).log.getfmt[]
`basic
```

### Add Formats

_Register custom format_

```q
.log.addfmt[name;format]
```

Where
- `name` is a name to register the new format as (symbol)
- `format` is a string defining the format of the output (string)

```q
q).log.addfmt[`foo;"bar: $m\r\n"]
q).log.setfmt`foo
q).log.info "lorem"
bar: lorem
```

## Sinks

Sinks are the destination for logs, can be qipc, file or system handles.

### List Sinks

_List the sinks_

```q
.log.sinks[]
```

Returns a dictionary, with the keys of the available levels, and the values of the handles subscribed to that level.

```q
q).log.sinks[]
trace| 1
debug| 1
info | 1
warn | 1
error| 2
fatal| 2
```

### Remove

_Remove a handle from a level_

```q
.log.remove[handle;level]
```

Where 

- `handle` is an integer,
- `level` is a log level

removes the handle from the level. Returns the handle removed

```q
q).log.sinks[]
trace| 1
debug| 1
info | 1
warn | 1
error| 2
fatal| 2
q).log.info "hi"
2025.10.13D11:55:51.028205975 info PID[521724] HOST[a-lptp-p2myzzg4] hi
q).log.remove[1;`info]
1
q).log.info "you can't see me"
```

### Add

The add API has two different ways of being called

#### File and System Handles

_Add a file or system sink to a level_

```q
.log.add[handle;level]
```

Where 

- `handle` is an integer
- `level` is a log level

adds the handle to the level. Returns the handle added

```q
q).log.sinks[]
trace| 1
debug| 1
info | 1
warn | 1
error| 2
fatal| 2
q).log.error "hi" // logs to stderr system handle
2025.10.13D12:00:56.977883075 error PID[549311] HOST[a-lptp-p2myzzg4] hi
q).log.add[1;`error]
1
q).log.error "hi" // logs to both stderr and stdout system handles
2025.10.13D12:01:45.822436756 error PID[549311] HOST[a-lptp-p2myzzg4] hi
2025.10.13D12:01:45.822436756 error PID[549311] HOST[a-lptp-p2myzzg4] hi
```

#### qIPC Handles

qIPC handles require additionally a function to call on the server side.

_Add a qipc sink to a level_

```q
.log.add[(handle;function);level]
```

Where 

- `handle` is an integer
- `function` is a dyadic function that accepts arguments of [handle;message], where message is the formatted string representation of a log call
- `level` is a log level

adds the qIPC handle to the level. Returns the handle added and function.


```q
q)\q -p 5000
q)system "sleep 1" // give the process time to start before connecting
q)h:hopen 5000
q).log.add[(h;{x@({-1 reverse x};y)});`info]
4i
{x@({-1 reverse x};y)}
q).log.info "hi"
2025.10.13D12:12:20.903165119 info PID[579844] HOST[a-lptp-p2myzzg4] hi

ih ]4gzzym2p-ptpl-a[TSOH ]448975[DIP ofni 911561309.02:21:21D31.01.5202
```

## Disconnects

When attempting to log to a non-existent handle, the handle is removed from all levels in `sink` and a warning message is displayed `("lost connection to handle %1, dropping";handle)`

```q
q).log.add[999i;`info] // handle 999i is not a valid handle
999i
q).log.info "hi"
2025.10.13D12:14:54.784304296 info PID[593137] HOST[a-lptp-p2myzzg4] hi
2025.10.13D12:14:54.784402446 warn PID[593137] HOST[a-lptp-p2myzzg4] lost connection to handle 999, dropping
```

```q
q).log.add[(999i;{x@({-1 reverse x};y)});`info] // handle 999i is not a valid qIPC handle
999i
{x@({-1 reverse x};y)}
q).log.info "hi"
2025.10.13D12:19:48.981780007 info PID[607636] HOST[a-lptp-p2myzzg4] hi
2025.10.13D12:19:48.981878933 warn PID[607636] HOST[a-lptp-p2myzzg4] lost connection to handle 999, dropping
```
