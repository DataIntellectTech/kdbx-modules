/ fixture helpers for di.torq.proc.chainedtp's unit tests. Assumes cwd is the kdbx-modules repo root.
/ Uses REAL di.pubsub / di.subscriptions / di.tplogmgr with a recording mock log, timer, handlers and servers. The
/ servers mock hands out a genuine IPC handle to a STUB UPSTREAM (test_upstream.q, spawned here as a separate q
/ process) that answers .u.subdetails with whatever the harness set, so subscribe and replay run over real IPC without a
/ full tickerplant. The timer never runs a cycle, so the batched flush fires only when a test calls it. Each scenario
/ helper inits the module against its own log dir and returns 1b only if every named check passes; the per-check dict
/ is left in LAST so a failing row can be diagnosed with `show LAST`. Helpers live here because CSV fields cannot hold
/ commas.

BASE:"/tmp/di_chainedtp_k4unit";
MOD:`.m.di.0torq.0proc.0chainedtp;
UPDATE:2026.01.05;                                        / the date the stub upstream reports

/ read / write module state and reach internal functions
mv:{[n] get .Q.dd[MOD;n]};
mset:{[n;v] .Q.dd[MOD;n] set v;};

chk:{[d] `LAST set d; all value d};
errmsg:{[f] @[f;::;{x}]};

/ 1b only if f throws AND the error names the expected reason - a bare `fail` row would also pass on an
/ unrelated error (a fixture bug), proving nothing about the path under test
throws:{[f;s] r:errmsg f; (10h=type r) and 0<count r ss s};

/ --- mocks ---

calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklogfn:{[lvl;ctx;msg] `calls upsert `lvl`ctx`msg!(lvl;ctx;msg);};
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])};
logged:{[l;c] 0<count select from calls where lvl=l,ctx=c};

