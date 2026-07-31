/ fixture helpers for di.tplogmgr's tests. Assumes cwd is the TorqX repo root.
/ di.tplogmgr's open/replay execute the ROOT-level `upd` for each replayed message, so a
/ recorder `upd` is defined here at root. Message tuples contain commas/backticks, so
/ they are built in helpers, never inline in test.csv (raw commas break CSV fields).

BASE:"/tmp/di_tplog_k4unit"
D:2026.07.13

replayed:()
resetreplayed:{[] `replayed set (); }
upd:{[t;x] `replayed set replayed,enlist(t;x); }

/ a single trade message matching TorqX-POC's database.q trade schema
trademsg:{[ts;s] (`upd;`trade;(enlist ts;enlist s;enlist 1.0;enlist 100i;enlist 0b;enlist" ";enlist"N";enlist`buy))}

setupfixture:{[]
  system "rm -rf ",BASE;
  {system "mkdir -p ",BASE,"/",x} each ("main";"roll";"corr";"rep");
  }
teardownfixture:{[] system "rm -rf ",BASE; }

maindir:{[] BASE,"/main"}

/ open fresh (stores FRESHCOUNT), write two trades, close; reopen (stores REOPENCOUNT
/ and repopulates `replayed via the root upd during replay).
dowriteandreopen:{[]
  resetreplayed[];
  r:tp[`open][maindir[];D]; h:r 0;
  `FRESHCOUNT set r 1;
  tp[`write][h;trademsg[2026.07.13D10:00;`AAPL]];
  tp[`write][h;trademsg[2026.07.13D10:01;`MSFT]];
  hclose h;
  r2:tp[`open][maindir[];D];
  `REOPENCOUNT set r2 1;
  hclose r2 0;
  }

/ open, write one, roll -> the next day's log file must exist
dorollnewfile:{[]
  rd:BASE,"/roll";
  r:tp[`open][rd;D]; h:r 0;
  tp[`write][h;trademsg[2026.07.13D10:00;`AAPL]];
  r2:tp[`roll][h;rd;D];
  hclose r2 0;
  not ()~key hsym`$rd,"/tp",string D+1
  }

/ build a corrupt log in the given subdir (two good trades, then truncate 8 bytes off
/ the tail so the last message is unreadable). returns the log filename symbol.
buildcorrupt:{[sub]
  cd:BASE,"/",sub;
  r:tp[`open][cd;D]; h:r 0;
  tp[`write][h;trademsg[2026.07.13D10:00;`AAPL]];
  tp[`write][h;trademsg[2026.07.13D10:02;`IBM]];
  hclose h;
  fn:hsym`$cd,"/tp",string D;
  sz:hcount fn;
  fn 1: read1(fn;0;sz-8);
  fn
  }

/ open on a corrupt log must fail fast (used by a `fail` test row)
opencorrupt:{[] buildcorrupt["corr"]; tp[`open][BASE,"/corr";D]}

/ replay must execute the root upd EXACTLY once per recovered message - a naive
/ trap-and-retry would double-process the good messages before the corruption point.
replaynodouble:{[]
  fn:buildcorrupt["rep"];
  `CALLS set 0;
  old:upd;
  `upd set {[t;x] `CALLS set CALLS+1; };
  cnt:tp[`replay] fn;
  `upd set old;
  cnt=CALLS
  }

/ check on a clean log returns the same file unchanged (the main log has 2 good msgs)
checkcleanok:{[] f:hsym`$maindir[],"/tp",string D; f~tp[`check][f;100]}

/ replayupto[logfile;n] must replay ONLY the first n messages (subscriber replays exactly
/ the pre-subscription rowcount, not later live-and-logged messages). Writes 4, replays 2.
replayuptopartial:{[]
  rd:BASE,"/rep2"; system "mkdir -p ",rd;
  r:tp[`open][rd;D]; h:r 0;
  tp[`write][h;] each trademsg'[2026.07.13D10:00+(0 1 2 3)*0D00:01;`AAPL`MSFT`IBM`GOOG];
  hclose h;
  resetreplayed[];
  cnt:tp[`replayupto][hsym`$rd,"/tp",string D;2];
  (cnt=2) and (2=count replayed) and `AAPL`MSFT~{first (x 1) 1} each replayed
  }
