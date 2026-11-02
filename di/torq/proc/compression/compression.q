/ one-shot hdb compression process type - compresses an hdb once at startup, then exits

/ has init run?
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ refuse an exported call before init has wired the deps and config
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.compression: ",string[ctx],": init must be called before any other function"];
  }

/ coerce a config value that may arrive typed (.q) or as text (.toml)
asbool:{[x]
  if[-1h=type x;:x];
  if[-7h=type x;:0<>x];
  if[10h<>abs type x;:0b];
  s:`$lower (),x;
  $[s in `1`true;1b;
    s in `0`false;0b;
    '"di.torq.proc.compression: cannot read \"",(string s),"\" as a boolean - use true or false"]
  }

aslong:{[x] $[-7h=type x;x;10h=abs type x;"J"$(),x;"j"$x]}

/ code and config under TORQXAPPHOME, runtime data under TORQXDATAHOME
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative path setting to an absolute path string under base
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ the app's compression csv if it exists, else the one this framework ships
resolvecsv:{[config]
  p:hsym `$resolvedir[apphome[];$[`csvpath in key config;config`csvpath;"appconfig/compressionconfig.csv"]];
  $[count key p;p;hsym `$getenv[`TORQXHOME],"/di/torq/compressionconfig.csv"]
  }

/ count errors logged during a pass, so run can exit non-zero
counterrors:{[logdep]
  logdep,enlist[`error]!enlist {[f;c;m] .z.m.errors+:1; f[c;m]}[logdep`error]
  }

/ run one compression pass - re-triggerable, does not exit
compressnow:{[]
  requireinit[`compressnow];
  .z.m.errors:0;
  .z.m.log[`info][`compression;"compressing ",(string .z.m.hdbpath)," using ",string .z.m.csvpath];
  (.z.m.cmp`compressmaxage)[.z.m.hdbpath;.z.m.csvpath;.z.m.maxage];
  .z.m.log[`info][`compression;"finished compression"];
  }

/ di.torq's post-init hook - compress, then exit unless told to stay up.
/ a pass that logged errors exits non-zero, so a scheduler does not read it as success.
run:{[]
  compressnow[];
  if[not .z.m.exitonfinish;:()];
  if[.z.m.errors>0;
    .z.m.log[`warn][`compression;"exiting 1 - ",(string .z.m.errors)," error(s) during compression"];
    exit 1];
  .z.m.log[`info][`compression;"exitonfinish set, exiting"];
  exit 0;
  }

/ di.compression's post-compression summary table
getstatstab:{[] requireinit[`getstatstab]; (.z.m.cmp`getstatstab)[]}

/ how many errors the last pass logged
errorcount:{[] requireinit[`errorcount]; .z.m.errors}

init:{[config;deps]
  / resolve and validate first, so a failed init leaves no half-set state
  if[not `log in key deps;'"di.torq.proc.compression: log dependency is required - see di.util.log"];
  lg:deps`log;
  hp:hsym `$resolvedir[datahome[];$[`hdbpath in key config;config`hdbpath;"hdb"]];
  cp:resolvecsv config;
  / defaults must agree with di/torq/settings/compression.q - test.csv asserts both halves
  ma:$[`maxage in key config;aslong config`maxage;30];
  eof:$[`exitonfinish in key config;asbool config`exitonfinish;1b];
  / a bad hdb path otherwise compresses nothing and reports success
  if[not count key hp;lg[`error][`compression;e:"invalid hdb path ",string hp];'e];
  .z.m.errors:0;
  .z.m.log:counterrors lg;
  .z.m.hdbpath:hp;
  .z.m.csvpath:cp;
  .z.m.maxage:ma;
  .z.m.exitonfinish:eof;
  .z.m.cmp:use`di.compression;
  (.z.m.cmp`init)[enlist[`log]!enlist .z.m.log];
  / root names, so di.torq's runhook and IPC callers can reach them
  set[`.compression.run;run];
  set[`.compression.compressnow;compressnow];
  .z.m.log[`info][`init;"initialised, hdbpath=",(string hp),", csvpath=",(string cp),
    ", maxage=",(string ma),", exitonfinish=",string eof];
  }