tcalls:([]fn:`symbol$();arg:());
mockaddjob:{[id;func;params;period;mode;opts] `tcalls upsert `fn`arg!(`addjob;(id;period;mode;opts));};
mocktimerfn:{[fn;ids] `tcalls upsert `fn`arg!(fn;ids);};
mocktimer:{[] `addjob`deletejobs`enablejobs`disablejobs!(mockaddjob;mocktimerfn[`deletejobs];mocktimerfn[`enablejobs];mocktimerfn[`disablejobs])};

hcalls:([]fn:`symbol$();arg:());
HFUNCS:(`symbol$())!();
mockregister:{[event;phase;name;priority;func] `hcalls upsert `fn`arg!(`register;(event;phase;name)); HFUNCS[name]:func;};
mockremove:{[event;phase;name] `hcalls upsert `fn`arg!(`remove;(event;phase;name));};
mockhandlers:{[] `register`remove!(mockregister;mockremove)};
registered:{[name] (`.z.pc;`;name) in exec arg from hcalls where fn=`register};
removed:{[name] (`.z.pc;`;name) in exec arg from hcalls where fn=`remove};

/ servers mock: records the calls, waits as told (WAITOK) and hands out the stub upstream's real handle
scalls:([]fn:`symbol$();arg:());
WAITOK:1b;
mockstartup:{[c] `scalls upsert `fn`arg!(`startup;c);};
mockwait:{[pt;t;p] `scalls upsert `fn`arg!(`waitfortype;(pt;t;p)); WAITOK};
mockhandle:{[pt;sel] `scalls upsert `fn`arg!(`gethandlebytype;(pt;sel)); STUBH};
mockservers:{[] `startup`gethandlebytype`waitfortype!(mockstartup;mockhandle;mockwait)};
scount:{[f] count select from scalls where fn=f};

deps:{[] `log`timer`handlers`servers!(mocklog[];mocktimer[];mockhandlers[];mockservers[])};
resetmocks:{[] delete from `calls; delete from `tcalls; delete from `hcalls; delete from `scalls; `HFUNCS set (`symbol$())!(); STUBH "CALLS:0";};

/ an in-process subscription registers handle 0, and di.pubsub's end-of-day broadcast to handle 0 evaluates the root
/ `endofday` synchronously - which is the module's own (it publishes that name). so a test that wants to see what a
/ downstream receives swaps a capture function in at root for the call, driving the module through its .u.end alias
capture:{[d] `EOD set d;};
withdownstream:{[f]
  `EOD set 0Nd;
  (.u.subdetails)[`;`];
  @[`.;`endofday;:;capture];
  r:@[f;::;{x}];
  @[`.;`endofday;:;.u.end];
  (use`di.pubsub)[`closesub][0];
  if[10h=type r;'r];
  };

/ --- the stub upstream ---

STUBH:0Ni;
STUBPID:0N;
STUBPORT:0N;

moddir:{[] p:.Q.m.mp`di.torq.proc.chainedtp; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};

/ the binary running this session - guaranteed to be the kdb-x this suite runs on
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;"q"]}[];

/ ask the OS for a free port, then release it for the stub to bind
freeport:{[] system"p 0W"; p:system"p"; system"p 0"; p};

tryopen:{[p] @[{hopen (`$":localhost:",string x;500)};p;0Ni]};

waitopen:{[p;n]
  if[n<=0;:0Ni];
  if[not null h:tryopen p;:h];
  system "sleep 0.3";
  waitopen[p;n-1]
  };

spawnstub:{[]
  `STUBPORT set freeport[];
  cmd:QBIN," ",moddir[],"/test_upstream.q -q -p ",string STUBPORT;
  `STUBPID set "J"$first system cmd," </dev/null >>",BASE,"/stub.log 2>&1 & echo $!";
  `STUBH set waitopen[STUBPORT;40];
  if[null STUBH;'"test: stub upstream failed to listen on ",string STUBPORT];
  };

killstub:{[]
  if[not null STUBH;@[hclose;STUBH;{}]];
  if[not null STUBPID;@[system;"kill -9 ",(string STUBPID)," 2>/dev/null";{}]];
  `STUBH set 0Ni;
  `STUBPID set 0N;
  };

/ the schemas and the upstream's own log the stub offers: 4 messages - 3 trade (2 of them sym A), 1 quote (sym C)
schemas:{[] `trade`quote!(([]time:`timestamp$();sym:`g#`symbol$();price:`float$());([]time:`timestamp$();sym:`g#`symbol$();bid:`float$()))};
UPLOG:hsym`$BASE,"/upstream/tp",string UPDATE;
uplogmsgs:(
  (`upd;`trade;(2026.01.05D09:00:00;`A;1.0));
  (`upd;`trade;(2026.01.05D09:00:01;`B;2.0));
  (`upd;`quote;(2026.01.05D09:00:02;`C;0.9));
  (`upd;`trade;(2026.01.05D09:00:03;`A;3.0)));

writeuplog:{[]
  UPLOG set ();
  h:hopen UPLOG;
  {[h;m] h enlist m}[h] each uplogmsgs;
  hclose h;
  };

/ what the stub replies to .u.subdetails: full log by default; a test can override rowcount/logfile
setstub:{[extra] STUBH (set;`SD;(`tables`schemas`logfile`rowcount`date!(`trade`quote;schemas[];UPLOG;4;UPDATE)),extra);};
stubcalls:{[] STUBH "CALLS"};

/ --- fixture ---

setupfixture:{[]
  system "rm -rf ",BASE;
  system "mkdir -p ",BASE,"/upstream";
  setenv[`TORQXAPPHOME;BASE];
  setenv[`TORQXDATAHOME;BASE];
  writeuplog[];
  spawnstub[];
  setstub[()!()];
  };

teardownfixture:{[]
  if[mv`initdone;(ct`teardown)[]];
  killstub[];
  system "rm -rf ",BASE;
  };

/ config for a log dir (relative to TORQXDATAHOME) plus scenario settings; nolog omits tplogdir
cfg:{[dir;extra] (`upstreamtype`tplogdir!(`stubtp;dir)),extra};
nolog:{[extra] (enlist[`upstreamtype]!enlist`stubtp),extra};

doinit:{[c]
  resetmocks[];
  (use`di.pubsub)[`closesub][0];
  (ct`init)[c;deps[]];
  };

/ --- lookups ---

ownlog:{[] mv`logname};
logcount:{[f] c:-11!(-2;f); $[0>type c;c;first c]};
cnt:{[t;col] c:0!((ct`getcounts)[])`tables; first (c col) where c[`tbl]=t};
msgs:{[] ((ct`getcounts)[])`msgcount};

/ open file descriptors of this process pointing exactly at a file (0 once closed)
fdcount:{[f] count @[system;"ls -l /proc/",(string .z.i),"/fd 2>/dev/null | awk '$NF==\"",(1_string f),"\"'";{()}]};

/ feed n rows of table t through the published root upd (column-list form, one record each) as the upstream would
feed:{[t;n] {[t;i] upd[t;(2026.01.05D10:00:00+i;`$"S",string i;1.0*i)]}[t] each til n;};

/ truncate a log mid-message
smash:{[f] n:hcount f; f 1: read1 (f;0;n-5);};

/ --- init validation ---

initnotdict:{[] throws[{(ct`init)[cfg["tplog/v";()!()];(::)]};"deps must be a dict"]};
initnolog:{[] throws[{(ct`init)[cfg["tplog/v";()!()];`timer`handlers`servers#deps[]]};"log dependency is required"]};
initnotimer:{[] throws[{(ct`init)[cfg["tplog/v";()!()];`log`handlers`servers#deps[]]};"timer dependency is required"]};
initnohandlers:{[] throws[{(ct`init)[cfg["tplog/v";()!()];`log`timer`servers#deps[]]};"handlers dependency is required"]};
initnoservers:{[] throws[{(ct`init)[cfg["tplog/v";()!()];`log`timer`handlers#deps[]]};"servers dependency is required"]};
initlogkeys:{[] throws[{(ct`init)[cfg["tplog/v";()!()];@[deps[];`log;:;`info`warn#mocklog[]]]};"missing error"]};
initserverskeys:{[] throws[{(ct`init)[cfg["tplog/v";()!()];@[deps[];`servers;:;`startup`gethandlebytype#mockservers[]]]};"missing waitfortype"]};
initnoupstream:{[] throws[{(ct`init)[enlist[`tplogdir]!enlist "tplog/v";deps[]]};"upstreamtype is required"]};
initbad:{[k;v] resetmocks[]; (ct`init)[cfg["tplog/v";enlist[k]!enlist v];deps[]]};
initrejects:{[k;v;s] throws[{[k;v;x] initbad[k;v]}[k;v];s]};

initwaittimeout:{[]
  `WAITOK set 0b;
  r:throws[{doinit cfg["tplog/wait";()!()]};"no stubtp connection within"];
  `WAITOK set 1b;
  chk `threw`notinit`errorlogged`nosubscription!(r;not mv`initdone;logged[`error;`init];0=stubcalls[])
  };

fixpartway:{[]
  / a throw from the module's own .z.pc registration, after the connection is up but before the subscription
  resetmocks[];
  boom:{[event;phase;name;priority;func] if[name=`chainedtp;'"boom"]; mockregister[event;phase;name;priority;func]};
  bad:@[deps[];`handlers;:;`register`remove!(boom;mockremove)];
  r:@[(ct`init)[cfg["tplog/partway";()!()]];bad;{x}];
  notdone:not mv`initdone;
  nosub:0=stubcalls[];
  doinit cfg["tplog/partway";()!()];
  chk `threw`notdone`nosubscription`done`onesubscription`registered!(10h=type r;notdone;nosub;mv`initdone;1=stubcalls[];registered`chainedtp)
  };

defaults:{[]
  doinit cfg["tplog/defaults";()!()];
  chk `upstreamtype`subscribeto`subscribesyms`replay`clearlog`publishmode`pubperiod`timeout`poll`logprefix`tplogdir`date`tables!(
    `stubtp=mv`upstreamtype;
    `~mv`subscribeto;
    `~mv`subscribesyms;
    0b~mv`replay;
    0b~mv`clearlogonsubscription;
    `immediate=mv`publishmode;
    1=mv`pubperiod;
    10000=mv`connecttimeoutms;
    500=mv`connectpollms;
    "chainedtp"~mv`logprefix;
    (BASE,"/tplog/defaults")~mv`tplogdir;
    UPDATE=mv`date;
    `trade`quote~mv`tables)
  };

stringconfig:{[]
  / .toml / command-line overrides deliver strings and plain numbers - each must reach state as the right type
  ks:`upstreamtype`replay`clearlogonsubscription`pubperiod`publishmode`connecttimeoutms`subscribeto;
  doinit cfg["tplog/strcfg";ks!("stubtp";"true";"1";"5";"batched";20000;"trade")];
  chk `upstreamtype`replay`clearlog`pubperiod`publishmode`timeout`subscribeto!(
    `stubtp=mv`upstreamtype;
    1b~mv`replay;
    1b~mv`clearlogonsubscription;
    5=mv`pubperiod;
    `batched=mv`publishmode;
    20000=mv`connecttimeoutms;
    `trade=mv`subscribeto)
  };

/ file names carry procname when di.torq supplies one, so a chained tp sharing a tplogdir cannot collide
prefixok:{[]
  doinit cfg["tplog/prefix";enlist[`procname]!enlist`ctp7];
  a:enlist[`procname]!enlist (hsym`$BASE,"/tplog/prefix/ctp7_",string UPDATE)~ownlog[];
  doinit cfg["tplog/prefix2";`procname`logprefix!(`ctp7;"custom")];
  chk a,enlist[`explicitwins]!enlist (hsym`$BASE,"/tplog/prefix2/custom_",string UPDATE)~ownlog[]
  };

emptylogdir:{[]
  / an empty tplogdir is absence, not a log in the data root
  doinit cfg["";()!()];
  chk `nolog`nohandle!(0=count mv`tplogdir;0i=mv`logh)
  };

/ --- wiring ---

rootok:{[]
  / forget the live handle so this init dials afresh (startup is skipped while an earlier init's handle lives)
  mset[`tph;0Ni];
  doinit cfg["tplog/root";()!()];
  chk `upd`uupd`sub`subdetails`endofday`uend`pc`pubsubpc`startup`waited`handle`connections!(
    `upd in key `.;
    `upd in key `.u;
    `sub in key `.u;
    `subdetails in key `.u;
    `endofday in key `.;
    `end in key `.u;
    registered`chainedtp;
    registered`pubsub;
    1=scount`startup;
    (`stubtp;10000;500)~exec first arg from scalls where fn=`waitfortype;
    STUBH=mv`tph;
    (enlist`stubtp)~(exec first arg from scalls where fn=`startup)`connections)
  };

reinit:{[]
  c:cfg["tplog/reinit";enlist[`publishmode]!enlist`batched];
  doinit c;
  doinit c;
  chk `done`onestartup`onesubscription`jobreplaced`deletedfirst`onefd!(
    mv`initdone;
    0=scount`startup;
    1=stubcalls[];
    1=count select from tcalls where fn=`addjob;
    (exec first i from tcalls where fn=`deletejobs)<exec first i from tcalls where fn=`addjob;
    1=fdcount ownlog[])
  };

logdictwiring:{[]
  resetmocks[];
  (use`di.pubsub)[`closesub][0];
  lg:use`di.util.log;
  (ct`init)[cfg["tplog/logdict";()!()];lg[`logdict],`timer`handlers`servers!(mocktimer[];mockhandlers[];mockservers[])];
  mv`initdone
  };

versionok:{[]
  v:ct`version;
  chk `exported`semver`nonewline!(`version in key ct;3=count "." vs v;not any v in "\n\r")
  };

/ --- updates under both publish modes, with and without a log ---

immediateok:{[]
  doinit cfg["tplog/imm";()!()];
  feed[`trade;2];
  feed[`quote;1];
  chk `norows`logged`msgcount`traderows`quoterows`nopending`nojob!(
    0=count trade;
    3=logcount ownlog[];
    3=msgs[];
    2=cnt[`trade;`rowcount];
    1=cnt[`quote;`rowcount];
    0=cnt[`trade;`pendingrowcount];
    0=count select from tcalls where fn=`addjob)
  };

immediatenolog:{[]
  doinit nolog[()!()];
  r:@[{feed[`trade;2];1b};::;{x}];
  sd:(ct`getcounts)[];
  chk `nothrow`counted`nolog`nohandle!(1b~r;2=cnt[`trade;`rowcount];0=sd`msgcount;0i=mv`logh)
  };

batchedok:{[]
  doinit cfg["tplog/batch";`publishmode`pubperiod!(`batched;3)];
  feed[`trade;3];
  a:`rows`logged`pending`notpublished`job!(
    3=count trade;
    3=logcount ownlog[];
    3=cnt[`trade;`pendingrowcount];
    0=cnt[`trade;`rowcount];
    (`chainedtp;3;1h)~3#exec first arg from tcalls where fn=`addjob);
  (mv`flush)[];
  chk a,`cleared`published`nopending!(0=count trade;3=cnt[`trade;`rowcount];0=cnt[`trade;`pendingrowcount])
  };

batchednolog:{[]
  doinit nolog[enlist[`publishmode]!enlist`batched];
  r:@[{feed[`trade;2];1b};::;{x}];
  chk `nothrow`rows`nolog!(1b~r;2=count trade;0=msgs[])
  };

payloadok:{[]
  / a table (live di.pubsub delivery), a single record (atom columns), a batch (vector columns), a string table name
  doinit cfg["tplog/payload";enlist[`publishmode]!enlist`batched];
  upd[`trade;([]time:2#2026.01.05D10:00:00;sym:`A`B;price:1 2f)];
  upd[`trade;(2026.01.05D10:00:01;`C;3f)];
  upd[`trade;(2#2026.01.05D10:00:02;`D`E;4 5f)];
  upd["trade";(2026.01.05D10:00:03;`F;6f)];
  chk `rows`syms`logged`replayform!(
    6=count trade;
    `A`B`C`D`E`F~trade`sym;
    4=logcount ownlog[];
    all 0h=type each last each get ownlog[])
  };

unknowntable:{[]
  doinit cfg["tplog/unknown";()!()];
  chk `unknown`list`notasymbol!(
    throws[{upd[`nosuch;(2026.01.05D10:00:00;`A;1f)]};"not a subscribed table"];
    throws[{upd[`trade`quote;((2026.01.05D10:00:00;`A;1f);(2026.01.05D10:00:00;`A;1f))]};"must be one symbol"];
    throws[{upd[42;(2026.01.05D10:00:00;`A;1f)]};"must be one symbol"])
  };

publishfailok:{[]
  / a publish that throws (a subscriber gone without .z.pc) is logged at error and signalled, not lost in the async handler
  doinit cfg["tplog/pubfail";()!()];
  ps:mv`ps;
  mset[`ps;@[ps;`publish;:;{[t;x] '"4 is not an ipc handle"}]];
  r:throws[{feed[`trade;1]};"publish of trade failed"];
  mset[`ps;ps];
  chk `threw`logged`stilllogged!(r;logged[`error;`upd];1=logcount ownlog[])
  };

initfailslate:{[]
  / an init that fails after subscribing (an unwritable log dir) takes the root surface down again and is retryable
  r:throws[{doinit cfg["/proc/nowhere/ctp";()!()]};"cannot create the log directory"];
  a:`threw`notinit`notready`notconnected`updthrows!(r;not mv`initdone;not mv`ready;not mv`upstreamup;throws[{feed[`trade;1]};"init must be called"]);
  doinit cfg["tplog/late";()!()];
  chk a,`recovered`ready!(mv`initdone;(ct`connected)[])
  };

/ a tick that beats the log open (possible under multithreaded input) is published, not thrown, and not logged
earlytick:{[]
  doinit cfg["tplog/early";()!()];
  h:mv`logh;
  mset[`logh;0i];
  r:@[{feed[`trade;1];1b};::;{x}];
  mset[`logh;h];
  feed[`trade;1];
  chk `nothrow`published`onelogged!(1b~r;2=cnt[`trade;`rowcount];1=logcount ownlog[])
  };

/ --- the upstream replay into the own log ---

replayok:{[]
  doinit cfg["tplog/replay";`replay`clearlogonsubscription!(1b;1b)];
  chk `logged`msgcount`traderows`quoterows`norows`onesubscription`replaylogged!(
    4=logcount ownlog[];
    4=msgs[];
    3=cnt[`trade;`rowcount];
    1=cnt[`quote;`rowcount];
    0=count trade;
    1=stubcalls[];
    logged[`info;`replay])
  };

replaybatched:{[]
  doinit cfg["tplog/replayb";`replay`clearlogonsubscription`publishmode!(1b;1b;`batched)];
  chk `logged`buffered`pending`quote!(4=logcount ownlog[];3=count trade;3=cnt[`trade;`pendingrowcount];1=count quote)
  };

replaynarrowed:{[]
  doinit cfg["tplog/replayn";`replay`clearlogonsubscription`subscribeto!(1b;1b;`trade)];
  chk `tables`logged`tradeonly!((enlist`trade)~mv`tables;3=logcount ownlog[];all `trade=(get ownlog[])[;1])
  };

replaysyms:{[]
  doinit cfg["tplog/replays";`replay`clearlogonsubscription`subscribesyms!(1b;1b;`A)];
  chk `logged`onlya!(2=logcount ownlog[];all `A=raze (last each get ownlog[])[;1])
  };

replaynone:{[]
  / nothing logged upstream: no replay, no warning
  setstub[enlist[`rowcount]!enlist 0];
  doinit cfg["tplog/replay0";enlist[`replay]!enlist 1b];
  setstub[()!()];
  chk `empty`noreplay!(0=msgs[];not logged[`info;`replay])
  };

replaynofile:{[]
  setstub[enlist[`logfile]!enlist`];
  r:throws[{doinit cfg["tplog/replaynf";enlist[`replay]!enlist 1b]};"no log file"];
  setstub[()!()];
  chk `threw`notinit!(r;not mv`initdone)
  };

replayappendwarn:{[]
  c:cfg["tplog/replaya";enlist[`replay]!enlist 1b];
  doinit c;
  a:enlist[`first]!enlist 4=msgs[];
  doinit c;
  chk a,`appended`warned!(8=msgs[];logged[`warn;`init])
  };

existingcount:{[]
  / a restart COUNTS the day's log rather than replaying it - replaying would republish
  c:cfg["tplog/existing";()!()];
  doinit c;
  feed[`trade;2];
  (ct`teardown)[];
  doinit c;
  chk `counted`notrepublished`notcleared!(2=msgs[];0=cnt[`trade;`rowcount];2=logcount ownlog[])
  };

clearlogok:{[]
  c:cfg["tplog/clear";()!()];
  doinit c;
  feed[`trade;2];
  (ct`teardown)[];
  doinit c,enlist[`clearlogonsubscription]!enlist 1b;
  chk `cleared`logged!(0=msgs[];logged[`info;`clearlog])
  };

corruptok:{[]
  c:cfg["tplog/corrupt";()!()];
  doinit c;
  feed[`trade;3];
  orig:ownlog[];
  (ct`teardown)[];
  smash orig;
  osize:hcount orig;
  doinit c;
  g:ownlog[];
  a:`usesgood`goodcount`warned`origuntouched!(g~(mv`goodname) orig;2=msgs[];logged[`warn;`openlog];osize=hcount orig);
  feed[`trade;1];
  a:a,enlist[`appends]!enlist 3=logcount g;
  (ct`teardown)[];
  doinit c;
  chk a,`stillgood`nodataloss!(g~ownlog[];3=msgs[])
  };

/ --- the surface offered to this process's own subscribers ---

subdetailsok:{[]
  doinit cfg["tplog/subd";()!()];
  feed[`trade;4];
  feed[`quote;1];
  sd:(.u.subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];
  chk `keys`tables`schemas`logfile`rowcount`date!(
    `tables`schemas`logfile`rowcount`date~key sd;
    `trade`quote~sd`tables;
    all 98h=type each sd`schemas;
    ownlog[]~sd`logfile;
    5=sd`rowcount;
    UPDATE=sd`date)
  };

subdetailsnolog:{[]
  doinit nolog[()!()];
  feed[`trade;2];
  sd:(.u.subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];
  chk `nologfile`zero!(`~sd`logfile;0=sd`rowcount)
  };

subdetailsflush:{[]
  / batched: the buffer is flushed to the existing subscribers before the caller is registered, so the replay count
  / it receives never includes a row it would also get in the next flush
  doinit cfg["tplog/subdf";enlist[`publishmode]!enlist`batched];
  feed[`trade;2];
  sd:(.u.subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];
  chk `flushed`published`rowcount!(0=count trade;2=cnt[`trade;`rowcount];2=sd`rowcount)
  };

subbad:{[]
  doinit cfg["tplog/subbad";()!()];
  throws[{(.u.subdetails)[enlist`nosuch;`]};"not available"]
  };

subok:{[]
  doinit cfg["tplog/sub";()!()];
  r:(.u.sub)[`trade;`];
  (use`di.pubsub)[`closesub][0];
  (`trade;98h)~(first r 0;type r[1;0])
  };

eodok:{[]
  doinit cfg["tplog/eod";()!()];
  feed[`trade;2];
  old:ownlog[];
  withdownstream {(.u.end)[UPDATE]};
  a:`downstream`newfile`dateadvanced`reset`oldclosed`newopen!(
    UPDATE=EOD;
    (hsym`$BASE,"/tplog/eod/chainedtp_",string UPDATE+1)~ownlog[];
    (UPDATE+1)=mv`date;
    0=msgs[];
    0=fdcount old;
    1=fdcount ownlog[]);
  / a later date than expected is followed, with a warning; an earlier one - a day already ended - is ignored
  withdownstream {(.u.end)[UPDATE+7]};
  a:a,`warned`followed`downstream2!(logged[`warn;`endofday];(UPDATE+8)=mv`date;(UPDATE+7)=EOD);
  f:ownlog[];
  withdownstream {(.u.end)[UPDATE+2]};
  chk a,`pastignored`notrebroadcast`samelog!((UPDATE+8)=mv`date;null EOD;f~ownlog[])
  };

eodnolog:{[]
  doinit nolog[()!()];
  withdownstream {(.u.end)[UPDATE]};
  chk `downstream`dateadvanced`nohandle!(UPDATE=EOD;(UPDATE+1)=mv`date;0i=mv`logh)
  };

eodbaddate:{[]
  doinit cfg["tplog/eodbad";()!()];
  throws[{endofday[`notadate]};"expected a date"]
  };

/ --- connection loss, lifecycle ---

connectedok:{[]
  doinit cfg["tplog/conn";()!()];
  `EXITED set 0N;
  mset[`exitfn;{[c] `EXITED set c;}];
  a:enlist[`up]!enlist (ct`connected)[];
  (mv`pcfunc)[STUBH+1000i];
  a:a,`foreignignored`noexit!((ct`connected)[];null EXITED);
  (mv`pcfunc)[STUBH];
  chk a,`down`exit0`errorlogged!(not (ct`connected)[];0=EXITED;logged[`error;`pc])
  };

pcviahandlers:{[]
  / the function handed to the handlers dep is the module's handler
  doinit cfg["tplog/pcvia";()!()];
  `EXITED set 0N;
  mset[`exitfn;{[c] `EXITED set c;}];
  HFUNCS[`chainedtp][STUBH];
  chk `down`exit0`pubsubfn!(not (ct`connected)[];0=EXITED;HFUNCS[`pubsub]~(use`di.pubsub)`closesub)
  };

teardownok:{[]
  doinit cfg["tplog/teardown";enlist[`publishmode]!enlist`batched];
  feed[`trade;2];
  f:ownlog[];
  (ct`teardown)[];
  chk `flushed`closed`job`handler`pubsubhandlerkept`notinit`notready!(
    0=count trade;
    0=fdcount f;
    (enlist`chainedtp)~exec last arg from tcalls where fn=`deletejobs;
    removed`chainedtp;
    not removed`pubsub;
    not mv`initdone;
    not mv`ready)
  };

afterteardown:{[]
  chk `connected`getcounts`teardown`upd`subdetails`endofday!(
    throws[{(ct`connected)[]};"init must be called"];
    throws[{(ct`getcounts)[]};"init must be called"];
    throws[{(ct`teardown)[]};"init must be called"];
    throws[{upd[`trade;(2026.01.05D10:00:00;`A;1f)]};"init must be called"];
    throws[{(.u.subdetails)[`;`]};"init must be called"];
    throws[{endofday[UPDATE]};"init must be called"])
  };
