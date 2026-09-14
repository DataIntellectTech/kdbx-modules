/ helpers for di.torq.proc.chainedtp's integration suite. Drives REAL child kdb-x processes on OS-assigned ports: an
/ upstream di.torq.proc.tickerplant (test_integration_tp.q) and the chained tickerplant under test
/ (test_integration_ctp.q, wired to the real di.timer, di.torq.handlers, di.util.log and di.torq.servers). THIS
/ process plays the downstream subscriber: it calls the chained tp's .u.subdetails over IPC and receives its
/ publishes and end-of-day at root. Every child is launched through a shell wrapper that records its exit code, and
/ every pid is killed by the after row whatever happened. Scenario helpers return 1b only if every named check passes
/ and leave the per-check dict in LAST.

IBASE:"/tmp/di_chainedtp_integration";
SM:".m.di.0torq.0proc.0chainedtp.";
TPM:".m.di.0torq.0proc.0tickerplant.";
PIDS:`long$();

chk:{[d] `LAST set d; all value d};

moddir:{[] p:.Q.m.mp`di.torq.proc.chainedtp; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};

/ the binary running this session - guaranteed to be the kdb-x this suite runs on
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;"q"]}[];

/ what a downstream subscriber defines at root: the chained tp publishes (`upd;t;x) and broadcasts (`endofday;d)
RECV:();
EOD:0Nd;
upd:{[t;x] `RECV set RECV,enlist (t;x);};
endofday:{[d] `EOD set d;};

setupintegration:{[]
  system "rm -rf ",IBASE;
  system "mkdir -p ",IBASE;
  (hsym`$IBASE,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$())";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$())");
  setenv[`TORQXAPPHOME;IBASE];
  setenv[`TORQXDATAHOME;IBASE];
  };

killall:{[]
  {@[system;"kill -9 ",(string x)," 2>/dev/null";{}]} each PIDS;
  system "sleep 0.5";
  system "rm -rf ",IBASE;
  };

/ ask the OS for a free port, then release it for the child to bind
freeport:{[] system"p 0W"; p:system"p"; system"p 0"; p};

