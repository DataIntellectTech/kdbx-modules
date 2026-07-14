/ configuration loading and cascade resolution for the modular torq world - replaces
/ torq.q's loadf/loadconfig/loadaddconfig/overrideconfig. the logger is injected via init;
/ the module reads no env/identity - the caller (di.torq) supplies dirs, names and overrides.
/ public api: loadcascade (resolve cascade over dirs x names, name-major), overrideconfig
/ (command-line overrides, applied after), getmodule (query the store as a per-namespace
/ dict; di.torq partitions config per module with it). loadconfig is the internal per-file
/ loader behind loadcascade.

init:{[deps]
  / wire the injected logger - required, no silent fallback. deps: a dict with a `log key
  / holding a binary `info`warn`error dict of {[c;m]} loggers (from di.log or hand-rolled).
  / no adaptation here, so a monadic kx.log instance must be wrapped first.
  / e.g. config.init[enlist[`log]!enlist logdep]
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
  / internal - load cascade file dir/{name}.q if present, tracking it so it is not
  / re-loaded. a missing file is normal in the cascade, so logged at info and skipped.
  / returns the file path.
  if[not 10h=abs type dir;
    .z.m.logerr[`loadconfig;err:"di.config: dir must be a string path"];
    'err;
  ];
  if[not -11h=type name;
    .z.m.logerr[`loadconfig;err:"di.config: name must be a symbol"];
    'err;
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
  .[system;enlist"l ",file;{[f;e] .z.m.logerr[`loadconfig;err:"di.config: failed to load ",f,": ",e];'err}[file;]];
  .z.m.loaded,:enlist file;
  :file;
  };

loadcascade:{[dirs;names]
  / resolve a cascade name-major: for each name (least->most specific) load it from every
  / dir in turn, so a more specific name always wins and, within a name, the later (higher-
  / priority) dir overrides. dirs is a path or list of paths (low->high priority); names a
  / symbol or symbol list (least->most specific). missing files are skipped. returns the
  / constructed paths in load order. e.g. loadcascade[(kdbconfig;appconfig);`default,proctype,procname]
  dirs:$[10h=type dirs;enlist dirs;dirs];
  names:(),names;
  if[not 0h=type dirs;
    .z.m.logerr[`loadcascade;err:"di.config: dirs must be a string path or a list of string paths"];
    'err;
  ];
  if[not all 10h=type each dirs;
    .z.m.logerr[`loadcascade;err:"di.config: dirs must be a string path or a list of string paths"];
    'err;
  ];
  if[not 11h=abs type names;
    .z.m.logerr[`loadcascade;err:"di.config: names must be a symbol or a symbol list"];
    'err;
  ];
  .z.m.loginfo[`loadcascade;"resolving cascade: ",(string count dirs)," dir(s) x ",(string count names)," name(s)"];
  :raze {[ds;nm] loadconfig[;nm] each ds}[dirs;] each names;
  };

hexchars:"0123456789abcdefABCDEF";

parsefailed:{[t;raw;vals]
  / internal - true if any raw string failed to parse to type t. boolean (1h) and byte (4h)
  / have no null, so a bad parse ("B"$"bad"->0b, "X"$"gg"->0x00) slips past a null check and
  / would corrupt config - validate their string form explicitly. other types null on failure.
  :$[1h=abs t;not all raw in (enlist"0";enlist"1");
     4h=abs t;not all {(0=count[x] mod 2) and all x in hexchars} each raw;
     any null vals];
  };

applyoverride:{[name;raw]
  / internal - parse raw value(s) into name's current type and set it. raw is a string or
  / list of strings. returns 1b if applied, 0b if name is not a basic type or a value failed
  / to parse. name must already exist - its type drives the parse.
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
  / reduce to scalar only after parsefailed (which checks the full per-element list); runs
  / before the log and set, so both use the scalar form.
  if[t<0;vals:first vals];
  .z.m.loginfo[`overrideconfig;"setting ",(string name)," to ",-3!vals];
  set[name;vals];
  :1b;
  };

overrideconfig:{[params]
  / apply command-line-style overrides to defined variables, parsing each value into the
  / variable's existing type. params is a dict of variable name (symbol) -> string (or list
  / of strings). only defined names are overridden; undefined ones are logged and skipped.
  / returns the variables actually overridden. call after loadcascade so the command line wins.
  if[99h<>type params;
    .z.m.logerr[`overrideconfig;err:"di.config: params must be a dict keyed by variable name"];
    'err;
  ];
  vars:key params;
  if[0<count vars;
    if[not 11h=abs type vars;
      .z.m.logerr[`overrideconfig;err:"di.config: params keys must be symbols (variable names)"];
      'err;
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
/ the store is the root namespaces the settings files populate (plus overrideconfig
/ changes); getmodule queries them and di.torq uses it to partition config per module.
/ EXTENSION POINT (out of scope for v1): other sources (env vars, k8s config maps) plug in
/ by populating the same namespaces before the store is queried - keep source reading
/ separate from querying so a new source is additive, not a getmodule contract change.

getmodule:{[namespace]
  / return a namespace's whole resolved config as a bare-keyed dict, for di.torq to
  / partition and inject via a module's init. namespace is a bare symbol (no leading dot);
  / an unconfigured namespace yields an empty dict.
  if[not -11h=type namespace;
    .z.m.logerr[`getmodule;err:"di.config: namespace must be a symbol (no leading dot)"];
    'err;
  ];
  ns:`$".",string namespace;
  vars:@[{system"v ",x};".",string namespace;`$()];
  / \v lists child namespaces alongside settings; drop them so the slice is flat
  / setting->value pairs. ask kdb+ whether each name is itself a namespace (\v succeeds on a
  / namespace, signals on a plain variable) - more robust than checking for a null-symbol
  / self-key, which a dict-valued setting could carry or a namespace lack.
  issub:{[ns;v] @[{system"v ",x;1b};string ` sv (ns;v);0b]};
  vars:vars where not issub[ns;] each vars;
  :vars!{[ns;v] value ` sv (ns;v)}[ns;] each vars;
  };
