/ fixture helpers for di.proc.tickerplant's tests. Assumes cwd is the TorqX repo root.
/ Uses REAL di.pubsub / di.tplogmgr / di.eodtime (this is an integration test of the
/ wiring) with a mock log (recording) and a mock timer (recording addjob calls, not
/ running a cycle - so endofday/flush fire only when the test calls them directly).
/ Real feed->TP->subscriber delivery is covered by the torqx.sh end-to-end, not here:
/ pubsub publishes via async -25!, which does not flush inside a synchronous test.

BASE:"/tmp/di_tickerplant_k4unit"

/ mock log
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

/ mock timer - records scheduled jobs
timercalls:([]id:`symbol$();period:`int$();mode:`short$())
resettimer:{[] `timercalls set ([]id:`symbol$();period:`int$();mode:`short$()); }
mockaddjob:{[id;func;params;period;mode;opts] `timercalls insert (id;`int$period;mode); }
mocktimer:{[] enlist[`addjob]!enlist mockaddjob}

deps:{[] `log`timer!(mocklog[];mocktimer[])}

setupfixture:{[]
  system "rm -rf ",BASE;
  {system "mkdir -p ",BASE,"/",x} each ("log";"batchlog";"eodlog";"replog";"subdlog");
  setenv[`TORQXAPPHOME;BASE];
  / good schema: trade + quote, both time,sym first
  (hsym`$BASE,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`int$())";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$())");
  / bad schema: a table with neither time nor sym first
  (hsym`$BASE,"/badschema.q") 0: enlist "widgets:([]id:`int$();name:`symbol$())";
  }
teardownfixture:{[] system "rm -rf ",BASE; }

/ config builders (kept out of test.csv: they contain commas/backticks)
immcfg:{[] `publishmode`tplogdir`schemafile!(`immediate;BASE,"/log";BASE,"/database.q")}
batchcfg:{[] `publishmode`pubperiod`tplogdir`schemafile!(`batched;2;BASE,"/batchlog";BASE,"/database.q")}
nologcfg:{[] `publishmode`schemafile!(`immediate;BASE,"/database.q")}
badcfg:{[] `publishmode`schemafile!(`immediate;BASE,"/badschema.q")}
replaycfg:{[] `publishmode`tplogdir`schemafile!(`batched;BASE,"/replog";BASE,"/database.q")}
subdcfg:{[] `publishmode`tplogdir`schemafile!(`immediate;BASE,"/subdlog";BASE,"/database.q")}

/ feed n trade rows through the published root upd (columns form, single record each)
feedtrades:{[n] {upd[`trade;(.z.p;`$"S",string x;1.0*x;`int$x)]} each til n; }

/ message count in a log dir's current-day log (GMT date, matching eodtime GMT config)
logcount:{[dir] c:-11!(-2;hsym`$dir,"/tp",string "d"$.z.p); $[0>type c;c;first c]}

/ assertion helpers factored here because they contain raw commas (which split CSV fields)
loghas:{[sub;n] n=logcount[BASE,"/",sub]}
flushperiodok:{[] 2=first exec period from timercalls where id=`tpflush}
rolledfile:{[sub;date] not ()~key hsym`$BASE,"/",sub,"/tp",string date}

/ init helpers that store handles / state for assertions
doinit:{[cfg] resetcalls[]; resettimer[]; (tk`init)[cfg;deps[]]; }
initbad:{[] (tk`init)[badcfg[];deps[]]; }   / expected to throw (used by a fail row)

scheduled:{[id] id in exec id from timercalls}

/ subdetails: after feeding 5 trades, the subscription-details call reports rowcount=5,
/ the publishable tables + their schemas, and the correct log file / date. (Registration
/ targets .z.w=0 in-process; here we assert the returned replay metadata.)
subdetailsok:{[]
  doinit[subdcfg[]]; feedtrades[5];        / fresh log dir so rowcount is deterministic
  sd:(tk`subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];           / deregister the in-process handle-0 sub so later tests aren't polluted
  all(5=sd`rowcount;
      2=count sd`tables;
      all `trade`quote in sd`tables;
      all `trade`quote in key sd`schemas;
      98h=type sd[`schemas]`trade;
      sd[`logfile]~hsym`$BASE,"/subdlog/tp",string sd`date)
  }
