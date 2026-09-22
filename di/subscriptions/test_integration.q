/ helpers for di.subscriptions' integration suite. Drives REAL child kdb-x processes on OS-assigned ports - a
/ di.torq.proc.segmentedtp (test_integration_stp.q) and a di.torq.proc.tickerplant (test_integration_tp.q) - and
/ THIS process plays the subscriber, wiring the real di.subscriptions against them over genuine IPC. That is the
/ half test.csv cannot reach: there the tickerplant is a mock function, so the root name, the dict shape and the
/ log files are all whatever the fixture says they are. Here they are whatever the modules actually produce.
/ Every child pid is tracked and killed by the after row whatever happened. Scenario helpers return 1b only if
/ every named check passes and leave the per-check dict in LAST.

IBASE:"/tmp/di_subs_integration";
PIDS:`long$();

chk:{[d] `LAST set d; all value d};

moddir:{[] p:.Q.m.mp`di.subscriptions; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};
STPCHILD:moddir[],"/test_integration_stp.q";
TPCHILD:moddir[],"/test_integration_tp.q";

qcands:$[count qh:getenv[`QHOME];(qh,"/bin/q";qh,"/",(string .z.o),"/q");()];
QBIN:$[count ex:qcands where {not ()~key hsym `$x} each qcands;first ex;"q"];

/ what a subscriber defines at root. Root-namespace-safe, as di.torq.proc.rdb's is: a bare insert would, under
/ di.tplogmgr's -11! replay, resolve the table name in THAT module's namespace and silently capture nothing
upd:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]];};

/ a segmented TP also broadcasts end of period and end of day to its subscribers (di.pubsub's
/ callendofperiod/callendofday). A subscriber that defines neither signals into the publish, so define
/ both - as any real consumer must
EOP:();
EOD:0Nd;
endofperiod:{[x] `EOP set x;};
endofday:{[d] `EOD set d;};

/ capturing logger, so the corrupt-segment assertions can check what was actually logged
calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); };
caplogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); };
caplog:{[] `info`warn`error!(caplogfn[`info;;];caplogfn[`warn;;];caplogfn[`error;;])};
logged:{[lv;s] 0<count select from calls where lvl=lv,{0<count x ss y}[;s] each msg};

setupintegration:{[]
  system "rm -rf ",IBASE;
  system "mkdir -p ",IBASE;
  (hsym`$IBASE,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$())";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$())");
  setenv[`TORQXAPPHOME;IBASE];
  setenv[`TORQXDATAHOME;IBASE];
  };

killall:{[]
  {@[system;"kill -9 ",(string x)," 2>/dev/null";{}]} each PIDS;
  system "sleep 0.5";
  system "rm -rf ",IBASE;
  };

/ ask the OS for a free port, then release it for the child to bind
freeport:{[] system"p 0W"; p:system"p"; system"p 0"; p};
tryopen:{[p] @[{hopen (`$":localhost:",string x;500)};p;0Ni]};
waitopen:{[p;n]
  if[n<=0;:0Ni];
  if[not null h:tryopen p;:h];
  system "sleep 0.3";
  waitopen[p;n-1]
  };

/ NB the log-directory setting is NOT the same flag for the two process types: di.torq.proc.segmentedtp reads
/ `kdbtplog` (and requires it), di.torq.proc.tickerplant reads `tplogdir` and simply logs nothing without it -
/ which surfaces as di.subscriptions' "rowcount>0 but no log file" guard rather than as a startup failure
startchild:{[child;flag;dir;args]
  p:freeport[];
  cmd:QBIN," ",child," -q -p ",(string p)," -",flag," ",dir," -schemafile ",IBASE,"/database.q ",args;
  pid:"J"$first system cmd," </dev/null >>",IBASE,"/child.log 2>&1 & echo $!";
  `PIDS set PIDS,pid;
  `pid`port`h!(pid;p;waitopen[p;40])
  };

kill9:{[c]
  @[system;"kill -9 ",(string c`pid)," 2>/dev/null";{}];
  @[hclose;c`h;{}];
  system "sleep 0.5";
  };

/ n async updates then a sync round-trip, so every message has been logged before the helper returns.
/ NB columns are sent ENLISTED, not as a row of atoms. A tickerplant accepts either - stamp[] keeps an atom row
/ atomic and logs it that way - but di.torq.proc.rdb's and di.torq.proc.wdb's updfn replay a logged payload with
/ `flip (cols tab)!d`, which throws 'rank on atoms. Live delivery hides this (the TP enlists before publishing),
/ so it only surfaces on replay. That gap is real and outside this module; this suite feeds the shape a
/ replaying consumer can actually handle
cfeed:{[c;t;n;off]
  {[c;t;off;i] neg[c`h](`upd;t;(enlist `$"S",string off+i;enlist 1.0*off+i))}[c;t;off] each til n;
  c[`h]"::";
  };

/ a fresh subscriber: clear the tables this process holds, as a restarted rdb would come up empty
resettables:{[] @[`.;`trade;:;([]time:`timestamp$();sym:`symbol$();price:`float$())]; };

