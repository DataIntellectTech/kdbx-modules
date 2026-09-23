/ fixture helpers for di.torq's tests.
/ Assumes q is started with the kdbx-modules repo root as the working directory AND with
/ TORQXHOME already pointing at the real kdbx-modules checkout (di.torq's own built-in
/ settings and `builtin` registry genuinely live there - there is no faking that part).
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

/ --- a fake discovery peer for the auto-subscribe tests ---
/ a plain q listener carrying a recording .discovery.getservices, keyed on the CALLER'S handle so a
/ repeat subscribe from the same handle shows as one entry (as it does on the real discovery side).
/ spawned from this process's own executable (the kdb-x build), like the servers/discovery suites.
DISCPORT:0N; DISCPID:0N;
QBIN:{[] r:@[system;"readlink /proc/",(string .z.i),"/exe";{()}]; $[count r;first r;count qh:getenv`QHOME;qh,"/bin/q";"q"]}[];
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
pickport:{[start] first (start+til 500) where isfree each start+til 500};
waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  not isfree port};
spawndisc:{[]
  system QBIN," -p ",string[DISCPORT]," -q </dev/null >/dev/null 2>&1 &";
  if[not waitlisten[DISCPORT;3000];'"test: fake discovery peer failed to listen on ",string DISCPORT];
  h:hopen (`$":localhost:",string DISCPORT;2000);
  DISCPID::h ".z.i";
  h "SUBS:(`int$())!(); .discovery.getservices:{[t;s] SUBS[.z.w]:(t;s); 0#([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$())}";
  hclose h;
  };
killdisc:{[] if[not null DISCPID;@[system;"kill ",string DISCPID;{}]]; DISCPID::0N; system "sleep 0.3";};
/ what the fake peer has recorded: handle -> (proctypes;subscribe). Read over THIS process's own live
/ handle to it when there is one: an async subscribe sits queued on that handle until the event loop
/ flushes it, and a k4unit run never returns to the event loop - a sync read on the same handle flushes
/ it first (the discovery suite's received[] idiom). Otherwise (no connection) a throwaway handle.
discsubs:{[]
  reg:(.m.di.0torq.discoverysub[`servers]`getallservers)[];
  hs:exec w from reg where proctype=`discovery,not null w;
  if[count hs;:(first hs) "SUBS"];
  h:hopen (`$":localhost:",string DISCPORT;2000); r:h "SUBS"; hclose h; r};
/ the one recorded subscription's proctypes argument
discwant:{[] first first value discsubs[]};
/ make this process notice a dead discovery handle: a protected sync call on it makes kdb+ close it (the
/ servers suite's own idiom) - the event loop, which would do this by itself, never runs under k4unit
pokedisc:{[]
  hs:exec w from (.m.di.0torq.discoverysub[`servers]`getallservers)[] where proctype=`discovery,not null w;
  {@[x;"1";{}]} each hs;};

writelines:{[path;lines] (hsym `$path) 0: lines; }

setupfixture:{[]
  DISCPORT::pickport 22000+`int$.z.i mod 20000;
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
  / the custom proctype dials discovery (its init runs servers' startup with this connections list)
  writelines[APPBASE,"/settings/",string[TESTPROCNAME],".q";("widget:1";"connections:enlist`discovery")];

  writelines[APPBASE,"/process.csv";
    ("host,port,proctype,procname";
     "localhost,28580,hdb,hdb";
     "localhost,0,",(string TESTPROCNAME),",testinst";
     "localhost,",(string DISCPORT),",discovery,disc0")];

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
     "  (deps[`servers]`startup)[config];";
     "  deps[`log][`info][`",(string TESTPROCNAME),";\"custom proctype initialised\"];";
     "  };";
     "run:{[] runcalled::runcalled+1};";
     "\\d .")];
  }

/ helper so the test.csv cell stays comma-free (k4unit's CSV splits unquoted commas): writes
/ loadnamecode into the procname settings tier to turn on the procname-tier app-code cascade.
enablenamecode:{[] writelines[APPBASE,"/settings/testinst.q";enlist "loadnamecode:1b"]; }
/ narrow the custom proctype's discovery subscription via the procname settings tier (and undo it)
setdiscoverywant:{[] writelines[APPBASE,"/settings/testinst.q";("loadnamecode:1b";"discoverywant:`rdb`hdb")]; }
cleardiscoverywant:{[] writelines[APPBASE,"/settings/testinst.q";enlist "loadnamecode:1b"]; }
/ the custom proctype's settings with / without discovery in its connections (its init dials them)
setproctypeconns:{[on] writelines[APPBASE,"/settings/",string[TESTPROCNAME],".q";enlist["widget:1"],$[on;enlist "connections:enlist`discovery";()]]; }
/ drop the discovery entry from di.torq's builtin registry (and put it back) for the fragility test
BUILTIN0:();
breakregistry:{[] BUILTIN0::.m.di.0torq.builtin; .m.di.0torq.builtin:(enlist`discovery) _ BUILTIN0;};
fixregistry:{[] .m.di.0torq.builtin:BUILTIN0;};

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
  killdisc[];
  system "rm -rf ",APPBASE;
  system "rm -f ",TESTPROCFILE;
  }
