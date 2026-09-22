/ helpers for di.torq.proc.discovery's integration suite. Drives REAL child kdb-x processes on OS-assigned ports: the
/ discovery service under test (test_integration_discovery.q, wired to the real di.timer, di.torq.handlers, di.util.log
/ and di.torq.servers), plain-q backends for it to find (rdb1/hdb1/rdb2/pricer1 - they only need to listen), and
/ subscriber children (test_integration_sub.q, ordinary processes on the real di.torq.servers whose only phone-book
/ entry is discovery). Every child is launched through a shell wrapper that records its exit code, and every pid is
/ killed by the after row whatever happened. Scenario helpers return 1b only if every named check passes and leave the
/ per-check dict in LAST.

IBASE:"/tmp/di_discovery_integration";
SM:".m.di.0torq.0proc.0discovery.";
PIDS:`long$();

chk:{[d] `LAST set d; all value d};

moddir:{[] p:.Q.m.mp`di.torq.proc.discovery; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};

/ the binary running this session - guaranteed to be the kdb-x this suite runs on
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;"q"]}[];

setupintegration:{[]
  system "rm -rf ",IBASE;
  system "mkdir -p ",IBASE;
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

/ a plain q listener standing in for a backend process (it only has to be dialable)
startpeer:{[name;port] startchild[name;"";"";port]};

kill9:{[c]
  @[system;"kill -9 ",(string c`pid)," 2>/dev/null";{}];
  @[hclose;c`h;{}];
  system "sleep 0.5";
  };

/ phone books: rows are (port;proctype;procname)
csvrow:{[r] "localhost,",(string r 0),",",(string r 1),",",string r 2};
writecsvrows:{[path;rows] (hsym`$path) 0: enlist["host,port,proctype,procname"],csvrow each rows;};
appendcsvrow:{[path;r] (hsym`$path) 0: (read0 hsym`$path),enlist csvrow r;};

/ the discovery service under test: fast ticks so the suite is not waiting on the 30s default
startdiscoverynamed:{[dir;port;procname;args]
  startchild[procname;moddir[],"/test_integration_discovery.q";"-processcsv ",dir,"/process.csv -proctype discovery -procname ",procname," -retryperiod 2 ",args;port]
  };
startdiscovery:{[dir;port;args] startdiscoverynamed[dir;port;"disc1";args]};

/ a child's log so far
childlog:{[name] f:hsym`$IBASE,"/",name,".log"; $[type key f;read0 f;()]};
logmatches:{[name;s] count (childlog name) where (childlog name) like "*",s,"*"};

/ a subscriber whose phone book holds only the discovery service; want is a space-separated proctype list, ALL or none
startsub:{[dir;name;discport;want]
  book:dir,"/",name,"_process.csv";
  writecsvrows[book;enlist (discport;`discovery;`disc1)];
  startchild[name;moddir[],"/test_integration_sub.q";"-processcsv ",book," -proctype sub -procname ",name," -want ",want;freeport[]]
  };

/ --- what the parent asks the children ---
disclive:{[c] c[`h] "live[]"};                                               / discovery's live rows (all proctypes)
discservices:{[c;types] c[`h] (`.discovery.getservices;types;0b)};           / the api, over IPC, without subscribing
discsubs:{[c] c[`h] "(use`di.torq.proc.discovery)[`getsubs][]"};
subknown:{[c] c[`h] "known[]"};                                               / a subscriber's non-discovery registry rows
subconnected:{[c] select from subknown[c] where not null w};
alive:{[pid] not `dead~@[system;"kill -0 ",(string pid)," 2>/dev/null";{`dead}]};
exitcode:{[name] f:hsym`$IBASE,"/",name,".exit"; $[type key f;last read0 f;""]};

/ poll f (a projection still wanting ONE arg - a fully applied lambda would evaluate once, up front) every 250ms up
/ to n times; 1b as soon as it holds
waitfor:{[f;n]
  if[n<=0;:0b];
  if[@[f;::;0b];:1b];
  system "sleep 0.25";
  waitfor[f;n-1]
  };

/ a scenario's fixture dir + phone book with the given backend rows and the discovery row
scenario:{[name;rows;discport]
  dir:IBASE,"/",name;
  system "mkdir -p ",dir;
  writecsvrows[dir,"/process.csv";rows,enlist (discport;`discovery;`disc1)];
  dir
  };

probe:{[]
  dir:scenario["probe";();p:freeport[]];
  d:startdiscovery[dir;p;""];
  ok:not null d`h;
  kill9 d;
  ok
  };

