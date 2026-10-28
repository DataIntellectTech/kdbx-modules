/ fixture helpers for di.torq's tests.
/ Assumes q is started with the kdbx-modules repo root as the working directory and on QPATH
/ (di.torq's own built-in settings and `builtin` registry genuinely live there - there is no
/ faking that part).
/ TORQXAPPCONFIG and TORQXAPPHOME are both repointed at a temp fixture below to
/ isolate everything else (process.csv, app-level settings, a scratch hdb dir, the
/ custom proctype's code file) from any real app - nothing this test does touches a
/ real app directory. Uses real di.util.log/di.timer/di.torq.handlers/di.torq.proc.hdb throughout rather than
/ mocking them - they are each already covered by their own module's tests, and
/ di.torq's job is to wire them together correctly, which mocking them away would not
/ actually test.

APPBASE:"/tmp/di_torq_k4unit_app"
HDBDIR:APPBASE,"/hdb"
TESTPROCNAME:`k4unittestproc
TESTPROCFILE:APPBASE,"/code/processes/",string[TESTPROCNAME],".q"
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"

writelines:{[path;lines] (hsym `$path) 0: lines; }

/ the kdbx-modules checkout: the working directory
REPO:system "cd"

/ f[] with env var e set to v, then e restored; f's error is re-signalled after the restore
withenv:{[e;v;f] o:getenv e; setenv[e;v]; r:@[{(1b;x[])};f;{(0b;x)}]; setenv[e;o]; $[r 0;r 1;'r 1]}

setupfixture:{[]
  system "rm -rf ",APPBASE;
  system "mkdir -p ",APPBASE,"/settings ",APPBASE,"/code/processes ",APPBASE,"/code/common ",APPBASE,"/code/",string[TESTPROCNAME]," ",APPBASE,"/code/testinst ",HDBDIR;
  setenv[`TORQXAPPCONFIG;APPBASE];
  setenv[`TORQXAPPHOME;APPBASE];

  / app-code cascade markers: a bare file (no \d) in each tier dir sets a root flag when loaded,
  / so tests can assert which tiers di.torq's loadappcode picked up (common -> proctype -> procname).
  writelines[APPBASE,"/code/common/appcommon.q";enlist "APPCOMMON_LOADED:1b"];
  writelines[APPBASE,"/code/",string[TESTPROCNAME],"/appproc.q";enlist "APPPROC_LOADED:1b"];
  writelines[APPBASE,"/code/testinst/appname.q";enlist "APPNAME_LOADED:1b"];
  / -parentproctype fixtures: a parent settings tier (a parent-only key, a key the proctype also sets, and loadprocesscode
  / declared so -loadprocesscode can override it) and parent code recording whether the proctype's code had loaded yet
  writelines[APPBASE,"/settings/pptparent.q";("pptonly:1";"widget:0";"loadprocesscode:1b")];
  system "mkdir -p ",APPBASE,"/code/pptparent";
  writelines[APPBASE,"/code/pptparent/pptcode.q";("PPTCODE:1b";"PPTBEFOREPROC:@[value;`APPPROC_LOADED;0b]")];

  / a scratch hdb: just a serialized table, the simplest thing \l can load
  (hsym `$HDBDIR,"/widgets") set ([]id:1 2 3);

  writelines[APPBASE,"/settings/default.q";enlist "owner:`k4unittest"];
  writelines[APPBASE,"/settings/hdb.q";enlist "dir:`:",HDBDIR];
  writelines[APPBASE,"/settings/",string[TESTPROCNAME],".q";enlist "widget:1"];

  writelines[APPBASE,"/process.csv";
    ("host,port,proctype,procname";
     "localhost,28580,hdb,hdb";
     "localhost,0,",(string TESTPROCNAME),",testinst")];

  / a trivial custom process type - mirrors code/processes/loader.q's shape, but just
  / captures what it was called with so the test can assert on it. Also publishes a
  / `run` hook (di.torq's optional post-init convention, see torq.q's runhook) that
  / just counts how many times it fired, so tests can assert it ran/didn't run.
  writelines[TESTPROCFILE;
    ("\\d .",string TESTPROCNAME;
     "runcalled:0;";
     "deferredcalled:0;";
     "deferred:{[x] deferredcalled::deferredcalled+1};";
     "init:{[config;deps]";
     "  .proc.addinitlist(`.k4unittestproc.deferred;`);";
     "  capturedconfig::config;";
     "  captureddeps::deps;";
     "  deps[`log][`info][`",(string TESTPROCNAME),";\"custom proctype initialised\"];";
     "  };";
     "run:{[] runcalled::runcalled+1};";
     "\\d .")];

  / a launcher that starts a real process through torqx_init.q and writes the timerms its config carried
  writelines[APPBASE,"/launch.q";
    ("system \"l ",REPO,"/di/torq/bin/torqx_init.q\";";
     "(hsym`$getenv[`TORQXAPPHOME],\"/timerms.txt\") 0: enlist .Q.s1 .k4unittestproc.capturedconfig`timerms;";
     "exit 0")];
  }

/ a launcher that starts a real process through torqx_init.q and writes what -parentproctype changed
pptlauncher:{[] writelines[APPBASE,"/launchppt.q";
  ("system \"l ",REPO,"/di/torq/bin/torqx_init.q\";";
   "c:.k4unittestproc.capturedconfig;";
   "(hsym`$getenv[`TORQXAPPHOME],\"/ppt.txt\") 0: enlist .Q.s1 (c`parentproctype;$[`pptonly in key c;c`pptonly;0N];c`widget;@[value;`PPTCODE;0b];@[value;`PPTBEFOREPROC;0N]);";
   "exit 0")]}

/ launch a real process with extra q flags; return (parentproctype;pptonly;widget;parent code loaded;proctype code loaded before it)
launchppt:{[flags]
  pptlauncher[]; f:APPBASE,"/ppt.txt"; system "rm -f ",f;
  system QBIN," ",APPBASE,"/launchppt.q -proctype ",(string TESTPROCNAME)," -procname testinst",flags," -q </dev/null >",APPBASE,"/ppt.log 2>&1";
  value first read0 hsym`$f}

/ launch a real process through torqx_init.q with extra q flags; return the timerms in its config
launchtimerms:{[flags]
  f:APPBASE,"/timerms.txt"; system "rm -f ",f;
  system QBIN," ",APPBASE,"/launch.q -proctype ",(string TESTPROCNAME)," -procname testinst",flags," -q </dev/null >",APPBASE,"/launch.log 2>&1";
  value first read0 hsym`$f}

/ helper so the test.csv cell stays comma-free (k4unit's CSV splits unquoted commas): writes
/ loadnamecode into the procname settings tier to turn on the procname-tier app-code cascade.
enablenamecode:{[] writelines[APPBASE,"/settings/testinst.q";enlist "loadnamecode:1b"]; }

/ a synthetic parsed-command-line opt dict in .Q.opt shape (values are string lists; a bare flag
/ like -norun is ()) for the command-line override-layer tests. Mixes the reserved launcher/identity
/ flags di.torq consumes (proctype/procname/torqxstackid/p/norun) with two real setting flags
/ (myrows/myname), so a test can assert clioverrideparams keeps only the latter.
sampleopts:{[] `proctype`procname`torqxstackid`p`norun`myrows`myname!((enlist"hdb");(enlist"hdb");(enlist"s1");(enlist"5560");();(enlist"7");(enlist"widget"))}

/ query-logging helpers (the initquerylog tests), kept here so test.csv cells stay comma-free: count the
/ completed rows for one .z.* event, the total row count, and drive one sync and one async message
/ through the wrapped handlers.
qlcompleted:{[zc] count select from ((use`di.querylog)`getusage)[] where zcmd=zc,status="c"}
qlrowcount:{[] count ((use`di.querylog)`getusage)[]}
qlsync:{[] .z.pg "1+1"}
qlasync:{[] .z.ps (`upd;`trade;())}
qlcfg:{[on] `procname`querylog!(`qltest;`enabled`flushtime!(on;86400))}

teardownfixture:{[]
  system "rm -rf ",APPBASE;
  system "rm -f ",TESTPROCFILE;
  }
