/ di.torq - process orchestrator: resolves config via the settings cascade, builds the injected-dependency dict,
/ and starts a built-in (di.*) or custom (code/processes/) process type through init[config;deps]

/ built-in process type registry: proctype -> di.* module name
builtin:`hdb`tickerplant`rdb`wdb`sort`gateway`idb`segmentedtp`chainedtp`housekeeping`sortworker`discovery`tickerlogreplay`segmentedchainedtp!`di.torq.proc.hdb`di.torq.proc.tickerplant`di.torq.proc.rdb`di.torq.proc.wdb`di.torq.proc.wdb`di.torq.proc.gateway`di.torq.proc.idb`di.torq.proc.segmentedtp`di.torq.proc.chainedtp`di.torq.proc.housekeeping`di.torq.proc.wdb`di.torq.proc.discovery`di.torq.proc.tickerlogreplay`di.torq.proc.segmentedtp

reqenv:{[e]
  v:getenv e;
  if[""~v;'"di.torq: required environment variable ",(string e)," is not set"];
  v
  }

/ the kdbx-modules checkout holding di.torq: TORQXHOME if set, else the module search path entry that holds di/torq
frameworkhome:{[]
  if[count h:getenv`TORQXHOME;:h];
  / the module search path, as use searches it: QPATH's non-empty entries, or $QHOME/mod when it has none
  p:":" vs getenv`QPATH;
  p:p where 0<count each p;
  if[(0=count p) and 0<count getenv`QHOME;p:enlist getenv[`QHOME],"/mod"];
  d:{$["/"=first x;x;(system "cd"),"/",x]} each p;
  d:d where {not ()~key hsym `$x,"/di/torq/init.q"} each d;
  if[not count d;'"di.torq: TORQXHOME is not set and di/torq was not found; searched: ",$[count p;", " sv p;"nothing, QPATH and QHOME are unset"]];
  first d
  }

roots:{
  builtinroot:frameworkhome[],"/di/torq/settings";
  approot:reqenv[`TORQXAPPCONFIG],"/settings";
  (builtinroot;approot)
  }

/ resolves this process's identity: explicit args if both given, otherwise auto-detected from process.csv
/ by this session's listening port, with host as a tiebreaker
resolveidentity:{[proctype;procname]
  $[(null proctype) or (null procname);
    autodetect[];
    `proctype`procname!(proctype;procname)]
  }

/ reads process.csv and picks the row matching this host and port
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

/ builds the logging dependency dict, using di.util.log unless overridden
buildlogdep:{[overrides]
  modname:$[`log in key overrides;overrides`log;`di.util.log];
  lg:use modname;
  `info`warn`error!(lg`info;lg`warn;lg`error)
  }

/ builds the timer dependency dict, using di.timer unless overridden; addjob is di.timer's addjob.custom
buildtimerdep:{[overrides;logdep]
  modname:$[`timer in key overrides;overrides`timer;`di.timer];
  tm:use modname;
  (tm`init)[enlist[`log]!enlist logdep];
  `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!((tm`addjob)`custom;tm`deletejobs;tm`enablejobs;tm`disablejobs;tm`getactivejobs)
  }

/ builds the handlers dependency dict, using di.torq.handlers unless overridden
buildhandlersdep:{[overrides;logdep]
  modname:$[`handlers in key overrides;overrides`handlers;`di.torq.handlers];
  hz:use modname;
  (hz`init)[enlist[`log]!enlist logdep];
  `register`remove`list!(hz`register;hz`remove;hz`list)
  }

/ outbound-connection credentials, read from $TORQXAPPCONFIG/passwords/{default|proctype|procname}.txt -
/ the most specific file that exists wins, mirroring TorQ's hierarchic password load. One line,
/ `user:pass`. A process that permissions its own handlers refuses an unauthenticated peer, so
/ without this file an otherwise healthy stack cannot connect to itself. Plaintext on disk, as
/ TorQ's is; the file's contents are never logged.
passwordfile:{[proctype;procname]
  base:reqenv[`TORQXAPPCONFIG],"/passwords/";
  files:base,/:(string each distinct `default,proctype,procname),\:".txt";
  found:files where {not ()~key hsym `$x} each files;
  $[0=count found;`;`$first read0 hsym `$last found]
  };

