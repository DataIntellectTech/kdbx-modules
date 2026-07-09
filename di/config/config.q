/ configuration loading and cascade resolution for the modular torq world.
/ replaces torq.q's in-process config handling (loadf, loaddir, loadconfig,
/ loadaddconfig, overrideconfig). the logger is an injected dependency wired via
/ init; the module reads no environment variables or process identity itself -
/ the caller (di.torq) supplies the settings directories, name sequence and any
/ command-line overrides. layered lowest to highest priority:
/   loadfile  - load one file by path (deduplicated)
/   loadconfig - load one cascade file dir/{name}.q (missing is normal)
/   loaddir   - load every .q/.k file in a directory (honours order.txt)
/   loadcascade   - resolve the full cascade over dirs x names (name-major)
/   overrideconfig - apply command-line-style overrides after the cascade
/   get / getmodule - query the resolved config store (di.torq partitions per
/     module with getmodule and injects each slice via that module's init)

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable
  / in the log as well as thrown to the caller.
  .z.m.log[`error][ctx;msg];
  '"di.config: ",string[ctx],": ",msg;
  };

init:{[deps]
  / wire injectable dependencies - log is required, there is no silent fallback.
  / deps: a dict with a `log key; log must already be a binary `info`warn`error
  / dict of {[c;m]} loggers (from di.log once it ships, or hand-rolled). no
  / adaptation is performed here - a raw monadic kx.log instance must be wrapped
  / by the caller before being passed. examples:
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
  .z.m.log:deps`log;
  .z.m.loaded:enlist"";
  .z.m.log[`info][`init;"di.config initialised"];
  };

loadfile:{[file]
  / load a single q config file if it exists, tracking it so it is not re-loaded.
  / returns the file path; a missing file is a logged warning, not an error.
  if[not 10h=abs type file;
    raiseerror[`loadfile;"file must be a string path"];
  ];
  if[file in .z.m.loaded;
    .z.m.log[`info][`loadfile;"already loaded ",file];
    :file;
  ];
  if[()~key hsym `$file;
    .z.m.log[`warn][`loadfile;"config file not found: ",file];
    :file;
  ];
  .z.m.log[`info][`loadfile;"loading ",file];
  .[system;enlist"l ",file;{[f;e] raiseerror[`loadfile;"failed to load ",f,": ",e]}[file;]];
  .z.m.loaded,:enlist file;
  :file;
  };

loadconfig:{[dir;name]
  / load a single cascade config file dir/{name}.q if it is present. a missing
  / file is normal in the cascade (not every proctype/procname has one), so its
  / absence is logged at info and skipped, NOT warned. present files load via
  / loadfile, so they are tracked and de-duplicated. returns the file path.
  if[not 10h=abs type dir;
    raiseerror[`loadconfig;"dir must be a string path"];
  ];
  if[not -11h=type name;
    raiseerror[`loadconfig;"name must be a symbol"];
  ];
  file:dir,"/",string[name],".q";
  if[()~key hsym `$file;
    .z.m.log[`info][`loadconfig;"no config file (skipping): ",file];
    :file;
  ];
  :loadfile file;
  };

loaddir:{[dir]
  / load every .q and .k file in a directory, honouring an optional order.txt.
  / files listed in order.txt load first, in that order; the rest follow in the
  / order key returns them. returns the ordered list of file paths processed;
  / a missing directory is a logged warning returning (). each load is delegated
  / to loadfile, so files already loaded are skipped.
  if[not 10h=abs type dir;
    raiseerror[`loaddir;"dir must be a string path"];
  ];
  if[()~files:key hsym `$dir;
    .z.m.log[`warn][`loaddir;"directory not found: ",dir];
    :();
  ];
  haveorder:`order.txt in files;
  if[haveorder;
    .z.m.log[`info][`loaddir;"found order.txt in ",dir];
  ];
  order:$[haveorder;(`$read0 hsym `$dir,"/order.txt") inter files;`symbol$()];
  files:files where any files like/:("*.q";"*.k");
  files:order,files except order;
  paths:(dir,"/"),/:string files;
  .z.m.log[`info][`loaddir;"loading ",(string count paths)," file(s) from ",dir];
  loadfile each paths;
  :paths;
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
  .z.m.log[`info][`loadcascade;"resolving cascade: ",(string count dirs)," dir(s) x ",(string count names)," name(s)"];
  :raze {[ds;nm] loadconfig[;nm] each ds}[dirs;] each names;
  };

applyoverride:{[name;raw]
  / internal - parse raw command-line value(s) into name's current type and set
  / it. raw is a string or a list of strings. returns 1b if applied, 0b if the
  / variable is not a basic type or a value failed to parse (null). the variable
  / must already exist - its current type drives the parse.
  t:type value name;
  if[not (abs t) within (1;-1+count .Q.t);
    .z.m.log[`error][`overrideconfig;"cannot override ",(string name),": not a basic type"];
    :0b;
  ];
  raw:$[10h=type raw;enlist raw;raw];
  vals:(upper .Q.t abs t)$'raw;
  if[t<0;vals:first vals];
  if[any null vals;
    .z.m.log[`error][`overrideconfig;"cannot override ",(string name),": value did not parse"];
    :0b;
  ];
  .z.m.log[`info][`overrideconfig;"setting ",(string name)," to ",-3!vals];
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
    .z.m.log[`warn][`overrideconfig;"skipping undefined variable(s): ",", " sv string undefined];
  ];
  applied:{[params;v] applyoverride[v;params v]}[params;] each defined;
  :defined where applied;
  };

/ --- queryable config store ---
/ the store is the set of root namespaces populated by the settings files that
/ loadcascade loads (plus anything overrideconfig changes). getcfg/getmodule
/ query it; di.torq uses getmodule to partition config per module and pass each
/ slice to that module's init.
/ EXTENSION POINT (out of scope for v1, flagged per the modularisation plan):
/ additional config sources - environment variables, k8s config maps, external
/ key-value stores - would plug in by populating the same root namespaces before
/ the store is queried. keep source reading (loadcascade et al.) separate from
/ querying (below) so a new source is an additive step, not a change to the
/ get/getmodule contract.

getcfg:{[ns;k;dflt]
  / query the resolved config store: return the value of the loaded config
  / variable .{ns}.{k}, or dflt if it is not set. ns and k are bare symbols with
  / no leading dot (e.g. getcfg[`rdb;`subscribeto;`]). exported under the `get`
  / key. NB: params are ns/k/dflt because key and default are reserved words -
  / used as parameter names they throw 'match when the function is called (and
  / neither is listed in .Q.res).
  if[not -11h=type ns;
    raiseerror[`get;"namespace must be a symbol (no leading dot)"];
  ];
  if[not -11h=type k;
    raiseerror[`get;"key must be a symbol"];
  ];
  :@[value;`$".",(string ns),".",string k;dflt];
  };

getmodule:{[namespace]
  / return all resolved config for a namespace as a bare-keyed value dict, for
  / di.torq to partition and pass to a module's init. namespace is a bare symbol
  / with no leading dot; an unconfigured namespace yields an empty dict.
  if[not -11h=type namespace;
    raiseerror[`getmodule;"namespace must be a symbol (no leading dot)"];
  ];
  ns:`$".",string namespace;
  vars:@[{system"v ",x};".",string namespace;`$()];
  :vars!{[ns;v] value ` sv (ns;v)}[ns;] each vars;
  };
