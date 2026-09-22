/ di.torq.proc.chainedtp - chained tickerplant. Subscribes to an upstream tickerplant (as di.torq.proc.rdb does, via
/ di.subscriptions over a handle from the injected di.torq.servers), optionally writes what it receives to a log of its
/ own, and re-presents itself to its own subscribers as a tickerplant (the same root surface as di.torq.proc.tickerplant:
/ upd, .u.upd, .u.sub, .u.subdetails, endofday, .u.end) in immediate or batched publish mode. It follows the upstream's
/ date rather than computing one: the date arrives with the subscription and advances when the upstream ends its day.
/ Built from TorQ/code/processes/chainedtp.q onto the di.torq process-module conventions; the divergences from the
/ legacy process are recorded in chainedtp.md. Hard deps: di.pubsub, di.subscriptions, di.tplogmgr (write only - the
/ log is named, opened and rolled here, because di.tplogmgr.open replays through upd, which would republish).
/ Injected deps: log, timer, handlers, servers - all required.

/ --- constants ---

jobid:`chainedtp;                                        / the flush timer job and the .z.pc handler name
pubmodes:`immediate`batched;
copychunk:8388608;                                       / bytes per read when copying a corrupt log's good prefix

/ --- module state read before init has run (everything else is written by init) ---

initdone:0b;                                             / the exported api may be called
ready:0b;                                                / the root surface may be called (set once subscribed, before init completes)
logwired:0b;
upstreamup:0b;                                           / what connected[] reports
logh:0i;
logname:`;
msgcount:0;
tph:0Ni;
exitfn:{[code] exit code};                               / how the .z.pc handler leaves the process; replaced by the tests

/ --- shared helpers (as di.torq.proc.segmentedtp) ---

/ base dirs: CODE/CONFIG under TORQXAPPHOME, runtime DATA under TORQXDATAHOME (falling back to TORQXAPPHOME)
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]};

/ resolve a possibly-relative dir setting to an absolute path STRING under base; symbol (.q) or string (.toml) input
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  };

/ config values may be symbols (.q settings), strings (.toml, command-line overrides) or numbers; coerce at the
/ point of use. strings are parsed, not cast: `boolean$"true" is a boolean LIST and "j"$"5" is the character code 53
/ (a one-character string is a char atom in q, hence the abs types and the (),x)
astz:{[x] $[11h=abs type x;x;`$(),x]};
tostr:{[x] $[10h=abs type x;(),x;string x]};
tolong:{[x] $[10h=abs type x;"J"$(),x;"j"$x]};
cfgor:{[config;k;dflt] $[k in key config;config k;dflt]};

/ boolean config. The enlisted single characters in the one-liner this replaces were already guarding
/ one trap - a one-character string is a char ATOM, so "1"/"t"/"y" would otherwise never match. Two
/ remained: it fell through to `boolean$ for a symbol, which throws, though a .q settings file is
/ exactly where symbols come from; and an unrecognised word silently read as FALSE. That now SIGNALS -
/ a typo is a configuration error, and reading it as "off" is how a safety setting gets disabled unnoticed
/ NB the `1 and `0 words are LOAD-BEARING - do not trim them in a tidy-up. A command-line override
/ arrives as a STRING, and di.torq.proc.chainedtp's integration suite passes `-replay 1
/ -clearlogonsubscription 1` (test_integration.q:175,238) precisely to exercise that path, as
/ test_integration_ctp.q:4-7 states. Two integration tests depend on "1" coercing to true.
truewords:`true`yes`on`t`y`1;
falsewords:`false`no`off`f`n`0;

tobool:{[x]
  if[-1h=type x;:x];
  if[type[x] in -4 -5 -6 -7 -8 -9h;:0<>x];
  if[not type[x] in -11 -10 10h;
    '"di.torq.proc.chainedtp: cannot read ",(-3!x)," as a boolean"];
  w:`$lower $[-11h=type x;string x;(),x];
  if[w in truewords;:1b];
  if[w in falsewords;:0b];
  '"di.torq.proc.chainedtp: cannot read ",(-3!x)," as a boolean; expected one of ",
    ", " sv string truewords,falsewords
  };