/ builds the servers dependency dict, using di.torq.servers unless overridden; it is initialised with the
/ log, timer and handlers deps, and exposes startup and the lookup functions but not init
buildserversdep:{[overrides;config;logdep;timerdep;handlersdep]
  modname:$[`servers in key overrides;overrides`servers;`di.torq.servers];
  srv:use modname;
  / credentials come from the password file unless the settings cascade already named them
  config:$[`userpass in key config;config;config,enlist[`userpass]!enlist passwordfile[config`proctype;config`procname]];
  / init reads log/timer/handlers and proctype/procname from the config
  (srv`init)[config,`log`timer`handlers!(logdep;timerdep;handlersdep)];
  `startup`getservers`gethandlebytype`waitfortype!((srv`startup);(srv`getservers);(srv`gethandlebytype);(srv`waitfortype))
  }

/ starts a built-in process type, shipped as a di.* module
startbuiltin:{[proctype;config;deps]
  m:use builtin proctype;
  (m`init)[config;deps]
  }

/ starts a custom process type, defined by the app under $TORQXAPPHOME/code/processes/{proctype}.q
startcustom:{[proctype;config;deps]
  appbase:reqenv[`TORQXAPPHOME];
  procfile:appbase,"/code/processes/",(string proctype),".q";
  system "l ",procfile;
  initfunc:get `$".",(string proctype),".init";
  initfunc[config;deps]
  }

/ --- application code cascade ------------------------------------------------------------
/ loads q scripts under $TORQXAPPHOME/code/<dir>/ at root with system "l": common, parentproctype, proctype,
/ then procname, gated by loadcommoncode / loadprocesscode / loadnamecode (procname off by default)
optflag:{[config;k;dflt] $[k in key config;`boolean$config k;dflt]}

/ load every q/k file in one dir at root: files listed in an optional order.txt first, then the rest
/ alphabetically; a missing or empty dir is a no-op
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
  if[optflag[config;`loadprocesscode;1b] and not null ppt:$[`parentproctype in key config;config`parentproctype;`]; loadappcodedir[lg;base,string ppt]];
  if[optflag[config;`loadprocesscode;1b]; loadappcodedir[lg;base,string proctype]];
  if[optflag[config;`loadnamecode;0b];    loadappcodedir[lg;base,string procname]];
  }

/ calls the optional post-init hook .{proctype}.run[] if the process type published one, unless overrides`norun is set
runhook:{[proctype;overrides]
  if[`norun in key overrides;if[overrides`norun;:()]];
  ns:`$".",string proctype;
  if[`run in key ns;(get `$".",(string proctype),".run")[]];
  }

/ client tracking, every process
clientswired:0b
initclients:{[config;deps] if[.z.m.clientswired;:()]; ((use`di.clienttracking)`init)[config;deps]; .z.m.clientswired:1b;}

/ --- optional permissions -----------------------------------------------------------------
/ Wires di.permissions behind a [permissions] settings section - a no-op unless enabled=true,
/ same convention as logroll and querylog. It claims the exec owner of .z.pg/.z.ps/etc through
/ di.torq.handlers, so it MUST run before initclients and initquerylog: both of those wrap those
/ events by direct assignment, and claiming an exec owner afterwards reinstalls the dispatcher
/ and silently discards their wrappers.
permissionswired:0b
initpermissions:{[config;deps]
  sect:$[`permissions in key config;config`permissions;()!()];
  if[not $[`enabled in key sect;`boolean$sect`enabled;0b];:()];
  if[.z.m.permissionswired;:()];
  ((use`di.permissions)`init)[sect;deps];
  .z.m.permissionswired:1b;
  }

/ the permissions rule cascade: plain q that calls di.permissions' admin api, loaded additively
/ from the framework root then the app root, `default` then proctype then procname - the same two
/ roots and three tiers as the settings cascade, and as TorQ's own $KDBCONFIG/$KDBAPPCONFIG
/ permissions cascade. The rules are code (a paramcheck is a lambda), so they cannot be settings.
/ Loaded with `system "l"` at root, like loadappcodedir, so a rule file is an ordinary caller.
permissionroots:{[]
  (frameworkhome[],"/di/torq/permissions";reqenv[`TORQXAPPCONFIG],"/permissions")
  }

loadpermissionrules:{[lg;config;proctype;procname]
  sect:$[`permissions in key config;config`permissions;()!()];
  if[not $[`enabled in key sect;`boolean$sect`enabled;0b];:()];
  tiers:distinct `default,proctype,procname;
  sfxs:{[t] "/",(string t),".q"} each tiers;
  / root-major: every framework tier, then every app tier (`cross` here would concatenate the
  / whole lot into one string, not pair them)
  files:raze {[r;s] r,/:s}[;sfxs] each permissionroots[];
  {[lg;f] if[not ()~key hsym `$f; system "l ",f; lg[`info][`torq;"loaded permission rules ",f]]}[lg] each files;
  }

