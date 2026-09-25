/ connection management and handle-by-type lookup for the modular torq world - the di.* analogue
/ of TorQ's .servers (code/handlers/trackservers.q + servers.q). The discovery-protocol parts of
/ trackservers.q are ported line for line and published at their legacy root names (.servers.*,
/ .dotz.liveh*); registry state and config live at legacy's root .servers.* globals. See servers.md.
/ FRAMEWORK-tier module: no hard di.* deps; log, timer and handlers are injected (all required).
/ standard one-arg init[deps]: di.torq merges this process's config slice (proctype/procname,
/ connections, processcsv) into the same deps dict it passes the injectables in. conventions match
/ di.torq.config: strict init validation (no fallback), three-flat-var logging, log-then-signal via
/ raiseerror, getapimeta for di.api, and the env-free boundary (the process.csv path arrives via
/ config; di.torq.servers reads no env itself).

/ --- module-local state (initial values at load; read/written via .z.m at runtime) ---

self:`proctype`procname!``;

/ guards init's one-time process-global side effects (the .z.pc observer + the timer jobs) so
/ init is IDEMPOTENT - di.torq calls it once per process, but a second call (a test re-run, a
/ future re-init) must not re-register: di.timer.addjob throws on a duplicate id. the dep refs are
/ always refreshed; only the one-time registrations are guarded.
registered:0b;

