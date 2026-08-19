/ connection management and handle-by-type lookup for the modular torq world - the di.* analogue
/ of TorQ's .servers (code/handlers/trackservers.q + servers.q), scoped down for v1: no discovery
/ service, no password/access-list files, no non-torq process tracking, no FinSpace. process.csv
/ is a static phone book (who to dial), NOT an identity source - self-identity comes from config.
/ FRAMEWORK-tier module: no hard di.* deps; log, timer and handlers are injected (all required).
/ standard one-arg init[deps]: di.torq merges this process's config slice (proctype/procname,
/ connections, processcsv) into the same deps dict it passes the injectables in. conventions match
/ di.config: strict init validation (no fallback), three-flat-var logging, log-then-signal via
/ raiseerror, getapimeta for di.api, and the env-free boundary (the process.csv path arrives via
/ config; di.servers reads no env itself).

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
/ always refreshed; only the one-time registrations are guarded. teardown resets it to 0b so a
/ later init registers again - it is the SIDE-EFFECT guard only, deliberately not the initialised[]
/ probe below (see there for why the two are separate flags).
registered:0b;

initialised:{[]
  / has init run? .z.m.loginfo has no load-time default - its only value comes from init, so this
  / probe cannot be fooled by a constant of the same name. that rules out the two obvious
  / alternatives: `self` and `registered` are both declared at LOAD time above, so neither can tell
  / "init ran" from "the module was merely loaded". it is also the truest probe of what requireinit
  / actually protects - without a wired logger the module cannot even report its own failures.
  / deliberately NOT `registered`: teardown resets that, and conflating the two would make every
  / function report "init must be called" after a teardown, which is both untrue and would put
  / SERVERS out of reach of the shutdown path teardown exists to serve. di.rdb (probes hdbdir,
  / resets started) and di.subscriptions (probes subscriptions, resets observing) split them the
  / same way.
  :@[{.z.m.loginfo;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init/getapimeta refuses to run before init has wired the deps.
  / without this a pre-init call is SILENTLY wrong rather than loud, which is the worst shape a bug
  / here could take: getservers returns an empty table, gethandlebytype 0Ni, and waitfortype spins
  / its full timeout before returning 0b - all three indistinguishable from "genuinely nothing of
  / that type is connected right now". signals with a plain ' and NOT raiseerror: the logger is the
  / very thing that may not be wired yet.
  if[not initialised[];
    '"di.servers: ",string[ctx],": init must be called before any other function"];
  };

iscallable:{[x]
  / internal - is x a genuinely callable value? 100 112h spans every callable form (lambda,
  / primitive, operator, iterator, projection, composition), but 101h - the generic null :: - sits
  / INSIDE that range while being callable in no useful sense, so the bare range check is not enough.
  / that matters because :: is exactly what a dict hands back for a MISSING key when its value side
  / is plain functions, which is what a real dep dict looks like (`deletejobs _ di.timer gives 101h,
  / not the 99h a table-valued dep gives). admitting it lets an absent or explicitly-null dep reach
  / teardown and no-op in silence: @[::;id;handler] simply returns id, deleting nothing, while
  / teardown logs success. measured end to end, hence the extra exclusion
  t:type x;
  :(t within 100 112h) and 101h<>t;
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx via the injected logger, then signal it, so a failure is
  / observable in the log as well as thrown. used for all post-init domain errors (init's own
  / dependency validation signals with a plain ' - the logger is not wired yet).
  .z.m.logerr[ctx;msg];
  '"di.servers: ",string[ctx],": ",msg;
  };

init:{[deps]
  / wire the injected deps (log/timer/handlers - all required, no fallback) and this process's
  / config (proctype/procname identity, connections, processcsv), and install the one-time side
  / effects (a .z.pc cleanup observer via handlers + a 10s serversretry job via timer). config
  / arrives in the SAME deps dict (the one-arg init convention - di.torq merges the config slice
  / into it). idempotent (see `registered). does NOT open connections - that is startup's job.
  if[99h<>type deps;
    '"di.servers: deps must be a dict of injectables + config"];
  if[not all `log`timer`handlers in key deps;
    '"di.servers: log, timer and handlers dependencies are required (see di.log, di.timer, di.handlers)"];
  if[99h<>type deps`log;
    '"di.servers: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.servers: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.servers: timer value must be a dict (see di.timer)"];
  if[not `addjob in key deps`timer;
    '"di.servers: timer dict must expose `addjob (see di.timer)"];
  if[99h<>type deps[`timer]`addjob;
    '"di.servers: timer`addjob must be a variant dict (see di.timer addjob.custom/default/simple)"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.servers: timer`addjob must expose the `custom variant [id;func;params;period;mode;opts]"];
  / deletejobs is checked here for the same reason addjob is, and the consequence of NOT checking it
  / is worse than a late error - it is a SILENT one. the timer dep's value side is dict-typed, so a
  / MISSING key returns a null-shaped DICT rather than erroring. teardown's
  / @[.z.m.timer[`deletejobs];ids;handler] then stops being protected-apply at all: @[x;y;z] is
  / "try x[y], catch with z" only when x is a FUNCTION, and here x is a dict, so q reads the whole
  / expression as three-argument AMEND. it upserts the job id into that throwaway dict using the
  / error handler as the new value, discards the result (nothing in teardown captures it) and
  / carries on. nothing throws, nothing warns, serversretry is never deleted, and teardown still
  / logs success - a false positive. see di.rdb, which closes the identical trap
  if[not `deletejobs in key deps`timer;
    '"di.servers: timer dict must expose `deletejobs - teardown needs it, and a timer dep without ",
      "it fails SILENTLY at teardown rather than loudly here; see di.timer"];
  / presence is NOT enough: a non-callable deletejobs reaches teardown's @[...] and lands in exactly
  / the same amend interpretation as a missing key, so it too returns quietly having deleted
  / nothing. iscallable, not a bare `within 100 112h`: the range admits 101h (::), which is both a
  / non-callable and the exact value a function-valued dep dict returns for a missing key - see there
  if[not iscallable deps[`timer]`deletejobs;
    '"di.servers: timer`deletejobs must be a function [ids]; a non-callable or null value fails ",
      "silently at teardown - see di.timer"];
  if[99h<>type deps`handlers;
    '"di.servers: handlers value must be a dict (see di.handlers)"];
  / register is what init calls and remove is what teardown calls; neither was validated before, so
  / a handlers dep missing either failed late and obscurely at the call site instead of here, naming
  / neither the module nor the missing key. same presence-then-callable pair as the timer checks
  if[not all `register`remove in key deps`handlers;
    '"di.servers: handlers dict must have `register`remove keys (init registers, teardown removes); ",
      "got: ",(", " sv string key deps`handlers)];
  if[not all iscallable each deps[`handlers]`register`remove;
    '"di.servers: handlers`register and handlers`remove must both be functions, neither null ",
      "- see di.handlers"];
  if[not all `proctype`procname in key deps;
    '"di.servers: proctype and procname (self-identity) are required in deps"];
  if[not all -11h=type each deps`proctype`procname;
    '"di.servers: proctype and procname must be symbols"];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.self:`proctype`procname!deps`proctype`procname;
  .z.m.connections:$[`connections in key deps;deps`connections;`symbol$()];
  .z.m.processcsv:$[`processcsv in key deps;deps`processcsv;""];
  if[not .z.m.registered;
    / .z.pc is a SIMPLE (observer) event in di.handlers - side-effect only, fan-out. registered via
    / the injected handlers dep with di.handlers' register[event;phase;nm;pri;func] contract; phase
    / is ` (null) for a simple event, pri 0. the callback marks a closed handle's row disconnected.
    / (param `wh`, not `w`, so it does not shadow the SERVERS column w.)
    pcfunc:{[wh] .z.m.SERVERS:update endp:.z.p,w:0Ni from .z.m.SERVERS where w=wh; };
    (.z.m.handlers[`register])[`.z.pc;`;`servers;0j;pcfunc];
    / di.timer's addjob is a VARIANT DICT; take `custom - the fully-configurable 6-arg form
    / [id;func;params;period;mode;opts]. mode-1h period is in SECONDS, so 10 = a 10s retry (a bare
    / 10000 would be ~2.8h - the latent typo that made dead-handle recovery never fire in early POCs).
    / retry is passed BY VALUE (a lambda, not a symbol) so di.timer stores and runs it directly; its
    / compile-time .z.m rewrite means it still updates di.servers' SERVERS when the timer fires it.
    (.z.m.timer[`addjob][`custom])[`serversretry;retry;();10;1;()!()];
    .z.m.registered:1b;
    ];
  .z.m.loginfo[`init;"di.servers initialised"];
  };

teardown:{[]
  / release both process-global registrations init installed - the .z.pc observer and the
  / serversretry timer job - so nothing of di.servers is left bound process-wide. paired with init's
  / side effects, exactly as di.subscriptions.teardown is paired with its .z.pc registration and
  / di.rdb.teardown with its root entry points and timer jobs.
  / module state is deliberately LEFT INTACT - SERVERS above all - so a shutdown path can still
  / inspect what was connected and to whom; only the process-global bindings are withdrawn. the same
  / convention every other teardown in this project follows.
  / IDEMPOTENT: a second call must not die on what the first already removed. both release calls are
  / no-ops on an already-removed registration - di.timer.deletejobs is a delete-where over its jobs
  / table (an id that is not there matches nothing) and di.handlers' removesimple early-returns with
  / an info log when the event or the name is not registered. verified in both modules, not assumed.
  requireinit[`teardown];
  / called directly rather than through @[...]: init guarantees `remove is present and callable, so
  / a throw here is a genuine handlers failure and should surface rather than be swallowed
  .z.m.handlers[`remove][`.z.pc;`;`servers];
  / NB this @[...] IS protected-apply only because init guarantees `deletejobs is present and is a
  / function. were the key missing, x would be the null-shaped dict a dict-valued dep returns for an
  / absent key and q would read the line as three-argument amend instead, deleting nothing and
  / logging nothing while teardown reported success. the init check is what keeps this line honest
  @[.z.m.timer[`deletejobs];`serversretry;
    {[e] .z.m.logwarn[`teardown;"could not delete the serversretry timer job: ",e]}];
  / reset the SIDE-EFFECT guard only, so a later init registers both again. initialised[] probes
  / .z.m.loginfo, not this, so everything else stays callable after a teardown - see initialised[]
  .z.m.registered:0b;
  .z.m.loginfo[`teardown;"di.servers .z.pc registration and serversretry job removed"];
  };

formathp:{[host;port]
  / internal - build the tcp connection-handle symbol from a process.csv row. v1 is tcp only; a
  / future SOCKETTYPE config would reintroduce tcps/unix handling (and a type arg) when there is a
  / real requirement and a test - we do not ship unexercised branches.
  lower `$":",(string host),":",string port
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
  / internal - read the static process.csv phone book. the PATH comes from config`processcsv (di.torq
  / resolves it; di.servers reads no env). v1 is a STRICT 4-column host,port,proctype,procname layout:
  / validate the header up front and FAIL LOUD, because ("SISS";",") is positional and would otherwise
  / silently misread a reordered or wider file (e.g. a real 13-column TorQ process.csv) into garbage.
  fsym:`$":",path;
  if[0=count key fsym;raiseerror[`readprocesscsv;"process.csv not found at ",path]];
  lines:read0 fsym;
  if[0=count lines;raiseerror[`readprocesscsv;"process.csv is empty at ",path]];
  if[not `host`port`proctype`procname~`$trim each "," vs first lines;
    raiseerror[`readprocesscsv;"process.csv header must be exactly host,port,proctype,procname (v1 4-column phone book); got: ",first lines]];
  ("SISS";enlist",") 0: lines
  };

startup:{[]
  / open connections to every process.csv row whose proctype is in the configured connections list,
  / excluding this process's own row. reads the config stored at init. a failed connection is logged
  / (not raised) and left as w:0Ni for retry. a no-op if no connections are configured.
  / normalise connections to symbols to match process.csv's `proctype column (always a symbol via
  / the "S" spec): a .q settings file gives symbols already (`$ throws 'type on a symbol - it is
  / NOT idempotent, hence the type check); a .toml one gives plain strings (TOML has no symbol).
  requireinit[`startup];
  conns:.z.m.connections;
  conns:$[11h=abs type conns;conns;`$conns];
  if[0=count conns;.z.m.loginfo[`servers;"no configured connections to make"];:()];
  if[0=count .z.m.processcsv;raiseerror[`startup;"processcsv (path to process.csv) is required in config to open connections"]];
  procs:readprocesscsv[.z.m.processcsv];
  pt:.z.m.self`proctype;
  pn:.z.m.self`procname;
  procs:update isme:(proctype=pt)&procname=pn from procs;
  procs:select from procs where not isme;
  procs:select from procs where proctype in conns;
  / SELF-CONNECTION GUARD. the exclusion above is an exact (proctype;procname) match against the
  / identity from config. if process.csv disagrees - a drifted proctype for this procname - the self
  / row is not recognised and this process dials ITSELF. procname is process.csv's unique key (the
  / idempotency filter below relies on that too), so a surviving row carrying our procname IS us:
  / drop it and say why, rather than opening a self-connection nobody would think to look for.
  / checked AFTER the connections filter: a row that could never be connected to was never at risk
  if[count mismatched:select from procs where procname=pn;
    .z.m.logwarn[`startup;"process.csv lists procname ",(string pn)," as proctype ",
      (string first mismatched`proctype),", but this process is configured as proctype ",(string pt),
      " - identity drift, skipping that row rather than connecting to myself"];
    procs:select from procs where not procname=pn];
  / idempotent: skip any proc already tracked in SERVERS. a repeat startup (or a process.csv that has
  / grown since) then adds only NEW rows - never a duplicate row or a leaked second handle to a proc
  / already connected. reconnecting a dropped peer is retry's job, not startup's.
  procs:select from procs where not procname in exec procname from .z.m.SERVERS;
  if[0=count procs;.z.m.loginfo[`servers;"no new process.csv rows to connect"];:()];
  {[row]
    hpup:formathp[row`host;row`port];
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
  / every live (non-null handle) SERVERS row for a proctype. ` matches EVERY proctype and a list
  / matches any of them - the contract legacy TorQ's .servers.getservers (trackservers.q:75) and
  / di.serverselect.getservers both implement, and which any consumer written against either expects.
  / matching with `in` rather than `=` is what makes both shapes work; a bare symbol still behaves
  / exactly as before, so every existing caller is unaffected
  requireinit[`getservers];
  if[not 11h=abs type pt;raiseerror[`getservers;"proctype must be a symbol or symbol list"]];
  $[`~pt;
    select from .z.m.SERVERS where not null w;
    select from .z.m.SERVERS where proctype in pt, not null w]
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
  requireinit[`gethandlebytype];
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
  / a zero or already-expired timeout performs NO active retry - see servers.md, waitfortype[pt;0;p]
  requireinit[`waitfortype];
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
    (`teardown;        1b; "release the .z.pc handler and retry job installed by init";                     "[]";                                       "null");
    (`startup;         1b; "open connections to configured proctypes from process.csv (reads init config)"; "[]";                                       "null");
    (`getservers;      1b; "live SERVERS rows for a proctype, a list of proctypes, or ` for all";   "[symbol|list: proctype, or ` for all]";           "table: live server rows");
    (`gethandlebytype; 1b; "one live handle for a proctype via any/roundrobin/last selection";      "[symbol: proctype; symbol: selection]";           "int: handle, 0Ni if none");
    (`waitfortype;     1b; "block until a proctype connects or timeout elapses";                    "[symbol: proctype; long: timeoutms; long: pollms]"; "boolean: 1b connected, 0b timed out"));
  };
