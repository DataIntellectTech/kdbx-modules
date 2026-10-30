/ fixture helpers for di.torq.proc.tickerplant's tests, loaded from the repo root
/ real di.pubsub, di.tplogmgr and di.eodtime with recording log and timer mocks; timer jobs run only when called

BASE:"/tmp/di_tickerplant_k4unit"

/ mock log
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

/ mock timer - records scheduled jobs
timercalls:([]id:`symbol$();period:`timespan$();mode:`short$())
resettimer:{[] `timercalls set ([]id:`symbol$();period:`timespan$();mode:`short$()); }
mockaddjob:{[id;func;params;period;mode;opts] `timercalls insert (id;period;mode); }
mocktimer:{[] enlist[`addjob]!enlist mockaddjob}

/ mock handlers - records (event;name) registrations with di.torq.handlers' register shape
hcalls:([]event:`symbol$();name:`symbol$())
resethandlers:{[] `hcalls set ([]event:`symbol$();name:`symbol$()); }
mockhandlers:{[] `register`remove!({[ev;ph;nm;pri;fn] `hcalls insert (ev;nm);};{[ev;ph;nm]})}

deps:{[] `log`timer`handlers!(mocklog[];mocktimer[];mockhandlers[])}

setupfixture:{[]
  system "rm -rf ",BASE;
  {system "mkdir -p ",BASE,"/",x} each ("log";"batchlog";"eodlog";"replog";"subdlog";"subdblog");
  setenv[`TORQXAPPHOME;BASE];
  / good schema: trade + quote, both time,sym first
  (hsym`$BASE,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`int$())";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$())");
  / bad schema: a table with neither time nor sym first
  (hsym`$BASE,"/badschema.q") 0: enlist "widgets:([]id:`int$();name:`symbol$())";
  }
teardownfixture:{[] system "rm -rf ",BASE; }

/ config builders
immcfg:{[] `tplogdir`schemafile!(BASE,"/log";BASE,"/database.q")}
batchcfg:{[] `timerms`tplogdir`schemafile!(2000;BASE,"/batchlog";BASE,"/database.q")}
nologcfg:{[] enlist[`schemafile]!enlist BASE,"/database.q"}
badcfg:{[] enlist[`schemafile]!enlist BASE,"/badschema.q"}
replaycfg:{[] `timerms`tplogdir`schemafile!(2000;BASE,"/replog";BASE,"/database.q")}
subdcfg:{[] `tplogdir`schemafile!(BASE,"/subdlog";BASE,"/database.q")}
subdbcfg:{[] `timerms`tplogdir`schemafile!(2000;BASE,"/subdblog";BASE,"/database.q")}
tzcfg:{[] `schemafile`rolltimezone`datatimezone`rolltimeoffset!(BASE,"/database.q";`$"America/New_York";`$"Asia/Tokyo";0D01)}
/ the same settings as TOML delivers them: strings
tzstrcfg:{[] `schemafile`rolltimezone`datatimezone`rolltimeoffset!(BASE,"/database.q";"America/New_York";"Asia/Tokyo";"0D17:00:00.000")}
/ timerms (q's -t) 200, null or 0
tcfg:{[ms] `timerms`schemafile!(ms;BASE,"/database.q")}

/ feed n trade rows through the published root upd (columns form, single record each)
feedtrades:{[n] {upd[`trade;(.z.p;`$"S",string x;1.0*x;`int$x)]} each til n; }

/ message count in a log dir's current-day log (GMT date, matching eodtime GMT config)
logcount:{[dir] c:-11!(-2;hsym`$dir,"/tp",string "d"$.z.p); $[0>type c;c;first c]}

/ assertion helpers
loghas:{[sub;n] n=logcount[BASE,"/",sub]}
flushperiodok:{[] 0D00:00:02=first exec period from timercalls where id=`tpflush}
rolledfile:{[sub;date] not ()~key hsym`$BASE,"/",sub,"/tp",string date}
/ an upd arriving after the roll time: put the roll 1s in the past, send one trade (stamped by the feed or not),
/ return (date before;date after;messages in the next day's log)
pastroll:{[sub;stamped]
  (use`di.eodtime)[`setnextroll] .z.p-0D00:00:01;
  d0:.u.d;
  upd[`trade;$[stamped;(.z.p;`R;1f;1i);(`R;1f;1i)]];
  f:hsym`$BASE,"/",sub,"/tp",string d0+1;
  (d0;.u.d;$[()~key f;0;first -11!(-2;f)])}

/ init helpers
doinit:{[cfg] resetcalls[]; resettimer[]; resethandlers[]; (tk`init)[cfg;deps[]]; }
initbad:{[] (tk`init)[badcfg[];deps[]]; }   / expected to throw (used by a fail row)

scheduled:{[id] id in exec id from timercalls}

/ subdetails after 5 trades reports rowcount 5, both tables and schemas, and the log file
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

/ pubsub's subscriber cleanup is registered on .z.pc through the handlers dep
pcregistered:{[] (`.z.pc;`pubsub) in flip value flip hcalls}

/ batched: subdetails flushes the 3 buffered rows before registering, so rowcount covers them and they are not sent again
subdetailsbatchedok:{[]
  doinit[subdbcfg[]]; feedtrades[3];
  buffered:count trade;
  sd:(tk`subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];
  all(3=buffered;
      0=count trade;
      3=sd`rowcount)
  }
