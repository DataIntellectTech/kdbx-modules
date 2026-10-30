/ di.torq.proc.compression - one-shot hdb compression process type. Walks an hdb's partitions up
/ to a maximum age and rewrites each column named in a compression config csv using the algorithm,
/ block size and level that csv gives it. Ported from TorQ/code/processes/compression.q.
/ ---
/ The compression itself lives in di.compression; this module is only the process wrapper around
/ it - config resolution, validation of the hdb path, and the one-shot run/exit lifecycle.
/ ---
/ Lifecycle: the pass runs from di.torq's post-init runhook as .compression.run[], NOT from init.
/ init must not exit - torqx.sh owns this process's lifecycle, and exiting from inside init would
/ fight it (the same reason di.torq.proc.housekeeping declined to port legacy's one-shot mode).
/ Keeping the pass in its own named function also leaves it re-triggerable by hand or over IPC as
/ .compression.compressnow[] without killing the session. Same split di.torq's sample loader uses.

/ has init run? probes .z.m.log, which has no load-time default - only init ever sets it - via a
/ trap rather than a `in key .z.m` test, so it cannot be confused by how module state is shaped.
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ an exported function that touches injected deps or config refuses to run before init wired them,
/ so a pre-init call says what the real mistake was instead of dying on an unset .z.m.hdbpath.
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.compression: ",string[ctx],": init must be called before any other function"];
  }

/ config arrives from a .q settings file (typed) or a .toml one (string/long), so coerce both.
/ Same shape as di.permissions' own helpers.
asbool:{[x] $[-1h=type x;x;10h=abs type x;first "B"$(),x;-7h=type x;0<>x;0b]}
aslong:{[x] $[-7h=type x;x;10h=abs type x;"J"$(),x;"j"$x]}

/ base dirs: code/config under TORQXAPPHOME, runtime data under TORQXDATAHOME falling back to it
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative path setting to an absolute path string under base. Same body as
/ di.torq.proc.wdb's resolvedir - accepts a `.q` settings symbol (`:x) or a colon-less `.toml`
/ string ("x") and normalises both.
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ run one compression pass. Deliberately NOT named `run`: di.torq's runhook fires
/ .{proctype}.run[] once after init, and that one exits the process. This one does not, so it
/ stays callable from a console or over IPC to recompress without a restart.
compressnow:{[]
  requireinit[`compressnow];
  .z.m.log[`info][`compression;"compressing ",(string .z.m.hdbpath)," using ",string .z.m.csvpath];
  (.z.m.cmp`compressmaxage)[.z.m.hdbpath;.z.m.csvpath;.z.m.maxage];
  .z.m.log[`info][`compression;"finished compression"];
  }

/ the di.torq post-init one-shot hook: compress, then terminate unless told to stay up. Legacy
/ TorQ exits here too (exitonfinish defaults on) - this is a batch job, not a server, and its
/ process.csv row carries port 0.
run:{[]
  compressnow[];
  if[.z.m.exitonfinish;
    .z.m.log[`info][`compression;"exitonfinish set, exiting"];
    exit 0];
  }

/ the post-compression summary table di.compression accumulates, for an operator or a peer that
/ kept the process alive with exitonfinish=0b
getstatstab:{[] requireinit[`getstatstab]; (.z.m.cmp`getstatstab)[]}

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.compression: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  / the hdb is runtime data; the compression csv is config - they resolve under different roots
  .z.m.hdbpath:hsym `$$[`hdbpath in key config;resolvedir[datahome[];config`hdbpath];datahome[],"/hdb"];
  .z.m.csvpath:hsym `$$[`csvpath in key config;resolvedir[apphome[];config`csvpath];getenv[`TORQXAPPCONFIG],"/compressionconfig.csv"];
  / presence-check-with-default, per consistency.md. These defaults must agree with
  / di/torq/settings/compression.q, which is what makes them discoverable and command-line
  / overridable; the tests assert both halves.
  .z.m.maxage:$[`maxage in key config;aslong config`maxage;365];
  .z.m.exitonfinish:$[`exitonfinish in key config;asbool config`exitonfinish;1b];
  / fail fast on a bad hdb path. Without this the partition traverse simply returns nothing and
  / the run reports success having compressed zero columns, which reads identically to a no-op.
  if[not count key .z.m.hdbpath;
    .z.m.log[`error][`compression;e:"invalid hdb path ",string .z.m.hdbpath];'e];
  .z.m.cmp:use`di.compression;
  (.z.m.cmp`init)[enlist[`log]!enlist deps`log];
  / publish at real root names - use-loading this file compiles it into a private namespace, so
  / di.torq's runhook and any IPC caller would otherwise hit an undefined function.
  set[`.compression.run;run];
  set[`.compression.compressnow;compressnow];
  .z.m.log[`info][`init;"initialised, hdbpath=",(string .z.m.hdbpath),", csvpath=",(string .z.m.csvpath),
    ", maxage=",(string .z.m.maxage),", exitonfinish=",string .z.m.exitonfinish];
  }
