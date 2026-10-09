/ fixture helpers for di.torq.proc.wdb's sort-mode tests (proctypes sort and sortworker). Assumes cwd is the kdbx-modules repo root.
/ Uses the REAL di.dbwrite with a recording mock log and a mock servers dep that hands out no handles -
/ the sort tail's reload step is then a logged no-op, which is what we assert on, while the sort and the
/ move (the parts that touch real data) run for real against a working partition built on disk here.
/ Each scenario helper returns 1b only if every named check passes; the per-check dict is left in LAST so
/ a failing row can be diagnosed with `show LAST`. Helpers live here because CSV fields cannot hold commas.

BASE:"/tmp/di_sort_k4unit";
OSSYSCALL:`.m.di.0os.syscall;
PDATE:2026.01.05;

chk:{[d] `LAST set d; all value d};
errmsg:{[f] @[f;::;{x}]};

/ 1b only if f throws AND the error names the expected reason - a bare `fail` row would also pass on an
/ unrelated error (a fixture bug), proving nothing about the path under test
throws:{[f;s] r:errmsg f; (10h=type r) and 0<count r ss s};

/ --- mocks ---

calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklogfn:{[lvl;ctx;msg] `calls upsert `lvl`ctx`msg!(lvl;ctx;msg);};
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])};
logged:{[l;c] 0<count select from calls where lvl=l,ctx=c};
loggedlike:{[l;s] 0<count select from calls where lvl=l,msg like s};

/ nothing but the sortworkers in WORKERS is ever connected, so every reload is a logged no-op
WORKERS:`int$();
scalls:([]fn:`symbol$();arg:());
mockstartup:{[c] `scalls upsert `fn`arg!(`startup;c);};
mockgetservers:{[pt] `scalls upsert `fn`arg!(`getservers;pt); ([]w:$[pt=`sortworker;WORKERS;`int$()])};
mockservers:{[] `startup`getservers!(mockstartup;mockgetservers)};

deps:{[] `log`timer`servers!(mocklog[];(`symbol$())!();mockservers[])};

/ the legacy endofdaysort signature, default writedown mode
tail:{[d;p;t] .m.di.0torq.0proc.0wdb.endofdaysort[d;p;t;`default;()!();(::);`part]};

/ re-SET the recording tables rather than deleting their rows: arg holds a symbol for a getservers
/ call and a config dict for a startup one, and a delete leaves behind whatever type the column
/ narrowed to - after a scenario that only recorded symbols, the next startup upsert throws 'type
resetmocks:{[]
  `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:());
  `scalls set ([]fn:`symbol$();arg:());
  };

/ --- on-disk fixture ---

hdbdir:{[] BASE,"/hdb"};
savedir:{[] BASE,"/wdb"};

/ the wdb module resolves its dirs under TORQXDATAHOME (and the sortcsv under TORQXAPPHOME)
setupfixture:{[]
  system "rm -rf ",BASE;
  system "mkdir -p ",hdbdir[];
  system "mkdir -p ",savedir[];
  setenv[`TORQXDATAHOME;BASE];
  setenv[`TORQXAPPHOME;BASE];
  setenv[`TORQXAPPCONFIG;BASE,"/appconfig"];
  };

/ a deliberately UNSORTED table, so a passing sort assertion cannot be an accident of the input
rawtrade:{[] ([]time:PDATE+0D12:03 0D09:01 0D15:30 0D10:00;sym:`ibm`msft`ibm`msft;price:4?100f)};
rawquote:{[] ([]time:PDATE+0D14:00 0D08:30;sym:`ibm`msft;bid:2?10f)};

/ write one table into the working partition, enumerated against the hdb sym file exactly as the wdb
/ does - so the column on disk is an enum and sorting it needs the root `sym` the module reloads
writepart:{[dir;date;t;data]
  p:` sv (.Q.par[hsym `$dir;date;t];`);
  p set .Q.en[hsym `$hdbdir[];data];
  };

/ the standard starting state: an unsorted trade and quote working partition, empty hdb
makepartition:{[]
  system "rm -rf ",savedir[];
  system "rm -rf ",hdbdir[];
  system "mkdir -p ",hdbdir[];
  writepart[savedir[];PDATE;`trade;rawtrade[]];
  writepart[savedir[];PDATE;`quote;rawquote[]];
  };