/ wire the real module under test with a capturing logger
freshsub:{[]
  resetcalls[];
  s:use`di.subscriptions;
  s[`init][()!();enlist[`log]!enlist caplog[]];
  s
  };

/ destroy a log file so no repair can recover it
smash:{[f] f 1: "this is not a tickerplant log"; };

/ a segmented TP rolled twice, so three physical segments hold the messages
threesegments:{[dir]
  c:startchild[STPCHILD;"kdbtplog";dir;"-multilog periodic -batchmode immediate -multilogperiod 0D00:00:03 -replayperiod day"];
  cfeed[c;`trade;2;0];
  system "sleep 4";
  cfeed[c;`trade;2;2];
  system "sleep 4";
  cfeed[c;`trade;1;4];
  c
  };

/ --- scenarios ---

segmentedreplay:{[]
  / the headline case: a real segmented TP with three real segments, replayed through the real module
  c:threesegments[IBASE,"/seg"];
  resettables[];
  s:freshsub[];
  sd:s[`subscribe][c`h;`;`;1b];
  / NB the number of segments is asserted as "more than one", not as exactly three. Period boundaries are
  / wall-clock aligned, so the two sleeps sometimes straddle a third boundary and the TP reports a fourth,
  / empty segment. Multi-file replay is the property under test; the exact count is a property of the clock
  / (an empty segment replaying 0 messages without error is a useful incidental case to keep covering)
  a:`allreplayed`exactlyonce`ascending`rowcount`multiplefiles`nologfile`normalised!(
    5=count trade;
    5=count distinct trade`sym;
    (asc trade`time)~trade`time;
    5=sd`rowcount;
    1<count sd`logfilelist;
    not `logfile in key sd;
    all `tables`schemas`rowcount`date`logdir in key sd);
  kill9 c;
  chk a
  };

exactlyonceacrossroll:{[]
  / subscribe, then keep feeding across a further roll: the live feed must not redeliver what replay already
  / applied, and a subscriber that restarts and replays from scratch must land on exactly the same set
  c:threesegments[IBASE,"/once"];
  resettables[];
  s:freshsub[];
  s[`subscribe][c`h;`;`;1b];
  afterreplay:count trade;
  cfeed[c;`trade;2;5];
  system "sleep 4";
  cfeed[c;`trade;1;7];
  c[`h]"::";
  system "sleep 0.5";
  live:count trade;
  a:`replayedfive`livearrived`nodupes!(5=afterreplay;8=live;8=count distinct trade`sym);
  / now a restart: a fresh subscriber replays the whole day from the log and must see each message once
  resettables[];
  s2:freshsub[];
  sd:s2[`subscribe][c`h;`;`;1b];
  kill9 c;
  chk a,`restartcomplete`restartnodupes`restartascending!(
    8=count trade;
    8=count distinct trade`sym;
    (asc trade`time)~trade`time)
  };

corruptsegment:{[]
  / one unreadable segment must not cost the subscriber the other two, and must be named in the log
  dir:IBASE,"/corrupt";
  c:threesegments[dir];
  pairs:c[`h] ".m.di.0torq.0proc.0segmentedtp.getlogsday`trade";
  files:pairs[;1];
  / count each segment locally - a CLOSED segment reports the 0W sentinel, not its size, so the pair's own
  / count cannot be used here. Pick the first segment that actually holds messages: smashing an empty one
  / (which a wall-clock period boundary can produce) would lose nothing and prove nothing
  counts:{first -11!(-2;x)} each files;
  i:first where counts>0;
  bad:files i;
  expected:(sum counts)-counts i;
  kill9 c;
  smash bad;
  c2:startchild[STPCHILD;"kdbtplog";dir;"-multilog periodic -batchmode immediate -multilogperiod 0D01 -replayperiod day"];
  resettables[];
  s:freshsub[];
  sd:s[`subscribe][c2`h;`;`;1b];
  a:`cameup`fedfive`lostonlythebad`stillhasdata`loggederror`namedthefile`rowcountmatches!(
    `trade in tables[];
    5=sum counts;
    expected=count trade;
    0<count trade;
    logged[`error;"replay failed"];
    logged[`error;1_string bad];
    sd[`rowcount]=count trade);
  kill9 c2;
  chk a
  };

standardreplay:{[]
  / the classic path over real IPC - the regression half. A real tickerplant publishes .u.subdetails and the
  / singular dict, and its details must come back through subscribe untouched
  c:startchild[TPCHILD;"tplogdir";IBASE,"/std";"-publishmode immediate"];
  cfeed[c;`trade;4;0];
  resettables[];
  s:freshsub[];
  sd:s[`subscribe][c`h;`;`;1b];
  a:`replayed`exactlyonce`singularshape`nolist`rowcount!(
    4=count trade;
    4=count distinct trade`sym;
    all `tables`schemas`logfile`rowcount`date in key sd;
    not `logfilelist in key sd;
    4=sd`rowcount);
  kill9 c;
  chk a
  };