/ payloads arrive as a table (di.pubsub's live publish) or as a list of columns (log replay); normalise to a list of
/ vector columns, so a single record (atom columns) and a batch take the same path everywhere below
tocols:{[x]
  x:$[98h=type x;value flip x;x];
  $[0>type first x;enlist each x;x]
  };

/ shell-quote a path for system calls (mkdir / mv)
shq:{[p] "\"",p,"\""};

raiseerror:{[ctx;msg]
  / log (once a logger is wired) then signal, so failures are observable as well as thrown
  if[.z.m.logwired;.z.m.log[`error][ctx;msg]];
  '"di.torq.proc.chainedtp: ",(string ctx),": ",msg;
  };

requireinit:{[ctx]
  if[not .z.m.initdone;raiseerror[ctx;"init must be called before any other function"]];
  };

requireready:{[ctx]
  / the root surface is live from the moment the upstream subscription exists - upstream replay drives upd before
  / init has completed - and dead again after teardown
  if[not .z.m.ready;raiseerror[ctx;"init must be called before any other function"]];
  };

/ --- own log: one file per date, <tplogdir>/<logprefix>_<date>, as TorQ's chainedtp named it ---

lognamefor:{[d] hsym `$.z.m.tplogdir,"/",.z.m.logprefix,"_",string d};

goodname:{[ln] `$(string ln),".good"};

/ a log recovered on an earlier start lives on as <name>.good - keep using it rather than the corrupt original
resolvelog:{[ln] $[type key g:goodname ln;g;ln]};

clearlog:{[ln]
  / truncate an existing log (clearlogonsubscription): the upstream replay rebuilds it
  if[not type key ln;:()];
  .z.m.log[`info][`clearlog;"clearing log ",1_string ln];
  .[ln;();:;()];
  };

openfile:{[ln]
  / hopen a log, creating it if absent. an existing log is COUNTED first without executing it (executing it would
  / republish every message), and a corrupt one is never opened blind - its good prefix is copied to <name>.good and
  / that is opened. returns (name;handle;message count)
  if[not type key ln;.[ln;();:;()]];
  / a zero-byte file (a crash between create and header write) is safely re-headed; a file shorter than the 8-byte
  / header, or one -11!(-2;..) cannot read at all, holds no recoverable message - recover it as an empty log
  if[0=hcount ln;.[ln;();:;()]];
  info:@[-11!;(-2;ln);{0 0}];
  if[1<count info;ln:recoverlog[ln;info];info:first info];
  (ln;hopen ln;info)
  };

recoverlog:{[ln;info]
  / copy the good prefix (info 1 bytes, info 0 messages) of a corrupt log aside and return its name. a generic byte
  / copy, as di.torq.proc.segmentedtp does - not di.tplog.repair, whose message signature is hardcoded to `trade and
  / would silently drop every other table this process relays. the corrupt original is left untouched; the copy is
  / written via a temp file so a .good can itself be recovered. a prefix shorter than a log header is no log at all -
  / the copy is a fresh empty log instead
  g:$[ln like "*.good";ln;goodname ln];
  tmp:`$(string g),".tmp";
  $[8>info 1;.[tmp;();:;()];copyprefix[ln;tmp;info 1]];
  system "mv -f ",(shq 1_string tmp)," ",shq 1_string g;
  .z.m.log[`warn][`openlog;"corrupt log ",(1_string ln),": kept ",(string info 0)," good message(s) (",(string info 1)," bytes) in ",1_string g];
  g
  };

copyprefix:{[src;dst;n]
  / copy the first n bytes of src to dst in bounded chunks; the destination handle is closed even if a read fails
  dst 1: `byte$();
  h:hopen dst;
  r:@[{[src;h;n] copychunkto[src;h;n]/[0j]}[src;h];n;{[e] (`copyfailed;e)}];
  hclose h;
  if[`copyfailed~first r;'"copying ",(1_string src),": ",r 1];
  };

copychunkto:{[src;h;n;o]
  / append the next chunk of src from offset o; returns the new offset, unchanged once at n (ending the over)
  if[o>=n;:o];
  k:copychunk&n-o;
  h read1 (src;o;k);
  o+k
  };

openlog:{[d;clear]
  / open the log for date d - cleared first when asked - and take its message count as the replay count offered to
  / subscribers
  ln:resolvelog lognamefor d;
  if[clear;clearlog ln];
  r:openfile ln;
  .z.m.logname:r 0;
  .z.m.logh:r 1;
  .z.m.msgcount:r 2;
  .z.m.log[`info][`openlog;"logging to ",(1_string r 0),", holding ",(string r 2)," message(s)"];
  };

closefail:{[e] .z.m.log[`warn][`closelog;"log handle already closed: ",e];};

closelog:{[]
  if[.z.m.logh>0;@[hclose;.z.m.logh;closefail]];
  .z.m.logh:0i;
  };

writelog:{[t;x]
  / append to the own log. no log (tplogdir unset) or a log not yet open (a tick that beats the open under
  / multithreaded input) is a skip, not a throw - the message still reaches the subscribers
  if[not .z.m.logh>0;:()];
  (.z.m.tp`write)[.z.m.logh;(`upd;t;x)];
  .z.m.msgcount+:1;
  };

/ --- updates and the two publish modes (as di.torq.proc.tickerplant) ---

publishfail:{[t;e] raiseerror[`upd;"publish of ",(string t)," failed (a subscriber gone without .z.pc?): ",e]};

pubimmediate:{[t;x]
  / publish now. a send to a handle that died without .z.pc firing throws inside di.pubsub - logged here, then
  / signalled, rather than vanishing into the async handler
  d:flip .z.m.tabcols[t]!x;
  .z.m.rowcount[t]+:count d;
  .[.z.m.ps`publish;(t;d);publishfail[t]];
  };

pubbatched:{[t;x]
  / buffer into the ROOT table for the flush job. insert by NAME: a runtime symbol resolves to the root table from
  / this module's private namespace and under -11! replay alike (only source-level names are rewritten module-local;
  / the unit suite proves both paths), and it appends in place - the @[`.;t;upsert-by-value] idiom copies the whole
  / buffer on every update (measured: 20k rows 242ms, 40k rows 878ms, against 14ms here)
  t insert x;
  .z.m.pending[t]+:count first x;
  };

pubfns:`immediate`batched!(pubimmediate;pubbatched);

upd:{[t;x]
  / feed entry point (root upd / .u.upd): what the upstream publishes and what its log replays. the data arrives
  / already timestamped by the upstream, so nothing is stamped here
  requireready`upd;
  / a string table name (a one-character one is a char atom) is accepted; anything but one symbol is not - a symbol
  / list would otherwise throw a bare 'type from the membership test below
  if[10h=abs type t;t:`$(),t];
  if[not -11h=type t;raiseerror[`upd;"table must be one symbol; got ",-3!t]];
  if[not t in .z.m.tables;raiseerror[`upd;"not a subscribed table: ",-3!t]];
  x:tocols x;
  writelog[t;x];
  .z.m.pubfn[t;x];
  };

flush:{[]
  / batched-mode flush (timer job): publish every buffered table and clear it. a no-op in immediate mode
  if[.z.m.publishmode=`immediate;:()];
  @[.z.m.ps`pubclear;.z.m.tables;publishfail[`$", " sv string .z.m.tables]];
  .z.m.rowcount+:.z.m.pending;
  .z.m.pending:.z.m.tables!count[.z.m.tables]#0;
  };

/ --- the surface this process presents to its own subscribers (root .u.sub / .u.subdetails / endofday / .u.end) ---

sub:{[tabs;syms]
  requireready`sub;
  (.z.m.ps`subscribe)[tabs;syms]
  };

subdetails:{[tabs;syms]
  / register the caller with di.pubsub and return, in one synchronous call, what di.subscriptions needs to define and
  / replay the subscribed tables - the same dict as di.torq.proc.tickerplant.subdetails. in batched mode the buffer is
  / flushed FIRST, to the subscribers that already exist: the new one replays those rows from the log, so the replay
  / count never includes a message it would also receive in the next flush
  requireready`subdetails;
  flush[];
  r:(.z.m.ps`subscribe)[tabs;syms];
  if[-11h=type r;raiseerror[`subdetails;string r]];
  if[-11h=type first r;.z.m.log[`warn][`subdetails;string first r];r:last r];
  `tables`schemas`logfile`rowcount`date!(r 0;(r 0)!r 1;$[.z.m.logh>0;.z.m.logname;`];.z.m.msgcount;.z.m.date)
  };

endofday:{[d]
  / what the upstream sends at its end of day (di.pubsub's (`endofday;d) broadcast; .u.end is the alias): flush, pass
  / the end of day on to this process's own subscribers, roll the own log into d+1 and follow the upstream's date
  requireready`endofday;
  if[not -14h=type d;raiseerror[`endofday;"expected a date; got ",-3!d]];
  / a day already ended is not ended again: rolling into d+1 would reopen an older log and move the date backwards,
  / and re-broadcasting would make every subscriber save that day down twice
  if[d<.z.m.date;.z.m.log[`warn][`endofday;"upstream ended ",(string d)," but the current date is already ",(string .z.m.date),"; ignored"];:()];
  if[d>.z.m.date;.z.m.log[`warn][`endofday;"upstream ended ",(string d)," but the current date is ",(string .z.m.date),"; following it"]];
  flush[];
  (.z.m.ps`callendofday)[d];
  if[.z.m.logh>0;closelog[];openlog[d+1;0b]];
  .z.m.date:d+1;
  .z.m.log[`info][`endofday;"end of day complete, ",(string d)," -> ",string d+1];
  };

/ --- the upstream side ---

connect:{[]
  / dial the upstream through the injected di.torq.servers and block until it is up. startup is skipped when an
  / earlier init's connection is still live (init is idempotent; a second startup would dial and register it again)
  if[not .z.m.tph in key .z.W;
    (.z.m.svc`startup)[.z.m.cfg,(enlist`connections)!enlist enlist .z.m.upstreamtype]];
  if[not (.z.m.svc`waitfortype)[.z.m.upstreamtype;.z.m.connecttimeoutms;.z.m.connectpollms];
    raiseerror[`init;"no ",(string .z.m.upstreamtype)," connection within ",(string .z.m.connecttimeoutms),"ms"]];
  .z.m.tph:(.z.m.svc`gethandlebytype)[.z.m.upstreamtype;`any];
  if[null .z.m.tph;raiseerror[`init;"no live ",(string .z.m.upstreamtype)," handle after waiting"]];
  };

subscribe:{[]
  / one .u.subdetails call through di.subscriptions: registers this process for live delivery and defines the
  / subscribed tables at root. replay is NOT asked of di.subscriptions - the own log must be open, for the date this
  / call returns, before any replayed message reaches upd - so the replay is driven here afterwards (see doreplay)
  sd:(.z.m.subs`subscribe)[.z.m.tph;.z.m.subscribeto;.z.m.subscribesyms;0b];
  if[not all `tables`schemas`logfile`rowcount`date in key sd;raiseerror[`init;"upstream .u.subdetails returned ",-3!key sd]];
  .z.m.date:sd`date;
  .z.m.tables:sd`tables;
  .z.m.tabcols:(key sd`schemas)!cols each value sd`schemas;
  .z.m.rowcount:.z.m.tables!count[.z.m.tables]#0;
  .z.m.pending:.z.m.tables!count[.z.m.tables]#0;
  .z.m.upstreamup:1b;
  / live from here: an update can now arrive on tph
  .z.m.ready:1b;
  .z.m.log[`info][`subscribe;"subscribed to ",(", " sv string .z.m.tables)," on ",(string .z.m.upstreamtype),", date ",string .z.m.date];
  sd
  };

replayfilter:{[origupd;tabs;syms;t;x]
  / installed as root upd during the replay of a narrowed subscription: the upstream log holds every table and sym,
  / so drop what was not subscribed before the real upd sees it (as di.subscriptions' own replay does for an rdb)
  if[not t in tabs;:()];
  x:tocols x;
  if[not syms~`;x:x@\:where x[1] in syms];
  if[not count first x;:()];
  origupd[t;x];
  };

runreplay:{[lf;n] .[{[m;lf;n] (m`replayupto)[lf;n]};(.z.m.tp;lf;n);{[e] (`replayerr;e)}]};

doreplay:{[sd]
  / replay the messages the upstream had logged at subscription time through root upd - so they land in the own log
  / and, in batched mode, the buffer. count-limited to rowcount, as live delivery has started
  lf:sd`logfile;
  n:sd`rowcount;
  if[null lf;raiseerror[`replay;"upstream reports ",(string n)," logged message(s) but no log file"]];
  narrowed:not (.z.m.subscribeto~`) and .z.m.subscribesyms~`;
  origupd:`. `upd;
  if[narrowed;@[`.;`upd;:;replayfilter[origupd;sd`tables;.z.m.subscribesyms]]];
  r:runreplay[lf;n];
  if[narrowed;@[`.;`upd;:;origupd]];
  if[`replayerr~first r;raiseerror[`replay;"replay of ",(1_string lf)," failed: ",r 1]];
  .z.m.log[`info][`replay;"replayed ",(string r)," of ",(string n)," message(s) from ",1_string lf];
  };

