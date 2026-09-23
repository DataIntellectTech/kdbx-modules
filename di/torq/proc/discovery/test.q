/ di.torq.proc.discovery unit test helpers (loaded by test.csv).
/ recording mock deps (log/timer/handlers/servers - the servers mock carries a FAKE registry so
/ the live filter, discovery exclusion and per-subscriber slicing are exercised without sockets),
/ plus ONE genuinely separate plain-q peer carrying a recording .torq.servers.addprocs stub so
/ pushes can be asserted on. a subscription is keyed on a real open handle: here the test's own
/ OUTBOUND handle to the peer (it is in key .z.W, so pushes reach the peer), recorded through the
/ internal recordsub. it cannot be the peer's INBOUND handle (.z.w of a remote call): a k4unit
/ run never returns to the main loop, and a process blocked in a sync call does not service a
/ peer's connect/call back into it (measured - it deadlocks), so the genuine
/ .discovery.getservices-over-IPC path is covered by test_integration.csv instead.

/ --- recording mock dependencies ---
logrows:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklog:`info`warn`error!(
  {[c;m]`logrows upsert(`info;c;m)};
  {[c;m]`logrows upsert(`warn;c;m)};
  {[c;m]`logrows upsert(`error;c;m)});
logged:{[lv;s] any (exec msg from logrows where lvl=lv) like "*",s,"*"};
infologged:logged[`info];
warnlogged:logged[`warn];
errlogged:logged[`error];
warncount:{[s] count select from logrows where lvl=`warn,msg like ("*",s,"*")};
errcount:{[s] count select from logrows where lvl=`error,msg like ("*",s,"*")};

/ timer mock: records (id;period;opts) and captures each job's func by id so a test can fire the
/ tick exactly as the real timer would (with its one null arg)
timercalls:([]id:`symbol$();period:`long$();opts:());
timerjobs:(`symbol$())!();
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] timerjobs[id]:func; `timercalls upsert (id;period;opts);};
firejob:{[id] timerjobs[id][`]};

/ handlers mock: records (event;name) with di.torq.handlers' register shape and captures the func so
/ the .z.pc observer can be fired by hand with a handle
handlercalls:([]event:`symbol$();name:`symbol$());
handlerfuncs:(`symbol$())!();
mockhandlers:`register`remove`list!(
  {[ev;ph;nm;pri;fn] handlerfuncs[nm]:fn; `handlercalls upsert(ev;nm)};
  {[ev;ph;nm]};
  {[ev]});
firepc:{[wh] handlerfuncs[`discovery] wh};

/ servers mock: a FAKE registry in the real SERVERS shape (rdb1/hdb1 live, rdb2 dead, disc2 a live
/ discovery peer that must never be handed out - every one of them LISTED in the fixture phone
/ book, or eviction would drop it), a record of every startup call, and a removeprocs that really
/ deletes from FAKE (recording what it was given)
FAKE:([]procname:`rdb1`hdb1`rdb2`disc2;proctype:`rdb`hdb`rdb`discovery;hpup:`:localhost:1`:localhost:2`:localhost:3`:localhost:4;
  w:1 2 0N 4i;hits:4#0i;startp:4#0Np;lastp:4#0Np;endp:4#0Np);
startupcalls:([]connections:();processcsv:());
removecalls:();
fakeremove:{[rows]
  removecalls,:enlist rows;
  hit:(select procname,proctype,hpup from FAKE) in rows;
  FAKE::FAKE where not hit;
  sum hit};
/ STARTUPFAIL makes the next startup call throw once (servers re-reading a file mid-rewrite)
STARTUPFAIL:0b;
mockservers:`startup`getservers`getallservers`removeprocs!(
  {[c] `startupcalls upsert ([]connections:enlist c`connections;processcsv:enlist c`processcsv);
    if[STARTUPFAIL;STARTUPFAIL::0b;'"mock: process.csv unreadable"]};
  {[pt] select from FAKE where proctype=pt,not null w};
  {[] FAKE};
  fakeremove);
mockdeps:{[] `log`timer`handlers`servers!(mocklog;mocktimer;mockhandlers;mockservers)};
livefake:{[] distinct select procname,proctype,hpup from FAKE where not null w,not proctype=`discovery};
/ plant a registry row as servers would hold it after dialling (wh null = known but down)
fakerow:{[nm;pt;hp;wh] `FAKE upsert (nm;pt;hp;wh;0i;0Np;0Np;0Np);};
lastremoved:{[] last removecalls};
row3:{[nm;pt;hp] ([]procname:enlist nm;proctype:enlist pt;hpup:enlist hp)};

/ --- fixture: phone books + a plain-q peer that dials back in ---
FIXDIR:"/tmp/didiscoverytest";
PROCFILE:FIXDIR,"/process.csv";
NTFILE:FIXDIR,"/nontorqprocess.csv";
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
pickport:{[start] first (start+til 500) where isfree each start+til 500};
PEERPORT:0N; PEERPID:0N; PEERH:0Ni;
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;count qh:getenv`QHOME;qh,"/bin/q";"q"]}[];

waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  not isfree port};

setupfixture:{[]
  PEERPORT::pickport 21000+`int$.z.i mod 20000;
  system "mkdir -p ",FIXDIR;
  (hsym`$PROCFILE) 0: (
    "host,port,proctype,procname";
    "localhost,5010,rdb,rdb1";
    "localhost,5011,hdb,hdb1";
    "localhost,5012,rdb,rdb2";
    "localhost,5013,discovery,disc1";
    "localhost,5019,discovery,disc2");
  };
/ drop the phone-book line(s) matching a pattern (a process decommissioned by the operator)
dropline:{[pat] l:read0 hsym`$PROCFILE; (hsym`$PROCFILE) 0: l where not l like pat;};
writentfile:{[] (hsym`$NTFILE) 0: ("host,port,proctype,procname";"localhost,5020,pricer,pricer1");};
removentfile:{[] system "rm -f ",NTFILE;};
/ append raw csv lines to the phone book (a late arrival, or a deliberately undialable row)
appendprocs:{[lines] (hsym`$PROCFILE) 0: (read0 hsym`$PROCFILE),lines;};
/ how many "pushed ..." lines the module has logged so far
pushlogcount:{[] count select from logrows where lvl=`info,msg like "pushed *"};
/ the servers contract as it was in 0.4.0 (no removeprocs)
oldservers:{[] `startup`getservers`getallservers!(mockservers`startup;mockservers`getservers;mockservers`getallservers)};
/ the minimal contract this module actually calls
minservers:{[] `startup`getallservers`removeprocs!(mockservers`startup;mockservers`getallservers;mockservers`removeprocs)};
withservers:{[svd] `log`timer`handlers`servers!(mocklog;mocktimer;mockhandlers;svd)};

/ the config di.torq would hand this process (flat keys + the stamped identity/processcsv)
basecfg:{[] `processcsv`proctype`procname!(PROCFILE;`discovery;`disc1)};
cfg:{[] basecfg[],enlist[`retryperiod]!enlist 7};

spawnpeer:{[]
  / a plain q listener that records what is pushed at its .torq.servers.addprocs
  system QBIN," -p ",string[PEERPORT]," -q </dev/null >/dev/null 2>&1 &";
  if[not waitlisten[PEERPORT;3000];'"test: peer failed to listen on ",string PEERPORT];
  PEERH::hopen (`$":localhost:",string PEERPORT;2000);
  PEERPID::PEERH ".z.i";
  PEERH "RECV:(); RMRECV:(); ORDER:()";
  PEERH ".torq.servers.addprocs:{RECV,:enlist x; ORDER,:`add; count x}";
  PEERH ".torq.servers.removeprocs:{RMRECV,:enlist x; ORDER,:`rm; count x}";
  };
killpeer:{[] if[not null PEERPID;@[system;"kill ",string PEERPID;{}]]; PEERPID::0N; PEERH::0Ni; system "sleep 0.3";};
teardownfixture:{[] killpeer[]; system "rm -rf ",FIXDIR;};

/ module internals reachable by the mangled module name (the api is via exports; these drive the
/ two paths a single-process suite cannot reach through the api - see the header)
SM:".m.di.0torq.0proc.0discovery.";
mstate:{[nm] value SM,nm};
/ subscribe the peer: record its (real, open) handle exactly as a remote getservices[..;1b] would
subscribevia:{[types] mstate["recordsub"][PEERH;types,()];};
/ what the peer has received so far (a list of pushed tables) - async pushes are ordered before
/ this sync read on the same handle, so it sees everything the last tick sent
received:{[] PEERH "RECV"};
lastreceived:{[] r:received[]; $[count r;last r;0#livefake[]]};
/ the removals the peer has received (a list of tables) and the order of every call it took
rmreceived:{[] PEERH "RMRECV"};
peerorder:{[] PEERH "ORDER"};
subhandle:{[] first exec handle from d.getsubs[]};
/ plant a bogus (never-open) subscriber handle to drive the push-failure path
plantbogus:{[] value SM,"subs[999i]:enlist`ALL";};
