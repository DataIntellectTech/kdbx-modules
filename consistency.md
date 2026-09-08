# Data Intellect KDB-X Module Consistency Guide

## module Contents
Every module must have: 
1. The code 
2. Documentation in a .md file
3. Tests, conforming to k4unit

The tests should be runnable as 

```q
q)k4unit:use`k4unit
q)k4unit.moduletest`module_to_test
```

## Paths 

Use module local paths for loading and file references

```q
/ local loading
\l ::local/path/to/file.q

/ local path
get`:::local/path/to/datafile
```

## Export

Only export the functions which should be called externally. 

## Namespaces

Avoid `\d` namespace switches.

## Injectable Dependencies

Pass dependencies as a single dict to `init` — this keeps the signature stable as more injectables are added. All dependencies are required; `init` must error immediately with a clear message if any are absent. Store each injected function in `.z.m` and always call it through `.z.m` at call sites.

```q
/ mymodule.q
init:{[deps]
  / deps - `log!(logdict) or `log`timer!(logdict;timerdict)
  /   `log: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required
  / examples:
  /   mymodule.init[enlist[`log]!enlist logdep]
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;
    '"di.mymodule: log dependency is required; pass `info`warn`error functions - see di.log or refer to confluence documentation";
  ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  };

myfunc:{[x]
  .z.m.loginfo[`mymodule;"processing ",string x];
  };
```

Callers provide a dict of functions. Use `di.log` if no custom logger is needed:

```q
logging:use`di.log
logdep:`info`warn`error!(logging.info;logging.warn;logging.error)
mymodule.init[enlist[`log]!enlist logdep]
```

`di.log`'s `logdict` skips building that dict by hand — it's already wrapped in the shape `init`
expects:

```q
logging:use`di.log
mymodule.init[logging.logdict]
```
