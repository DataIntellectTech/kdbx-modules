/ di.torq.servers live-peer integration test helpers (loaded by test.csv).
/ recording mock deps + genuinely separate spawned q peers: hopen to a port THIS process is
/ listening on returns a pseudo-handle 0 and never exercises real disconnect/retry/cleanup, so we
/ spawn real peers to dial - a plain listener (otherproc) and a kdb-x peer that has loaded
/ di.torq.servers itself (modpeer), to prove .torq.servers.addprocs is reachable over IPC by name.

/ --- recording mock dependencies ---
logrows:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklog:`info`warn`error!(
  {[c;m]`logrows upsert(`info;c;m)};
  {[c;m]`logrows upsert(`warn;c;m)};
  {[c;m]`logrows upsert(`error;c;m)});

/ timer mock: records (id;period) for the wiring asserts AND captures each job's func by id, so a
/ test can fire the retry cycle exactly as the real timer would (retry/cleanup are INTERNAL - not
/ exported - so they are driven only via this captured callback).
timercalls:([]id:`symbol$();period:`long$());
timerjobs:(`symbol$())!();
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] timerjobs[id]:func; `timercalls upsert (id;period);};

/ handlers mock: records (event;name) with di.torq.handlers' register[event;phase;nm;pri;func] shape. it
/ does NOT actually bind .z.pc - so the only cleanup path exercised here is the explicit retry->
/ cleanup, tested in isolation from the auto .z.pc hook (which di.torq.handlers would install for real).
handlercalls:([]event:`symbol$();name:`symbol$());
mockhandlers:`register`remove`list!(
  {[ev;ph;nm;pri;fn]`handlercalls upsert(ev;nm)};
  {[ev;ph;nm]};
  {[ev]});

warnlogged:{[s] any (exec msg from logrows where lvl=`warn) like "*",s,"*"};
infologged:{[s] any (exec msg from logrows where lvl=`info) like "*",s,"*"};
firejob:{[id] timerjobs[id][]};

/ --- real peer process fixture ---
FIXDIR:"/tmp/diserverstest";
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
pickport:{[start] first (start+til 500) where isfree each start+til 500};
PEERPORT:0N; DEADPORT:0N; MOVEDPORT:0N; MODPEERPORT:0N; PEERPID:0N; MODPEERPID:0N;

/ the q binary to spawn peers with: THIS process's own executable (so the kdb-x peer gets the same
/ build and licence), falling back to $QHOME/bin/q, then whatever `q` is on PATH.
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;count qh:getenv`QHOME;qh,"/bin/q";"q"]}[];
/ this module's directory (for the kdb-x peer's script), from the module path registry
moddir:{[] p:.Q.m.mp`di.torq.servers; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};

waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  not isfree port};

pidof:{[port]
  / grab a just-spawned peer's pid over IPC (.z.i) for an exact-pid kill later
  h:hopen (`$":localhost:",string port;2000);
  pid:h ".z.i";
  hclose h;
  pid};

spawnpeer:{[]
  / launch a plain q listener (otherproc); wait until it accepts connections.
  system QBIN," -p ",string[PEERPORT]," -q </dev/null >/dev/null 2>&1 &";
  if[not waitlisten[PEERPORT;3000];'"test: peer failed to listen on ",string PEERPORT];
  PEERPID::pidof PEERPORT;};

spawnmodpeer:{[]
  / launch a kdb-x peer that has loaded di.torq.servers under its own identity (modpeer/modpeer1),
  / so the suite can call its root-published .torq.servers.addprocs over a real handle.
  system QBIN," ",moddir[],"/test_modpeer.q -p ",string[MODPEERPORT]," -q </dev/null >",FIXDIR,"/modpeer.log 2>&1 &";
  if[not waitlisten[MODPEERPORT;5000];'"test: modpeer failed to listen on ",string MODPEERPORT];
  MODPEERPID::pidof MODPEERPORT;};

killpid:{[pid] if[not null pid;@[system;"kill ",string pid;{}]];};
killpeer:{[] killpid PEERPID; PEERPID::0N; system "sleep 0.3";};
killmodpeer:{[] killpid MODPEERPID; MODPEERPID::0N; system "sleep 0.3";};

setupfixture:{[]
  / pick two free ports (peer + a never-listening dead one), then write a header'd process.csv
  / phone book with self, the peer (otherproc), and a dead proctype.
  PEERPORT::pickport 20000+`int$.z.i mod 20000;
  DEADPORT::pickport PEERPORT+1;
  MOVEDPORT::pickport DEADPORT+1;
  MODPEERPORT::pickport MOVEDPORT+1;
  system "mkdir -p ",FIXDIR;
  writeprocs PEERPORT;
  };

/ write the fixture phone book with otherproc on the given port (setupfixture, and movepeerport)
writeprocs:{[otherport]
  (`$":",FIXDIR,"/process.csv") 0: (
    "host,port,proctype,procname";
    "localhost,",string[PEERPORT-2],",selfproc,selfinst";
    "localhost,",string[otherport],",otherproc,otherinst";
    "localhost,",string[DEADPORT],",deadproc,deadinst");
  };

/ simulate an operator moving otherproc to a new (dead) port in process.csv
movepeerport:{[] writeprocs MOVEDPORT;};

teardownfixture:{[] killpeer[]; killmodpeer[]; system "rm -rf ",FIXDIR;};

/ --- addprocs fixtures (a pushed dead row + the self row, which must be dropped) ---
pushhp:{[port] `$":localhost:",string port};
pushrows:{[] ([]procname:`pushed1`selfinst;proctype:`pushedproc`selfproc;hpup:(pushhp DEADPORT+1;pushhp 1))};
onerow:{[nm;pt;port] ([]procname:enlist nm;proctype:enlist pt;hpup:enlist pushhp port)};
/ the kdb-x peer's own SERVERS, read over the handle
peerservers:{[h] h "(use`di.torq.servers)[`getallservers][]"};

/ build the deps dict di.torq would assemble: injectables + this process's config slice.
svrdeps:{[conns] `log`timer`handlers`proctype`procname`connections`processcsv!(mocklog;mocktimer;mockhandlers;`selfproc;`selfinst;conns;FIXDIR,"/process.csv")};

/ true if a dial to a non-routable address returns within the instance hopentimeout (plus slack) -
/ or instantly, on a box whose network stack rejects the route outright (nothing to time then)
dialwithin:{[ms]
  t:.z.p;
  .m.di.0torq.0servers.opencon `:10.255.255.1:5000;
  took:(.z.p-t)%1000000;
  (took<50) or took within (ms-50;ms+800)};