warnappend:{[n]
  / the upstream replay appends to whatever the own log already holds - legacy's clearlogonsubscription exists for this
  msg:"replay will append ",(string n)," message(s) to a log already holding ",string .z.m.msgcount;
  .z.m.log[`warn][`init;msg," - set clearlogonsubscription to rebuild it instead"];
  };

pcfunc:{[w]
  / .z.pc (via di.torq.handlers, alongside di.torq.servers' own hook): losing the upstream ends this process. nothing
  / in the stack resubscribes a bounced tickerplant yet (di.torq.servers reopens the socket, but no one calls
  / di.subscriptions.subscribe again on it), so a clean exit 0 hands the restart to the supervisor
  if[not w=.z.m.tph;:()];
  .z.m.upstreamup:0b;
  msg:"lost the ",(string .z.m.upstreamtype)," connection on handle ",string w;
  .z.m.log[`error][`pc;msg,"; no resubscribe path exists - exiting 0 for the supervisor to restart"];
  .z.m.exitfn 0;
  };

/ --- exported api ---

connected:{[]
  / is the upstream subscription live? backed by local state (flipped by subscribe and the .z.pc handler) -
  / di.subscriptions' registry tracks no disconnects
  requireinit`connected;
  .z.m.upstreamup
  };

getcounts:{[]
  / messages in the own log for the current date, the date, and per-table rows published and rows pending in the
  / unflushed batch
  requireinit`getcounts;
  t:.z.m.tables;
  `msgcount`date`tables!(.z.m.msgcount;.z.m.date;([tbl:t]rowcount:.z.m.rowcount t;pendingrowcount:.z.m.pending t))
  };

teardown:{[]
  / stop the module: flush, close the own log, remove the flush job and the own .z.pc handler. the upstream
  / subscription itself cannot be withdrawn (no protocol for it); the socket stays with di.torq.servers
  requireinit`teardown;
  flush[];
  closelog[];
  (.z.m.timer`deletejobs)[enlist jobid];
  (.z.m.handlers`remove)[`.z.pc;`;jobid];
  / the pubsub cleanup registration stays: a subscriber that leaves between a teardown and the next init would
  / otherwise remain registered, and the first publish after that init would fail on its dead handle
  .z.m.upstreamup:0b;
  .z.m.ready:0b;
  .z.m.initdone:0b;
  .z.m.log[`info][`teardown;"stopped"];
  };

checkdep:{[deps;k;fns;hint]
  if[not k in key deps;'"di.torq.proc.chainedtp: ",(string k)," dependency is required - ",hint];
  if[99h<>type deps k;'"di.torq.proc.chainedtp: ",(string k)," dependency must be a dict - ",hint];
  if[count missing:fns except key deps k;'"di.torq.proc.chainedtp: ",(string k)," dependency is missing ",", " sv string missing];
  };

checkdeps:{[deps]
  / validate the injected deps before anything is wired - plain signals, as no logger is usable yet. all four are
  / required whatever the config (timer is only used in batched mode), as di.torq injects all four into every process
  if[99h<>type deps;'"di.torq.proc.chainedtp: deps must be a dict with `log`timer`handlers`servers keys"];
  checkdep[deps;`log;`info`warn`error;"see di.util.log"];
  checkdep[deps;`timer;`addjob`deletejobs;"see di.timer"];
  checkdep[deps;`handlers;`register`remove;"see di.torq.handlers"];
  checkdep[deps;`servers;`startup`gethandlebytype`waitfortype;"injected by di.torq, see di.torq.servers"];
  };

checkin:{[k;v;ok]
  if[not v in ok;raiseerror[`init;(string k)," must be one of ",(", " sv string ok),"; got ",-3!v]];
  };

readconfig:{[config]
  / read and validate every setting up front
  .z.m.cfg:config;
  if[not `upstreamtype in key config;raiseerror[`init;"upstreamtype is required - the proctype of the tickerplant to subscribe to"]];
  .z.m.upstreamtype:astz config`upstreamtype;
  .z.m.subscribeto:astz cfgor[config;`subscribeto;`];
  .z.m.subscribesyms:astz cfgor[config;`subscribesyms;`];
  .z.m.replay:tobool cfgor[config;`replay;0b];
  .z.m.clearlogonsubscription:tobool cfgor[config;`clearlogonsubscription;0b];
  / the presence of tplogdir is the logging switch, as di.torq.proc.tickerplant; an empty value is absence
  .z.m.tplogdir:$[(`tplogdir in key config) and count tostr config`tplogdir;resolvedir[datahome[];config`tplogdir];""];
  .z.m.publishmode:astz cfgor[config;`publishmode;`immediate];
  .z.m.pubperiod:tolong cfgor[config;`pubperiod;1];
  .z.m.connecttimeoutms:tolong cfgor[config;`connecttimeoutms;10000];
  .z.m.connectpollms:tolong cfgor[config;`connectpollms;500];
  / the log file name carries the process name, as TorQ's chainedtp did, so two chained tickerplants sharing a
  / tplogdir - or one sharing its upstream's - cannot write the same file. "chainedtp" only when no procname is known
  .z.m.logprefix:tostr cfgor[config;`logprefix;$[`procname in key config;config`procname;"chainedtp"]];
  .z.m.proctype:astz cfgor[config;`proctype;`chainedtp];
  .z.m.procname:astz cfgor[config;`procname;`];
  checkin[`publishmode;.z.m.publishmode;pubmodes];
  if[not 0<.z.m.pubperiod;raiseerror[`init;"pubperiod must be a positive number of seconds"]];
  if[not 0<.z.m.connecttimeoutms;raiseerror[`init;"connecttimeoutms must be a positive number of milliseconds"]];
  if[not 0<.z.m.connectpollms;raiseerror[`init;"connectpollms must be a positive number of milliseconds"]];
  if[0=count .z.m.logprefix;raiseerror[`init;"logprefix must not be empty"]];
  .z.m.pubfn:pubfns .z.m.publishmode;
  };

publishroot:{[]
  / the IPC surface the upstream, its log replay and this process's own subscribers call by name - use keeps module
  / code in a private namespace, so each is set at a real root name
  set[`upd;upd];
  set[`.u.upd;upd];
  set[`.u.sub;sub];
  set[`.u.subdetails;subdetails];
  set[`endofday;endofday];
  set[`.u.end;endofday];
  };

finishinit:{[sd]
  / the part of init that runs once subscribed: pubsub on the subscribed tables, the own log, the replay, the flush job
  (.z.m.ps`setsubtables)[.z.m.tables];
  (.z.m.ps`init)[];
  .z.m.msgcount:0;
  .z.m.logname:`;
  if[count .z.m.tplogdir;
    mkdirfail:{[dir;e] raiseerror[`init;"cannot create the log directory ",dir,": ",e]}[.z.m.tplogdir];
    @[system;"mkdir -p ",shq .z.m.tplogdir;mkdirfail];
    openlog[.z.m.date;.z.m.clearlogonsubscription]];
  if[.z.m.replay and 0<sd`rowcount;
    if[.z.m.msgcount>0;warnappend[sd`rowcount]];
    doreplay sd];
  if[.z.m.publishmode=`batched;(.z.m.timer`addjob)[jobid;flush;();.z.m.pubperiod;1h;()!()]];
  };

init:{[config;deps]
  / wire the injected deps, read config, publish the root surface, connect and subscribe to the upstream, open the
  / own log, replay if asked, and schedule the flush job. safe to call again, and to retry after a call that failed
  / part-way
  checkdeps deps;
  if[.z.m.initdone;teardown[]];
  .z.m.log:deps`log;
  .z.m.logwired:1b;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.svc:deps`servers;
  / a failed earlier init may have left the log open or a job/handler registered (all removals are no-ops if absent)
  closelog[];
  (.z.m.timer`deletejobs)[enlist jobid];
  (.z.m.handlers`remove)[`.z.pc;`;jobid];
  .z.m.upstreamup:0b;
  .z.m.ready:0b;
  readconfig config;
  .z.m.ps:use`di.pubsub;
  .z.m.subs:use`di.subscriptions;
  (.z.m.subs`init)[config;deps];
  .z.m.tp:use`di.tplogmgr;
  / di.pubsub's subscriber cleanup goes on .z.pc through the handlers dep, a simple event alongside di.torq.servers'
  / hook and this module's own (di.pubsub does not bind .z.pc itself - that replaced the di.torq.handlers dispatcher)
  (.z.m.handlers`register)[`.z.pc;`;`pubsub;0;.z.m.ps`closesub];
  publishroot[];
  connect[];
  / registered before subscribing, so an upstream lost during the subscription is seen
  (.z.m.handlers`register)[`.z.pc;`;jobid;0;pcfunc];
  sd:subscribe[];
  / from here the root surface is live (the upstream may already be sending); a failure below takes it down again
  / so a half-initialised process does not keep relaying with no log and no flush job
  r:@[finishinit;sd;{[e] .z.m.ready:0b;.z.m.upstreamup:0b;closelog[];(`initfailed;e)}];
  if[`initfailed~first r;'r 1];
  msg:"initialised, upstream=",(string .z.m.upstreamtype),", mode=",string .z.m.publishmode;
  msg,:", log=",$[count .z.m.tplogdir;1_string .z.m.logname;"off"];
  .z.m.log[`info][`chainedtp;msg,", tables=",", " sv string .z.m.tables];
  / written last: a throw anywhere above leaves the module uninitialised, so a retry is a full init, not a re-init
  .z.m.initdone:1b;
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE API function, for di.torq to register with di.api. init and
  / getapimeta are plumbing di.torq calls by convention and are deliberately not listed. names are bare.
  :flip `name`public`descrip`params`return!flip(
    (`upd;       1b; "log and publish an update from the upstream (also root upd / .u.upd)"; "[symbol: t; list|table: x]"; "null");
    (`connected; 1b; "is the upstream subscription live";                                    "[]";                         "boolean");
    (`getcounts; 1b; "own-log message count, the date, and per-table published/pending rows"; "[]";                        "dict");
    (`teardown;  1b; "flush, close the own log, remove the flush job and .z.pc handlers";     "[]";                         "null"));
  };
