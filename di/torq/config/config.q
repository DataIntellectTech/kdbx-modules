/ resolve a settings cascade over a builtin root and an app root, from flat name:value .q files and
/ .toml files, into one flat config dict; precedence is name-major, app over builtin, .toml over .q

init:{[deps]
  / wire the required `log dep (`info`warn`error dict of {[c;m]}), used by overrideconfig
  if[99h<>type deps;
    '"di.torq.config: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.torq.config: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.torq.config: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.torq.config: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.loginfo[`init;"di.torq.config initialised"];
  };

/ --- settings cascade resolution (.q + .toml -> flat dict) ---

requiretoml:{[path]
  / internal - load di.util.toml, signalling with the file name if unavailable
  :@[use;`di.util.toml;{[p;e]
    msg:"di.torq.config: cannot parse TOML file '",p,"' - the di.util.toml module was not found on QPATH; ";
    msg,:"a di.util.toml module is required to parse .toml settings (underlying: ",e,")";
    'msg
    }[path;]];
  };

parsefile:{[path]
  / parse one settings file to a flat dict: .toml via di.util.toml, .q as name:value lines;
  / a missing file is an empty dict
  fsym:`$":",path;
  if[0=count key fsym; :()!()];
  if[path like "*.toml"; :(requiretoml[path])[`parsefile] path];
  lines:read0 fsym;
  lines:lines where 0<count each lines;
  lines:lines where not lines like "/*";
  / keep only name:value lines
  lines:lines where lines like "*:*";
  pairs:{[ln] i:first where ln=":"; (`$i#ln;value (i+1)_ln)} each lines;
  $[count pairs; (first each pairs)!last each pairs; ()!()]
  };

parsetier:{[base]
  / internal - resolve one tier: base.q then base.toml, .toml winning on a clash. missing -> empty.
  (parsefile base,".q"),parsefile base,".toml"
  };

cascade:{[builtinroot;approot;parentproctype;proctype;procname]
  / merge the cascade over roots x (default;parentproctype;proctype;procname) into a flat dict;
  / proctype and procname must be non-null symbols
  if[not all -11h=type each (parentproctype;proctype;procname);
    '"di.torq.config: cascade requires parentproctype, proctype and procname to be symbol atoms"];
  if[(null proctype)|null procname;
    '"di.torq.config: cascade requires non-null proctype and procname; got ",(-3!proctype)," and ",-3!procname];
  dirs:(builtinroot;approot);
  / distinct tier names, least to most specific; parentproctype sits between default and proctype
  names:distinct (`default,parentproctype,proctype,procname) except `;
  bases:raze {[ds;nm] ds,\:"/",string nm}[dirs;] each names;
  acc:{[a;b] a,parsetier b}/[(enlist `)!enlist(::);bases];
  acc _ `
  };

/ config files for a path relative to the two roots, app before builtin; level 0 the first existing
/ (else builtin), 1 each existing app path then builtin, 2 both; empty approot is unset
getconfig:{[builtinroot;approot;path;level]
  appconf:$[count approot;`$approot,"/",path;()];
  if[(level<2) and $[count appconf;()~key hsym appconf;0b];appconf:()];
  conf:`$builtinroot,"/",path;
  (),$[level;appconf,conf;first appconf,conf]
  };

/ the first config file for a path
getconfigfile:getconfig[;;;0];

/ --- command-line override layer (top of the cascade) ---

hexchars:"0123456789abcdefABCDEF";

parsefailed:{[t;raw;vals]
  / internal - true if any raw string failed to parse to type t, including bool and byte
  :$[1h=abs t;not all raw in (enlist"0";enlist"1");
     4h=abs t;not all {(0=count[x] mod 2) and all x in hexchars} each raw;
     any null vals];
  };

applyoverride:{[name;cur;raw]
  / internal - parse raw into cur's type; returns (applied;newvalue)
  t:type cur;
  if[not (abs t) within (1;-1+count .Q.t);
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": not a basic type"];
    :(0b;cur);
  ];
  raw:$[10h=type raw;enlist raw;raw];
  / atom and string settings take exactly one value, vectors any number
  if[(1<>count raw) and ((t<0)|(10h=t));
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": expected a single value, got ",string count raw];
    :(0b;cur);
  ];
  / strings are taken as-is
  if[10h=t;
    vals:first raw;
    .z.m.loginfo[`overrideconfig;"setting ",(string name)," to ",-3!vals];
    :(1b;vals);
  ];
  vals:(upper .Q.t abs t)$'raw;
  if[parsefailed[t;raw;vals];
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": value did not parse"];
    :(0b;cur);
  ];
  / reduce to scalar only after parsefailed (which checks the whole list).
  if[t<0;vals:first vals];
  .z.m.loginfo[`overrideconfig;"setting ",(string name)," to ",-3!vals];
  :(1b;vals);
  };

overrideconfig:{[config;params]
  / apply command-line overrides to a config dict, parsed to each setting's type;
  / unknown keys and bad values are logged and skipped
  if[99h<>type config;
    .z.m.logerr[`overrideconfig;err:"di.torq.config: config must be a dict"];
    'err;
  ];
  if[99h<>type params;
    .z.m.logerr[`overrideconfig;err:"di.torq.config: params must be a dict keyed by setting name"];
    'err;
  ];
  vars:key params;
  if[0<count vars;
    if[not 11h=abs type vars;
      .z.m.logerr[`overrideconfig;err:"di.torq.config: params keys must be symbols (setting names)"];
      'err;
    ];
  ];
  paths:settingpath[config] each vars;
  undefined:vars where 0=count each paths;
  if[count undefined;
    .z.m.logwarn[`overrideconfig;"skipping unknown setting(s): ",", " sv string undefined];
  ];
  / fold each override into the config dict at its path; a skipped/rejected one leaves it unchanged
  w:where 0<count each paths;
  :{[config;params;name;path]
     res:applyoverride[name;config . path;params name];
     $[res 0;.[config;path;:;res 1];config]
   }[;params]/[config;vars w;paths w];
  };

settingpath:{[config;name]
  / internal - where an override lands: (name) for a top-level setting, (section;key) for a .section.key
  / (or section.key) naming a key of a dict-valued section, () if neither
  if[name in key config;:enlist name];
  p:`$parts where 0<count each parts:"." vs string name;
  if[not (2=count p) and (first p) in key config;:()];
  if[not 99h=type sect:config first p;:()];
  $[(last p) in key sect;p;()]
  };

getapimeta:{[]
  / this module's api metadata, one row per exported function
  :flip `name`public`descrip`params`return!flip(
    (`init;           0b; "wire the injected logger (required by overrideconfig)";       "[dict: deps with a `log key]";                                                    "null");
    (`cascade;        1b; "resolve the settings cascade over two roots -> merged flat dict (name-major, .toml>.q)"; "[string: builtinroot; string: approot; symbol: parentproctype (` if none); symbol: proctype; symbol: procname]"; "dict: merged setting -> value");
    (`overrideconfig; 1b; "apply the command-line override layer onto a resolved config dict"; "[dict: resolved config; dict: setting name (symbol) -> string or list of strings]";  "dict: updated config");
    (`getconfig;      1b; "the config file(s) for a path over the two roots, app before builtin (TorQ .proc.getconfig)"; "[string: builtinroot; string: approot (empty if unset); string: path; long: level 0/1/2]"; "symbol list: config file path(s)");
    (`getconfigfile;  1b; "the first config file for a path over the two roots (TorQ .proc.getconfigfile)"; "[string: builtinroot; string: approot; string: path]"; "symbol list: one config file path");
    (`parsefile;      1b; "parse one .q or .toml settings file into a flat dict";        "[string: file path (.q flat name:value, or .toml via di.util.toml)]";                   "dict: setting -> value (empty if the file is missing)");
    (`getapimeta;     0b; "this module's api metadata rows";                             "[]";                                                                               "table: metadata rows"));
  };