/ --- scenarios ---

discovers:{[]
  / two plain backends in the phone book are dialled and reported live within the first ticks; the discovery row
  / itself is never handed out; a port-0 row (the loader convention) is never dialled; identity and settings
  / reached the module
  rp:freeport[]; hp:freeport[]; dp:freeport[];
  dir:scenario["discovers";((rp;`rdb;`rdb1);(hp;`hdb;`hdb1);(0;`loader;`loader1));dp];
  rdb:startpeer["rdb1";rp];
  hdb:startpeer["hdb1";hp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  found:waitfor[{[d;x] 2=count select from disclive d where proctype in `rdb`hdb}[d];40];
  system "sleep 2.5";                                                       / one more tick with nothing new
  ks:`discoveryup`found`identity`retryperiod`services`hdbonly`nodiscoveryrow`nosubs`unknownempty`loaderskipped;
  ks,:`nodialtoport0`quietwhenunchanged`noeviction;
  a:ks!(
    1b;
    found;
    (`discovery;`disc1)~d[`h]"(",SM,"self`proctype;",SM,"self`procname)";
    2=d[`h] SM,"retryperiod";
    (`hdb1`rdb1)~asc exec procname from discservices[d;`ALL];
    (enlist`hdb1)~exec procname from discservices[d;`hdb];
    not `discovery in exec proctype from discservices[d;`ALL];
    0=count discsubs d;
    0=count discservices[d;`nosuch];
    not `loader in exec proctype from d[`h]"registry[]";
    0=logmatches["disc1";"localhost:0"];
    0=logmatches["disc1";"already known"];
    0=logmatches["disc1";"evicted"]);
  kill9 each (d;rdb;hdb);
  chk a
  };

twodiscovery:{[]
  / two independent discovery instances: each dials the other (it is just another phone-book row) but neither hands
  / a discovery row out; a subscriber to either one is served
  rp:freeport[]; d1p:freeport[]; d2p:freeport[];
  dir:IBASE,"/twodiscovery";
  system "mkdir -p ",dir;
  writecsvrows[dir,"/process.csv";((rp;`rdb;`rdb1);(d1p;`discovery;`disc1);(d2p;`discovery;`disc2))];
  rdb:startpeer["rdb1";rp];
  d1:startdiscoverynamed[dir;d1p;"disc1";""];
  d2:startdiscoverynamed[dir;d2p;"disc2";""];
  if[any null (d1`h;d2`h);kill9 each (d1;d2;rdb);:chk enlist[`discoveryup]!enlist 0b];
  seeseach:waitfor[{[d1;d2;x] (`disc2 in exec procname from disclive d1) and `disc1 in exec procname from disclive d2}[d1;d2];40];
  s1:startsub[dir,"/sub";"sub1";d2p;"rdb"];
  if[null s1`h;kill9 each (d1;d2;rdb;s1);:chk enlist[`subsup]!enlist 0b];
  pushed:waitfor[{[s;x] 1=count subknown s}[s1];40];
  a:`discoveryup`seeseach`neitherhandsout`nonebytype`servedbysecond`pushed!(
    1b;
    seeseach;
    not any `discovery in/: (exec proctype from discservices[d1;`ALL];exec proctype from discservices[d2;`ALL]);
    all 0=count each (discservices[d1;`discovery];discservices[d2;`discovery]);
    (enlist`rdb1)~exec procname from s1[`h]"ANSWER";
    pushed);
  kill9 each (d1;d2;rdb;s1);
  chk a
  };

subscribed:{[]
  / a subscriber asking for rdb is pushed exactly the live rdb row and its own retry connects it; a subscriber that
  / never subscribes is pushed nothing; discovery lists exactly the one subscription
  rp:freeport[]; hp:freeport[]; dp:freeport[];
  dir:scenario["subscribed";((rp;`rdb;`rdb1);(hp;`hdb;`hdb1));dp];
  rdb:startpeer["rdb1";rp];
  hdb:startpeer["hdb1";hp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  s1:startsub[dir;"sub1";dp;"rdb"];
  s2:startsub[dir;"sub2";dp;"none"];
  if[any null (s1`h;s2`h);kill9 each (d;rdb;hdb;s1;s2);:chk enlist[`subsup]!enlist 0b];
  pushed:waitfor[{[s;x] 1=count subknown s}[s1];40];
  connected:waitfor[{[s;x] 1=count subconnected s}[s1];80];          / the subscriber's own 10s retry opens it
  a:`subsup`answered`pushed`onlyrdb`connected`hpup`controlgotnothing`onesub`subwants!(
    1b;
    (enlist`rdb1)~exec procname from s1[`h]"ANSWER";
    pushed;
    (enlist`rdb)~exec proctype from subknown s1;
    connected;
    (enlist `$":localhost:",string rp)~exec hpup from subknown s1;
    0=count subknown s2;
    1=count discsubs d;
    (enlist enlist`rdb)~exec proctypes from discsubs d);
  kill9 each (d;rdb;hdb;s1;s2);
  chk a
  };

