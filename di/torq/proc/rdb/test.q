/ fixture helpers for di.torq.proc.rdb's end-of-day tests, loaded from the repo root
/ init runs against mocked servers with no tickerplant, so it stops at the tickerplant wait; the hdb reload goes to handle 0

BASE:"/tmp/di_rdb_k4unit_",string .z.i;
D:2026.01.01;

chk:{[d] `LAST set d; all value d};

calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklogfn:{[lvl;ctx;msg] `calls upsert `lvl`ctx`msg!(lvl;ctx;msg);};
reclog:`info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);

/ servers mock: no tickerplant comes up; the one hdb is this process
servers:`startup`waitfortype`getservers!({[c]};{[t;to;p] 0b};{[t] ([]w:enlist 0i)});
deps:`log`timer`servers!(reclog;`addjob`deletejobs!({[a;b;c;d;e;f]};{[x]});servers);

/ the hdb reload the rdb sends, answered here
RELOADED:0b;
.hdb.reload:{[] `RELOADED set 1b};

/ what a postreplay hook saw: its arguments, the trade count and sym attribute, and whether the hdb had reloaded
POST:();
recpost:{[d;p] `POST set (d;p;count trade;attr trade`sym;RELOADED)};

/ a fresh rdb on config c: init stops at the tickerplant wait; every other root table is ignored at end of day
freshrdb:{[c]
  `calls set 0#calls;
  `RELOADED set 0b;
  `POST set ();
  system "rm -rf ",BASE;
  ![`.;();0b;`trade`quote];
  c:(`hdbdir`tpwaittimeout`ignorelist!(BASE,"/hdb";1;`heartbeat`logmsg,tables`.)),c;
  e:@[rdb.init[;deps];c;{x}];
  if[not e like "*no tickerplant connection*";'"freshrdb: unexpected init result: ",-3!e];
  `trade set ([]time:2026.01.01D09:00+til 3;sym:`g#`b`a`b;price:1 2 3f);
  `quote set ([]time:2026.01.01D09:00+til 2;sym:`g#`a`b;bid:2#1f);
  };

/ true if the module's private namespace holds no trade table
nomodtrade:{[] not `trade in key .m.di.0torq.0proc.0rdb};

/ upd appends a table, a list of columns and a single row to the root table
updpayloads:{[]
  freshrdb ()!();
  upd[`trade;([]time:enlist 2026.01.01D10:00;sym:enlist`c;price:enlist 4f)];
  upd[`trade;(2026.01.01D10:01 2026.01.01D10:02;`d`e;5 6f)];
  upd[`trade;(2026.01.01D10:03;`f;7f)];
  chk `prices`gattr`root!(1 2 3 4 5 6 7f~trade`price;`g=attr trade`sym;nomodtrade[])
  };

/ -11! replay of a tickerplant log drives the published upd into the root table
updreplay:{[]
  freshrdb ()!();
  f:hsym `$BASE,"/tplog";
  f set ();
  h:hopen f;
  h enlist (`upd;`trade;(2026.01.01D10:00 2026.01.01D10:01;`c`d;4 5f));
  h enlist (`upd;`trade;(2026.01.01D10:02;`e;6f));
  hclose h;
  n:-11!f;
  chk `msgs`prices`root!(2=n;1 2 3 4 5 6f~trade`price;nomodtrade[])
  };

/ upd appends in place: one row onto a 1M-row table allocates under 1MB
updinplace:{[]
  freshrdb ()!();
  n:1000000;
  `trade set ([]time:n#2026.01.01D09:00;sym:`g#n#`a`b;price:n#1f);
  b:last system "ts upd[`trade;([]time:enlist 2026.01.01D10:00;sym:enlist`c;price:enlist 4f)]";
  chk `rows`bytes!((n+1)=count trade;b<1000000)
  };

/ a saved column from the hdb partition
disk:{[t;c] (get ` sv (hsym`$BASE),`hdb,(`$string D),t,`) c};

/ standalone end of day keeps g# on sym after the clear
gattr:{[]
  freshrdb ()!();
  rdb.endofday D;
  chk `cleared`trade`quote`saved`reloaded!(0=count[trade]+count quote;`g=attr trade`sym;`g=attr quote`sym;3=count disk[`trade;`price];RELOADED)
  };

/ a config savedownmanipulation is applied once before the save
manipulation:{[]
  freshrdb (enlist`savedownmanipulation)!enlist enlist[`trade]!enlist {update price:2*price from x};
  rdb.endofday D;
  2 4 6f~asc disk[`trade;`price]
  };

/ a config postreplay is called with the hdb dir and date after the clear and reapply, before the hdb reload
postreplay:{[]
  freshrdb (enlist`postreplay)!enlist recpost;
  rdb.endofday D;
  chk `args`cleared`gattr`beforereload`reloaded!((hsym`$BASE,"/hdb";D)~2#POST;0=POST 2;`g=POST 3;not POST 4;RELOADED)
  };

/ a failing postreplay propagates out of end of day: saved and cleared, no hdb reload
failedpostreplay:{[]
  freshrdb (enlist`postreplay)!enlist {[d;p] '"boom"};
  e:@[rdb.endofday;D;{x}];
  chk `signalled`saved`cleared`noreload!(e~"boom";3=count disk[`trade;`price];0=count trade;not RELOADED)
  };

/ with reloadenabled the end of day escapes before postreplay
reloadenabled:{[]
  freshrdb `reloadenabled`postreplay!(1b;recpost);
  rdb.endofday D;
  chk `nopost`noreload`kept!(()~POST;not RELOADED;3=count trade)
  };
