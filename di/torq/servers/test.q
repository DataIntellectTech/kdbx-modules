/ di.torq.servers live-peer integration test helpers (loaded by test.csv).
/ recording mock deps + a genuinely separate spawned q peer: hopen to a port THIS process is
/ listening on returns a pseudo-handle 0 and never exercises real disconnect/retry/cleanup, so we
/ spawn a real peer to dial.

/ --- recording mock dependencies ---
logrows:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklog:`info`warn`error!(
  {[c;m]`logrows upsert(`info;c;m)};
  {[c;m]`logrows upsert(`warn;c;m)};
  {[c;m]`logrows upsert(`error;c;m)});

/ timer mock: records (id;period;mode) for the wiring asserts AND captures each job's func by id, so a
/ test can fire the retry cycle exactly as the real timer would (retry/cleanup are INTERNAL - not
/ exported - so they are driven only via this captured callback).
timercalls:([]id:`symbol$();period:`timespan$();mode:`long$());
timerjobs:(`symbol$())!();
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] timerjobs[id]:func; `timercalls upsert (id;period;`long$mode);};

/ handlers mock: records (event;name) with di.torq.handlers' register[event;phase;nm;pri;func] shape. it
/ does NOT actually bind .z.pc - so the only cleanup path exercised here is the explicit retry->
/ cleanup, tested in isolation from the auto .z.pc hook (which di.torq.handlers would install for real).
handlercalls:([]event:`symbol$();name:`symbol$());
mockhandlers:`register`remove`list!(
  {[ev;ph;nm;pri;fn]`handlercalls upsert(ev;nm)};
  {[ev;ph;nm]};
  {[ev]});

warnlogged:{[s] any (exec msg from logrows where lvl=`warn) like "*",s,"*"};
firejob:{[id] timerjobs[id][]};

/ --- real peer process fixture ---
FIXDIR:"/tmp/diserverstest_",string .z.i;
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe";
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
PEERPORT:0N; DEADPORT:0N; PEERPID:0N;

/ an OS-assigned free port: a q started with -p 0W writes its port and exits before any connection is made,
/ so the port can be bound again (no port picking: a port with no listener can still be unbindable)
reserveport:{[]
  f:FIXDIR,"/port",string 1+count key hsym`$FIXDIR;
  (hsym`$FIXDIR,"/portprobe.q") 0: enlist "(hsym`$first .z.x) 0: enlist string system\"p\"; exit 0";
  system QBIN," ",FIXDIR,"/portprobe.q ",f," -p 0W -q </dev/null >/dev/null 2>&1";
  "J"$first read0 hsym`$f};

waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  not isfree port};

/ start q on port with args, logging to FIXDIR; wait until it listens and check the listener is the process
/ just spawned (its .z.i is the spawned pid); returns the pid
spawnat:{[args;port]
  pid:"J"$first system QBIN," ",args," -p ",(string port)," -q </dev/null >",FIXDIR,"/q",(string port),".log 2>&1 & echo $!";
  if[not waitlisten[port;3000];'"test: q failed to listen on ",(string port)," (see ",FIXDIR,"/q",(string port),".log)"];
  h:hopen (`$":localhost:",string port;2000);
  ok:pid=h ".z.i";
  hclose h;
  if[not ok;'"test: port ",(string port)," answered for a process this fixture did not spawn"];
  pid};

spawnpeer:{[] PEERPID::spawnat["";PEERPORT];};

killpeer:{[] if[not null PEERPID;@[system;"kill ",string PEERPID;{}]]; PEERPID::0N; system "sleep 0.3";};

setupfixture:{[]
  / reserve two ports (peer + a never-listening dead one), then write a header'd process.csv
  / phone book with self, the peer (otherproc), and a dead proctype.
  system "mkdir -p ",FIXDIR;
  PEERPORT::reserveport[];
  DEADPORT::reserveport[];
  (`$":",FIXDIR,"/process.csv") 0: (
    "host,port,proctype,procname";
    "localhost,",string[PEERPORT-2],",selfproc,selfinst";
    "localhost,",string[PEERPORT],",otherproc,otherinst";
    "localhost,",string[DEADPORT],",deadproc,deadinst");
  };

teardownfixture:{[] killpeer[]; killdisc[]; system "rm -rf ",FIXDIR;};

/ --- discovery-later fixture: a discovery stub naming one tpproc peer, started after startup ---
DISCPORT:0N; TPPORT:0N; DISCPIDS:`long$();

/ add a discovery row to process.csv, write the stub, and bind the .z.pc that addprocs calls
setupdisc:{[]
  .z.pc:{};
  DISCPORT::reserveport[];
  TPPORT::reserveport[];
  (`$":",FIXDIR,"/process.csv") 0: (read0 `$":",FIXDIR,"/process.csv"),enlist "localhost,",string[DISCPORT],",discovery,discinst";
  (`$":",FIXDIR,"/disc.q") 0: (
    "REGN:0;register:{[x] `REGN set REGN+1}";
    "getservices:{[p;s] ([]procname:enlist`tpinst;proctype:enlist`tpproc;hpup:enlist`$\":localhost:",string[TPPORT],"\";attributes:enlist()!())}");
  };

spawnq:{[args;port] DISCPIDS,:spawnat[args;port];};

spawndisc:{[] spawnq["";TPPORT]; spawnq[FIXDIR,"/disc.q";DISCPORT];};
killdisc:{[] {@[system;"kill ",string x;{}]} each DISCPIDS; DISCPIDS::`long$();};

/ addh to the live peer: the handle it returns works and is stored in SERVERS; the row is removed after
addhpeer:{[]
  W:.servers.addh `$":localhost:",string PEERPORT;
  r:(2=W"1+1";1=count select from .servers.SERVERS where w=W);
  delete from `.servers.SERVERS where w=W; hclose W;
  all r};

/ addprocs calls .servers.addprocscustom with the new rows and the procs; the hook and row are reset after
addprocshook:{[]
  / bind the .z.pc that addprocs' removerows calls, as setupdisc does; a fresh dead port so no fixture row is replaced
  .z.pc:{};
  `APC set ();
  .servers.addprocscustom:{[t;p] `APC set (exec procname from t;p)};
  .servers.addprocs[([]procname:enlist`newinst;proctype:enlist`newproc;hpup:enlist`$":localhost:",string reserveport[]);enlist`newproc;0b];
  .servers.addprocscustom:{[connectiontab;procs]};
  delete from `.servers.SERVERS where procname=`newinst;
  (enlist`newinst;enlist`newproc)~APC};

/ refreshattributes sends one register to each live discovery service
refreshregisters:{[]
  h:first exec w from .servers.getservers[`proctype;`discovery;()!();0b;0b];
  b:h"REGN";
  .servers.refreshattributes[];
  (b+1)=h"REGN"};

/ build the deps dict di.torq would assemble: injectables + this process's config slice.
/ discovery off, so startup dials process.csv directly (trackservers.q's own defaults are 1b).
svrdeps:{[conns] `log`timer`handlers`proctype`procname`connections`processcsv`discoveryregister`connectionsfromdiscovery!(mocklog;mocktimer;mockhandlers;`selfproc;`selfinst;conns;FIXDIR,"/process.csv";0b;0b)};