latearrival:{[]
  / a backend added to the phone book after discovery started is found on the next tick and pushed to an ALL
  / subscriber; a dead backend leaves the live view and returns when it comes back
  rp:freeport[]; hp:freeport[]; rp2:freeport[]; dp:freeport[];
  dir:scenario["latearrival";((rp;`rdb;`rdb1);(hp;`hdb;`hdb1));dp];
  rdb:startpeer["rdb1";rp];
  hdb:startpeer["hdb1";hp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  s1:startsub[dir;"sub1";dp;"ALL"];
  if[null s1`h;kill9 each (d;rdb;hdb;s1);:chk enlist[`subsup]!enlist 0b];
  initial:waitfor[{[s;x] 2=count subknown s}[s1];40];
  / late arrival: a new row in process.csv (plus an operator's garbage line) and a process behind it
  (hsym`$dir,"/process.csv") 0: (read0 hsym`$dir,"/process.csv"),enlist "this line is garbage";
  appendcsvrow[dir,"/process.csv";(rp2;`rdb;`rdb2)];
  rdb2:startpeer["rdb2";rp2];
  late:waitfor[{[d;x] `rdb2 in exec procname from disclive d}[d];40];
  latepushed:waitfor[{[s;x] `rdb2 in exec procname from subknown s}[s1];40];
  / a backend dies: it leaves the live view (the .z.pc observer on discovery's servers marks it) ...
  kill9 hdb;
  gone:waitfor[{[d;x] not `hdb1 in exec procname from disclive d}[d];60];
  / ... and comes back on the same port: discovery's servers retry reconnects it and it is live again
  hdb:startpeer["hdb1";hp];
  back:waitfor[{[d;x] `hdb1 in exec procname from disclive d}[d];80];
  a:`subsup`initial`late`latepushed`gone`back`subhasall`noeviction!(1b;initial;late;latepushed;gone;back;
    (`hdb1`rdb1`rdb2)~asc exec procname from subknown s1;
    0=logmatches["disc1";"evicted"]);
  kill9 each (d;rdb;hdb;rdb2;s1);
  chk a
  };

nontorq:{[]
  / a process listed only in nontorqprocess.csv is tracked and pushed exactly like a TorQ one; with tracking off it
  / is ignored; a relative nontorqprocessfile resolves beside process.csv
  rp:freeport[]; pp:freeport[]; dp:freeport[];
  dir:scenario["nontorq";enlist (rp;`rdb;`rdb1);dp];
  writecsvrows[dir,"/nontorqprocess.csv";enlist (pp;`pricer;`pricer1)];
  rdb:startpeer["rdb1";rp];
  pricer:startpeer["pricer1";pp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  s1:startsub[dir;"sub1";dp;"pricer"];
  if[null s1`h;kill9 each (d;rdb;pricer;s1);:chk enlist[`subsup]!enlist 0b];
  found:waitfor[{[d;x] `pricer1 in exec procname from disclive d}[d];40];
  pushed:waitfor[{[s;x] `pricer1 in exec procname from subknown s}[s1];40];
  / the non-TorQ file is deleted: what only it listed is decommissioned - on discovery and on the subscriber
  system "rm -f ",dir,"/nontorqprocess.csv";
  evicted:waitfor[{[d;x] not `pricer1 in exec procname from d[`h]"registry[]"}[d];40];
  subevicted:waitfor[{[s;x] not `pricer1 in exec procname from subknown s}[s1];40];
  / the SAME file comes back unchanged: its rows were evicted, so they must be dialled (live in the real
  / registry, not just requested) and pushed again - not skipped as already seen
  writecsvrows[dir,"/nontorqprocess.csv";enlist (pp;`pricer;`pricer1)];
  returned:waitfor[{[d;x] `pricer1 in exec procname from disclive d}[d];40];
  subreturned:waitfor[{[s;x] `pricer1 in exec procname from subknown s}[s1];40];
  system "rm -f ",dir,"/nontorqprocess.csv";
  kill9 each (d;s1);
  / the file appears AFTER startup: warned once, then tracked from the tick it shows up
  dl:startdiscoverynamed[dir;dp;"disclate";""];
  system "sleep 2.5";
  warnedonce:1=logmatches["disclate";"does not exist"];
  writecsvrows[dir,"/nontorqprocess.csv";enlist (pp;`pricer;`pricer1)];
  latefound:$[null dl`h;0b;waitfor[{[d;x] `pricer1 in exec procname from disclive d}[dl];40]];
  stillonce:1=logmatches["disclate";"does not exist"];
  kill9 dl;
  / tracking off: the same file is ignored
  d2:startdiscovery[dir;dp;"-tracknontorqprocess false"];
  system "sleep 3";
  offignored:$[null d2`h;0b;not `pricer1 in exec procname from disclive d2];
  kill9 d2;
  / a relative nontorqprocessfile resolves beside process.csv
  writecsvrows[dir,"/other.csv";enlist (pp;`pricer;`pricer1)];
  d3:startdiscovery[dir;dp;"-nontorqprocessfile other.csv"];
  relfound:$[null d3`h;0b;waitfor[{[d;x] `pricer1 in exec procname from disclive d}[d3];40]];
  relpath:$[null d3`h;0b;(dir,"/other.csv")~d3[`h] SM,"ntfile"];
  kill9 each (d3;rdb;pricer);
  chk `found`pushed`evicted`subevicted`returned`subreturned`warnedonce`latefound`stillonce`offignored`relfound`relpath!(
    found;pushed;evicted;subevicted;returned;subreturned;warnedonce;latefound;stillonce;offignored;relfound;relpath)
  };

