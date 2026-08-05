/ connection management and handle-by-type lookup for the modular torq world - the di.* analogue
/ of TorQ's .servers (code/handlers/trackservers.q + servers.q), scoped down for v1: no discovery
/ service, no password/access-list files, no non-torq process tracking, no FinSpace. process.csv
/ is a static phone book (who to dial), NOT an identity source - self-identity comes from config.
/ FRAMEWORK-tier module: no hard di.* deps; log, timer and handlers are injected (all required).
/ standard one-arg init[deps]: di.torq merges this process's config slice (proctype/procname,
/ connections, processcsv) into the same deps dict it passes the injectables in. conventions match
/ di.config: strict init validation (no fallback), three-flat-var logging, log-then-signal via
/ raiseerror, getapimeta for di.api, and the env-free boundary (the process.csv path arrives via
/ config; di.torq.servers reads no env itself).

/ --- module-local state (initial values at load; read/written via .z.m at runtime) ---

SERVERS:([]
  procname:`symbol$();
  proctype:`symbol$();
  hpup:`symbol$();
  w:`int$();
  hits:`int$();
  startp:`timestamp$();
  lastp:`timestamp$();
  endp:`timestamp$());

HOPENTIMEOUT:2000;

self:`proctype`procname!``;

/ guards init's one-time process-global side effects (the .z.pc observer + the retry timer job) so
/ init is IDEMPOTENT - di.torq calls it once per process, but a second call (a test re-run, a
/ future re-init) must not re-register: di.timer.addjob throws on a duplicate id. the dep refs are
/ always refreshed; only the one-time registrations are guarded.
registered:0b;

