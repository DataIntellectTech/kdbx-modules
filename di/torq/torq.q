/ di.torq - process orchestrator. Resolves config via the settings cascade, builds
/ the injected-dependency dict, and starts either a built-in (di.*) process module or
/ a custom one supplied by the app's code/processes/ directory - both through the
/ same init[config;deps] calling convention.

/ built-in process type registry: proctype -> di.* module name
builtin:`hdb`tickerplant`rdb`wdb`gateway!`di.proc.hdb`di.proc.tickerplant`di.proc.rdb`di.proc.wdb`di.proc.gateway

reqenv:{[e]
  v:getenv e;
  if[""~v;'"di.torq: required environment variable ",(string e)," is not set"];
  v
  }

roots:{
  builtinroot:reqenv[`TORQXHOME],"/di/torq/settings";
  approot:reqenv[`TORQXAPPCONFIG],"/settings";
  (builtinroot;approot)
  }

/ resolves this process's identity: explicit args if both given, otherwise auto-detected
/ from process.csv by matching this session's listening port (and, as a tiebreaker, its
/ host) - ported from TorQ/torq.q's readprocfile, scoped down (no envvar substitution in
/ the csv, no -procfile override, no finspace host handling). Both-or-neither only - no
/ partial mode where one of proctype/procname is given and the other auto-detected.
resolveidentity:{[proctype;procname]
  / NOTE: q evaluates right-to-left with flat precedence - `not a or b` parses as
  / `not[a or b]`, not `(not a) or b`. Written as `(null x) or (null y)` directly instead
  / of negating a fenced-off "both given" test, to avoid that trap.
  $[(null proctype) or (null procname);
    autodetect[];
    `proctype`procname!(proctype;procname)]
  }

