/ di.servers live-peer integration test helpers (loaded by test.csv).
/ recording mock deps + a genuinely separate spawned q peer: hopen to a port THIS process is
/ listening on returns a pseudo-handle 0 and never exercises real disconnect/retry/cleanup, so we
/ spawn a real peer (the licensed q via QHOME) to dial.

/ --- recording mock dependencies ---
logrows:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklog:`info`warn`error!(
  {[c;m]`logrows upsert(`info;c;m)};
  {[c;m]`logrows upsert(`warn;c;m)};
  {[c;m]`logrows upsert(`error;c;m)});

/ REAL di.timer - di.servers is its first consumer, so we integrate against the merged module (not a
/ mock's guess at the addjob contract) to prove the addjob[`custom] wiring end-to-end. di.servers does
/ NOT call timer.init, so no .z.ts cycle starts here: init adds the serversretry job to di.timer's jobs
/ table, and firejob invokes the stored func manually - exactly what the timer's cycle would do.
rtmr:use`di.timer;

/ handlers mock: records (event;name) with di.handlers' register[event;phase;nm;pri;func] shape. it
/ does NOT actually bind .z.pc - so the only cleanup path exercised here is the explicit retry->
/ cleanup, tested in isolation from the auto .z.pc hook (which di.handlers would install for real).
handlercalls:([]event:`symbol$();name:`symbol$());
mockhandlers:`register`remove`list!(
  {[ev;ph;nm;pri;fn]`handlercalls upsert(ev;nm)};
  {[ev;ph;nm]};
  {[ev]});

warnlogged:{[s] any (exec msg from logrows where lvl=`warn) like "*",s,"*"};
/ fire a scheduled job's stored func exactly as the real di.timer's cycle would (retry/cleanup are
/ INTERNAL - not exported - so this is the only handle on them: the func di.servers gave the timer).
firejob:{[jid] (first exec func from rtmr.getalljobs[] where id=jid)[]};

/ --- real peer process fixture ---
FIXDIR:"/tmp/diserverstest";
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
pickport:{[start] first (start+til 500) where isfree each start+til 500};
PEERPORT:0N; DEADPORT:0N; PEERPID:0N;

waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  not isfree port};

spawnpeer:{[]
  / launch the licensed q (via QHOME) as a detached listener; wait until it accepts connections,
  / then grab its pid over IPC (.z.i) for an exact-pid kill later.
  system (getenv[`QHOME]),"/bin/q -p ",string[PEERPORT]," -q </dev/null >/dev/null 2>&1 &";
  if[not waitlisten[PEERPORT;3000];'"test: peer failed to listen on ",string PEERPORT];
  h:hopen (`$":localhost:",string PEERPORT;2000);
  PEERPID::h ".z.i";
  hclose h;};

killpeer:{[] if[not null PEERPID;@[system;"kill ",string PEERPID;{}]]; PEERPID::0N; system "sleep 0.3";};

setupfixture:{[]
  / pick two free ports (peer + a never-listening dead one), then write a header'd process.csv
  / phone book with self, the peer (otherproc), and a dead proctype.
  PEERPORT::pickport 20000+`int$.z.i mod 20000;
  DEADPORT::pickport PEERPORT+1;
  system "mkdir -p ",FIXDIR;
  (`$":",FIXDIR,"/process.csv") 0: (
    "host,port,proctype,procname";
    "localhost,",string[PEERPORT-2],",selfproc,selfinst";
    "localhost,",string[PEERPORT],",otherproc,otherinst";
    "localhost,",string[DEADPORT],",deadproc,deadinst");
  };

teardownfixture:{[] killpeer[]; system "rm -rf ",FIXDIR;};

/ build the deps dict di.torq would assemble: injectables + this process's config slice.
svrdeps:{[conns] `log`timer`handlers`proctype`procname`connections`processcsv!(mocklog;rtmr;mockhandlers;`selfproc;`selfinst;conns;FIXDIR,"/process.csv")};
