/ mock log dependency and fixture helpers, loaded from the repo root; sets TORQXAPPHOME so run in its own q session

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

/ servers mock for a reachable wdb: waitfortype succeeds and gethandlebytype returns mockhandle
LASTQ:();
WAITOK:1b;
scalls:([]fn:`symbol$();arg:());
mockstartup:{[c] `scalls set scalls upsert `fn`arg!(`startup;c);};
mockwait:{[pt;t;p] `scalls set scalls upsert `fn`arg!(`waitfortype;pt); WAITOK};
/ the handle evaluates the query against the root .wdb.* variables
mockhandle:{[pt;sel] `scalls set scalls upsert `fn`arg!(`gethandlebytype;pt); {[q] `LASTQ set q; value q}};
mockgetservers:{[pt] ([]w:`int$())};
mockservers:{[] `startup`getservers`gethandlebytype`waitfortype!(mockstartup;mockgetservers;mockhandle;mockwait)}

mockdeps:{[] `log`servers!(`info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);mockservers[])}

/ the root variables a real wdb publishes, which the evaluated query reads
setwdb:{[sd] set[`.wdb.savedir;sd]; set[`.wdb.hdbdir;hsym `$FIXTUREHDBDIR]; set[`.wdb.currentpartition;TESTDATE]; set[`.wdb.writedownmode;`default];}
setwdbparams:{[] setwdb hsym `$FIXTUREDIR;}

/ the wdb reports a savedir that is not on disk - the window before its first flush
setwdbmissingdir:{[] setwdb `:/tmp/di_idb_k4unit_no_such_dir;}

/ remove one of the .wdb variables
dropwdbvar:{[v] ![`.wdb;();0b;enlist v];}

/ init fails with an error naming the unreadable variable
initnovar:{[v]
  resetservercalls[];
  setwdbparams[];
  dropwdbvar v;
  e:@[{idb[`init][cfg[];mockdeps[]]; ""};::;{x}];
  setwdbparams[];
  $[(10h=type e) and 0<count e;0<count e ss "could not read from the wdb: .wdb.",string v;0b]
  }

askedwdb:{[] `waitfortype in exec fn from scalls}

/ the query the idb actually sent, captured by the mock handle
askedforvars:{[] LASTQ~(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition`.wdb.writedownmode)}
resetservercalls:{[] `scalls set ([]fn:`symbol$();arg:()); `WAITOK set 1b; `LASTQ set ();}

FIXTUREDIR:"/tmp/di_idb_k4unit_fixture"
FIXTUREHDBDIR:"/tmp/di_idb_k4unit_hdb_fixture"
TESTDATE:2020.01.01

/ two dated partitions with name enumerated against FIXTUREHDBDIR/sym
setupfixture:{[]
  system "rm -rf ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREHDBDIR;
  widgets:.Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/",string TESTDATE;
  / trailing ` splays the table, as di.torq.proc.wdb's flushtable
  (` sv (hsym `$FIXTUREDIR,"/",(string TESTDATE),"/widgets";`)) set widgets;
  system "mkdir -p ",FIXTUREDIR,"/",string .z.d;
  (` sv (hsym `$FIXTUREDIR,"/",(string .z.d),"/widgets";`)) set widgets;
  }

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; system "rm -rf ",FIXTUREHDBDIR; }

/ config-dict builders; savedir and hdbdir come from the mock wdb
cfg:{[] (enlist`wdbtypes)!enlist `wdb}

/ config that still (wrongly) sets the dirs - init must ignore them and warn
stalecfg:{[] `wdbtypes`savedir`hdbdir!(`wdb;`$":",FIXTUREDIR;`$":",FIXTUREHDBDIR)}

/ --- sym-file change detection ---

/ an unchanged sym file is silent, so a skip is proven by the absence of the entry log
symattempted:{[] 0<count select from calls where lvl=`info,msg like "loading the sym file*"}
symreloaded:{[] symattempted[] and not symfailed[]}
symfailed:{[] 0<count select from calls where lvl=`error,msg like "failed to load sym file*"}

/ .Q.en with an unseen symbol rewrites FIXTUREHDBDIR/sym, making it strictly bigger
growsym:{[s] .Q.en[hsym `$FIXTUREHDBDIR;([]id:enlist 0;name:enlist s)];}

/ no sym file yet
setupnosymfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "rm -rf ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREDIR,"/",string TESTDATE;
  }

/ the first wdb flush creates hdbdir/sym
createsymfile:{[] .Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];}

/ a sym file that exists but cannot be read back as a symbol vector - load signals on it, so the
/ size is never recorded and the next reload must try again
corruptsymfile:{[] (hsym `$FIXTUREHDBDIR,"/sym") 0: enlist "not a serialised symbol vector";}

/ the module's recorded partition and idbdir, read from its private namespace
recordedpartition:{[] get `.m.di.0torq.0proc.0idb.currentpartition}
idbdir:{[] get `.m.di.0torq.0proc.0idb.idbdir}
rootmounted:{[] idbdir[]~.Q.dd[hsym `$FIXTUREDIR;`]}
datemounted:{[d] idbdir[]~.Q.dd[hsym `$FIXTUREDIR;d]}

/ a new dated partition appears under the savedir root, as the wdb's first flush of a new day makes
addpartition:{[d] (` sv (hsym `$FIXTUREDIR,"/",(string d),"/widgets";`)) set .Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];}

/ a partitioned writedown mode: savedir/<partition>/<int partition>/<table>, as the wdb's partbyenum writes
setupenumfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  widgets:.Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];
  {[w;i] (` sv (hsym `$FIXTUREDIR,"/",(string TESTDATE),"/",(string i),"/widgets";`)) set w}[widgets] each 0 1;
  set[`.wdb.writedownmode;`partbyenum];
  }