/ --- optional query logging ---------------------------------------------------------------
/ wires di.querylog from a [querylog] settings section, a no-op unless enabled=true; di.querylog wraps
/ the .z.* handlers by direct assignment, so it runs after everything else that binds them; initpermissions runs
/ before it, so refused queries are logged too
querylogwired:0b
qlflushtime:0D

/ ignorelist names as both symbol and string message heads
qlignore:{[names]
  s:{$[-11h=type x;x;`$x]} each names,();
  s,string s
  }

qlresolvedir:{[dir] $["/"=first dir;dir;reqenv[`TORQXAPPHOME],"/",dir]}

/ timer job body - drop in-memory query-log rows older than the configured flushtime
flushquerylog:{[] ((use`di.querylog)`flushusage)[.z.m.qlflushtime];}

initquerylog:{[config;deps]
  sect:$[`querylog in key config;config`querylog;()!()];
  if[not $[`enabled in key sect;`boolean$sect`enabled;0b];:()];
  / wire once per process
  if[.z.m.querylogwired;deps[`log][`info][`torq;"query logging already wired in this process - not re-wrapping"];:()];
  opt:{[s;k;d] $[k in key s;s k;d]}[sect];
  cfg:`logtomemory`logtodisk`level`localtime`ignore`ignorelist!(
    `boolean$opt[`logtomemory;1b];
    `boolean$opt[`logtodisk;0b];
    "j"$opt[`level;3];
    `boolean$opt[`localtime;0b];
    1b;
    qlignore opt[`ignorelist;`upd`.u.upd]);
  if[cfg`logtodisk;
    dir:qlresolvedir opt[`dir;"logs"];
    system "mkdir -p ",dir;
    cfg:cfg,`logdir`logname!(dir;string config`procname)];
  ((use`di.querylog)`init)[cfg];
  .z.m.querylogwired:1b;
  ft:"j"$opt[`flushtime;86400];
  if[ft>0;
    .z.m.qlflushtime:ft*0D00:00:01;
    (deps[`timer][`addjob])[`querylogflush;flushquerylog;();0D00:00:01*"j"$opt[`flushinterval;1800];3h;()!()]];
  msg:"query logging on (level ",(string cfg`level),", memory=",(string cfg`logtomemory),", disk=",(string cfg`logtodisk),")";
  deps[`log][`info][`torq;msg," - di.querylog wraps .z.* directly; see torq.md Query logging"];
  }

/ zpsignore: ignorelisted async messages skip the .z.ps wrappers
zpsignorewired:0b
initzpsignore:{[config]
  if[.z.m.zpsignorewired;:()];
  s:$[`zpsignore in key config;config`zpsignore;()!()];
  if[$[`enabled in key s;`boolean$s`enabled;1b];
    .z.ps:{[il;f;y] $[any first[y]~/:il;value y;f y]}[qlignore $[`ignorelist in key s;s`ignorelist;`upd`.u.upd];@[value;`.z.ps;{value}]]];
  .z.m.zpsignorewired:1b;
  }

/ launcher and identity flags parsed from the command line, not config settings
reservedflags:`proctype`procname`parentproctype`torqxstackid`p`norun;

