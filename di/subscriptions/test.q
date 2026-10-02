/ fixture helpers for di.subscriptions' tests. Assumes cwd is the kdbx-modules repo root.
/ The tickerplant "handle" is mocked as a FUNCTION: subscribe calls tph(`.u.subdetails;..),
/ and `h(msg)` applies h to the message whether h is an int handle (real IPC) or a
/ function (here). The mock answers with a canned subdetails dict that points at a REAL
/ tp log built via di.tplogmgr, so replay is genuine. Real cross-process IPC subscribe is
/ covered by the torqx.sh end-to-end, not here.

BASE:"/tmp/di_subs_k4unit"
D:2026.07.13
LOGFILE:`

/ mock log (recording)
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}
timercalls:([]id:`symbol$();period:`long$();mode:`long$())
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] `timercalls upsert (id;`long$period;`long$mode);}
handlercalls:([]event:`symbol$();name:`symbol$())
mockhandlers:enlist[`register]!enlist {[ev;ph;nm;pri;fn] `handlercalls upsert (ev;nm);}
deps:{[] `log`timer`handlers!(mocklog[];mocktimer;mockhandlers)}

/ the trade schema a TP would return (g# on sym, as di.torq.proc.tickerplant applies)
tradeschema:{[] ([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())}

/ the root-namespace-safe upd di.torq.proc.rdb uses: append to the ROOT table t, handling a table
/ payload (live) or a list-of-columns payload (replay). @[`.;..] targets root explicitly
/ so it works even when di.tplogmgr's -11! replay executes upd from a module context (a bare
/ `insert` would resolve the table symbol in di.tplogmgr's namespace, not root).
rootupd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]]}

/ build a real tp log of n single-row trade messages (syms S0..S(n-1)); store LOGFILE
buildlog:{[n]
  tp:use`di.tplogmgr;
  system "rm -rf ",BASE; system "mkdir -p ",BASE;
  r:tp[`open][BASE;D]; h:r 0;
  {[tp;h;i] tp[`write][h;(`upd;`trade;(enlist D+0D00:00:01*i;enlist`$"S",string i;enlist 1.0*i;enlist`int$i))]}[tp;h] each til n;
  hclose h;
  `LOGFILE set tp[`logname][BASE;D];
  }

/ a mock TP handle (function): ignores the message, answers subdetails with a canned dict
/ referencing the real log + the given rowcount
mocktph:{[n] {[n;msg] `tables`schemas`logfile`rowcount`date!(enlist`trade;(enlist`trade)!enlist tradeschema[];LOGFILE;n;D)}[n]}

/ a real peer answering .sub.subscribe as a chained tickerplant, over the real log above
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]}
PEERPORT:0N; tph:0N
spawnpeer:{[]
  (`$":",BASE,"/peer.q") 0: (
    "tptype:`chained";
    "tablelist:{enlist`trade}";
    "subdetails:{[t;s] `schemalist`logfilelist`rowcounts`date!(enlist(`trade;([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$()));enlist(4;",(-3!LOGFILE),");(enlist`trade)!enlist 4;",(string D),")}");
  `PEERPORT set first p where isfree each p:30000+(`int$.z.i mod 20000)+til 500;
  system QBIN," ",BASE,"/peer.q -p ",(string PEERPORT)," -q </dev/null >/dev/null 2>&1 &";
  d:.z.p+0D00:00:03; while[(.z.p<d) and isfree PEERPORT; system "sleep 0.05"];
  `tph set hopen (`$":localhost:",string PEERPORT;2000);
  }
peerproc:{[] `procname`proctype`w!(`ctp1;`chainedtp;tph)}

/ a separate, idle client process with real handlers subscribes to a peer, the peer exits, and the
/ client's .z.pc must mark the subscription inactive (its timer is a mock, so checksubscriptions never runs)
pcclosecheck:{[]
  p:first p where isfree each p:40000+(`int$.z.i mod 20000)+til 500;
  system QBIN," -p ",(string p)," -q </dev/null >/dev/null 2>&1 &";
  d:.z.p+0D00:00:03; while[(.z.p<d) and isfree p; system "sleep 0.05"];
  c:hopen (`$":localhost:",string p;2000);
  c"sub:use`di.subscriptions; system \"l di/subscriptions/test.q\"; BASE::\"/tmp/di_subs_pcclose\"; buildlog[4]";
  c"hz:use`di.torq.handlers; (hz`init)[enlist[`log]!enlist mocklog[]]";
  c"sub.init[enlist[`autoreconnect]!enlist 0b;`log`timer`handlers!(mocklog[];mocktimer;`register`remove`list!(hz`register;hz`remove;hz`list))]";
  c"spawnpeer[]; .sub.subscribe[`trade;`;1b;0b;peerproc[]]";
  a:c"first exec active from .sub.SUBSCRIPTIONS";
  c"neg[tph]\"exit 0\"; neg[tph][]";
  system "sleep 1";
  b:c"first exec active from .sub.SUBSCRIPTIONS";
  c"system \"rm -rf \",BASE";
  @[{(neg x)"exit 0";(neg x)[]};c;()];
  (a;b)
  }

teardownfixture:{[] @[{(neg x)"exit 0";(neg x)[]};tph;()]; system "sleep 0.3"; system "rm -rf ",BASE; }
