/ helpers for di.torq.proc.segmentedtp's integration suite. Drives REAL child kdb-x processes (see
/ test_integration_child.q) on OS-assigned ports: updates arrive over IPC, the real di.timer fires the rolls,
/ .z.exit runs through the real di.torq.handlers, and crashes are real kill -9s. Every child pid is tracked and
/ killed by the after row whatever happened. Scenario helpers return 1b only if every named check passes and
/ leave the per-check dict in LAST.

IBASE:"/tmp/di_segmentedtp_integration";
SM:".m.di.0torq.0proc.0segmentedtp.";
PIDS:`long$();

chk:{[d] `LAST set d; all value d};

moddir:{[] p:.Q.m.mp`di.torq.proc.segmentedtp; p:$[10h=type p;p;string p]; $[":"=first p;1_p;p]};
CHILD:moddir[],"/test_integration_child.q";

qcands:$[count qh:getenv[`QHOME];(qh,"/bin/q";qh,"/",(string .z.o),"/q");()];
QBIN:$[count ex:qcands where {not ()~key hsym `$x} each qcands;first ex;"q"];

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

startchild:{[dir;args]
  p:freeport[];
  cmd:QBIN," ",CHILD," -q -p ",(string p)," -kdbtplog ",dir," -schemafile ",IBASE,"/database.q ",args;
  pid:"J"$first system cmd," </dev/null >>",IBASE,"/child.log 2>&1 & echo $!";
  `PIDS set PIDS,pid;
  `pid`port`h!(pid;p;waitopen[p;40])
  };

kill9:{[c]
  @[system;"kill -9 ",(string c`pid)," 2>/dev/null";{}];
  @[hclose;c`h;{}];
  system "sleep 0.5";
  };

/ n async updates then a sync round-trip, so every message has been processed before the helper returns
cfeed:{[c;t;n]
  {[c;t;i] neg[c`h](`upd;t;(`$"S",string i;1.0*i))}[c;t] each til n;
  c[`h]"::";
  };

cfile:{[c;t] c[`h] "exec first logname from ",SM,"currlog where tbl=`",string t};
cpairs:{[c] c[`h] SM,"getlogsperiod`trade`quote"};
cmetafile:{[c] hsym`$(c[`h] SM,"dldir"),"/stpmeta"};

smash:{[f] n:hcount f; f 1: read1 (f;0;n-5);};

/ open file descriptors of a process whose target contains a path
fdsfor:{[pid;f] c:@[system;"ls -l /proc/",(string pid),"/fd 2>/dev/null";{()}]; sum 0<count each c ss\: 1_string f};

probe:{[]
  c:startchild[IBASE,"/probe";"-multilog tabperiod -batchmode immediate"];
  ok:not null c`h;
  kill9 c;
  ok
  };

restarts:{[]
  dir:IBASE,"/restart";
  lay:"-multilog singular -batchmode immediate";
  c:startchild[dir;lay];
  cfeed[c;`trade;3];
  cfeed[c;`quote;2];
  f:cfile[c;`trade];
  metaf:cmetafile c;
  a:`shared`summed!(f~cfile[c;`quote];(enlist(5;f))~cpairs c);
  / a real crash: nothing gets to close its segment
  kill9 c;
  m:get metaf;
  a:a,enlist[`uncleanleftopen]!enlist all null m`end;
  / restart with the same layout: the open row is resumed and the file's messages still count
  c:startchild[dir;lay];
  m1:get metaf;
  a:a,`resumednorow`resumedcount!(count[m]=count m1;(enlist(5;f))~cpairs c);
  / crash again, corrupt the file the child wrote, restart: recovered into .good, never opened blind
  kill9 c;
  smash f;
  osize:hcount f;
  c:startchild[dir;lay];
  g:`$(string f),".good";
  m2:get metaf;
  a:a,`recovered`goodcount!(g~cfile[c;`trade];(enlist(4;g))~cpairs c);
  a:a,`metarenamed`origuntouched!((g in m2`logname) and not f in m2`logname;osize=hcount f);
  / crash, restart under a different layout: the singular segment is not reopened, so it is an orphan
  kill9 c;
  c:startchild[dir;"-multilog tabular -batchmode immediate"];
  m3:get metaf;
  r:first select from m3 where logname=g;
  a:a,`orphanclosed`orphannullcount`tabularopen!(not null r`end;null r`msgcount;2=count select from m3 where null end);
  / a clean exit runs .z.exit through the real di.torq.handlers, closing every segment
  @[c`h;"exit 0";{}];
  system "sleep 1";
  chk a,enlist[`cleanexitclosed]!enlist all not null (get metaf)`end
  };

periodroll:{[]
  c:startchild[IBASE,"/period";"-multilog periodic -batchmode immediate -multilogperiod 0D00:00:03"];
  cfeed[c;`trade;2];
  system "sleep 4";
  cfeed[c;`trade;1];
  m:get cmetafile c;
  opencount:c[`h] "sum ",SM,"filecount each exec logname from ",SM,"metatable where null end";
  kill9 c;
  closed:exec sum msgcount from m where not null end;
  chk `rolled`closedcounted`oneopen`nothinglost`seqadvanced!(
    1<count m;
    not any null exec msgcount from m where not null end;
    1=count select from m where null end;
    3=closed+opencount;
    0<max m`seq)
  };

dayroll:{[]
  / a roll time 5 seconds from now; di.eodtime then reports yesterday as the current date until it passes
  off:"n"$(`long$"n"$.z.p+0D00:00:05) mod `long$1D;
  c:startchild[IBASE,"/day";"-multilog tabular -batchmode immediate -rolltimeoffset ",string off];
  cfeed[c;`trade;1];
  d0:c[`h] "(",SM,"eod`getd)[]";
  dld0:c[`h] SM,"dldir";
  err0:c[`h] SM,"errlog";
  trade0:cfile[c;`trade];
  system "sleep 8";
  d1:c[`h] "(",SM,"eod`getd)[]";
  dld1:c[`h] SM,"dldir";
  err1:c[`h] SM,"errlog";
  a:`nextdate`newdir`oldclosed`olderrfdclosed`oldtradefdclosed`newerrfdopen!(
    d1=d0+1;
    not dld0~dld1;
    all not null (get hsym`$dld0,"/stpmeta")`end;
    0=fdsfor[c`pid;err0];
    0=fdsfor[c`pid;trade0];
    1=fdsfor[c`pid;err1]);
  kill9 c;
  chk a
  };

/ --- a real di.torq boot: torqx_init.q -> di.torq.init -> settings cascade -> startbuiltin ---

/ the kdbx-modules root that holds di/torq (two levels above the di.torq module dir)
torqxhome:{[] p:.Q.m.mp`di.torq; p:$[10h=type p;p;string p]; p:$[":"=first p;1_p;p]; "/" sv -2_"/" vs p};

stackapp:{[]
  / a minimal app: schema, process.csv, and a proctype-tier toml with a string-valued timespan and booleans
  / (singular forces the period to 1D whatever the toml says - the assertion below checks that too)
  app:IBASE,"/app";
  system "mkdir -p ",app,"/appconfig/settings";
  (hsym`$app,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`g#`symbol$();price:`float$())";
    "quote:([]time:`timestamp$();sym:`g#`symbol$();bid:`float$())");
  (hsym`$app,"/appconfig/settings/default.toml") 0: enlist "# app defaults";
  (hsym`$app,"/appconfig/settings/segmentedtp.toml") 0: (
    "kdbtplog = \"stplogs\"";"multilog = \"singular\"";"batchmode = \"immediate\"";
    "multilogperiod = \"0D01:00:00\"";"errmode = true";"tickinterval = 1");
  app};

startstack:{[app;port]
  / launch exactly as torqx.sh does: QINIT=torqx_init.q with explicit identity and a stack id
  setenv[`TORQXHOME;torqxhome[]];
  setenv[`TORQXAPPCONFIG;app,"/appconfig"];
  setenv[`TORQXAPPHOME;app];
  setenv[`TORQXDATAHOME;app];
  (hsym`$app,"/appconfig/process.csv") 0: ("host,port,proctype,procname";"localhost,",(string port),",segmentedtp,stp1");
  cmd:"QINIT=",torqxhome[],"/di/torq/bin/torqx_init.q ",QBIN," -q -p ",(string port)," -proctype segmentedtp -procname stp1 -torqxstackid itest";
  pid:"J"$first system cmd," </dev/null >>",IBASE,"/stack.log 2>&1 & echo $!";
  `PIDS set PIDS,pid;
  `pid`port`h!(pid;port;waitopen[port;40])};

stackboot:{[]
  / kdb-x abandons a QINIT script silently at the first error and leaves the process at its prompt, so a boot
  / failure looks like a running process: assert the module's observable effects, never just "it came up"
  app:stackapp[];
  c:startstack[app;freeport[]];
  if[null c`h;:chk enlist[`childup]!enlist 0b];
  a:`tptype`updpublished`identity`cascade`jobopts`exithandler!(
    `segmented~c[`h]"tptype";
    c[`h]"`upd in key `.";
    (`segmentedtp;`stp1)~c[`h]"(",SM,"proctype;",SM,"procname)";
    (`singular;`immediate;1D;1b)~c[`h]"(",SM,"multilog;",SM,"batchmode;",SM,"multilogperiod;",SM,"errmode)";
    0b~c[`h]"exec first disableonfail from .m.di.0timer.jobs where id=`segmentedtp";
    `segmentedtp in c[`h]"exec name from (use`di.torq.handlers)[`list]`.z.exit");
  cfeed[c;`trade;3];
  cfeed[c;`quote;2];
  f:cfile[c;`trade];
  metaf:cmetafile c;
  a:a,`shared`counted!(f~cfile[c;`quote];(enlist(5;f))~cpairs c);
  @[c`h;"exit 0";{}];
  system "sleep 1";
  chk a,enlist[`cleanexitclosed]!enlist all not null (get metaf)`end
  };
