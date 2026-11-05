/ fixture helpers, run from the repo root; root `upd` records replayed messages

BASE:"/tmp/di_tplog_k4unit"
D:2026.07.13

replayed:()
resetreplayed:{[] `replayed set (); }
upd:{[t;x] `replayed set replayed,enlist(t;x); }

/ a single trade message
trademsg:{[ts;s] (`upd;`trade;(enlist ts;enlist s;enlist 1.0;enlist 100i;enlist 0b;enlist" ";enlist"N";enlist`buy))}

setupfixture:{[]
  system "rm -rf ",BASE;
  {system "mkdir -p ",BASE,"/",x} each ("main";"roll";"corr";"rep");
  }
teardownfixture:{[] system "rm -rf ",BASE; }

maindir:{[] BASE,"/main"}

/ open fresh, write two trades, close and reopen, storing FRESHCOUNT and REOPENCOUNT
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

/ write two trades to a log in sub and truncate its last 8 bytes; returns the log handle
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

/ replay of a corrupt log calls upd once per recovered message
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

/ write 4 messages, replayupto 2 replays only the first 2
replayuptopartial:{[]
  rd:BASE,"/rep2"; system "mkdir -p ",rd;
  r:tp[`open][rd;D]; h:r 0;
  tp[`write][h;] each trademsg'[2026.07.13D10:00+(0 1 2 3)*0D00:01;`AAPL`MSFT`IBM`GOOG];
  hclose h;
  resetreplayed[];
  cnt:tp[`replayupto][hsym`$rd,"/tp",string D;2];
  (cnt=2) and (2=count replayed) and `AAPL`MSFT~{first (x 1) 1} each replayed
  }
