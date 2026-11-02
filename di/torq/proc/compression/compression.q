/ one-shot hdb compression process type - compresses an hdb once at startup, then exits

/ has init run?
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ refuse an exported call before init has wired the deps and config
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.compression: ",string[ctx],": init must be called before any other function"];
  }

/ coerce a config value that may arrive typed (.q) or as text (.toml)
asbool:{[x] $[-1h=type x;x;10h=abs type x;first "B"$(),x;-7h=type x;0<>x;0b]}
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

/ run one compression pass - re-triggerable, does not exit
compressnow:{[]
  requireinit[`compressnow];
  .z.m.log[`info][`compression;"compressing ",(string .z.m.hdbpath)," using ",string .z.m.csvpath];
  (.z.m.cmp`compressmaxage)[.z.m.hdbpath;.z.m.csvpath;.z.m.maxage];
  .z.m.log[`info][`compression;"finished compression"];
  }

/ di.torq's post-init hook - compress, then exit unless told to stay up
run:{[]
  compressnow[];
  if[.z.m.exitonfinish;
    .z.m.log[`info][`compression;"exitonfinish set, exiting"];
    exit 0];
  }

/ di.compression's post-compression summary table
getstatstab:{[] requireinit[`getstatstab]; (.z.m.cmp`getstatstab)[]}

init:{[config;deps]
  / wire deps, resolve config, load di.compression and publish the IPC surface
  if[not `log in key deps;'"di.torq.proc.compression: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.hdbpath:hsym `$resolvedir[datahome[];$[`hdbpath in key config;config`hdbpath;"hdb"]];
  .z.m.csvpath:hsym `$resolvedir[apphome[];$[`csvpath in key config;config`csvpath;"appconfig/compressionconfig.csv"]];
  / defaults must agree with di/torq/settings/compression.q - test.csv asserts both halves
  .z.m.maxage:$[`maxage in key config;aslong config`maxage;30];
  .z.m.exitonfinish:$[`exitonfinish in key config;asbool config`exitonfinish;1b];
  / a bad hdb path otherwise compresses nothing and reports success
  if[not count key .z.m.hdbpath;
    .z.m.log[`error][`compression;e:"invalid hdb path ",string .z.m.hdbpath];'e];
  .z.m.cmp:use`di.compression;
  (.z.m.cmp`init)[enlist[`log]!enlist deps`log];
  / root names, so di.torq's runhook and IPC callers can reach them
  set[`.compression.run;run];
  set[`.compression.compressnow;compressnow];
  .z.m.log[`info][`init;"initialised, hdbpath=",(string .z.m.hdbpath),", csvpath=",(string .z.m.csvpath),
    ", maxage=",(string .z.m.maxage),", exitonfinish=",string .z.m.exitonfinish];
  }