subscriberleaves:{[]
  / a subscriber that dies is forgotten (the .z.pc observer) and discovery keeps ticking
  rp:freeport[]; dp:freeport[];
  dir:scenario["leaves";enlist (rp;`rdb;`rdb1);dp];
  rdb:startpeer["rdb1";rp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  s1:startsub[dir;"sub1";dp;"ALL"];
  if[null s1`h;kill9 each (d;rdb;s1);:chk enlist[`subsup]!enlist 0b];
  had:waitfor[{[d;x] 1=count discsubs d}[d];40];
  kill9 s1;
  dropped:waitfor[{[d;x] 0=count discsubs d}[d];40];
  system "sleep 3";
  stillalive:alive d`pid;
  stillserving:(enlist`rdb1)~exec procname from discservices[d;`ALL];
  / the subscriber comes back (a new process - the OS may well hand its connection the SAME fd number the dead one
  / had, which is exactly why the .z.pc drop above matters): it re-subscribes itself, now for rdb only, and the
  / recorded subscription is the new one
  s1b:startsub[dir;"sub1b";dp;"rdb"];
  resubscribed:$[null s1b`h;0b;waitfor[{[d;x] 1=count discsubs d}[d];40]];
  newwant:$[null s1b`h;0b;(enlist enlist`rdb)~exec proctypes from discsubs d];
  repushed:$[null s1b`h;0b;waitfor[{[s;x] `rdb1 in exec procname from subknown s}[s1b];40]];
  kill9 each (d;rdb;s1b);
  chk `had`dropped`stillalive`stillserving`resubscribed`newwant`repushed!(had;dropped;stillalive;stillserving;resubscribed;newwant;repushed)
  };

decommission:{[]
  / a process REMOVED from process.csv while still running is evicted from discovery's registry, an ALL subscriber
  / is told (its own registry drops the row and closes its handle - the process ends up with no connection from
  / either), and it comes back when the line is restored. a process that merely dies is latearrival's case: it
  / stays known and returns on retry
  rp:freeport[]; hp:freeport[]; dp:freeport[];
  dir:scenario["decommission";((rp;`rdb;`rdb1);(hp;`hdb;`hdb1));dp];
  rdb:startpeer["rdb1";rp];
  hdb:startpeer["hdb1";hp];
  d:startdiscovery[dir;dp;""];
  if[null d`h;:chk enlist[`discoveryup]!enlist 0b];
  s1:startsub[dir;"sub1";dp;"ALL"];
  if[null s1`h;kill9 each (d;rdb;hdb;s1);:chk enlist[`subsup]!enlist 0b];
  initial:waitfor[{[s;x] 2=count subconnected s}[s1];80];
  before:hdb[`h]"count key .z.W";                                           / parent + discovery + subscriber
  / the operator drops hdb1 from the phone book; the process itself keeps running
  writecsvrows[dir,"/process.csv";((rp;`rdb;`rdb1);(dp;`discovery;`disc1))];
  evicted:waitfor[{[d;x] not `hdb1 in exec procname from d[`h]"registry[]"}[d];40];
  subevicted:waitfor[{[s;x] not `hdb1 in exec procname from subknown s}[s1];40];
  disconnected:waitfor[{[c;x] 1=c[`h]"count key .z.W"}[hdb];40];            / only the parent's handle is left
  a:`subsup`initial`threeconns`evicted`logged`subevicted`disconnected`stillalive`rdbuntouched!(
    1b;
    initial;
    3=before;
    evicted;
    0<logmatches["disc1";"evicted 1 row(s) no longer in any phone book: hdb1/hdb@"];
    subevicted;
    disconnected;
    alive hdb`pid;
    `rdb1 in exec procname from subconnected s1);
  / the line is restored: found, dialled and pushed again
  appendcsvrow[dir,"/process.csv";(hp;`hdb;`hdb1)];
  a[`back]:waitfor[{[d;x] `hdb1 in exec procname from disclive d}[d];40];
  a[`subback]:waitfor[{[s;x] `hdb1 in exec procname from subconnected s}[s1];80];
  kill9 each (d;rdb;hdb;s1);
  chk a
  };

/ --- a real di.torq boot through torqx_init.q ---
torqxhome:{[] p:.Q.m.mp`di.torq; p:$[10h=type p;p;string p]; p:$[":"=first p;1_p;p]; "/" sv -2_"/" vs p};

stackapp:{[]
  / a minimal app: a default toml and a discovery proctype toml with flat keys
  app:IBASE,"/app";
  system "mkdir -p ",app,"/appconfig/settings";
  (hsym`$app,"/appconfig/settings/default.toml") 0: enlist "# app defaults";
  (hsym`$app,"/appconfig/settings/discovery.toml") 0: ("retryperiod = 2";"tracknontorqprocess = false");
  app
  };

startstack:{[app;proctype;procname;port]
  / launch exactly as torqx.sh does: QINIT=torqx_init.q with explicit identity and a stack id
  ident:" -proctype ",(string proctype)," -procname ",(string procname)," -torqxstackid itest";
  cmd:"QINIT=",torqxhome[],"/di/torq/bin/torqx_init.q ",QBIN," -q -p ",(string port),ident;
  pid:"J"$first system cmd," </dev/null >>",IBASE,"/stack_",(string procname),".log 2>&1 & echo $!";
  `PIDS set PIDS,pid;
  `pid`port`h!(pid;port;waitopen[port;120])};

autosubapp:{[]
  / a second minimal app: a custom `sub proctype (its init only runs servers' startup with its own connections) that
  / lists discovery in connections and narrows what it wants - the two-key consumer contract, zero module code
  app:IBASE,"/app2";
  system "mkdir -p ",app,"/appconfig/settings ",app,"/code/processes";
  (hsym`$app,"/appconfig/settings/default.toml") 0: enlist "# app defaults";
  (hsym`$app,"/appconfig/settings/discovery.toml") 0: ("retryperiod = 2";"tracknontorqprocess = false");
  (hsym`$app,"/appconfig/settings/sub.toml") 0: ("connections = [\"discovery\"]";"discoverywant = \"rdb\"");
  (hsym`$app,"/code/processes/sub.q") 0: ("\\d .sub";"init:{[config;deps] (deps[`servers]`startup)[config];};";"\\d .");
  app
  };

subreg:{[c] c[`h]"select procname,proctype,hpup,w from (use`di.torq.servers)[`getallservers][]"};

