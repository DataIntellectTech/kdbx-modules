/ fixture helpers for di.torq's tests, loaded from the repo root, which is on QPATH
/ TORQXAPPCONFIG and TORQXAPPHOME point at a temp fixture; di.util.log, di.timer, di.torq.handlers and di.torq.proc.hdb are real

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

  / app-code cascade markers: a file in each tier dir sets a root flag when loaded
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

  / a custom process type that records its init args and counts calls to its run hook
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

/ writes loadnamecode into the procname settings tier
enablenamecode:{[] writelines[APPBASE,"/settings/testinst.q";enlist "loadnamecode:1b"]; }

/ a .Q.opt-shape command line with reserved flags (proctype/procname/torqxstackid/p/norun) and two settings (myrows/myname)
sampleopts:{[] `proctype`procname`torqxstackid`p`norun`myrows`myname!((enlist"hdb");(enlist"hdb");(enlist"s1");(enlist"5560");();(enlist"7");(enlist"widget"))}

/ query-logging helpers: completed rows for one .z.* event, total rows, and one sync and one async message
qlcompleted:{[zc] count select from ((use`di.querylog)`getusage)[] where zcmd=zc,status="c"}
qlrowcount:{[] count ((use`di.querylog)`getusage)[]}
qlsync:{[] .z.pg "1+1"}
qlasync:{[] .z.ps (`upd;`trade;())}
qlcfg:{[on] `procname`querylog!(`qltest;`enabled`flushtime!(on;86400))}

teardownfixture:{[]
  system "rm -rf ",APPBASE;
  system "rm -f ",TESTPROCFILE;
  }