/ the on-disk hdb partition for a table, read back
hdbtable:{[t] get hsym `$hdbdir[],"/",(string PDATE),"/",string t};

partitiontables:{[dir] asc key hsym `$dir,"/",string PDATE};

config:{[] `savedir`hdbdir`hdbtypes`rdbtypes`gatewaytypes`reloadorder`permitreload`gc`eodwaittime!
  ("wdb";"hdb";`hdb;`rdb;`gateway;`hdb`rdb;1b;0b;0)};

/ wire the module against a fresh fixture, returning nothing - every scenario starts here
freshwire:{[cfg]
  resetmocks[];
  makepartition[];
  wdb.init[cfg,(enlist`mode)!enlist`sort;deps[]];
  };

/ --- scenarios ---




/ the happy path: sym reloaded, both tables sorted by time, partition moved, working dir gone
tailok:{[]
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  tr:hdbtable`trade;
  qu:hdbtable`quote;
  chk `sortedtrade`sortedquote`rowstrade`rowsquote`moved`workinggone`symloaded`reloadlogged!(
    tr[`time]~asc tr`time;
    qu[`time]~asc qu`time;
    4=count tr;
    2=count qu;
    `quote`trade~partitiontables hdbdir[];
    0=count key hsym `$savedir[],"/",string PDATE;
    (11h=abs type get `sym) and all `ibm`msft in get `sym;
    logged[`info;`reloadsymfile])
  };

/ the sym column survives the move as a resolvable enum - the point of enumerating against hdb/sym
enumintact:{[]
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  tr:hdbtable`trade;
  / read back from disk the column is an ENUM (20h), not a symbol vector - value resolves it
  / against the root sym the module reloaded, which is the property under test
  chk `enumerated`resolves!(
    20h=type tr`sym;
    `msft`msft`ibm`ibm~value tr`sym)
  };

/ no table list means "whatever is in the working partition" - what an operator re-running a sort wants
discovertables:{[]
  freshwire config[];
  tail[savedir[];PDATE;`];
  chk `moved`sorted!(
    `quote`trade~partitiontables hdbdir[];
    (hdbtable[`trade]`time)~asc hdbtable[`trade]`time)
  };

/ an empty savedir on the wire means "use the one I was configured with"
defaultsavedir:{[]
  freshwire config[];
  tail[`;PDATE;`];
  chk `moved`workinggone!(
    `quote`trade~partitiontables hdbdir[];
    0=count key hsym `$savedir[],"/",string PDATE)
  };

/ workers sets a negative -s so peach goes to the sortworkers; reset so later tests run in-process
workerssetting:{[]
  freshwire config[],(enlist`workers)!enlist "2";
  r:system"s";
  system"s 0";
  -2i~r
  };

/ a table already in the hdb partition aborts the whole move, as legacy - nothing is overwritten
nooverwrite:{[]
  freshwire config[];
  / plant a different trade table in the hdb partition first
  writepart[hdbdir[];PDATE;`trade;([]time:enlist PDATE+0D01;sym:enlist`aaa;price:enlist 1f)];
  tail[savedir[];PDATE;`trade`quote];
  tr:hdbtable`trade;
  chk `untouched`logged`quotenotmoved`workingkept!(
    1=count tr;
    loggedlike[`error;"*present in both location*"];
    not `quote in partitiontables hdbdir[];
    `quote`trade~asc key hsym `$savedir[],"/",string PDATE)
  };

/ permitreload off stops the downstream calls but not the sort and the move
noreload:{[]
  freshwire config[],(enlist`permitreload)!enlist 0b;
  tail[savedir[];PDATE;`trade`quote];
  chk `moved`noservercalls!(
    `quote`trade~partitiontables hdbdir[];
    not any `hdb`rdb`gateway in exec arg from scalls where fn=`getservers)
  };

/ with permitreload on, each reloadorder entry is looked up - and logs when nothing is connected
reloadattempted:{[]
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  chk `lookedup`warned!(
    `gateway`hdb`idb`rdb`sortworker`wdb~asc distinct exec arg from scalls where fn=`getservers;
    loggedlike[`error;"no connection to the hdb*"])
  };

/ an unknown reloadorder entry is reported rather than silently skipped
badreloadorder:{[]
  freshwire config[],(enlist`reloadorder)!enlist `hdb`nosuchtype;
  tail[savedir[];PDATE;`trade`quote];
  chk `warned`stillmoved!(
    loggedlike[`warn;"*is neither an hdb, rdb, nor idb type*"];
    `quote`trade~partitiontables hdbdir[])
  };

/ idb is a valid reloadorder entry: looked up like the others, not reported as unknown
idbreloadorder:{[]
  freshwire config[],(enlist`reloadorder)!enlist `hdb`rdb`idb;
  tail[savedir[];PDATE;`trade`quote];
  chk `lookedup`notwarned!(
    `idb in exec arg from scalls where fn=`getservers;
    not loggedlike[`warn;"*is neither*"])
  };

/ run f with di.os's shell calls silenced: a deliberately failing mv writes to stderr, which q does
/ not capture, so the suite prints it even though the failure is the point. The module's own error
/ log still fires, which is what the check below asserts.
quietshell:{[f]
  o:get OSSYSCALL;
  OSSYSCALL set {system x," 2>/dev/null"};
  r:@[f;::;{x}];
  OSSYSCALL set o;
  r
  };

/ a date with no working partition logs the failed move rather than throwing
emptypartition:{[]
  freshwire config[];
  quietshell {tail[savedir[];PDATE+10;`]};
  chk `logged`nothdb!(
    loggedlike[`error;"Failed to move data from wdb*"];
    0=count key hsym `$hdbdir[],"/",string PDATE+10)
  };

/ string settings (toml / command-line overrides) reach module state as the right types
stringconfig:{[]
  c:`savedir`hdbdir`hdbtypes`rdbtypes`gatewaytypes`reloadorder`permitreload`gc`eodwaittime!
    ("wdb";"hdb";"hdb";"rdb";"gateway";"hdb rdb";"true";"false";"0");
  freshwire c;
  tail["";PDATE;`];
  chk `moved`reloadorderparsed!(
    `quote`trade~partitiontables hdbdir[];
    `gateway`hdb`idb`rdb`sortworker`wdb~asc distinct exec arg from scalls where fn=`getservers)
  };

/ the sortcsv is honoured: sorting by sym rather than the time-asc default changes the result
sortcsvhonoured:{[]
  system "mkdir -p ",BASE,"/appconfig";
  (hsym `$BASE,"/appconfig/sort.csv") 0: ("tabname,att,column,sort";"default,,sym,1");
  freshwire config[],(enlist`sortcsv)!enlist "appconfig/sort.csv";
  tail[savedir[];PDATE;`trade];
  tr:hdbtable`trade;
  hdel hsym `$BASE,"/appconfig/sort.csv";
  chk `sortedbysym`nottimesorted!(
    (tr`sym)~asc tr`sym;
    not (tr`time)~asc tr`time)
  };

/ with no sortcsv set, the app's sort.csv under TORQXAPPCONFIG is used
defaultsortcsv:{[]
  system "mkdir -p ",BASE,"/appconfig";
  (hsym `$BASE,"/appconfig/sort.csv") 0: ("tabname,att,column,sort";"default,,sym,1");
  freshwire config[];
  tail[savedir[];PDATE;`trade];
  tr:hdbtable`trade;
  hdel hsym `$BASE,"/appconfig/sort.csv";
  (tr`sym)~asc tr`sym
  };


/ a sort process opens its own connections and publishes the root entry point
initpublishes:{[]
  resetmocks[];
  makepartition[];
  set[`.wdb.endofdaysort;(::)];
  wdb.init[config[],(enlist`mode)!enlist`sort;deps[]];
  c:first exec arg from scalls where fn=`startup;
  chk `startedup`connections`nott`published!(
    1=count select from scalls where fn=`startup;
    `gateway`hdb`idb`rdb`sortworker`wdb~asc c`connections;
    not `tickerplant in c`connections;
    not (::)~ .wdb.endofdaysort)
  };

/ --- sortworkers: real q processes, each on a fresh port so a dying one is never reconnected to ---

NEXTPORT:25931;

/ a sortworker is the wdb module in sort mode with every connection type emptied, as di/torq/settings/sortworker.q does
WCFG:"((enlist`mode)!enlist`sort),`tickerplanttypes`hdbtypes`rdbtypes`idbtypes`gatewaytypes`sorttypes`sortworkertypes`wdbtypes!8#enlist`symbol$()";
workerinit:{[cfg] "w.init[(",WCFG,"),",cfg,";`log`timer`servers!(`info`warn`error!(lg`info;lg`warn;lg`error);(`symbol$())!();`startup`getservers!({[c]};{[pt] ([]w:`int$())}))];"};
workerlog:("lg:{[l;c;m] `LOGS upsert `lvl`ctx`msg!(l;c;m);};";"LOGS:([]lvl:`symbol$();ctx:`symbol$();msg:());";"w:use`di.torq.proc.wdb;");

workerscript:(!) . flip (
  (`real;workerlog,enlist workerinit "()!()");
  (`symsort;workerlog,enlist workerinit "(enlist`sortcsv)!enlist \"appconfig/sym.csv\"");
  (`bare;enlist ""));

startworker:{[kind;port]
  f:BASE,"/worker_",(string kind),".q";
  (hsym `$f) 0: workerscript kind;
  system "timeout 120 ",(first .z.X)," ",f," -p ",(string port)," -q </dev/null >/dev/null 2>&1 &";
  h:0Ni;n:0;
  while[(null h) and 50>n+:1;h:@[hopen;(`$"::",string port;200);{0Ni}];if[null h;system "sleep 0.1"]];
  h
  };

startworkers:{[kinds] `WORKERS set kinds startworker' NEXTPORT+til count kinds;`NEXTPORT set NEXTPORT+count kinds;};

stopworkers:{[]
  {@[{neg[x](exit;0);neg[x][]};x;::];@[hclose;x;::]} each WORKERS;
  `WORKERS set `int$();
  system "s 0";
  };

workersorted:{[h] exec msg from h"LOGS" where ctx=`sort,msg like "finished*"};

/ with -s negative, each of two workers sorts one table
fanoutok:{[]
  startworkers`real`real;
  system "s -2";
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  tr:hdbtable`trade;
  r:chk `sorted`moved`bothworked`logged!(
    tr[`time]~asc tr`time;
    `quote`trade~partitiontables hdbdir[];
    all 1=count each workersorted each WORKERS;
    loggedlike[`info;"sorting on worker sort*"]);
  stopworkers[];
  r
  };

/ a worker sorts to its own sortcsv, as legacy's did
workersortcsv:{[]
  system "mkdir -p ",BASE,"/appconfig";
  (hsym `$BASE,"/appconfig/sym.csv") 0: ("tabname,att,column,sort";"default,,sym,1");
  startworkers`symsort`symsort;
  system "s -2";
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  tr:hdbtable`trade;
  r:chk `sortedbysym`nottimesorted!((tr`sym)~asc tr`sym;not (tr`time)~asc tr`time);
  stopworkers[];
  r
  };

/ without a negative -s, connected workers are not used
noworkers:{[]
  startworkers`real`real;
  freshwire config[];
  tail[savedir[];PDATE;`trade`quote];
  r:chk `main`idle!(loggedlike[`info;"sorting on main sort"];all 0=count each workersorted each WORKERS);
  stopworkers[];
  r
  };

/ a failing worker makes the tail throw before the move
workerfails:{[]
  startworkers enlist`bare;
  system "s -1";
  freshwire config[];
  r:chk `threw`notmoved!(
    0<count @[{tail[savedir[];PDATE;`trade`quote];""};::;{x}];
    0=count key hsym `$hdbdir[],"/",string PDATE);
  stopworkers[];
  r
  };

/ proctype sortworker is the wdb module under di/torq/settings/sortworker.q: it dials nothing but publishes the worker calls
workersettings:{[]
  wc:((use`di.torq.config)`parsefile)["di/torq/settings/sortworker.q"];
  resetmocks[];
  wdb.init[config[],wc;deps[]];
  c:first exec arg from scalls where fn=`startup;
  chk `noconnections`sorttab`merge`reloadsymfile`syncpartsizes!(
    0=count c`connections;
    not (::)~.sort.sorttab;
    not (::)~.wdb.merge;
    not (::)~.wdb.reloadsymfile;
    not (::)~.merge.syncpartsizes)
  };
