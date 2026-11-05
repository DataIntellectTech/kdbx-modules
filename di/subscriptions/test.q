/ fixture helpers, run from the repo root

/ the settings file plus overrides
subcfg:{[x] ((use`di.torq.config)[`parsefile] "di/torq/settings/default.q"),x}
/ the tickerplant handle is mocked as a function answering subdetails over a real tp log

BASE:"/tmp/di_subs_k4unit"
D:2026.07.13
LOGFILE:`

/ mock log (recording)
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}
timercalls:([]id:`symbol$();period:`timespan$();mode:`long$())
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] `timercalls upsert (id;period;`long$mode);}
handlercalls:([]event:`symbol$();name:`symbol$())
mockhandlers:enlist[`register]!enlist {[ev;ph;nm;pri;fn] `handlercalls upsert (ev;nm);}
deps:{[] `log`timer`handlers!(mocklog[];mocktimer;mockhandlers)}

/ the trade schema a tickerplant returns
tradeschema:{[] ([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())}

/ upsert a table (live) or list of columns (replay) into the root table t
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

/ a mock tickerplant handle answering subdetails with the real log and rowcount n
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

/ a client subscribes to a peer that then exits; its .z.pc marks the subscription inactive
pcclosecheck:{[]
  p:first p where isfree each p:40000+(`int$.z.i mod 20000)+til 500;
  system QBIN," -p ",(string p)," -q </dev/null >/dev/null 2>&1 &";
  d:.z.p+0D00:00:03; while[(.z.p<d) and isfree p; system "sleep 0.05"];
  c:hopen (`$":localhost:",string p;2000);
  c"sub:use`di.subscriptions; system \"l di/subscriptions/test.q\"; BASE::\"/tmp/di_subs_pcclose\"; buildlog[4]";
  c"hz:use`di.torq.handlers; (hz`init)[enlist[`log]!enlist mocklog[]]";
  c"sub.init[subcfg enlist[`autoreconnect]!enlist 0b;`log`timer`handlers!(mocklog[];mocktimer;`register`remove`list!(hz`register;hz`remove;hz`list))]";
  c"spawnpeer[]; .sub.subscribe[`trade;`;1b;0b;peerproc[]]";
  a:c"first exec active from .sub.SUBSCRIPTIONS";
  c"neg[tph]\"exit 0\"; neg[tph][]";
  system "sleep 1";
  b:c"first exec active from .sub.SUBSCRIPTIONS";
  c"system \"rm -rf \",BASE";
  @[{(neg x)"exit 0";(neg x)[]};c;()];
  (a;b)
  }

/ a fresh init with checksubscriptionperiod p; returns the timer jobs it registered
periodinit:{[p] .m.di.0subscriptions.registered:0b; delete from `timercalls; sub.init[subcfg enlist[`checksubscriptionperiod]!enlist p;deps[]]; flip value flip timercalls}

teardownfixture:{[] @[{(neg x)"exit 0";(neg x)[]};tph;()]; system "sleep 0.3"; system "rm -rf ",BASE; }
