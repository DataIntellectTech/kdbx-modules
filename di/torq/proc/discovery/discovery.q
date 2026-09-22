/ di.torq.proc.discovery - discovery service. The sole ACTIVE party in service discovery: it dials
/ every process listed in process.csv (and, if enabled, nontorqprocess.csv) through its own
/ injected di.torq.servers instance, re-reads those phone books on every tick to pick up processes
/ that were not there last time, evicts rows that have left every phone book (a decommissioned
/ process - a merely DOWN one is retained and retried, as legacy did), and pushes the rows it
/ currently has a LIVE handle to into every subscribed peer by calling that peer's root-published,
/ discovery-unaware .torq.servers.addprocs (and .torq.servers.removeprocs for the evictions).
/ Peers never register, self-report, or dial back in: a peer that wants to be told about services
/ dials a `discovery row in ITS phone book (ordinary connections config) and calls
/ .discovery.getservices[proctypes;1b] over that handle once. Ported from the whole of TorQ's
/ discovery protocol - code/processes/discovery.q plus the client half spread across
/ code/handlers/trackservers.q (autodiscovery/procupdate/registerfromdiscovery/querydiscovery/
/ retrydiscovery) - collapsed into this one process module so di.torq.servers can stay generic.
/ ---
/ Deliberately absent (design, not phasing - see discovery.md "Design record"): a `register`
/ entry point (nothing self-announces), attributes/attributematch (di.serverselect's domain),
/ record retention/autoclean knobs (legacy discovery retained forever), and every DISCOVERY*
/ consumer-side setting (nothing to configure on a consumer).
/ ---
/ Module-namespace notes: mutable state lives in .z.m; the two IPC entry points are published at
/ REAL root names via set[`.discovery.<fn>;fn] because use loads this file into a private
/ namespace. Nothing module-local is referenced inside a qsql expression (module-local function
/ names do not resolve there, and a $[..] inside one throws 'rank) - values are computed into
/ locals first; see di.torq.servers 0.4.0 for the measurement.

/ --- module-local state (initial values at load; read/written via .z.m at runtime) ---

/ subscriptions: handle -> the proctypes that peer asked for (a symbol list; `ALL means everything)
subs:(`int$())!();

/ guards init's one-time registrations (the .z.pc observer + the tick job) so init is idempotent
registered:0b;

/ the nontorqprocess.csv-absent warning is emitted once, not every tick
warnedntfile:0b;

/ likewise the "process.csv does not list this process - not evicting" warning
warnednoself:0b;

/ the period the discoverytick job was registered with (a re-init cannot change a registered job)
jobperiod:0N;

/ phone-book change detection: path -> the dialable rows last handed to servers.startup, so an
/ unchanged file costs one read and no startup call (and no "already known" log line) per tick
seen:(`symbol$())!();

/ removals not yet delivered: handle -> the evicted rows that subscriber wants told about. an
/ eviction is an EVENT (the row is gone from the registry the moment it happens), so a push that
/ is skipped or fails is queued and retried next tick rather than lost
rmq:(`int$())!();

/ the (live view;subscriber handles;their wants) of the last push, so the push is logged when it
/ CHANGES rather than every tick (pushes themselves go every tick - idempotent on the consumer,
/ and self-healing)
lastpush:();

/ the tick job's di.timer options: survive a failing run - with disableonfail (di.timer's default)
/ one transient failure would silently stop this process discovering anything for good
jobopts:enlist[`disableonfail]!enlist 0b;

/ config defaults, applied key-by-key in init (flat keys, the proctype-module convention)
defaultretryperiod:30;
defaulttracknontorq:1b;
defaultntfilename:"nontorqprocess.csv";

/ config coercion (values are symbols from .q settings or strings from .toml)
assym:{[x] $[11h=abs type x;x;`$x]};
asstr:{[x] $[10h=abs type x;x;string x]};
/ a boolean / numeric setting may arrive as a real value (.q/.toml) or as text (a raw command-line flag).
/ NOTE "J"$ (parse) for text - "j"$ on a string casts each CHARACTER to its code
asbool:{[x] $[-1h=type x;x;(abs type x) within 5 9h;x<>0;any (lower (),asstr x)~/:("true";enlist "1";"1b")]};
aslong:{[x] $[10h=abs type x;"J"$(),x;-11h=type x;"J"$string x;"j"$x]};
/ a path setting may be a string or a symbol, with or without a leading ":" (an hsym-style value)
aspath:{[x] x:asstr x; $[(0<count x) and ":"=first x;1_x;x]};