autosubscribe:{[]
  / the consumer half, end to end through a real di.torq boot: a `sub process (connections=discovery, discoverywant=rdb)
  / is subscribed on BOTH discovery instances by di.torq's generic job with nothing but config; the two discovery
  / instances - which dial each other - never subscribe to one another (the load-bearing invariant of stateless
  / eviction), re-checked after a full job cycle; a restarted discovery is re-subscribed with no intervention
  app:autosubapp[];
  setenv[`TORQXHOME;torqxhome[]];
  setenv[`TORQXAPPCONFIG;app,"/appconfig"];
  setenv[`TORQXAPPHOME;app];
  setenv[`TORQXDATAHOME;app];
  rp:freeport[]; d1p:freeport[]; d2p:freeport[]; sp:freeport[];
  writecsvrows[app,"/appconfig/process.csv";((rp;`rdb;`rdb1);(d1p;`discovery;`disc1);(d2p;`discovery;`disc2);(sp;`sub;`sub1))];
  rdb:startpeer["rdb1";rp];
  d1:startstack[app;`discovery;`disc1;d1p];
  d2:startstack[app;`discovery;`disc2;d2p];
  if[any null (d1`h;d2`h);kill9 each (rdb;d1;d2);:chk enlist[`discoveryup]!enlist 0b];
  s1:startstack[app;`sub;`sub1;sp];
  if[null s1`h;kill9 each (rdb;d1;d2;s1);:chk enlist[`subup]!enlist 0b];
  subs1:waitfor[{[d;x] 1=count discsubs d}[d1];40];
  subs2:waitfor[{[d;x] 1=count discsubs d}[d2];40];
  pushed:waitfor[{[s;x] `rdb1 in exec procname from subreg s}[s1];40];
  connected:waitfor[{[s;x] not null first exec w from subreg s where procname=`rdb1}[s1];80];
  system "sleep 13";                                                        / more than one full 10s job cycle
  a:`subs1`subs2`want1`want2`pushed`connected`stillone1`stillone2`loggedonce`quiet!(
    subs1;
    subs2;
    (enlist enlist`rdb)~exec proctypes from discsubs d1;
    (enlist enlist`rdb)~exec proctypes from discsubs d2;
    pushed;
    connected;
    1=count discsubs d1;
    1=count discsubs d2;
    1=logmatches["stack_sub1";"subscribed to discovery on 2 handle(s) for rdb"];
    0=count (childlog "stack_sub1") where (childlog "stack_sub1") like "*ERROR] *");
  / disc1 restarts: sub1's own servers retry reconnects (<=10s), then the next job cycle (<=10s) re-subscribes
  kill9 d1;
  d1b:startstack[app;`discovery;`disc1;d1p];
  a[`resubscribed]:$[null d1b`h;0b;waitfor[{[d;x] 1=count discsubs d}[d1b];120]];
  a[`rewant]:$[null d1b`h;0b;(enlist enlist`rdb)~exec proctypes from discsubs d1b];
  a[`relogged]:2<=logmatches["stack_sub1";"subscribed to discovery on"];
  a[`d2unaffected]:1=count discsubs d2;
  {@[x`h;"exit 0";{}]} each (d1b;d2;s1);
  system "sleep 1";
  kill9 each (rdb;d1b;d2;s1);
  setenv[`TORQXAPPHOME;IBASE];
  setenv[`TORQXDATAHOME;IBASE];
  chk a
  };