/ trackservers.q l.13-28: flat config key -> (.servers global;trackservers default)
settings:`connections`discoveryregister`connectionsfromdiscovery`subscribetodiscovery`discoveryretry`tracknontorqprocess`hopentimeout`retry`retain`autoclean`debug`startup`discovery!(
  (`.servers.CONNECTIONS;`);
  (`.servers.DISCOVERYREGISTER;1b);
  (`.servers.CONNECTIONSFROMDISCOVERY;1b);
  (`.servers.SUBSCRIBETODISCOVERY;1b);
  (`.servers.DISCOVERYRETRY;0D00:05);
  (`.servers.TRACKNONTORQPROCESS;0b);
  (`.servers.HOPENTIMEOUT;2000);
  (`.servers.RETRY;0D00:05);
  (`.servers.RETAIN;`long$0D00:30);
  (`.servers.AUTOCLEAN;0b);
  (`.servers.DEBUG;1b);
  (`.servers.STARTUP;0b);
  (`.servers.DISCOVERY;enlist`));

raiseerror:{[ctx;msg]
  / internal - log an error under ctx via the injected logger, then signal it, so a failure is
  / observable in the log as well as thrown. used for all post-init domain errors (init's own
  / dependency validation signals with a plain ' - the logger is not wired yet).
  .z.m.logerr[ctx;msg];
  '"di.torq.servers: ",string[ctx],": ",msg;
  };

init:{[deps]
  / wire the injected deps (log/timer/handlers - all required, no fallback) and this process's
  / config (proctype/procname identity, processcsv, the trackservers settings), publish the legacy
  / root names, and install the one-time side effects (a .z.pc observer via handlers + the
  / trackservers.q timer jobs via timer). idempotent (see `registered). does NOT open
  / connections - that is startup's job.
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
  .z.m.processcsv:$[`processcsv in key deps;deps`processcsv;""];
  / trackservers.q l.10
  @[value;`.servers.SERVERS;{set[`.servers.SERVERS;([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();hits:`int$();startp:`timestamp$();lastp:`timestamp$();endp:`timestamp$();attributes:())]}];
  / trackservers.q l.13-28
  {[deps;k] set[first .z.m.settings k;$[k in key deps;deps k;last .z.m.settings k]]}[deps] each key .z.m.settings;
  set[`.servers.NONTORQPROCESSFILE;$[`nontorqprocessfile in key deps;hsym deps`nontorqprocessfile;hsym `$("/" sv -1_"/" vs .z.m.processcsv),"/nontorqprocess.csv"]];
  / dotz.q l.8
  set[`.dotz.liveh;{x in key .z.W}];
  set[`.dotz.livehn;{x in 0Ni,key .z.W}];
  set[`.dotz.liveh0;{x in 0i,key .z.W}];
  pub:`opencon`cleanup`addnthawc`getdetails`addhw`addw`retry`retrydiscovery`autodiscovery`retryrows`removerows`register`querydiscovery`registerfromdiscovery`addprocs`procupdate`domainsocketsenabled`formathp`formatprocs`startup`pc!(opencon;cleanup;addnthawc;getdetails;addhw;addw;retry;retrydiscovery;autodiscovery;retryrows;removerows;register;querydiscovery;registerfromdiscovery;addprocs;procupdate;domainsocketsenabled;formathp;formatprocs;startup;pc);
  set'[` sv/:`.servers,/:key pub;value pub];
  if[not .z.m.registered;
    / trackservers.q l.385
    (.z.m.handlers[`register])[`.z.pc;`;`servers;0j;pc];
    / trackservers.q l.387-389 (legacy .timer.repeat's default schedule is mode 2)
    if[.servers.DISCOVERYRETRY>0;(.z.m.timer[`addjob])[`discoveryretry;retrydiscovery;();`long$.servers.DISCOVERYRETRY%0D00:00:01;2;()!()]];
    if[.servers.RETRY>0;(.z.m.timer[`addjob])[`serversretry;retry;();`long$.servers.RETRY%0D00:00:01;2;()!()]];
    .z.m.registered:1b;
    ];
  .z.m.loginfo[`init;"di.torq.servers initialised"];
  };

/ open a connection
opencon:{[hpup]
  if[.servers.DEBUG;.z.m.loginfo[`conn;"attempting to open handle to ",string hpup]];
  / NOTE the timeout form is hopen[(handle;timeoutms)] (a single 2-item list), not the dyadic
  / hopen[handle;timeoutms], which throws 'rank.
  r:@[{(hopen (x;.servers.HOPENTIMEOUT);"")};hpup;{(0Ni;x)}];
  if[.servers.DEBUG;.z.m.loginfo[`conn;"connection to ",(string hpup),$[null first r;" failed: ",last r;" successful"]]];
  if[null first r;.z.m.logwarn[`servers;"failed to open connection to ",(string hpup),": ",last r]];
  first r
  };

readprocesscsv:{[path]
  / internal - read the static process.csv phone book (host,port,proctype,procname). the PATH is
  / supplied by the caller (from config`processcsv); di.torq.servers reads no env itself, holding
  / di.torq.config's env-free boundary - di.torq resolves the path and puts it in config.
  fsym:`$":",path;
  if[0=count key fsym;raiseerror[`readprocesscsv;"process.csv not found at ",path]];
  ("SISS";enlist",") 0: fsym
  };

cleanup:{if[count w0:exec w from`.servers.SERVERS where not .dotz.livehn w;
    update endp:.z.p,lastp:.z.p,w:0Ni from`.servers.SERVERS where w in w0];
  if[.servers.AUTOCLEAN;delete from`.servers.SERVERS where not .dotz.liveh w,(.z.p^endp)<.z.p-.servers.RETAIN];}

/ add a new server for current session
addnthawc:{[name;proctype;hpup;attributes;W;checkhandle]
  if[checkhandle and not isalive:.dotz.liveh W;'"invalid handle"];
  cleanup[];
  $[not hpup in (exec hpup from .servers.SERVERS) inter (exec hpup from .servers.nontorqprocesstab);
    `.servers.SERVERS insert(name;proctype;lower hpup;W;0i;$[isalive;.z.p;0Np];.z.p;0Np;attributes);
    .z.m.loginfo[`conn;"Removed double entries: name->", string[name],", proctype->",string[proctype],", hpup->\"",string[hpup],"\""]];
  W
  }

/ return the details of the current process
getdetails:{(.z.f;.z.h;system"p";.z.m.self`procname;.z.m.self`proctype;@[value;(`.proc.getattributes;`);()!()])}

/ add session behind a handle
addhw:{[hpuP;W]
  / Get the information around a process
  info:`f`h`port`procname`proctype`attributes!(@[W;({$[`getdetails in key`.servers;.servers.getdetails[];(.z.f;.z.h;system"p";`;`;$[`getattributes in key`.proc;.proc.getattributes[];()!()])]};`);(`;`;0Ni;`;`;()!())]);
  if[0Ni~info`port;'"remote call failed on handle ",string W];
  if[null name:info`procname;name:`$last("/"vs string info`f)except enlist""];
  if[0=count name;name:`default];
  if[null hpuP;hpuP:formathp[info`h;info`port;`tcp;info`proctype;info`procname]];
  / If this handle already has an entry, delete the old entry
  delete from `.servers.SERVERS where w=W;
  addnthawc[name;info`proctype;hpuP;info`attributes;W;0b]}

addw:addhw[`]

/ after getting new servers run retry to open connections
retry:{retryrows exec i from `.servers.SERVERS where not .dotz.liveh0 w,not proctype=`discovery}

retrydiscovery:{
  if[count d:exec i from `.servers.SERVERS where proctype=`discovery,not ({any .dotz.liveh0 x};w) fby hpup, i=(first;i) fby hpup;
    .z.m.loginfo[`conn;"attempting to connect to discovery services"];
    retryrows d;
    / register with the newly opened discovery services
    if[.servers.DISCOVERYREGISTER and count h:exec w from .servers.SERVERS[d] where .dotz.liveh w;
      .z.m.loginfo[`conn;"registering with discovery services"];
      @[;(`..register;`);()] each neg h];
    if[.servers.CONNECTIONSFROMDISCOVERY and count h;
      registerfromdiscovery[$[`discovery in .servers.CONNECTIONS;(.servers.CONNECTIONS,()) except `discovery;.servers.CONNECTIONS];0b]];
    ]}

/ Called by the discovery service when it restarts
autodiscovery:{if[.servers.DISCOVERYRETRY>0; .servers.retrydiscovery[]]}

/ Attempt to make a connection for specified row ids
retryrows:{[rows]
  / a returns the remote .proc.getattributes[] for a live handle, else an empty dict
  a:{$[not null x;@[x;({.proc.getattributes[]};::);()!()];()!()]};
  handles:opencon each exec hpup from .servers.SERVERS where i in rows;
  update lastp:.z.p,w:handles from`.servers.SERVERS where i in rows;
  update attributes:a each w,startp:?[null w;0Np;.z.p] from`.servers.SERVERS where i in rows;}

/ close handles and remove rows from the table
removerows:{[rows]
  @[hclose;;()] each .servers.SERVERS[rows][`w] except 0 0Ni;
  @[.z.pc;;()] each .servers.SERVERS[rows][`w] except 0 0Ni;
  delete from `.servers.SERVERS where i in rows}

/ Create some connections and optionally connect to them
register:{[connectiontab;proc;connect]
  {addnthawc[x`procname;x`proctype;x`hpup;()!();0Ni;0b]}each distinct select from connectiontab where proctype=proc;
  / automatically connect
  if[connect;
    $[`discovery=proc;retrydiscovery[];retry[]]]};

/ Query a discovery service, and get the list of available services
/ Does not attempt to re-open any discovery services
querydiscovery:{[procs]
  if[0=count procs;:()];
  .z.m.loginfo[`conn;"querying discovery services for processes of types "," " sv string procs,()];
  h:exec w from .servers.SERVERS where proctype=`discovery,.dotz.liveh w;
  $[0=count h;
    [.z.m.loginfo[`conn;"no discovery services available"];()];
    raze @[;(`getservices;procs;.servers.SUBSCRIBETODISCOVERY);()] each h]}

/ register processes from the discovery service
registerfromdiscovery:{[procs;connect]
  if[`discovery in procs; '"cannot use registerfromdiscovery to locate discovery services"];
  .z.m.loginfo[`conn;"requesting processes from discovery service"];
  res:querydiscovery[procs];
  if[0=count res; .z.m.loginfo[`conn;"no processes found"]; :()];
  / add the processes
  addprocs[res;procs;connect];}

addprocs:{[connectiontab;procs;connect]
  connectiontab:formatprocs[delete split from update host:hpup^`$last each -1 _' split, port:"I"$last each split from update split:{":" vs string x}each hpup from connectiontab];
  / filter out any we already have - same name,type and hpup
  res:select from connectiontab where not ([]procname;proctype;hpup) in select procname,proctype,hpup from .servers.SERVERS;
  / we've dropped some items - maybe there are updated attributes
  if[not count[res]=count connectiontab;
    if[`attributes in cols connectiontab;
      .servers.SERVERS:.servers.SERVERS lj 3!select procname,proctype,hpup,attributes from connectiontab where not ([]procname;proctype;hpup) in select procname,proctype,hpup from .servers.SERVERS]];
  / if we have a match where the hpup is the same, but different name/type, then remove the old details
  removerows exec i from `.servers.SERVERS where hpup in exec hpup from res;
  register[res;;connect] each $[procs~`ALL;exec distinct proctype from res;procs,()];}

/ used to handle updates from the discovery service
procupdate:{[procs] addprocs[procs;exec distinct proctype from procs;0b];}

/ return true if unix domain sockets can be used
domainsocketsenabled:{[]
  / unix domain sockets only works on unix and not windows
  notwin:not .z.o like "w*";
  / v3.4 brought in the first version of unix domain sockets ipc
  iskdbv:3.4<=.z.K;
  :notwin and iskdbv;
  }

/ format hpup from procs table, take into account ipc type
formathp:{[HOST;PORT;IPCTYPE;PROCTYPE;PROCNAME]
  ipctype:IPCTYPE;
  isunixsocket:ipctype = `unix;
  notsamebox:not any HOST in `localhost,.z.h;
  host:string $[HOST=`localhost;.z.h;HOST];
  port:string PORT;
  / revert socket to tcp
  if[isunixsocket and notsamebox;
    .z.m.logwarn[`formathp;"Expects to connect via domain sockets, but host is not on the same machine. Reverting IPC mechanism to TCP"];
    ipctype:`tcp;
    ];
  if[isunixsocket and not domainsocketsenabled[];
    .z.m.logwarn[`formathp;"Domain sockets are not enabled for this system. Reverting IPC mechanism from to TCP"];
    ipctype:`tcp;
    ];
  / Format hpup file handle
  if[ipctype = `tcp;
    hpup:lower `$":",host,":",port;
    ];
  if[ipctype = `tcps;
    hpup:lower `$":tcps://",host,":",port;
    ];
  if[ipctype = `unix;
    hpup:lower `$":unix://",port;
    ];
  :hpup;
  }

/ do full formatting of proc table
formatprocs:{[PROCS]
  procs:update ipctype:`tcp from PROCS;
  procs:update hpup:.servers.formathp'[host;port;ipctype;proctype;procname] from procs;
  :procs;
  }

/ called at start up. config`connections / config`processcsv stand in for legacy's
/ .servers.CONNECTIONS / .proc.file (a TOML config gives strings - normalised to symbols)
startup:{[config]
  if[`connections in key config;
    .servers.CONNECTIONS:$[11h=abs type c:config`connections;c;`$c]];
  pf:$[`processcsv in key config;config`processcsv;.z.m.processcsv];
  / correctly format procs and hpup
  .servers.procstab:procs:formatprocs readprocesscsv pf;
  .servers.nontorqprocesstab:formatprocs $[count key .servers.NONTORQPROCESSFILE;readprocesscsv 1_string .servers.NONTORQPROCESSFILE;0#procs];
  / If DISCOVERY servers have been explicity defined
  if[count .servers.DISCOVERY;
    if[not null first .servers.DISCOVERY;
      if[count select from procs where hpup in .servers.DISCOVERY; .z.m.logerr[`startup; "host:port in .servers.DISCOVERY list is already present in data read from ",pf]];
      procs,:([]host:`;port:0Ni;proctype:`discovery;procname:`;hpup:.servers.DISCOVERY)]];
  / Remove any processes that have an active connection
  connectedprocs:select procname, proctype, hpup from .servers.SERVERS;
  procs:delete from procs where ([] procname; proctype; hpup) in connectedprocs;
  nontorqprocs:delete from .servers.nontorqprocesstab where ([] procname; proctype; hpup) in connectedprocs;
  / if there aren't any processes left to connect to, then escape
  if[not any count each (procs;nontorqprocs); .z.m.loginfo[`conn;"No new processes to connect to.  Escaping..."];:()];
  if[.servers.CONNECTIONSFROMDISCOVERY or .servers.DISCOVERYREGISTER;
    register[procs;`discovery;0b];
    retrydiscovery[]];
  if[not .servers.CONNECTIONSFROMDISCOVERY; register[procs;;0b] each $[.servers.CONNECTIONS~`ALL;exec distinct proctype from procs;.servers.CONNECTIONS]];
  if[.servers.TRACKNONTORQPROCESS;register[nontorqprocs;;0b] each $[.servers.CONNECTIONS~`ALL;exec distinct proctype from nontorqprocs;.servers.CONNECTIONS]];
  / try and open dead connections
  retry[]}

pc:{[W] update w:0Ni,endp:.z.p from`.servers.SERVERS where w=W;cleanup[];}

getservers:{[pt]
  / every live (non-null handle) SERVERS row for a proctype.
  if[not -11h=type pt;raiseerror[`getservers;"proctype must be a symbol"]];
  select from .servers.SERVERS where proctype=pt, not null w
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
  .servers.SERVERS:update lastp:.z.p,hits:1+hits from .servers.SERVERS where w=wh
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