/ NOTE: deliberately does not reuse di.torq.servers.readprocesscsv - di.torq shouldn't have
/ to load di.torq.servers just to boot. Small duplication; extract to a shared helper if a
/ third consumer of process.csv ever shows up.
autodetect:{[]
  path:reqenv[`TORQXAPPCONFIG],"/process.csv";
  fsym:`$":",path;
  if[0=count key fsym;'"di.torq: cannot auto-detect identity - process.csv not found at ",path];
  procs:("SISS";enlist",") 0: fsym;
  procs:select from procs where not null host;
  myport:system "p";
  cands:$[myport=0i;procs;select from procs where abs[port]=abs myport];
  myip:`$"." sv string "i"$0x0 vs .z.a;
  prefs:(`$lower string .z.h;`$lower string myip;`localhost);
  cands:update hlow:`$lower each string host from cands;
  cands:select from cands where hlow in prefs;
  if[0=count cands;
    '"di.torq: cannot auto-detect identity - no process.csv row matches this host",$[myport=0i;"";" and port ",string myport]];
  if[(1<count cands) and myport=0i;
    '"di.torq: cannot auto-detect identity - ",(string count cands)," process.csv rows match this host with no port to disambiguate; pass -p or proctype/procname explicitly"];
  best:first cands iasc prefs?cands`hlow;
  if[myport=0i;system "p ",string best`port];
  `proctype`procname!(best`proctype;best`procname)
  }

/ builds the logging dependency dict, using di.util.log unless overridden.
/ NOTE: deliberately indexes the freshly-`use`d handle with brackets (lg`info) rather
/ than dot-syntax (lg.info) - calling a just-loaded module via dot-syntax from within
/ the same function frame that called `use` fails in this kdb-x build (module
/ registration is evidently not visible to dot-resolution until the frame returns to
/ top level); bracket indexing on the returned dict works immediately. Flagged as a
/ tooling rough edge to revisit, not a design choice.
buildlogdep:{[overrides]
  modname:$[`log in key overrides;overrides`log;`di.util.log];
  lg:use modname;
  `info`warn`error!(lg`info;lg`warn;lg`error)
  }

/ builds the timer dependency dict, using di.timer (kdbx-modules) unless overridden.
/ di.timer needs no injected deps of its own (Tier-1 standalone). It exports `setcp`
/ rather than a bare `cp`, so the plan's timer contract's `cp` key is omitted here - not
/ currently used by anything that consumes this dep.
/ di.timer's exported `addjob` is itself a dict of variants (custom/default/simple),
/ not a directly-callable function - `custom` is the one matching the plan's timer
/ contract signature {[id;func;params;period;mode;opts] ...}
buildtimerdep:{[overrides]
  modname:$[`timer in key overrides;overrides`timer;`di.timer];
  tm:use modname;
  (tm`init)[()!()];
  `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!((tm`addjob)`custom;tm`deletejobs;tm`enablejobs;tm`disablejobs;tm`getactivejobs)
  }

/ builds the handlers dependency dict, using di.torq.handlers unless overridden. di.torq.handlers's own
/ remove function is named `deregister` (avoiding a suspected reserved-name collision -
/ see di/torq/handlers/handlers.q) but is exposed here under the contract's `remove` key.
buildhandlersdep:{[overrides;logdep]
  modname:$[`handlers in key overrides;overrides`handlers;`di.torq.handlers];
  hz:use modname;
  (hz`init)[enlist[`log]!enlist logdep];
  `register`remove`list!(hz`register;hz`deregister;hz`list)
  }

/ builds the servers (connection-management) dependency dict, using di.torq.servers unless
/ overridden. Unlike log/timer/handlers, di.torq.servers is itself a CONSUMER of those three -
/ its init registers a .z.pc cleanup handler (via handlers) and a reconnection retry timer
/ job (via timer), and stamps self-identity from config`proctype`/`procname - so it is built
/ LAST, after all three exist. Exposes only the lookup/lifecycle surface consumers call;
/ `init` is deliberately NOT re-exported - di.torq has already run it, and a second init would
/ double-register the pc handler and the retry job (the exact fragility that motivated
/ promoting servers from a per-module `use`+init to an injected singleton). `startup` IS
/ exposed: it opens the actual connections and is called by each consumer with its own
/ `connections` list, so connection-opening timing stays with the consumer.
/ NB every process gets an init'd servers instance, even ones that never dial out
/ (hdb/tickerplant): harmless - the registry starts empty, the pc handler and the retry job
/ are no-ops on an empty SERVERS table, and startup (the part that opens sockets) is never
/ called. Prune per-proctype if/when a capabilities declaration lands (see servers.md).
/ NB local is `srv` not `sv` - `sv` is the built-in scalar-from-vector/join operator and
/ won't reliably shadow as a local (same reserved-name trap as `log`/`ss` noted in project
/ memory); assigning it here threw '`sv` at module load.
buildserversdep:{[overrides;config;logdep;timerdep;handlersdep]
  modname:$[`servers in key overrides;overrides`servers;`di.torq.servers];
  srv:use modname;
  (srv`init)[config;`log`timer`handlers!(logdep;timerdep;handlersdep)];
  `startup`getservers`gethandlebytype`waitfortype!((srv`startup);(srv`getservers);(srv`gethandlebytype);(srv`waitfortype))
  }

/ starts a built-in process type, shipped as a di.* module
startbuiltin:{[proctype;config;deps]
  m:use builtin proctype;
  (m`init)[config;deps]
  }

/ starts a custom process type, defined by the app under code/processes/{proctype}.q
/ (code/ lives alongside appconfig/ under TORQXAPPHOME, the app's own project root -
/ independent of TORQXHOME, which is the di.torq/framework checkout)
startcustom:{[proctype;config;deps]
  appbase:reqenv[`TORQXAPPHOME];
  procfile:appbase,"/code/processes/",(string proctype),".q";
  system "l ",procfile;
  initfunc:get `$".",(string proctype),".init";
  initfunc[config;deps]
  }

/ --- application code cascade (TorQ-style) ------------------------------------------------
/ Loads add-on q scripts the APP drops under $TORQXAPPHOME/code/<dir>/ for a process, mirroring
/ torq.q's .proc.reloadallcode but scaled to the SINGLE app code root: the TorqX framework ships
/ behaviour as di.* MODULES (loaded via `use`), not code/<proctype> dirs, so there is no framework
/ code root to cascade over - only the app's. Cascade order mirrors the config cascade and torq.q:
/ common -> proctype -> procname, procname OFF by default (matching torq.q's loadnamecode). Flags
/ (from the merged config, per-process overridable in settings): loadcommoncode / loadprocesscode /
/ loadnamecode. Deliberately NOT via `use` (which mangles a module into a private namespace): a
/ plain `system "l"` lets each file's definitions land at the namespace ITS OWN \d directives
/ choose - a bare app query file like code/rdb/examplequeries.q (no \d) lands at ROOT, callable as
/ countbysym[...]. This is the same load mechanism startcustom already uses for code/processes/.
/ (parentproctype - torq.q's 4th tier, for wdb/sort sharing - is omitted: no sort-worker tier yet.)
optflag:{[config;k;dflt] $[k in key config;`boolean$config k;dflt]}

/ load every q/k file in one dir at root: an optional order.txt lists files to load first, then
/ the rest alphabetically. Absent/empty dir -> no-op (key on a missing path returns empty).
/ (param is `lg` not `log` - `log` is the built-in natural-log and won't reliably shadow.)
loadappcodedir:{[lg;dir]
  files:key hsym `$dir;
  if[0=count files;:()];
  ord:$[`order.txt in files;(`$read0 hsym `$dir,"/order.txt") inter files;`symbol$()];
  qk:asc files where any files like/:("*.q";"*.k");
  {[lg;dir;f] p:dir,"/",string f; system "l ",p; lg[`info][`torq;"loaded app code ",p]}[lg;dir] each ord,qk except ord;
  }

loadappcode:{[lg;config;proctype;procname]
  base:reqenv[`TORQXAPPHOME],"/code/";
  if[optflag[config;`loadcommoncode;1b]; loadappcodedir[lg;base,"common"]];
  if[optflag[config;`loadprocesscode;1b]; loadappcodedir[lg;base,string proctype]];
  if[optflag[config;`loadnamecode;0b];    loadappcodedir[lg;base,string procname]];
  }

/ calls an optional post-init one-shot hook, .{proctype}.run[], if the process type
/ published one - same "publish at a real root name" convention already used for
/ .hdb.reload (custom proctypes under code/processes/ land there for free via their
/ own \d .proctype block; a built-in di.* module must explicitly set[`.X.run;...] since
/ use mangles its own namespace). Lets a process type (e.g. the sample loader) run its
/ own startup action without the generic launcher needing any proctype-specific logic.
/ Skipped entirely if the overrides dict's `norun key is set - the launcher's -norun
/ escape hatch threads through here.
runhook:{[proctype;overrides]
  if[`norun in key overrides;if[overrides`norun;:()]];
  ns:`$".",string proctype;
  if[`run in key ns;(get `$".",(string proctype),".run")[]];
  }

init:{[proctype;procname;overrides]
  / dependency check runs first, before anything else - a version mismatch should
  / be caught before identity resolution, config, or any module load even starts.
  / check[] is itself a no-op if TORQXAPPHOME has no deps.toml (opt-in feature, see
  / di.torq.depcheck's docs) - this doesn't require every app to have adopted one yet.
  dc:use`di.torq.depcheck;
  (dc`check)[reqenv[`TORQXAPPHOME],"/deps.toml"];
  (dc`checkztsintegrity)[];
  ident:resolveidentity[proctype;procname];
  proctype:ident`proctype;
  procname:ident`procname;
  / peer-version manifest graph (di.torq.depcheck 0.2.0+): now that identity is known, walk THIS
  / process's dependency subtree - each module's own deps.toml declares the minimum versions of
  / the modules it `use`s, and the walk validates them transitively against what's installed.
  / This is what turns "customer upgraded di.proc.gateway but not the di.serverselect it now needs"
  / from a cryptic mid-startup runtime error into a clear startup failure naming the culprit.
  / Built-in proctypes have a di.* entry module; a custom proctype's optional manifest lives at
  / code/processes/<proctype>.deps.toml. Pure on-disk reads, still before any module loads.
  $[proctype in key builtin;
    (dc`checkgraph)[builtin proctype];
    (dc`checkgraphfrom)[proctype;reqenv[`TORQXAPPHOME],"/code/processes/",(string proctype),".deps.toml"]];
  r:roots[];
  cc:use`di.torq.config;
  config:(cc`cascade)[r 0;r 1;proctype;procname];
  / self-identity, so any module (or something it calls) can find out who it is
  config:config,`proctype`procname!(proctype;procname);
  logdep:buildlogdep[overrides];
  timerdep:buildtimerdep[overrides];
  handlersdep:buildhandlersdep[overrides;logdep];
  / servers is built LAST (it consumes log/timer/handlers at init) and injected alongside
  / them, so consumers read deps`servers instead of `use`+init-ing di.torq.servers themselves.
  deps:`log`timer`handlers`servers!(logdep;timerdep;handlersdep;buildserversdep[overrides;config;logdep;timerdep;handlersdep]);
  / optional, config-driven (see di.torq.logroll's docs) - a silent no-op unless the
  / process's settings have a [logroll] section with enabled=true. Called before
  / startbuiltin/startcustom so the process type's own init-time log lines land in
  / the rolled files too, matching torq.q's own ordering.
  lr:use`di.torq.logroll;
  (lr`init)[config;deps];
  $[proctype in key builtin;
    startbuiltin[proctype;config;deps];
    startcustom[proctype;config;deps]
    ];
  / app-level add-on code (code/<common|proctype|procname>/*.q) - loaded AFTER the process
  / module init (so it can reference the module's tables/state) and BEFORE runhook (so an
  / app file may define/override .<proctype>.run for the hook to pick up).
  loadappcode[logdep;config;proctype;procname];
  runhook[proctype;overrides];
  `proctype`procname`config`deps!(proctype;procname;config;deps)
  }
