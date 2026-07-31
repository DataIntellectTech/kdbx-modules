/ fixture helpers for di.subscriptions' tests. Assumes cwd is the TorqX repo root.
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
deps:{[] enlist[`log]!enlist mocklog[]}

/ the trade schema a TP would return (g# on sym, as di.proc.tickerplant applies)
tradeschema:{[] ([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())}

/ the root-namespace-safe upd di.proc.rdb uses: append to the ROOT table t, handling a table
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

teardownfixture:{[] system "rm -rf ",BASE; }
