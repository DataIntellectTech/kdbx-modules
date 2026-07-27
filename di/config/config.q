/ configuration loading and cascade resolution for the modular torq world - replaces
/ torq.q's loadf/loadconfig/loadaddconfig/overrideconfig. the module resolves a settings
/ cascade over a builtin root and an app root, reading BOTH flat name:value .q files and
/ .toml files, and RETURNS the merged config as a single flat dict - the shape di.torq
/ consumes (config:cascade[...] straight after use`di.config, then passed to each module's
/ init). the module reads no env/identity - the caller (di.torq) supplies the roots and the
/ process identity (proctype/procname).
/ public api: cascade (resolve the cascade over two roots x default/proctype/procname ->
/ merged flat dict), parsefile (parse one .q or .toml settings file -> flat dict), and
/ overrideconfig (apply the command-line override layer on top of the resolved dict).
/ precedence is name-major (a more specific NAME wins; within a name the later/app root wins)
/ and, within a single tier, .toml wins over .q on a key clash (useful mid-migration).
/ NOTE: di.toml is not yet in kdbx-modules (it lands with the PoC merge) - the .toml half of
/ a tier stays dormant here (parsefile delegates .toml to di.toml lazily, only when a .toml
/ file actually exists); the .q path needs it never.
/ cascade/parsefile are PURE - no init, no logger, no globals - because di.torq resolves
/ config before the logger dependency is even built. overrideconfig logs (it is the one place
/ that reports skipped/rejected overrides), so it - and only it - requires init.

init:{[deps]
  / wire the injected logger - required for overrideconfig, no silent fallback. deps: a dict
  / with a `log key holding a binary `info`warn`error dict of {[c;m]} loggers (from di.log or
  / hand-rolled). no adaptation here, so a monadic kx.log instance must be wrapped first.
  / cascade/parsefile do not need init; overrideconfig does. e.g. config.init[enlist[`log]!enlist logdep]
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
  .z.m.loginfo[`init;"di.config initialised"];
  };

/ --- settings cascade resolution (.q + .toml -> flat dict) ---

requiretoml:{[path]
  / internal - a .toml settings file (path) exists and must be parsed, which needs the di.toml
  / module. di.toml is a SOFT dependency: it is not required to be in the repo/on QPATH and the
  / .q-only path never touches it - it is needed ONLY once a .toml file actually appears. guard
  / the load so a missing di.toml gives a clear, actionable error naming the file, instead of the
  / cryptic `notfound: di.toml` that a bare use would raise. returns the resolved di.toml module.
  :@[use;`di.toml;{[p;e]
    msg:"di.config: cannot parse TOML file '",p,"' - the di.toml module was not found on QPATH; ";
    msg,:"a di.toml module is required to parse .toml settings (underlying: ",e,")";
    'msg
    }[path;]];
  };