tryopen:{[p] @[{hopen (`$":localhost:",string x;500)};p;0Ni]};

waitopen:{[p;n]
  if[n<=0;:0Ni];
  if[not null h:tryopen p;:h];
  system "sleep 0.3";
  waitopen[p;n-1]
  };

startchild:{[name;script;args;port]
  / launch through a shell wrapper that appends EXIT=<code> to <name>.exit when the child ends; the wrapper's pid and,
  / once the child answers, its own pid are both tracked for the kill
  qcmd:QBIN," ",script," -q -p ",(string port)," ",args," </dev/null >>",IBASE,"/",name,".log 2>&1";
  cmd:"sh -c '",qcmd,"; echo EXIT=$? >> ",IBASE,"/",name,".exit' & echo $!";
  shpid:"J"$first system cmd;
  `PIDS set PIDS,shpid;
  h:waitopen[port;60];
  qpid:$[null h;0N;h ".z.i"];
  if[not null qpid;`PIDS set PIDS,qpid];
  `name`shpid`pid`port`h!(name;shpid;qpid;port;h)
  };

starttp:{[dir;args]
  startchild["tp";moddir[],"/test_integration_tp.q";"-tplogdir ",dir," -schemafile ",IBASE,"/database.q -publishmode immediate ",args;freeport[]]
  };

/ the process.csv phone book di.torq.servers dials from: rows as (port;proctype;procname)
csvrow:{[r] "localhost,",(string r 0),",",(string r 1),",",string r 2};
writecsvrows:{[path;rows] (hsym`$path) 0: enlist["host,port,proctype,procname"],csvrow each rows;};
writecsv:{[path;tpport;ctpport] writecsvrows[path;((tpport;`tickerplant;`tp1);(ctpport;`chainedtp;`ctp1))];};

/ a chained tp named procname subscribing to the proctype uptype, whose phone book holds the given rows plus itself
startctpnamed:{[name;procname;dir;uptype;rows;args]
  port:freeport[];
  pcsv:dir,"/process.csv";
  system "mkdir -p ",dir;
  writecsvrows[pcsv;rows,enlist (port;`chainedtp;procname)];
  a:"-upstreamtype ",(string uptype)," -tplogdir ",dir,"/log -processcsv ",pcsv," -proctype chainedtp -procname ",(string procname)," ",args;
  startchild[name;moddir[],"/test_integration_ctp.q";a;port]
  };

startctp:{[dir;tp;args] startctpnamed["ctp";`ctp1;dir;`tickerplant;enlist (tp`port;`tickerplant;`tp1);args]};

/ a real di.torq.proc.rdb taking the chained tp as its tickerplant type (a replaying di.subscriptions consumer)
startrdb:{[dir;ctp]
  port:freeport[];
  pcsv:dir,"/process.csv";
  system "mkdir -p ",dir;
  writecsvrows[pcsv;((ctp`port;`chainedtp;`ctp1);(port;`rdb;`rdb1))];
  a:"-tickerplanttypes chainedtp -hdbdir ",dir,"/hdb -processcsv ",pcsv," -proctype rdb -procname rdb1";
  startchild["rdb";moddir[],"/test_integration_rdb.q";a;port]
  };

kill9:{[c]
  @[system;"kill -9 ",(string c`pid)," 2>/dev/null";{}];
  @[hclose;c`h;{}];
  system "sleep 0.5";
  };

/ n async feed updates (syms S<from>..) then a sync round-trip, so the tickerplant has processed - and published - them all
feedtp:{[tp;t;from;n]
  {[tp;t;i] neg[tp`h](`.u.upd;t;(`$"S",string i;1.0*i))}[tp;t] each from+til n;
  tp[`h]"::";
  };

/ a sync round-trip to the chained tp: it has processed the upstream's publishes, and its own publishes queued on
/ this handle are processed here before the reply
sync:{[c] c[`h]"::";};

subscribe:{[c] `RECV set (); c[`h](`.u.subdetails;`;`)};

/ a sync round-trip is not a full barrier: the chained tp may answer it before draining the upstream's backlog on its
/ other socket. wait until its own message count reaches n, then round-trip to collect what it published
msgcount:{[c] (c[`h] "(use`di.torq.proc.chainedtp)[`getcounts][]")`msgcount};
settle:{[c;n] waitfor[{[c;n;x] n<=msgcount c}[c;n];80]; sync c;};

logcount:{[f] r:-11!(-2;f); $[0>type r;r;first r]};
ctpq:{[c;s] c[`h] s};
connected:{[c] c[`h] "(use`di.torq.proc.chainedtp)[`connected][]"};
pcnames:{[c] c[`h] "exec name from (use`di.torq.handlers)[`list]`.z.pc"};
/ syms received, from a table (live publish) or a list of columns (a replayed log message)
recvsyms:{[] raze {x:last x; $[98h=type x;x`sym;x 1]} each RECV};
exitcode:{[name] f:hsym`$IBASE,"/",name,".exit"; $[type key f;last read0 f;""]};
alive:{[pid] not `dead~@[system;"kill -0 ",(string pid)," 2>/dev/null";{`dead}]};

/ poll a condition (called as f[], so pass a projection with one argument left) every 0.25s for up to n tries
waitfor:{[f;n]
  if[n<=0;:0b];
  if[f[];:1b];
  system "sleep 0.25";
  waitfor[f;n-1]
  };

probe:{[]
  tp:starttp[IBASE,"/probe";""];
  ok:not null tp`h;
  kill9 tp;
  ok
  };

relay:{[]
  tp:starttp[IBASE,"/relay/tp";""];
  c:startctp[IBASE,"/relay/ctp";tp;""];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  sd:subscribe c;
  feedtp[tp;`trade;0;3];
  sync c;
  tpdate:tp[`h] "(",TPM,"eod`getd)[]";
  a:`tables`schemas`date`delivered`tableform`ownlog`msgcount`connected`pchandlers!(
    `quote`trade~asc sd`tables;
    all 98h=type each sd`schemas;
    tpdate=sd`date;
    `S0`S1`S2~recvsyms[];
    all 98h=type each last each RECV;
    3=logcount sd`logfile;
    3=(c[`h] "(use`di.torq.proc.chainedtp)[`getcounts][]")`msgcount;
    connected c;
    all `servers`chainedtp`pubsub in pcnames c);
  kill9 c;
  kill9 tp;
  chk a
  };

startupticks:{[]
  / ticks flow into the upstream before, during and after the chained tp starts (replaying with a cleared log): every
  / one reaches its log exactly once, and a downstream that replays from that log then follows live sees each once
  dir:IBASE,"/ticks";
  tp:starttp[dir,"/tp";""];
  feedtp[tp;`trade;0;5];
  c:startctp[dir,"/ctp";tp;"-replay 1 -clearlogonsubscription 1"];
  / launched but not yet subscribed: these land in the upstream log and are replayed, or arrive live - either way once
  feedtp[tp;`trade;5;5];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  feedtp[tp;`trade;10;5];
  sync c;
  sd:subscribe c;
  / replay the chained tp's own log here, as di.subscriptions would for an rdb, then take two more live
  -11!(sd`rowcount;sd`logfile);
  feedtp[tp;`trade;15;2];
  sync c;
  tplog:tp[`h] "(.u.subdetails)[`;`]";
  kill9 c;
  kill9 tp;
  chk `replaycount`ownlogcount`tplogcount`received`unique`all!(
    15=sd`rowcount;
    17=logcount sd`logfile;
    17=logcount tplog`logfile;
    17=count RECV;
    17=count distinct recvsyms[];
    all (`$"S",/:string til 17) in recvsyms[])
  };

rdbdownstream:{[]
  / the consumer this surface exists for: a real rdb, through di.subscriptions, replays the chained tp's log and then
  / follows live - and gets the chained tp's end of day
  dir:IBASE,"/rdb";
  tp:starttp[dir,"/tp";""];
  c:startctp[dir,"/ctp";tp;""];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  feedtp[tp;`trade;0;3];
  sync c;
  r:startrdb[dir,"/rdb";c];
  if[null r`h;kill9 c;kill9 tp;:chk enlist[`rdbup]!enlist 0b];
  feedtp[tp;`trade;3;2];
  feedtp[tp;`quote;10;1];
  sync c;
  r[`h]"::";
  a:`replayedandlive`quote`syms`subscribed`gattr!(
    5=r[`h]"count trade";
    1=r[`h]"count quote";
    (`$"S",/:string til 5)~r[`h]"trade`sym";
    r[`h]"(use`di.subscriptions)[`subscribed][]";
    `g=r[`h]"attr trade`sym");
  tp[`h] "endofday[]";
  waitfor[{[c;r;x] sync c; r[`h]"::"; 0=r[`h]"count trade"}[c;r];40];
  a:a,enlist[`rdbeod]!enlist 0=r[`h]"count trade";
  kill9 r;
  kill9 c;
  kill9 tp;
  chk a
  };

chainoftwo:{[]
  / tp -> ctp1 -> ctp2: the second chained tp subscribes to the first as its proctype, replays from ITS log, and this
  / downstream receives through both hops - and the end of day travels the whole chain
  dir:IBASE,"/chain";
  tp:starttp[dir,"/tp";""];
  c1:startctp[dir,"/ctp1";tp;""];
  if[null c1`h;kill9 tp;:chk enlist[`ctp1up]!enlist 0b];
  feedtp[tp;`trade;0;2];
  sync c1;
  book:((tp`port;`tickerplant;`tp1);(c1`port;`chainedtp;`ctp1));
  c2:startctpnamed["ctp2";`ctp2;dir,"/ctp2";`chainedtp;book;"-replay 1 -clearlogonsubscription 1"];
  if[null c2`h;kill9 c1;kill9 tp;:chk enlist[`ctp2up]!enlist 0b];
  sd:subscribe c2;
  -11!(sd`rowcount;sd`logfile);
  feedtp[tp;`trade;2;3];
  sync c1;
  sync c2;
  `EOD set 0Nd;
  tp[`h] "endofday[]";
  waitfor[{[c1;c2;x] sync c1; sync c2; not null EOD}[c1;c2];40];
  a:`replayed`received`unique`all`eodchained`upstreamname!(
    2=sd`rowcount;
    5=count RECV;
    5=count distinct recvsyms[];
    all (`$"S",/:string til 5) in recvsyms[];
    (sd`date)=EOD;
    `chainedtp~c2[`h] SM,"upstreamtype");
  kill9 c2;
  kill9 c1;
  kill9 tp;
  chk a
  };

/ a burst of n ten-row batches (syms B<i>) then a sync round-trip
burst:{[tp;n]
  {[tp;i] neg[tp`h](`.u.upd;`trade;(10#`$"B",string i;10#1.0*i))}[tp] each til n;
  tp[`h]"::";
  };

volume:{[]
  / 2000 ten-row batches through each mode: nothing lost, nothing duplicated, the log holds one message per batch, and
  / the batched buffer copes (the upsert-by-value idiom would go quadratic here)
  tp:starttp[IBASE,"/volume/tp";""];
  c:startctp[IBASE,"/volume/ctp";tp;""];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  sd:subscribe c;
  st:.z.p;
  burst[tp;2000];
  settle[c;2000];
  imm:`immrows`immmsgs`immlog!(20000=count recvsyms[];2000=count RECV;2000=logcount sd`logfile);
  immms:(`long$.z.p-st) div 1000000;
  kill9 c;
  c:startctp[IBASE,"/volume/ctpb";tp;"-publishmode batched -pubperiod 1"];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  sd:subscribe c;
  st:.z.p;
  burst[tp;2000];
  settle[c;2000];
  waitfor[{[c;x] sync c; 20000=count recvsyms[]}[c];40];
  bat:`batrows`batunique`batlog!(20000=count recvsyms[];2000=count distinct recvsyms[];2000=logcount sd`logfile);
  batms:(`long$.z.p-st) div 1000000;
  kill9 c;
  kill9 tp;
  `VOLMS set `immediate`batched!(immms;batms);
  chk imm,bat
  };

batched:{[]
  tp:starttp[IBASE,"/batched/tp";""];
  c:startctp[IBASE,"/batched/ctp";tp;"-publishmode batched -pubperiod 1"];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  subscribe c;
  feedtp[tp;`trade;0;2];
  sync c;
  pending:(c[`h] "(use`di.torq.proc.chainedtp)[`getcounts][]")`tables;
  system "sleep 2";
  sync c;
  after:(c[`h] "(use`di.torq.proc.chainedtp)[`getcounts][]")`tables;
  kill9 c;
  kill9 tp;
  chk `buffered`flushedbytimer`delivered`onemessage!(
    2=first exec pendingrowcount from pending where tbl=`trade;
    (2;0)~first each exec (rowcount;pendingrowcount) from after where tbl=`trade;
    `S0`S1~recvsyms[];
    1=count RECV)
  };

narrowed:{[]
  tp:starttp[IBASE,"/narrowed/tp";""];
  c:startctp[IBASE,"/narrowed/ctp";tp;"-subscribeto trade"];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  sd:subscribe c;
  feedtp[tp;`trade;0;2];
  feedtp[tp;`quote;10;2];
  sync c;
  kill9 c;
  kill9 tp;
  chk `tables`tradeonly`ownlog!((enlist`trade)~sd`tables;all `trade=first each RECV;2=logcount sd`logfile)
  };

eod:{[]
  tp:starttp[IBASE,"/eod/tp";""];
  c:startctp[IBASE,"/eod/ctp";tp;""];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  sd:subscribe c;
  feedtp[tp;`trade;0;2];
  sync c;
  `EOD set 0Nd;
  / the upstream ends its day: it tells the chained tp, which rolls and tells this process
  tp[`h] "endofday[]";
  waitfor[{[c;x] sync c; not null EOD}[c];40];
  sd1:c[`h](`.u.subdetails;`;`);
  kill9 c;
  kill9 tp;
  chk `downstream`dateadvanced`newlog`newlogempty`oldlogkept!(
    (sd`date)=EOD;
    (1+sd`date)=sd1`date;
    (string sd1`logfile) like "*_",string 1+sd`date;
    0=sd1`rowcount;
    2=logcount sd`logfile)
  };

upstreamloss:{[]
  tp:starttp[IBASE,"/loss/tp";""];
  c:startctp[IBASE,"/loss/ctp";tp;""];
  if[null c`h;kill9 tp;:chk enlist[`childup]!enlist 0b];
  a:`upbefore`alivebefore!(connected c;alive c`pid);
  / a real crash of the upstream
  kill9 tp;
  waitfor[{"EXIT=0"~exitcode"ctp"};60];
  a:a,`gone`exit0`logged!(
    not alive c`pid;
    "EXIT=0"~exitcode"ctp";
    0<count ss[raze read0 hsym`$IBASE,"/ctp.log";"lost the tickerplant connection"]);
  @[hclose;c`h;{}];
  chk a
  };

/ --- a real di.torq boot: torqx_init.q -> di.torq.init -> settings cascade -> startbuiltin, for both process types ---

/ the kdbx-modules root that holds di/torq (two levels above the di.torq module dir)
torqxhome:{[] p:.Q.m.mp`di.torq; p:$[10h=type p;p;string p]; p:$[":"=first p;1_p;p]; "/" sv -2_"/" vs p};

stackapp:{[]
  / a minimal app: schema, and a proctype-tier toml for each process type
  app:IBASE,"/app";
  system "mkdir -p ",app,"/appconfig/settings";
  (hsym`$app,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`g#`symbol$();price:`float$())";
    "quote:([]time:`timestamp$();sym:`g#`symbol$();bid:`float$())");
  (hsym`$app,"/appconfig/settings/default.toml") 0: enlist "# app defaults";
  (hsym`$app,"/appconfig/settings/tickerplant.toml") 0: ("tplogdir = \"tplog\"";"publishmode = \"immediate\"");
  (hsym`$app,"/appconfig/settings/chainedtp.toml") 0: (
    "upstreamtype = \"tickerplant\"";"tplogdir = \"ctplog\"";"publishmode = \"immediate\"";"connecttimeoutms = 15000");
  app};

startstack:{[app;proctype;procname;port]
  / launch exactly as torqx.sh does: QINIT=torqx_init.q with explicit identity and a stack id
  ident:" -proctype ",(string proctype)," -procname ",(string procname)," -torqxstackid itest";
  cmd:"QINIT=",torqxhome[],"/di/torq/bin/torqx_init.q ",QBIN," -q -p ",(string port),ident;
  pid:"J"$first system cmd," </dev/null >>",IBASE,"/stack_",(string procname),".log 2>&1 & echo $!";
  `PIDS set PIDS,pid;
  `pid`port`h!(pid;port;waitopen[port;120])};

stackboot:{[]
  / kdb-x abandons a QINIT script silently at the first error and leaves the process at its prompt, so a boot failure
  / looks like a running process: assert the module's observable effects, never just "it came up"
  app:stackapp[];
  setenv[`TORQXHOME;torqxhome[]];
  setenv[`TORQXAPPCONFIG;app,"/appconfig"];
  setenv[`TORQXAPPHOME;app];
  setenv[`TORQXDATAHOME;app];
  tpport:freeport[];
  ctpport:freeport[];
  writecsv[app,"/appconfig/process.csv";tpport;ctpport];
  tp:startstack[app;`tickerplant;`tp1;tpport];
  if[null tp`h;:chk enlist[`tpup]!enlist 0b];
  c:startstack[app;`chainedtp;`ctp1;ctpport];
  if[null c`h;:chk enlist[`ctpup]!enlist 0b];
  sd:subscribe c;
  feedtp[tp;`trade;0;3];
  sync c;
  a:`identity`updpublished`cascade`connected`pchandlers`ownlog`delivered!(
    (`chainedtp;`ctp1)~c[`h]"(",SM,"proctype;",SM,"procname)";
    c[`h]"`upd in key `.";
    (`tickerplant;`immediate;15000;app,"/ctplog")~c[`h]"(",SM,"upstreamtype;",SM,"publishmode;",SM,"connecttimeoutms;",SM,"tplogdir)";
    connected c;
    all `servers`chainedtp`pubsub in pcnames c;
    3=logcount sd`logfile;
    `S0`S1`S2~recvsyms[]);
  @[c`h;"exit 0";{}];
  @[tp`h;"exit 0";{}];
  system "sleep 1";
  setenv[`TORQXAPPHOME;IBASE];
  setenv[`TORQXDATAHOME;IBASE];
  chk a
  };