/ directory part of a path string ("." if it has none)
dirof:{[path] i:where "/"=path; $[count i;(last i)#path;"."]};

/ resolve a possibly-relative file setting to an absolute path STRING under base (a leading ":"
/ from a symbol-style setting is tolerated)
resolvefile:{[base;f]
  f:aspath f;
  $[f like "/*";f;base,"/",f]
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx via the injected logger, then signal it, so a failure is
  / observable in the log as well as thrown. used for all post-init domain errors (init's own
  / validation signals with a plain ' - the logger is not wired yet).
  .z.m.log[`error][ctx;msg];
  '"di.torq.proc.discovery: ",string[ctx],": ",msg;
  };

init:{[config;deps]
  / wire the injected deps (log/timer/handlers/servers - all required, no fallback) and this
  / process's flat config, install the one-time side effects (a .z.pc observer that drops a
  / departed subscriber, and the discoverytick job), publish the root IPC entry points, and run
  / the first tick synchronously so peers are found at startup rather than one period later.
  / two-arg init[config;deps] - the process-module convention (di.torq.startbuiltin calls it so).
  if[99h<>type config;
    '"di.torq.proc.discovery: config must be a dict (the merged settings for this process)"];
  if[99h<>type deps;
    '"di.torq.proc.discovery: deps must be a dict of injectables"];
  if[not all `log`timer`handlers`servers in key deps;
    '"di.torq.proc.discovery: log, timer, handlers and servers dependencies are all required (injected by di.torq)"];
  if[99h<>type deps`log;
    '"di.torq.proc.discovery: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.torq.proc.discovery: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.torq.proc.discovery: timer value must be a dict (see di.timer)"];
  if[not `addjob in key deps`timer;
    '"di.torq.proc.discovery: timer dict must have an `addjob key"];
  if[99h<>type deps`handlers;
    '"di.torq.proc.discovery: handlers value must be a dict (see di.torq.handlers)"];
  if[not `register in key deps`handlers;
    '"di.torq.proc.discovery: handlers dict must have a `register key"];
  if[99h<>type deps`servers;
    '"di.torq.proc.discovery: servers value must be a dict (the injected di.torq.servers contract)"];
  if[not all `startup`getallservers`removeprocs in key deps`servers;
    '"di.torq.proc.discovery: servers dict needs `startup`getallservers`removeprocs (di.torq.servers >= 0.5.0)"];
  if[not all `processcsv`proctype`procname in key config;
    '"di.torq.proc.discovery: config must carry processcsv, proctype and procname (stamped by di.torq)"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.svc:deps`servers;
  .z.m.self:`proctype`procname!(assym config`proctype;assym config`procname);
  .z.m.procfile:aspath config`processcsv;
  / fail fast: a discovery service without its phone book has nothing to discover (a file that
  / vanishes LATER, mid-rewrite say, is a tick failure - logged, retried next tick - not fatal)
  if[0=count key hsym`$.z.m.procfile;
    '"di.torq.proc.discovery: process.csv not found at ",.z.m.procfile];
  .z.m.retryperiod:$[`retryperiod in key config;aslong config`retryperiod;defaultretryperiod];
  if[not -7h=type .z.m.retryperiod;
    '"di.torq.proc.discovery: retryperiod must be a single number of seconds"];
  tnt:$[`tracknontorqprocess in key config;config`tracknontorqprocess;defaulttracknontorq];
  .z.m.tracknontorqprocess:asbool tnt;
  / the non-TorQ phone book lives next to process.csv unless configured; a relative setting is
  / resolved against that same directory (env-free: the directory comes from config`processcsv)
  pdir:dirof .z.m.procfile;
  .z.m.ntfile:$[`nontorqprocessfile in key config;resolvefile[pdir;config`nontorqprocessfile];pdir,"/",defaultntfilename];
  if[not .z.m.retryperiod>0;
    '"di.torq.proc.discovery: retryperiod must be a positive number of seconds; got ",string .z.m.retryperiod];
  if[not .z.m.registered;
    / .z.pc is a SIMPLE (observer) event in di.torq.handlers - side-effect only, fan-out; phase ` (null).
    / this coexists with di.torq.servers' own .z.pc observer (different name) in the same fan-out.
    (.z.m.handlers[`register])[`.z.pc;`;`discovery;0j;pcfunc];
    / di.timer mode-1h period is in SECONDS
    (.z.m.timer[`addjob])[`discoverytick;tick;();.z.m.retryperiod;1;jobopts];
    .z.m.jobperiod:.z.m.retryperiod;
    .z.m.registered:1b;
    ];
  / a re-init refreshes deps and settings but cannot re-register the job: say so rather than let a
  / changed retryperiod look applied
  if[not .z.m.jobperiod=.z.m.retryperiod;
    msg:"retryperiod ",(string .z.m.retryperiod),"s requested on re-init but the tick job keeps its registered ",(string .z.m.jobperiod),"s";
    .z.m.log[`warn][`discovery;msg]];
  / re-init forgets what it has seen and pushed, so the first tick below re-reads and re-logs
  .z.m.seen:(`symbol$())!();
  .z.m.lastpush:();
  .z.m.rmq:(`int$())!();
  / publish the IPC-callable surface at REAL root names (use mangles this file into a private
  / namespace, so a peer's remote .discovery.getservices[..] would otherwise be undefined)
  set[`.discovery.getservices;getservices];
  set[`.discovery.getsubs;getsubs];
  me:(string .z.m.self`proctype),"/",string .z.m.self`procname;
  nt:$[.z.m.tracknontorqprocess;.z.m.ntfile;"off"];
  .z.m.log[`info][`discovery;"initialised as ",me,": phone book ",.z.m.procfile,", retryperiod ",(string .z.m.retryperiod),"s, nontorq ",nt];
  tick[];
  };

pcfunc:{[wh]
  / .z.pc observer - a departed handle can no longer be pushed to, so forget its subscription
  if[wh in key .z.m.subs;
    forget wh;
    .z.m.log[`info][`discovery;"subscriber on handle ",(string wh)," disconnected - subscription dropped"]];
  };

phonebookcols:`host`port`proctype`procname;

readprocs:{[path]
  / internal - read a phone book in process.csv format (host,port,proctype,procname). a malformed
  / or short LINE parses to a row of nulls (dialable drops it); a file with the wrong header - or
  / an EMPTY one, as a file caught mid-rewrite is - parses to the wrong columns, so that is a
  / (logged, retried next tick) error rather than a 'host thrown from deep inside a select
  fsym:`$":",path;
  if[0=count key fsym;raiseerror[`readprocs;"phone book not found at ",path]];
  procs:("SISS";enlist",") 0: fsym;
  if[not phonebookcols~cols procs;raiseerror[`readprocs;"phone book ",path," does not have the columns host,port,proctype,procname"]];
  procs
  };

dialable:{[procs]
  / internal - the phone-book rows that can be dialled at all: a row with no host, no port (or port
  / 0 - "assigned at start", the loader convention) or no identity would just fail every retry
  select from procs where not null host, not null proctype, not null procname, port>0
  };

ntpaths:{[]
  / internal - the non-TorQ phone book, as a (possibly empty) path list: only when tracked and
  / present on disk - it is optional there, so its absence is warned once and then stays quiet
  if[not .z.m.tracknontorqprocess;:()];
  if[count key hsym`$.z.m.ntfile;.z.m.warnedntfile:0b;:enlist .z.m.ntfile];
  if[not .z.m.warnedntfile;
    .z.m.log[`warn][`discovery;"tracknontorqprocess is on but ",.z.m.ntfile," does not exist - non-TorQ tracking skipped until it appears"]];
  .z.m.warnedntfile:1b;
  ()
  };

readbooks:{[]
  / internal - read every phone book this tick works from, BEFORE anything is evicted or dialled:
  / path -> parsed rows. a read that fails (file gone, caught mid-rewrite, wrong header) raises
  / here and the whole tick is abandoned, so a bad read can never look like "everything is gone"
  paths:enlist[.z.m.procfile],ntpaths[];
  (`$paths)!readprocs each paths
  };

selflisted:{[books]
  / internal - 1b if process.csv lists this process's own (procname;proctype); warns once otherwise
  me:.z.m.self;
  procs:books`$.z.m.procfile;
  if[count select from procs where procname=me`procname,proctype=me`proctype;.z.m.warnednoself:0b;:1b];
  if[not .z.m.warnednoself;
    msg:"process.csv does not list this process (",(string me`proctype),"/",(string me`procname),") - partial or foreign phone book; nothing is evicted until it does";
    .z.m.log[`warn][`discovery;msg]];
  .z.m.warnednoself:1b;
  0b
  };

describerows:{[rows]
  / internal - "name/type@hpup, ..." for log lines
  ", " sv {string[x`procname],"/",string[x`proctype],"@",string x`hpup} each rows
  };

evict:{[books]
  / internal - drop every registry row whose (procname;proctype) is LISTED in no phone book any
  / more: that process has been decommissioned (a listed process that is merely down stays, for
  / servers' retry). stateless - the registry is diffed against the books every tick, so it is
  / right after a re-init too. "listed" means present in a file at all, dialable or not: a port-0
  / row is not a decommission. the hpup comes from the registry (whatever servers' formathp built),
  / so the removal is the exact triple servers dedups on. removal on THIS side is immediate;
  / subscribers are told through rmq (queued per handle, delivered by pushall)
  listed:distinct select procname,proctype from raze value books;
  listed:select from listed where not null procname,not null proctype;
  / sanity: process.csv must list THIS process (di.torq starts it from that row). a file that does
  / not is partial - a writer caught between the header and the rows would otherwise read as
  / "everything decommissioned" and close every subscriber's handles for a tick - or foreign
  if[not selflisted books;:()];
  reg:(.z.m.svc`getallservers)[];
  gone:select procname,proctype,hpup from reg where not ([]procname;proctype) in listed;
  if[0=count gone;:()];
  (.z.m.svc`removeprocs)[gone];
  .z.m.log[`info][`discovery;"evicted ",(string count gone)," row(s) no longer in any phone book: ",describerows gone];
  hs:key .z.m.subs;
  q:hs!{[g;h] distinct (0#g),.z.m.rmq[h],wanted[g;.z.m.subs h]}[gone] each hs;
  .z.m.rmq:.z.m.rmq,(where 0<count each q)#q;
  };

dialfrom:{[path;procs]
  / internal - point the injected servers at one (already-read) phone book, asking for EVERY
  / proctype in it (the legacy `ALL translation lives here, so di.torq.servers needs no `ALL
  / sentinel). servers.startup is repeat-safe: known rows are skipped, only new ones dialled; its
  / retry job reopens dead ones. the file is re-read every tick (that is how a late arrival is
  / found) but startup is only called when its dialable rows CHANGED - an unchanged file has
  / nothing new to dial, and this keeps "N rows already known" out of the log every tick. the
  / rows are recorded as seen only AFTER startup returns: servers re-reads the file itself, and if
  / that second read catches a rewrite and throws, the next tick must try again, not skip
  rows:dialable procs;
  if[path in key .z.m.seen;if[rows~.z.m.seen path;:()]];
  skipped:count[procs]-count rows;
  extra:$[skipped>0;", ",(string skipped)," undialable (no host/port/identity) skipped";""];
  msg:"phone book ",(string path),": ",(string count rows)," dialable row(s)",extra;
  .z.m.log[`info][`discovery;msg];
  types:distinct exec proctype from rows;
  if[count types;(.z.m.svc`startup)[`connections`processcsv!(types;string path)]];
  .z.m.seen:.z.m.seen,(enlist path)!enlist rows;
  };

liveview:{[]
  / internal - what discovery hands out: every row it currently holds a LIVE handle to, minus
  / other instances of THIS process type (a subscriber must never be told a discovery service is
  / an ordinary backend - carried forward from legacy getservices' own exclusion; keyed on our own
  / proctype rather than the literal `discovery so a differently-named deployment behaves the
  / same). liveness is the point of the service: a subscriber wanting the static phone book has
  / process.csv already.
  reg:(.z.m.svc`getallservers)[];
  me:.z.m.self`proctype;
  distinct select procname,proctype,hpup from reg where not null w, not proctype=me
  };

wanted:{[rows;want]
  / internal - the slice of a row set a subscriber asked for (`ALL = everything)
  $[`ALL in want;rows;select from rows where proctype in want]
  };

forget:{[h]
  / internal - drop a subscriber: its subscription and any removals still queued for it
  .z.m.subs:(enlist h) _ .z.m.subs;
  .z.m.rmq:(enlist h) _ .z.m.rmq;
  };

pushfail:{[h;e]
  / internal - a push that throws means the handle is gone (or the peer has no addprocs/
  / removeprocs): log, forget the subscription, report nothing pushed
  .z.m.log[`warn][`discovery;"push to subscriber on handle ",(string h)," failed: ",e," - subscription dropped"];
  forget h;
  0
  };

draining:{[h]
  / internal - .z.W[h] is the byte count still queued on that handle. async sends sit there until
  / the event loop flushes them, so at the START of a subscriber's tick anything queued is left
  / over from an earlier one: a peer that has stopped reading would eventually block this process
  / on the write - skip it this tick (adds are idempotent and removals stay queued; the next tick
  / retries) and say so
  queued:0^.z.W h;
  if[0=queued;:1b];
  msg:"subscriber on handle ",(string h)," is not draining its socket (",(string queued)," bytes queued) - push skipped this tick";
  .z.m.log[`warn][`discovery;msg];
  0b
  };

send:{[h;fn;rows]
  / internal - async-call fn (a root name on the peer) with rows on one subscriber handle; returns
  / the row count sent (0 if nothing to send or the push failed)
  if[0=count rows;:0];
  .[{[wh;f;r] (neg wh)(f;r);count r};(h;fn;rows);pushfail[h]]
  };

pushto:{[live;h]
  / internal - one subscriber's tick: queued removals first (cleared only once sent), then the
  / live rows it wants. a failed send forgets the subscriber, so the second send is not attempted
  if[not draining h;:0];
  rm:$[h in key .z.m.rmq;.z.m.rmq h;0#live];
  if[count rm;
    if[(count rm)=send[h;`.torq.servers.removeprocs;rm];.z.m.rmq:(enlist h) _ .z.m.rmq]];
  if[not h in key .z.m.subs;:0];
  send[h;`.torq.servers.addprocs;wanted[live;.z.m.subs h]]
  };

pushall:{[]
  / internal - push the live view to every subscriber whose handle is still open. every tick, not
  / only on change (idempotent on the consumer; self-healing) - but LOGGED only when the live view
  / or the subscriber set differs from the last push, so a steady state is silent
  live:liveview[];
  hs:(key .z.m.subs) inter key .z.W;
  if[0=count hs;:()];
  n:sum pushto[live] each hs;
  k:(live;hs;.z.m.subs hs);
  if[k~.z.m.lastpush;:()];
  .z.m.lastpush:k;
  msg:"pushed ",(string n)," row(s) across ",(string count hs)," subscriber(s); ",(string count live)," live service(s) known";
  .z.m.log[`info][`discovery;msg];
  };

tickbody:{[]
  / one discovery cycle: read every phone book, evict what none of them lists any more, dial what
  / is new, then push (removals, then live rows) to the subscribers
  books:readbooks[];
  / a book not read this tick (the optional non-TorQ file gone) is forgotten: its rows are evicted
  / below, so if it comes back unchanged they must be dialled again, not skipped as already seen
  .z.m.seen:(key[.z.m.seen] except key books) _ .z.m.seen;
  evict books;
  dialfrom'[key books;value books];
  pushall[];
  };

tickfail:{[e] .z.m.log[`error][`discovery;"discovery tick failed: ",e];};

tick:{[]
  / the discoverytick job body, every retryperiod seconds (and once from init). protected and
  / logged here: di.timer swallows a job's error unless its debug flag is on, and the job is
  / registered with disableonfail off so one bad cycle (a phone book mid-rewrite, a peer that
  / drops during a push) never stops discovery for good
  @[tickbody;::;tickfail];
  };

recordsub:{[h;proctypes]
  / internal - remember what a remote caller wants pushed. a LOCAL call has no remote handle
  / (.z.w is 0, never in key .z.W) so there is nothing to push to - logged, not recorded
  if[not h in key .z.W;
    .z.m.log[`info][`getservices;"subscribe requested from a local call - no remote handle to push to; not recorded"];
    :()];
  .z.m.subs:.z.m.subs,(enlist h)!enlist proctypes;
  .z.m.log[`info][`getservices;"handle ",(string h)," subscribed to ",", " sv string proctypes];
  };

getservices:{[proctypes;subscribe]
  / the IPC entry point (also at root as .discovery.getservices): the live services of the given
  / proctypes (`ALL for every proctype) as procname/proctype/hpup rows, right now. with subscribe
  / on, the CALLING handle is also recorded so every later tick pushes its slice of the live view
  / into the caller's .torq.servers.addprocs - a repeat call replaces the earlier subscription.
  if[not 11h=abs type proctypes;raiseerror[`getservices;"proctypes must be a symbol or symbol list (`ALL for everything)"]];
  if[not -1h=type subscribe;raiseerror[`getservices;"subscribe must be a boolean atom"]];
  proctypes:proctypes,();
  if[0=count proctypes;raiseerror[`getservices;"proctypes must not be empty (`ALL for everything)"]];
  if[any null proctypes;raiseerror[`getservices;"proctypes must not contain the null symbol (`ALL for everything)"]];
  if[subscribe;recordsub[.z.w;proctypes]];
  wanted[liveview[];proctypes]
  };

getsubs:{[]
  / current subscriptions (also at root as .discovery.getsubs): one row per subscribed handle
  ([]handle:key .z.m.subs;proctypes:value .z.m.subs)
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE API function, for di.torq to register with
  / di.api. init/getapimeta are plumbing (di.torq calls them by convention) and are deliberately NOT
  / listed - the registry describes the callable api, not plumbing. names are bare (di.torq qualifies).
  :flip `name`public`descrip`params`return!flip(
    (`getservices; 1b; "live services of the given proctypes (`ALL for all); subscribe=1b also records the caller for pushes"; "[symbol|symbols: proctypes; boolean: subscribe]"; "table: procname/proctype/hpup rows");
    (`getsubs;     1b; "current subscriptions - one row per subscribed handle";                                                "[]";                                            "table: handle/proctypes rows"));
  };