parsefile:{[path]
  / parse ONE settings file into a flat dict. a .toml path is delegated to di.toml (via the
  / requiretoml guard), loaded lazily - only when a .toml file actually appears, so the .q-only
  / path never needs it. a .q file is plain `name:value` lines: split on the first ":", the RHS
  / run through value (so `:hdb, `trade`quote, `symbol$() all work); blank, "/"-comment, and
  / stray non-pair lines (no ":") are skipped. a missing file of either extension contributes nothing (empty dict), so the
  / cascade needs no presence checks. order matters: existence is checked FIRST, so a missing
  / .toml tier never triggers the di.toml requirement; only a .toml file that actually EXISTS
  / requires di.toml - if it is absent, requiretoml signals a clear error (di.toml lives only in
  / the PoC today; the .q-only path needs it never).
  fsym:`$":",path;
  if[0=count key fsym; :()!()];
  if[path like "*.toml"; :(requiretoml[path])[`parsefile] path];
  lines:read0 fsym;
  lines:lines where 0<count each lines;
  lines:lines where not lines like "/*";
  / keep only lines that actually carry a "name:value" separator. this drops whitespace-only
  / and stray non-pair lines BEFORE the split - without it, first where ln=":" is 0N on such a
  / line and the 0N#ln / (0N+1)_ln that follow signal a cryptic 'type, failing the whole file.
  lines:lines where lines like "*:*";
  pairs:{[ln] i:first where ln=":"; (`$i#ln;value (i+1)_ln)} each lines;
  $[count pairs; (first each pairs)!last each pairs; ()!()]
  };

parsetier:{[base]
  / internal - resolve one cascade tier: try base.q then base.toml, .toml winning on a key
  / clash if both exist (useful mid-migration). each missing file yields an empty dict.
  (parsefile base,".q"),parsefile base,".toml"
  };

cascade:{[builtinroot;approot;proctype;procname]
  / resolve the settings cascade over the two roots x the (default;proctype;procname) name
  / sequence and RETURN the merged flat dict. pure - no init, no logger, no globals - so
  / di.torq can call it directly after use`di.config, before the logger exists. precedence is
  / name-major: a more specific NAME wins over the root layer (procname beats proctype beats
  / default), and within a name the later (app) root overrides the builtin root - so a key set
  / in both builtin/{proctype} and app/default resolves to the builtin proctype value. within a
  / single tier, .toml wins over .q (see parsetier). the accumulator is seeded with a sentinel
  / `!(::) key so its value list stays general from the first merge (a same-typed value list
  / coalesces to a typed vector that ,: then refuses to widen); the sentinel is dropped before return.
  / proctype and procname must be resolved, non-null symbol atoms. string`` is "", so a null
  / name would build a bogus "<root>/" base and make parsetier read a file literally named ".q"
  / (or ".toml") in the root. a null here means the caller's identity resolution failed - surface
  / it, don't silently resolve the wrong files. (a null symbol still has type -11h, so the null
  / check is needed in addition to the type check.)
  if[not all -11h=type each (proctype;procname);
    '"di.config: cascade requires proctype and procname to be symbol atoms"];
  if[(null proctype)|null procname;
    '"di.config: cascade requires non-null proctype and procname; got ",(-3!proctype)," and ",-3!procname];
  dirs:(builtinroot;approot);
  / dedup the name sequence (distinct keeps first-occurrence order, so least->most-specific is
  / preserved). without it, a name that coincides with an earlier tier re-applies that tier at a
  / LATER precedence slot: procname~proctype is merely redundant, but procname~`default would put
  / the default tier LAST and wrongly override the proctype tier - inverting name-major precedence.
  names:distinct `default,proctype,procname;
  bases:raze {[ds;nm] ds,\:"/",string nm}[dirs;] each names;
  acc:{[a;b] a,parsetier b}/[(enlist `)!enlist(::);bases];
  acc _ `
  };

/ --- command-line override layer (top of the cascade) ---

hexchars:"0123456789abcdefABCDEF";

parsefailed:{[t;raw;vals]
  / internal - true if any raw string failed to parse to type t. boolean (1h) and byte (4h)
  / have no null, so a bad parse ("B"$"bad"->0b, "X"$"gg"->0x00) slips past a null check and
  / would corrupt config - validate their string form explicitly. other types null on failure.
  :$[1h=abs t;not all raw in (enlist"0";enlist"1");
     4h=abs t;not all {(0=count[x] mod 2) and all x in hexchars} each raw;
     any null vals];
  };

applyoverride:{[name;cur;raw]
  / internal - parse raw value(s) into cur's type and return (applied;newvalue). cur is the
  / setting's current value from the config dict; its type drives the parse. raw is a string or
  / list of strings. applied is 0b (and newvalue is cur, unchanged) if cur is not a basic type,
  / a value failed to parse, or a single-valued (scalar/string) setting got other than one value.
  t:type cur;
  if[not (abs t) within (1;-1+count .Q.t);
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": not a basic type"];
    :(0b;cur);
  ];
  raw:$[10h=type raw;enlist raw;raw];
  / a scalar-atom (t<0) or string (10h) setting is single-valued: require EXACTLY one override
  / value. reject a multi- or zero-value override rather than silently taking the first (or, on
  / an empty list, writing a null) - a scalar cannot hold several values, and a null must never
  / reach config. vector settings (t>0, not 10h) legitimately take as many values as given.
  if[(1<>count raw) and ((t<0)|(10h=t));
    .z.m.logerr[`overrideconfig;"cannot override ",(string name),": expected a single value, got ",string count raw];
    :(0b;cur);
  ];
  / a char-string (10h) setting is already text - take the override string as-is (nothing to
  / parse, and any string is valid). this makes .toml-origin string settings overridable, the
  / same way symbol (.q-origin) settings already are; di.config stays policy-free by preserving
  / whatever type the setting already had.
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
  / reduce to scalar only after parsefailed (which checks the full per-element list); runs
  / before the log and return so both use the scalar form.
  if[t<0;vals:first vals];
  .z.m.loginfo[`overrideconfig;"setting ",(string name)," to ",-3!vals];
  :(1b;vals);
  };

overrideconfig:{[config;params]
  / apply the command-line override layer on top of a resolved config dict, parsing each value
  / into the matching setting's existing type. this is the TOP tier of the cascade - di.torq
  / parses the process command line (.Q.opt .z.x) and calls this after cascade, so launch-time
  / flags win over the settings files. config is the flat dict from cascade; params a dict keyed
  / by setting name (symbol) with string (or list-of-string) values. only keys already present in
  / config with a basic type are overridden; unknown keys, non-basic types, and unparseable
  / values are logged and skipped (a single bad override never aborts the batch and a null is
  / never written into config). returns the UPDATED config dict.
  if[99h<>type config;
    .z.m.logerr[`overrideconfig;err:"di.config: config must be a dict"];
    'err;
  ];
  if[99h<>type params;
    .z.m.logerr[`overrideconfig;err:"di.config: params must be a dict keyed by setting name"];
    'err;
  ];
  vars:key params;
  if[0<count vars;
    if[not 11h=abs type vars;
      .z.m.logerr[`overrideconfig;err:"di.config: params keys must be symbols (setting names)"];
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
  / this module's api metadata, one row per exported function, for di.torq to collect and register
  / with di.api. names are bare (the module's own); di.torq applies the process-wide qualification.
  / one self-contained (name;public;descrip;params;return) row per line - flip cols!flip rows.
  :flip `name`public`descrip`params`return!flip(
    (`init;           0b; "wire the injected logger (required by overrideconfig)";       "[dict: deps with a `log key]";                                                    "null");
    (`cascade;        1b; "resolve the settings cascade over two roots -> merged flat dict (name-major, .toml>.q)"; "[string: builtinroot; string: approot; symbol: proctype; symbol: procname]"; "dict: merged setting -> value");
    (`overrideconfig; 1b; "apply the command-line override layer onto a resolved config dict"; "[dict: resolved config; dict: setting name (symbol) -> string or list of strings]";  "dict: updated config");
    (`parsefile;      1b; "parse one .q or .toml settings file into a flat dict";        "[string: file path (.q flat name:value, or .toml via di.toml)]";                   "dict: setting -> value (empty if the file is missing)");
    (`getapimeta;     0b; "this module's api metadata rows";                             "[]";                                                                               "table: metadata rows"));
  };
