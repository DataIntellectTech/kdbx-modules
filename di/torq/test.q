/ fixture helpers for di.torq's tests.
/ Assumes q is started with the TorqX repo root as the working directory AND with
/ TORQXHOME already pointing at the real TorqX checkout (di.torq's own built-in
/ settings and `builtin` registry genuinely live there - there is no faking that part).
/ TORQXAPPCONFIG and TORQXAPPHOME are both repointed at a temp fixture below to
/ isolate everything else (process.csv, app-level settings, a scratch hdb dir, the
/ custom proctype's code file) from any real app - nothing this test does touches a
/ real app directory. Uses real di.util.log/di.timer/di.torq.handlers/di.proc.hdb throughout rather than
/ mocking them - they are each already covered by their own module's tests, and
/ di.torq's job is to wire them together correctly, which mocking them away would not
/ actually test.

APPBASE:"/tmp/di_torq_k4unit_app"
HDBDIR:APPBASE,"/hdb"
TESTPROCNAME:`k4unittestproc
TESTPROCFILE:APPBASE,"/code/processes/",string[TESTPROCNAME],".q"

writelines:{[path;lines] (hsym `$path) 0: lines; }

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
     "init:{[config;deps]";
     "  capturedconfig::config;";
     "  captureddeps::deps;";
     "  deps[`log][`info][`",(string TESTPROCNAME),";\"custom proctype initialised\"];";
     "  };";
     "run:{[] runcalled::runcalled+1};";
     "\\d .")];
  }

/ helper so the test.csv cell stays comma-free (k4unit's CSV splits unquoted commas): writes
/ loadnamecode into the procname settings tier to turn on the procname-tier app-code cascade.
enablenamecode:{[] writelines[APPBASE,"/settings/testinst.q";enlist "loadnamecode:1b"]; }

/ a synthetic parsed-command-line opt dict in .Q.opt shape (values are string lists; a bare flag
/ like -norun is ()) for the command-line override-layer tests. Mixes the reserved launcher/identity
/ flags di.torq consumes (proctype/procname/torqxstackid/p/norun) with two real setting flags
/ (myrows/myname), so a test can assert clioverrideparams keeps only the latter.
sampleopts:{[] `proctype`procname`torqxstackid`p`norun`myrows`myname!((enlist"hdb");(enlist"hdb");(enlist"s1");(enlist"5560");();(enlist"7");(enlist"widget"))}

teardownfixture:{[]
  system "rm -rf ",APPBASE;
  system "rm -f ",TESTPROCFILE;
  }