raiseerror:{[ctx;msg]
  / internal - log an error under ctx via the injected logger, then signal it, so a failure is
  / observable in the log as well as thrown. used for all post-init domain errors (init's own
  / dependency validation signals with a plain ' - the logger is not wired yet).
  .z.m.logerr[ctx;msg];
  '"di.torq.servers: ",string[ctx],": ",msg;
  };

init:{[deps]
  / wire the injected deps (log/timer/handlers - all required, no fallback) and this process's
  / config (proctype/procname identity, connections, processcsv), and install the one-time side
  / effects (a .z.pc cleanup observer via handlers + a 10s serversretry job via timer). config
  / arrives in the SAME deps dict (the one-arg init convention - di.torq merges the config slice
  / into it). idempotent (see `registered). does NOT open connections - that is startup's job.
  if[99h<>type deps;
    '"di.torq.servers: deps must be a dict of injectables + config"];
  if[not all `log`timer`handlers in key deps;
    '"di.torq.servers: log, timer and handlers dependencies are required (see di.util.log, di.timer, di.torq.handlers)"];
  if[99h<>type deps`log;
    '"di.torq.servers: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.torq.servers: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.torq.servers: timer value must be a dict (see di.timer)"];
  if[99h<>type deps`handlers;
    '"di.torq.servers: handlers value must be a dict (see di.torq.handlers)"];
  if[not all `proctype`procname in key deps;
    '"di.torq.servers: proctype and procname (self-identity) are required in deps"];
  if[not all -11h=type each deps`proctype`procname;
    '"di.torq.servers: proctype and procname must be symbols"];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.self:`proctype`procname!deps`proctype`procname;
  .z.m.connections:$[`connections in key deps;deps`connections;`symbol$()];
  .z.m.processcsv:$[`processcsv in key deps;deps`processcsv;""];
  if[not .z.m.registered;
    / .z.pc is a SIMPLE (observer) event in di.torq.handlers - side-effect only, fan-out. registered via
    / the injected handlers dep with di.torq.handlers' register[event;phase;nm;pri;func] contract; phase
    / is ` (null) for a simple event, pri 0. the callback marks a closed handle's row disconnected.
    / (param `wh`, not `w`, so it does not shadow the SERVERS column w.)
    pcfunc:{[wh] .z.m.SERVERS:update endp:.z.p,w:0Ni from .z.m.SERVERS where w=wh; };
    (.z.m.handlers[`register])[`.z.pc;`;`servers;0j;pcfunc];
    / di.timer mode-1h period is in SECONDS, so 10 = a 10-second retry (a bare 10000 here would be
    / ~2.8h - the latent typo that made dead-handle recovery effectively never fire in early POCs).
    (.z.m.timer[`addjob])[`serversretry;retry;();10;1;()!()];
    .z.m.registered:1b;
    ];
  .z.m.loginfo[`init;"di.torq.servers initialised"];
  };

formathp:{[host;port;ipctype]
  / internal - build a connection-handle symbol for `tcp`/`tcps`/`unix. only `tcp is exercised by
  / startup in v1; the others exist for a future SOCKETTYPE-style config.
  h:string host;
  p:string port;
  $[ipctype=`tcp; lower `$":",h,":",p;
    ipctype=`tcps;lower `$":tcps://",h,":",p;
    ipctype=`unix;lower `$":unix://",p;
    raiseerror[`formathp;"unknown ipctype ",string ipctype]]
  };

opencon:{[hpup]
  / open a connection, logging (not erroring) on failure - a downed peer isn't necessarily an
  / error at connect time; retry keeps trying. NOTE the timeout form is hopen[(handle;timeoutms)]
  / (a single 2-item list), not the dyadic hopen[handle;timeoutms], which throws 'rank.
  r:@[{(hopen (x;.z.m.HOPENTIMEOUT);"")};hpup;{(0Ni;x)}];
  if[null first r;.z.m.logwarn[`servers;"failed to open connection to ",(string hpup),": ",last r]];
  first r
  };

readprocesscsv:{[path]
  / internal - read the static process.csv phone book (host,port,proctype,procname). the PATH is
  / supplied by the caller (from config`processcsv); di.torq.servers reads no env itself, holding
  / di.config's env-free boundary - di.torq resolves the path and puts it in config.
  fsym:`$":",path;
  if[0=count key fsym;raiseerror[`readprocesscsv;"process.csv not found at ",path]];
  ("SISS";enlist",") 0: fsym
  };

startup:{[config]
  / open connections to every process.csv row whose proctype is in the configured connections list,
  / excluding this process's own row. `connections` and `processcsv` are read from the config arg -
  / NOT from init - because each consumer computes its OWN role-specific connection list (e.g. an rdb
  / dials its tickerplant+hdb types, a gateway its backend types) and passes it in via its config
  / slice; di.torq cannot know that list at init time. a failed connection is logged (not raised) and
  / left as w:0Ni for retry. a no-op if no connections are configured.
  / normalise connections to symbols to match process.csv's `proctype column (always a symbol via
  / the "S" spec): a .q settings file gives symbols already (`$ throws 'type on a symbol - it is
  / NOT idempotent, hence the type check); a .toml one gives plain strings (TOML has no symbol).
  conns:$[`connections in key config;config`connections;`symbol$()];
  conns:$[11h=abs type conns;conns;`$conns];
  if[0=count conns;.z.m.loginfo[`servers;"no configured connections to make"];:()];
  if[not `processcsv in key config;raiseerror[`startup;"processcsv (path to process.csv) is required in config to open connections"]];
  procs:readprocesscsv[config`processcsv];
  pt:.z.m.self`proctype;
  pn:.z.m.self`procname;
  procs:update isme:(proctype=pt)&procname=pn from procs;
  procs:select from procs where not isme;
  procs:select from procs where proctype in conns;
  if[0=count procs;.z.m.loginfo[`servers;"no process.csv rows match the configured connections"];:()];
  {[row]
    hpup:formathp[row`host;row`port;`tcp];
    w:opencon[hpup];
    if[not null w;.z.m.loginfo[`servers;"connected to ",(string row`proctype),"/",(string row`procname)," at ",string hpup]];
    / catenate+reassign, NOT `tablename insert - a symbol-based insert into `.z.m.SERVERS` misses
    / the compile-time module-local rewrite a source-level .z.m.SERVERS gets, silently targeting the
    / wrong (literal) table.
    newrow:([]procname:enlist row`procname;proctype:enlist row`proctype;hpup:enlist hpup;w:enlist w;hits:enlist 0i;startp:enlist $[null w;0Np;.z.p];lastp:enlist .z.p;endp:enlist 0Np);
    .z.m.SERVERS:.z.m.SERVERS,newrow;
    } each 0!procs;
  };

retryrows:{[rows]
  / internal - reattempt opencon for the given SERVERS row indices, updating w/lastp (and startp on
  / a successful reconnect).
  hs:opencon each exec hpup from .z.m.SERVERS where i in rows;
  .z.m.SERVERS:update w:hs,lastp:.z.p from .z.m.SERVERS where i in rows;
  .z.m.SERVERS:update startp:.z.p from .z.m.SERVERS where i in rows, not null w;
  };

cleanup:{[]
  / internal - sweep any row whose handle has vanished from key .z.W (a peer that died WITHOUT a
  / clean .z.pc on this side) and mark it disconnected, so retry will reopen it. the .z.pc observer
  / already catches clean closes; this catches the ungraceful ones.
  dead:exec w from .z.m.SERVERS where not null w, not w in key .z.W;
  if[count dead;.z.m.SERVERS:update endp:.z.p,w:0Ni from .z.m.SERVERS where w in dead];
  };

retry:{[]
  / internal - the scheduled `serversretry job (driven by the injected timer; passed by value at
  / init, so it needs no export). first sweep ungracefully-vanished handles (cleanup), then reopen
  / every dead (null) handle - so both clean and unclean drops are recovered on the retry cycle.
  cleanup[];
  rows:exec i from .z.m.SERVERS where null w;
  if[count rows;retryrows[rows]];
  };

getservers:{[pt]
  / every live (non-null handle) SERVERS row for a proctype.
  if[not -11h=type pt;raiseerror[`getservers;"proctype must be a symbol"]];
  select from .z.m.SERVERS where proctype=pt, not null w
  };

selector:{[tab;selection]
  / internal - pick one row from a live-server table by algorithm.
  $[selection=`roundrobin;first `lastp xasc tab;
    selection=`any;      rand tab;
    selection=`last;     last `lastp xasc tab;
    raiseerror[`selector;"unknown selection type ",string selection]]
  };

updatestats:{[wh]
  / internal - bump hits/lastp on the row whose handle was just handed out.
  .z.m.SERVERS:update lastp:.z.p,hits:1+hits from .z.m.SERVERS where w=wh
  };

gethandlebytype:{[pt;selection]
  / get a single live handle for a proctype via a selection algorithm (`any`roundrobin`last), or
  / 0Ni if none is connected. bumps usage stats on the chosen row.
  if[not -11h=type pt;raiseerror[`gethandlebytype;"proctype must be a symbol"]];
  if[not -11h=type selection;raiseerror[`gethandlebytype;"selection must be a symbol (`any`roundrobin`last)"]];
  r:getservers[pt];
  if[0=count r;:0Ni];
  wh:(selector[r;selection])`w;
  updatestats[wh];
  wh
  };

signalfound:{[pt]
  / internal - log and return 1b once a connection to pt exists.
  .z.m.loginfo[`servers;"connected to ",string pt];
  1b
  };

waitfortype:{[pt;timeoutms;pollms]
  / block until at least one LIVE connection to pt exists, or timeoutms elapses. the DI-scoped
  / analogue of legacy TorQ's startupdepcycles - "fail fast, but wait for a hard dependency to come
  / up". startup must have run first (so a pt row exists to reattempt). polls retry between tries,
  / sleeping pollms. returns 1b once connected, 0b on timeout - the CALLER decides if that is fatal.
  / NOTE the blocking system"sleep" is fine at startup (single-threaded; the injected timer's .z.ts
  / just doesn't fire during the sleep).
  if[not -11h=type pt;raiseerror[`waitfortype;"proctype must be a symbol"]];
  if[not (abs type timeoutms) within 5 7h;raiseerror[`waitfortype;"timeoutms must be an integer (ms)"]];
  if[not (abs type pollms) within 5 7h;raiseerror[`waitfortype;"pollms must be an integer (ms)"]];
  deadline:.z.p+`timespan$1000000*`long$timeoutms;
  .z.m.loginfo[`servers;"waiting up to ",(string timeoutms),"ms for a ",(string pt)," connection"];
  while[(0=count getservers pt) and .z.p<deadline;
    retry[];
    if[0<count getservers pt;:signalfound pt];
    system "sleep ",string pollms%1000;
    ];
  $[0<count getservers pt;signalfound pt;
    [.z.m.logwarn[`servers;"timed out after ",(string timeoutms),"ms waiting for a ",(string pt)," connection"];0b]]
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE API function, for di.torq to register with
  / di.api. init/getapimeta are plumbing (di.torq calls them by convention) and are deliberately NOT
  / listed - the registry describes the callable api, not plumbing. names are bare (di.torq qualifies).
  :flip `name`public`descrip`params`return!flip(
    (`startup;         1b; "open connections to the config's proctypes from process.csv (config carries connections + processcsv)"; "[dict: config with `connections + `processcsv]"; "null");
    (`getservers;      1b; "live SERVERS rows for a proctype";                                      "[symbol: proctype]";                              "table: live server rows");
    (`gethandlebytype; 1b; "one live handle for a proctype via any/roundrobin/last selection";      "[symbol: proctype; symbol: selection]";           "int: handle, 0Ni if none");
    (`waitfortype;     1b; "block until a proctype connects or timeout elapses";                    "[symbol: proctype; long: timeoutms; long: pollms]"; "boolean: 1b connected, 0b timed out"));
  };