/ the config-override params from a parsed command-line opt dict (.Q.opt .z.x), without the reserved flags
clioverrideparams:{[cmdlineopts] (key[cmdlineopts] except reservedflags)#cmdlineopts}

/ q's own -t in ms, null if not given; q consumes -t, so it is read from the full command line .z.X
cmdlinet:{[] $[`t in key o:.Q.opt .z.X;"J"$first o`t;0N]}

init:{[proctype;procname;overrides]
  / dependency check first; a no-op if TORQXAPPHOME has no deps.toml
  dc:use`di.torq.depcheck;
  (dc`checkversiongraphfile)[`;reqenv[`TORQXAPPHOME],"/deps.toml"];
  ident:resolveidentity[proctype;procname];
  proctype:ident`proctype;
  procname:ident`procname;
  / check the VERSION graph for this process's module, or a custom proctype's code/processes/<proctype>.deps.toml
  $[proctype in key builtin;
    (dc`checkversiongraph)[enlist builtin proctype];
    (dc`checkversiongraphfile)[proctype;reqenv[`TORQXAPPHOME],"/code/processes/",(string proctype),".deps.toml"]];
  r:roots[];
  / -parentproctype as a symbol atom, null if not given
  parentproctype:$[`parentproctype in key o:.Q.opt .z.x;first `$o`parentproctype;`];
  / the logger is built before config so the command-line override layer can log through it
  logdep:buildlogdep[overrides];
  cc:use`di.torq.config;
  (cc`init)[enlist[`log]!enlist logdep];
  / segmentedchainedtp uses segmentedtp's settings
  settingsproctype:$[proctype=`segmentedchainedtp;`segmentedtp;proctype];
  if[not null parentproctype;logdep[`info][`init;"read in process parameter of parentproctype=",string parentproctype]];
  config:(cc`cascade)[r 0;r 1;parentproctype;settingsproctype;procname];
  / command-line overrides, the top cascade tier; flags that are reserved or not a setting are skipped
  config:(cc`overrideconfig)[config; clioverrideparams .Q.opt .z.x];
  / self-identity is stamped after the overrides
  config:config,`proctype`procname`parentproctype!(proctype;procname;parentproctype);
  / the process.csv path for di.torq.servers and other consumers
  config:config,enlist[`processcsv]!enlist reqenv[`TORQXAPPCONFIG],"/process.csv";
  / the process -t interval in ms, null if not given
  config:config,enlist[`timerms]!enlist cmdlinet[];
  timerdep:buildtimerdep[overrides;logdep];
  handlersdep:buildhandlersdep[overrides;logdep];
  / servers is built last as it consumes log, timer and handlers
  deps:`log`timer`handlers`servers!(logdep;timerdep;handlersdep;buildserversdep[overrides;config;logdep;timerdep;handlersdep]);
  / log rolling, a no-op unless the settings have [logroll] enabled=true; before the process type's init
  lr:use`di.torq.logroll;
  (lr`init)[config;deps];
  / init functions a process defers until pubsub and connections are initialised
  set[`.proc.initlist;()];
  set[`.proc.addinitlist;{[x] .proc.initlist,:enlist x}];
  $[proctype in key builtin;
    startbuiltin[proctype;config;deps];
    startcustom[proctype;config;deps]
    ];
  / optional permissions - before initclients/initquerylog, which wrap .z.pg/.z.ps by direct
  / assignment (claiming the exec owner after them would discard their wrappers), and before the
  / rule cascade, which needs di.permissions' admin api to exist
  initpermissions[config;deps];
  loadpermissionrules[logdep;config;proctype;procname];
  / app code, after the process module's init and before runhook
  loadappcode[logdep;config;proctype;procname];
  / initialise pubsub
  if[@[value;`.ps.loaded;0b];.ps.initialise[]];
  / initialise connections
  if[@[value;`.servers.STARTUP;0b];.servers.startup config];
  / run deferred init functions
  if[count .proc.initlist;value each .proc.initlist;.proc.initlist:()];
  / .z.* wrappers: clients, querylog, zpsignore last
  initclients[config;deps];
  / optional query logging, after everything else that binds .z.*
  initquerylog[config;deps];
  initzpsignore config;
  / post-load session audit: dependency contract shapes, .z.ts ownership and an optional minimum kdb-x version
  (dc`init)[`log`minkdbxversion!(logdep;$[`minkdbxversion in key config;"f"$config`minkdbxversion;0Nf])];
  runhook[proctype;overrides];
  `proctype`procname`config`deps!(proctype;procname;config;deps)
  }
