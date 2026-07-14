/ configuration loading and cascade resolution for the modular torq world.
/ replaces torq.q's in-process config handling (loadf, loadconfig, loadaddconfig,
/ overrideconfig). the logger is an injected dependency wired via init; the module
/ reads no environment variables or process identity itself - the caller (di.torq)
/ supplies the settings directories, name sequence and any command-line overrides.
/ public api:
/   loadcascade    - resolve the full cascade over dirs x names (name-major)
/   overrideconfig - apply command-line-style overrides after the cascade
/   getmodule      - query the resolved config store as a per-namespace dict; di.torq
/     partitions config per module with it and injects each slice via that module's init
/ internal helper loadconfig handles per-file loading behind loadcascade.

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable.
  / guard the log call: the logger is unset until init runs, so a public fn misused
  / before init still signals the real message rather than a name error on logerr.
  .[{.z.m.logerr[x;y]};(ctx;msg);{}];
  '"di.config: ",string[ctx],": ",msg;
  };

init:{[deps]
  / wire injectable dependencies - log is required, there is no silent fallback.
  / deps: a dict with a `log key; log must already be a binary `info`warn`error
  / dict of {[c;m]} loggers - build it from di.log (the standard logger, which
  / exports binary info/warn/error) or hand-roll one. no adaptation is performed
  / here, so a non-conforming logger (e.g. a raw monadic kx.log instance) must be
  / wrapped by the caller first. examples:
  /   config.init[enlist[`log]!enlist logdep]
  /   config.init[`log`timer!(logdep;timerdep)]
  if[99h<>type deps;
    '"di.config: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.config: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.config: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.config: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.loaded:enlist"";
  .z.m.loginfo[`init;"di.config initialised"];
  };

loadconfig:{[dir;name]
  / internal - load one cascade config file dir/{name}.q if present, tracking it
  / so it is not re-loaded. a missing file is normal in the cascade (not every
  / proctype/procname has one), so its absence is logged at info and skipped, not
  / warned. returns the file path.
  if[not 10h=abs type dir;
    raiseerror[`loadconfig;"dir must be a string path"];
  ];
  if[not -11h=type name;
    raiseerror[`loadconfig;"name must be a symbol"];
  ];
  file:dir,"/",string[name],".q";
  if[file in .z.m.loaded;
    .z.m.loginfo[`loadconfig;"already loaded ",file];
    :file;
  ];
  if[()~key hsym `$file;
    .z.m.loginfo[`loadconfig;"no config file (skipping): ",file];
    :file;
  ];
  .z.m.loginfo[`loadconfig;"loading ",file];
  .[system;enlist"l ",file;{[f;e] raiseerror[`loadconfig;"failed to load ",f,": ",e]}[file;]];
  .z.m.loaded,:enlist file;
  :file;
  };

loadcascade:{[dirs;names]
  / resolve a configuration cascade name-major: for each config name (least to
  / most specific) load it from every directory in turn. files load in sequence,
  / so a more specific name always wins over a less specific one regardless of
  / directory, and within a single name the later (higher-priority) directory
  / overrides the earlier. dirs is a directory path or list of paths (strings),
  / ordered lowest->highest priority; names is a config name or list of names
  / (symbols), ordered least->most specific. missing files are skipped (by
  / loadconfig). returns the flat list of constructed paths, in load order.
  / typical caller (di.torq resolves the dirs and process identity):
  /   config.loadcascade[(kdbconfig;appconfig);`default,proctype,procname]
  dirs:$[10h=type dirs;enlist dirs;dirs];
  names:(),names;
  if[not 0h=type dirs;
    raiseerror[`loadcascade;"dirs must be a string path or a list of string paths"];
  ];
  if[not all 10h=type each dirs;
    raiseerror[`loadcascade;"dirs must be a string path or a list of string paths"];
  ];
  if[not 11h=abs type names;
    raiseerror[`loadcascade;"names must be a symbol or a symbol list"];
  ];
  .z.m.loginfo[`loadcascade;"resolving cascade: ",(string count dirs)," dir(s) x ",(string count names)," name(s)"];
  :raze {[ds;nm] loadconfig[;nm] each ds}[dirs;] each names;
  };

hexchars:"0123456789abcdefABCDEF";

parsefailed:{[t;raw;vals]
  / internal - true if any raw string failed to parse to type t. boolean (1h) and byte
  / (4h) are the only in-scope basic types with no null, so a bad parse ("B"$"bad" -> 0b,
  / "X"$"gg" -> 0x00) slips past a null check and would silently corrupt config - validate
  / their raw string form explicitly. every other type yields a null on a bad parse.
  :$[1h=abs t;not all raw in (enlist"0";enlist"1");
     4h=abs t;not all {(0=count[x] mod 2) and all x in hexchars} each raw;
     any null vals];
  };

applyoverride:{[name;raw]
  / internal - parse raw command-line value(s) into name's current type and set it. raw
  / is a string or a list of strings. returns 1b if applied, 0b if the variable is not a
  / basic type or a value failed to parse. the variable must already exist - its current
  / type drives the parse.
  t:type value name;
  if[not (abs t) within (1;-1+count .Q.t);
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": not a basic type"];
    :0b;
  ];
  raw:$[10h=type raw;enlist raw;raw];
  vals:(upper .Q.t abs t)$'raw;
  if[parsefailed[t;raw;vals];
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": value did not parse"];
    :0b;
  ];
  if[t<0;vals:first vals];
  .z.m.loginfo[`overrideconfig;"setting ",(string name)," to ",-3!vals];
  set[name;vals];
  :1b;
  };

overrideconfig:{[params]
  / apply command-line-style overrides to already-defined variables, parsing each
  / value into the variable's existing type. params is a dict keyed by variable
  / name (symbol) with string (or list-of-string) values. only defined variables
  / can be overridden (their type drives the parse); undefined names are logged
  / and skipped. returns the list of variables actually overridden. call after
  / loadcascade to let the command line win over file config.
  if[99h<>type params;
    raiseerror[`overrideconfig;"params must be a dict keyed by variable name"];
  ];
  vars:key params;
  if[0<count vars;
    if[not 11h=abs type vars;
      raiseerror[`overrideconfig;"params keys must be symbols (variable names)"];
    ];
  ];
  defined:vars where {@[{value x;1b};x;0b]} each vars;
  undefined:vars except defined;
  if[count undefined;
    .z.m.logwarn[`overrideconfig;"skipping undefined variable(s): ",", " sv string undefined];
  ];
  applied:{[params;v] applyoverride[v;params v]}[params;] each defined;
  :defined where applied;
  };

/ --- queryable config store ---
/ the store is the set of root namespaces populated by the settings files that
/ loadcascade loads (plus anything overrideconfig changes). getmodule queries it;
/ di.torq uses getmodule to partition config per module and pass each slice to that
/ module's init.
/ EXTENSION POINT (out of scope for v1, flagged per the modularisation plan):
/ additional config sources - environment variables, k8s config maps, external
/ key-value stores - would plug in by populating the same root namespaces before
/ the store is queried. keep source reading (loadcascade et al.) separate from
/ querying (below) so a new source is an additive step, not a change to the
/ getmodule contract.

getmodule:{[namespace]
  / return all resolved config for a namespace as a bare-keyed value dict, for
  / di.torq to partition and pass to a module's init. namespace is a bare symbol
  / with no leading dot; an unconfigured namespace yields an empty dict.
  if[not -11h=type namespace;
    raiseerror[`getmodule;"namespace must be a symbol (no leading dot)"];
  ];
  ns:`$".",string namespace;
  vars:@[{system"v ",x};".",string namespace;`$()];
  cfg:vars!{[ns;v] value ` sv (ns;v)}[ns;] each vars;
  / \v lists child namespaces alongside settings, so drop them - only leaf settings
  / belong in a module's config slice. a child namespace is a 99h dict carrying a
  / null-symbol self-reference key; a genuine dict-valued setting has no such key and
  / is kept. guard the key lookup with a cond (not `and`, which evaluates eagerly and
  / would run `key` on non-dict values).
  :(where {$[99h=type x;(`) in key x;0b]} each cfg) _ cfg;
  };
