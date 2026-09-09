/ configuration cascade resolution for the modular torq world - replaces torq.q's
/ loadf/loadconfig/loadaddconfig/overrideconfig. resolves a settings cascade over a builtin root
/ and an app root, reading both flat name:value .q files and .toml files, and RETURNS the merged
/ config as one flat dict (the shape di.torq consumes). reads no env/identity - the caller supplies
/ the roots and process identity.
/ precedence is name-major (more specific NAME wins; within a name the app root wins) and, within a
/ tier, .toml wins over .q. cascade/parsefile are pure (no init/logger) - di.torq resolves config
/ before the logger exists; only overrideconfig logs, so only it needs init. di.util.toml is a soft dep:
/ parsefile loads it lazily, only when a .toml file is present (so a .q-only app needs no toml module).

init:{[deps]
  / wire the injected logger (required by overrideconfig; no fallback). deps: a dict with a `log
  / key holding a binary `info`warn`error dict of {[c;m]} loggers. cascade/parsefile don't need init.
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
  / internal - resolve di.util.toml to parse a .toml file. di.util.toml is a soft dep (needed only once a
  / .toml file appears); guard the load so a missing one gives a clear error naming the file, not a
  / cryptic `notfound: di.util.toml`. returns the di.util.toml module.
  :@[use;`di.util.toml;{[p;e]
    msg:"di.torq.config: cannot parse TOML file '",p,"' - the di.util.toml module was not found on QPATH; ";
    msg,:"a di.util.toml module is required to parse .toml settings (underlying: ",e,")";
    'msg
    }[path;]];
  };

parsefile:{[path]
  / parse ONE settings file into a flat dict. .toml -> di.util.toml (via requiretoml); .q -> flat
  / `name:value` lines (split on first ":", RHS through value). blank, "/"-comment and non-pair
  / (no ":") lines are skipped; a missing file -> empty dict. existence is checked FIRST, so a
  / missing .toml tier never triggers the di.util.toml requirement.
  fsym:`$":",path;
  if[0=count key fsym; :()!()];
  if[path like "*.toml"; :(requiretoml[path])[`parsefile] path];
  lines:read0 fsym;
  lines:lines where 0<count each lines;
  lines:lines where not lines like "/*";
  / keep only "name:value" lines: with no ":", `first where` gives 0N and the 0N#/0N_ that follow
  / throw 'type, failing the whole file.
  lines:lines where lines like "*:*";
  pairs:{[ln] i:first where ln=":"; (`$i#ln;value (i+1)_ln)} each lines;
  $[count pairs; (first each pairs)!last each pairs; ()!()]
  };

parsetier:{[base]
  / internal - resolve one tier: base.q then base.toml, .toml winning on a clash. missing -> empty.
  (parsefile base,".q"),parsefile base,".toml"
  };

cascade:{[builtinroot;approot;proctype;procname]
  / resolve the cascade over the two roots x (default;proctype;procname) and RETURN the merged flat
  / dict. pure (no init/logger/globals). name-major: a more specific NAME wins over the root layer,
  / and within a name the app root wins (parsetier gives .toml>.q within a tier). the accumulator is
  / seeded with a sentinel (`)!(::) key so its value list stays general from the first merge (a
  / same-typed value list coalesces to a typed vector that ,: then won't widen); dropped before return.
  / proctype/procname must be non-null symbol atoms: string`` is "", which would build a bogus
  / "<root>/" base and read a file named ".q"/".toml". a null means identity resolution failed, so
  / surface it. (a null symbol is still type -11h, so the null check is separate from the type check.)
  if[not all -11h=type each (proctype;procname);
    '"di.torq.config: cascade requires proctype and procname to be symbol atoms"];
  if[(null proctype)|null procname;
    '"di.torq.config: cascade requires non-null proctype and procname; got ",(-3!proctype)," and ",-3!procname];
  dirs:(builtinroot;approot);
  / dedup (distinct keeps first-occurrence order, preserving least->most-specific). without it a
  / repeated name re-applies its tier at a LATER slot: procname~proctype is redundant, but
  / procname~`default would put default LAST and wrongly override proctype.
  names:distinct `default,proctype,procname;
  bases:raze {[ds;nm] ds,\:"/",string nm}[dirs;] each names;
  acc:{[a;b] a,parsetier b}/[(enlist `)!enlist(::);bases];
  acc _ `
  };

/ --- command-line override layer (top of the cascade) ---

hexchars:"0123456789abcdefABCDEF";

parsefailed:{[t;raw;vals]
  / internal - true if any raw string failed to parse to type t. bool (1h) and byte (4h) have no
  / null, so a bad parse ("B"$"bad"->0b, "X"$"gg"->0x00) slips past a null check - check their form
  / explicitly. other types null on failure.
  :$[1h=abs t;not all raw in (enlist"0";enlist"1");
     4h=abs t;not all {(0=count[x] mod 2) and all x in hexchars} each raw;
     any null vals];
  };

applyoverride:{[name;cur;raw]
  / internal - parse raw into cur's type; return (applied;newvalue). cur's type drives the parse.
  / applied is 0b (newvalue=cur) if cur is not a basic type, a value failed to parse, or a
  / single-valued setting got other than one value.
  t:type cur;
  if[not (abs t) within (1;-1+count .Q.t);
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": not a basic type"];
    :(0b;cur);
  ];
  raw:$[10h=type raw;enlist raw;raw];
  / scalar-atom (t<0) and string (10h) settings are single-valued: require exactly one value. reject
  / a multi- or zero-value override rather than silently taking the first or writing a null. vector
  / settings (t>0, not 10h) take as many as given.
  if[(1<>count raw) and ((t<0)|(10h=t));
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": expected a single value, got ",string count raw];
    :(0b;cur);
  ];
  / a string (10h) is already text - take the override as-is (no parse). lets .toml-origin string
  / settings be overridden like symbol (.q-origin) ones; type is preserved either way.
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
  / apply the command-line override layer onto a resolved config dict - the TOP cascade tier
  / (di.torq calls this after cascade with .Q.opt .z.x, so launch flags win over files). config is
  / the cascade dict; params keys settings (symbol) to string / string-list values, parsed into each
  / setting's existing type. unknown keys, non-basic types and bad values are logged and skipped
  / (never aborts the batch, never writes a null). returns the updated config dict.
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
  defined:vars where vars in key config;
  undefined:vars except defined;
  if[count undefined;
    .z.m.logwarn[`overrideconfig;"skipping unknown setting(s): ",", " sv string undefined];
  ];
  / fold each defined override into the config dict; a skipped/rejected one leaves it unchanged
  :{[config;params;name]
     res:applyoverride[name;config name;params name];
     $[res 0;@[config;name;:;res 1];config]
   }[;params;]/[config;defined];
  };

getapimeta:{[]
  / this module's api metadata, one row per exported function, for di.torq to register with di.api.
  / names are bare (di.torq qualifies them). one (name;public;descrip;params;return) row per line.
  :flip `name`public`descrip`params`return!flip(
    (`init;           0b; "wire the injected logger (required by overrideconfig)";       "[dict: deps with a `log key]";                                                    "null");
    (`cascade;        1b; "resolve the settings cascade over two roots -> merged flat dict (name-major, .toml>.q)"; "[string: builtinroot; string: approot; symbol: proctype; symbol: procname]"; "dict: merged setting -> value");
    (`overrideconfig; 1b; "apply the command-line override layer onto a resolved config dict"; "[dict: resolved config; dict: setting name (symbol) -> string or list of strings]";  "dict: updated config");
    (`parsefile;      1b; "parse one .q or .toml settings file into a flat dict";        "[string: file path (.q flat name:value, or .toml via di.util.toml)]";                   "dict: setting -> value (empty if the file is missing)");
    (`getapimeta;     0b; "this module's api metadata rows";                             "[]";                                                                               "table: metadata rows"));
  };
