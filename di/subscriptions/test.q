/ fixture helpers for di.subscriptions' tests. Assumes cwd is the kdbx-modules repo root.
/ The tickerplant "handle" is mocked as a FUNCTION: subscribe calls tph(msg), and `h(msg)` applies
/ h to the message whether h is an int handle (real IPC) or a function (here). The mock therefore
/ answers all three calls a subscribe makes - the `tptype` probe, and whichever root subdetails
/ name that probe leads to - and REJECTS the wrong name, so a dispatch regression fails loudly
/ instead of passing by accident. The canned dicts point at REAL tp logs built via di.tplogmgr,
/ so every replay is genuine. Real cross-process IPC subscribe is covered by the torqx.sh
/ end-to-end, not here.

BASE:"/tmp/di_subs_k4unit"
D:2026.07.13

/ mock log (recording)
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}
deps:{[] enlist[`log]!enlist mocklog[]}

/ did anything get logged at level lv whose message contains s? (ss, not like - a multi-wildcard
/ like pattern throws 'nyi on this build)
logged:{[lv;s] 0<count select from calls where lvl=lv,{0<count x ss y}[;s] each msg}

/ the trade schema a TP would return (g# on sym, as di.torq.proc.tickerplant applies)
tradeschema:{[] ([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())}

/ the root-namespace-safe upd di.torq.proc.rdb uses - kept equivalent to rdb.q/wdb.q's updfn,
/ INCLUDING their ascols normalisation, so this fixture cannot quietly diverge from the real
/ consumer and hide a payload shape the real one would meet. Appends to the ROOT table t, handling
/ a table payload (live), a list-of-columns payload and a single row of ATOMS (both replay).
/ @[`.;..] targets root explicitly so it works even when di.tplogmgr's -11! replay executes upd
/ from a module context (a bare `insert` would resolve the table symbol in di.tplogmgr's
/ namespace, not root).
updascols:{[d] $[0>type first d;enlist each d;d]}
rootupd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!updascols d]}[;x]]}

/ build one real tp log per entry of `counts`, the i-th holding counts[i] single-row trade
/ messages. di.tplogmgr names one log per date, so consecutive dates stand in for a segmented
/ TP's several physical files - equivalent for replay, which only ever sees (msgcount;file).
/ Syms run S0..Sn-1 GLOBALLY across the files and times ascend with them, so a duplicated,
/ dropped or out-of-order replay is visible in the resulting table.
buildlogs:{[counts]
  tp:use`di.tplogmgr;
  system "rm -rf ",BASE;
  system "mkdir -p ",BASE;
  offs:sums 0,-1_counts;
  one:{[tp;offs;counts;i]
    r:tp[`open][BASE;D+i];
    h:r 0;
    {[tp;h;k] tp[`write][h;(`upd;`trade;(enlist D+0D00:00:01*k;enlist `$"S",string k;enlist 1.0*k;enlist `int$k))]}[tp;h]
      each offs[i]+til counts i;
    hclose h;
    (counts i;tp[`logname][BASE;D+i])
    }[tp;offs;counts];
  one each til count counts
  }

/ the single-file case, as a standard TP reports it
buildlog:{[n] first buildlogs enlist n}

/ make a log file unreplayable. NB truncating the TAIL is not enough: replayupto is repair-aware
/ and di.tplog.repair would trim to the last good message and succeed, which is the opposite of
/ what this fixture is for. Overwriting wholesale defeats the repair path too.
corruptlog:{[lf] hsym[`$1_string lf] 1: "this is not a tickerplant log"; }

/ a mock TP handle (function). tptype selects which protocol it speaks; pairs are the
/ (msgcount;logfile) entries built by buildlogs.
mocktph:{[tptype;pairs]
  {[tptype;pairs;msg]
    / the tptype probe: subscribe sends (function;`), which a real TP would evaluate remotely
    if[100h=type first msg; :tptype];
    nm:first msg;
    if[tptype=`standard;
      if[not nm~`.u.subdetails;'"mocktp: standard TP has no root ",string nm];
      :`tables`schemas`logfile`rowcount`date!
        (enlist`trade;(enlist`trade)!enlist tradeschema[];last first pairs;first first pairs;D)];
    if[not nm~`subdetails;'"mocktp: segmented TP has no root ",string nm];
    :`schemalist`logfilelist`rowcounts`date`logdir!
      (enlist(`trade;tradeschema[]);pairs;(enlist`trade)!enlist sum first each pairs;D;`$BASE);
    }[tptype;pairs]
  }

/ a mock that CLAIMS a logged count but reports no log file - a genuine fault, the TP contradicts itself
mocknolog:{[] {[msg] if[100h=type first msg;:`standard];
    `tables`schemas`logfile`rowcount`date!(enlist`trade;(enlist`trade)!enlist tradeschema[];`;4;D)}}

/ a standard TP with LOGGING DISABLED: no tplogdir, so msgcount never increments and logfile stays `.
/ There is simply nothing to replay, and that must NOT be treated as the fault above
mocklogoff:{[] {[msg] if[100h=type first msg;:`standard];
    `tables`schemas`logfile`rowcount`date!(enlist`trade;(enlist`trade)!enlist tradeschema[];`;0;D)}}

/ a segmented TP with nothing logged for the requested tables - getlogsday returns () in that case
mockemptyseg:{[] {[msg] if[100h=type first msg;:`segmented];
    `schemalist`logfilelist`rowcounts`date`logdir!
      (enlist(`trade;tradeschema[]);();(enlist`trade)!enlist 0;D;`$BASE)}}

/ a log holding ONE atom-row message - the shape a tickerplant writes when the feed sends a row of
/ atoms, since stamp[] keeps it atomic and logs it that way. Returns the (msgcount;logfile) pair.
/ Uses its own subdirectory, but buildlogs wipes BASE, so build this immediately before using it
buildatomlog:{[]
  d:BASE,"/atomrow";
  system "rm -rf ",d;
  system "mkdir -p ",d;
  tp:use`di.tplogmgr;
  h:first tp[`open][d;D];
  tp[`write][h;(`upd;`trade;(D+0D00:00:01;`$"S0";1.0;1i))];
  hclose h;
  (1;tp[`logname][d;D])
  }

/ a mock whose tptype is one di.subscriptions does not know
mockbadtype:{[] {[msg] if[100h=type first msg;:`weird]; '"mocktp: should not get here"}}

/ a mock that REPORTS one tptype but only answers a different root name than that tptype implies.
/ Subscribing against it must throw - which is what proves di.subscriptions picked the root name
/ from the probe rather than always sending the same one. Without this, every dispatch test passes
/ trivially, because the happy-path mocks report and accept the matching name.
mockmismatch:{[reported;accepts]
  {[reported;accepts;msg]
    if[100h=type first msg; :reported];
    if[not (first msg)~accepts;'"mocktp: no root ",string first msg];
    '"mocktp: unreachable - the wrong name should have been sent"
    }[reported;accepts]
  }

resettrade:{[] @[`.;`trade;:;0#tradeschema[]]; }
teardownfixture:{[] system "rm -rf ",BASE; }