stackboot:{[]
  / kdb-x abandons a QINIT script silently at the first error and leaves the process at its prompt, so a boot failure
  / looks like a running process: assert the module's observable effects, never just "it came up"
  app:stackapp[];
  setenv[`TORQXHOME;torqxhome[]];
  setenv[`TORQXAPPCONFIG;app,"/appconfig"];
  setenv[`TORQXAPPHOME;app];
  setenv[`TORQXDATAHOME;app];
  rp:freeport[]; dp:freeport[];
  writecsvrows[app,"/appconfig/process.csv";((rp;`rdb;`rdb1);(dp;`discovery;`disc1))];
  rdb:startpeer["rdb1";rp];
  d:startstack[app;`discovery;`disc1;dp];
  if[null d`h;kill9 rdb;:chk enlist[`discoveryup]!enlist 0b];
  found:waitfor[{[d;x] (enlist`rdb1)~exec procname from discservices[d;`ALL]}[d];40];
  a:`identity`retryperiod`nontorqoff`hopentimeout`rootnames`found`pchandlers!(
    (`discovery;`disc1)~d[`h]"(",SM,"self`proctype;",SM,"self`procname)";
    2=d[`h] SM,"retryperiod";
    not d[`h] SM,"tracknontorqprocess";
    200=d[`h]".m.di.0torq.0servers.hopentimeout";
    d[`h]"all `getservices`getsubs in key `.discovery";
    found;
    all `servers`discovery in d[`h]"exec name from (use`di.torq.handlers)[`list]`.z.pc");
  @[d`h;"exit 0";{}];
  system "sleep 1";
  kill9 rdb;
  setenv[`TORQXAPPHOME;IBASE];
  setenv[`TORQXDATAHOME;IBASE];
  chk a
  };
