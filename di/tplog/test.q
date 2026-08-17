/ fixture helpers for di.tplog's k4unit tests.
/ di.tplog replays through the ROOT-level upd, so a recorder upd + a trade schema are defined here at
/ root. message tuples carry commas/backticks, so they are built in these helpers and never written
/ inline in test.csv (raw commas would break the csv fields). the module handle `tp` and the module's
/ init are set up by test.csv's `before` rows before any of these run.

base:"/tmp/di_tplog_k4unit"
d:2026.08.13

/ root-level replay target + a recorder that also captures what was replayed
trade:([] time:`timestamp$(); sym:`symbol$(); price:`float$())
replayed:()
resetstate:{[] `replayed set (); `trade set 0#trade;}
upd:{[t;x] `replayed set replayed,enlist(t;x); t insert x;}

/ capturing logger - one row per call, so tests can assert on narration and the log contract
logcap:([] level:`symbol$(); ctx:`symbol$(); msg:())
capturelog:{[]
  `logcap set 0#logcap;
  `info`warn`error!(
    {[c;m] `logcap insert (`info;c;m);};
    {[c;m] `logcap insert (`warn;c;m);};
    {[c;m] `logcap insert (`error;c;m);})
  }

/ a single trade message matching the trade schema above
trademsg:{[ts;s] (`upd;`trade;(enlist ts;enlist s;enlist 1.0))}

setupfixture:{[] system "rm -rf ",base; system "mkdir -p ",base;}
teardownfixture:{[] system "rm -rf ",base;}

/ a fresh, empty per-test directory; returns the dir string
freshdir:{[sub] dd:base,"/",sub; system "rm -rf ",dd; system "mkdir -p ",dd; dd}

/ write n trade messages into a fresh clean log under sub; close; return the log filename handle
writelog:{[sub;n]
  dd:freshdir sub;
  r:tp[`open][dd;d]; h:r 0;
  tp[`write][h;] each trademsg[;`AAPL] each d+0D00:01*til n;
  hclose h;
  tp[`logname][dd;d]
  }

/ smash k bytes near the middle of a log file, in place; returns the filename
corrupt:{[fn;k]
  b:read1 fn;
  p:count[b] div 2;
  fn set @[b;p+til k&count[b]-p;:;k#0xff];
  fn
  }

/ =============================================================================
/ tests (each returns 1b on success)
/ =============================================================================

/ logname builds <dir>/tp<date>
testlogname:{[] (`$":/x/tp2026.08.13")~tp[`logname]["/x";2026.08.13]}

/ a freshly created log opens with count 0
testopenfresh:{[]
  dd:freshdir"fresh";
  r:tp[`open][dd;d]; hclose r 0;
  0=r 1
  }

/ write two, reopen replays both through the root upd
testwritereopen:{[]
  resetstate[];
  dd:freshdir"wr";
  r:tp[`open][dd;d]; h:r 0;
  tp[`write][h;trademsg[d+0D10:00;`AAPL]];
  tp[`write][h;trademsg[d+0D10:01;`MSFT]];
  hclose h;
  r2:tp[`open][dd;d]; c:r2 1; hclose r2 0;
  (2=c) and (2=count replayed) and (2=count trade)
  }

/ roll closes the current handle and creates the next day's log
testroll:{[]
  dd:freshdir"roll";
  r:tp[`open][dd;d]; h:r 0;
  tp[`write][h;trademsg[d+0D10:00;`AAPL]];
  r2:tp[`roll][h;dd;d]; hclose r2 0;
  not ()~key tp[`logname][dd;d+1]
  }

/ open fails fast (signals) on a corrupt log - used by a `fail` row
testopenfailsfast:{[]
  writelog["off";5];
  corrupt[tp[`logname][base,"/off";d];12];
  tp[`open][base,"/off";d]
  }

/ replay repairs a corrupt log and recovers a sensible number of messages
testreplayrepairs:{[]
  resetstate[];
  fn:corrupt[writelog["rrp";10];12];
  n:tp[`replay] fn;
  (n>0) and n<=10
  }

/ replay processes each recovered message EXACTLY once (double-processing regression guard)
testreplaynodouble:{[]
  resetstate[];
  fn:corrupt[writelog["nd";8];12];
  n:tp[`replay] fn;
  n=count replayed
  }

/ replayupto replays ONLY the first n messages
testreplayupto:{[]
  resetstate[];
  fn:writelog["upto";4];
  n:tp[`replayupto][fn;2];
  (2=n) and (2=count replayed)
  }

/ check returns a clean log unchanged
testcheckclean:{[]
  fn:writelog["ckc";3];
  fn~tp[`check][fn;100]
  }

/ check repairs a corrupt log (returns <fn>.good) AND logs a warning under ctx `check
testcheckcorruptwarns:{[]
  `logcap set 0#logcap;
  fn:corrupt[writelog["ckx";6];12];
  res:tp[`check][fn;100];
  (res~`$string[fn],".good") and `warn in exec level from logcap where ctx=`check
  }

/ repair writes a <fn>.good file
testrepaircreatesgood:{[]
  fn:corrupt[writelog["rep";5];12];
  g:tp[`repair] fn;
  (g~`$string[fn],".good") and not ()~key g
  }
