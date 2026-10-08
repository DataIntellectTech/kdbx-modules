/ fixture helpers for di.torq.proc.wdb's end-to-end tests. Assumes cwd is the kdbx-modules repo root.
/ A spawned q process answers .u.subdetails as the tickerplant; everything else is mocked.

BASE:"/tmp/di_wdb_k4unit";
TPPORT:25961;

chk:{[d] `LAST set d; all value d};

/ module-local state and internals, for the checks that cannot go through the export dict
MOD:`.m.di.0torq.0proc.0wdb;
mv:{[n] get .Q.dd[MOD;n]};

calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklogfn:{[lvl;ctx;msg] `calls upsert `lvl`ctx`msg!(lvl;ctx;msg);};
reclog:`info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);
loggedlike:{[l;s] 0<count select from calls where lvl=l,msg like s};

TPH:0Ni;
TPUP:1b;
PEERS:(`symbol$())!();
servers:{[] `startup`getservers`gethandlebytype`waitfortype!(
  {[c]};
  {[pt] ([]w:`int$(),$[pt in key PEERS;PEERS pt;()])};
  {[pt;sel] TPH};
  {[pt;t;p] TPUP})};
/ handlers is required by di.subscriptions, which the wdb inits with its own deps
rechandlers:`register`remove`list!({[ev;ph;nm;pri;fn]};{[ev;ph;nm]};{[ev]});
recdeps:{[] `log`timer`servers`handlers!(reclog;`addjob`deletejobs!({[a;b;c;d;e;f]};{[x]});servers[];rechandlers)};

starttp:{[]
  f:BASE,"/faketp.q";
  (hsym `$f) 0: ("sc:`trade`quote!(([]time:`timestamp$();sym:`symbol$();price:`float$());([]time:`timestamp$();sym:`symbol$();bid:`float$()));";
    ".u.subdetails:{[t;s] `tables`schemas`logfile`rowcount`date!(key sc;sc;`;0;.z.D)};");
  system "timeout 300 ",(first .z.X)," ",f," -p ",(string TPPORT)," -q </dev/null >/dev/null 2>&1 &";
  n:0;
  while[(null TPH) and 50>n+:1;`TPH set @[hopen;(`$"::",string TPPORT;200);{0Ni}];if[null TPH;system "sleep 0.1"]];
  };

stoptp:{[] @[{neg[x](exit;0);neg[x][]};TPH;::]; @[hclose;TPH;::]; `TPH set 0Ni;};

setup:{[]
  system "rm -rf ",BASE;
  system "mkdir -p ",BASE,"/appconfig";
  setenv[`TORQXDATAHOME;BASE];
  setenv[`TORQXAPPHOME;BASE];
  setenv[`TORQXAPPCONFIG;BASE,"/appconfig"];
  (hsym `$BASE,"/appconfig/sort.csv") 0: ("tabname,att,column,sort";"default,p,sym,1";"default,,time,1");
  starttp[];
  };

cfg:{[] `savedir`hdbdir`sortcsv`numrows`eodwaittime`reloadorder`ignorelist!("wdb";"hdb";"appconfig/sort.csv";100000;0;`hdb;`heartbeat`logmsg`calls)};

today:{[] .z.D};
hdbpart:{[t] hsym `$BASE,"/hdb/",(string today[]),"/",string t};
wdbpart:{[] hsym `$BASE,"/wdb/",string today[]};

freshwdb:{[c]
  `calls set 0#calls;
  system "rm -rf ",BASE,"/wdb ",BASE,"/hdb";
  wdb.init[c;recdeps[]];
  };

/ 8 trades over three syms, fed in two batches so a partitioned mode writes more than one segment
feed:{[]
  upd[`trade;([]time:.z.D+0D09 0D12 0D10 0D11;sym:`ibm`msft`ibm`aapl;price:4?100f)];
  upd[`quote;([]time:.z.D+0D09 0D08;sym:`ibm`msft;bid:2?10f)];
  .m.di.0torq.0proc.0wdb.savetodisk[];
  upd[`trade;([]time:.z.D+0D15 0D14 0D13 0D16;sym:`msft`aapl`ibm`msft;price:4?100f)];
  };

/ the whole day ends up in the hdb, grouped by sym with p# applied, and the working partition is gone
eodok:{[c]
  freshwdb c;
  feed[];
  endofday today[];
  t:select from get hdbpart`trade;
  / enum on disk, but select resolves it once the sym domain is loaded - take the column as-is
  s:t`sym;
  chk `rows`psym`grouped`quote`wdbgone!(
    8=count t;
    `p=attr (get hdbpart`trade)`sym;
    (count distinct s)=sum differ s;
    2=count get hdbpart`quote;
    0=count key wdbpart[])
  };

defaultmode:{[] eodok cfg[]};
partbyattr:{[m] eodok cfg[],`writedownmode`mergemode!(`partbyattr;m)};
partbyenum:{[m] eodok cfg[],`writedownmode`mergemode!(`partbyenum;m)};
partbyfirstchar:{[m] eodok cfg[],`writedownmode`mergemode!(`partbyfirstchar;m)};

/ each intraday flush writes one segment per parted value, and the sizes are tracked for the merge
segments:{[]
  freshwdb cfg[],`writedownmode`immediate!(`partbyattr;1b);
  feed[];
  ps:(use`di.merge)[`getpartsizes][];
  chk `segs`tracked!(
    `aapl`ibm`msft~asc key hsym `$(1_string wdbpart[]),"/trade";
    3=count select from ps where ptdir like "*trade*")
  };

/ startup writes empty schemas into the working partition for the idb
missingtables:{[]
  freshwdb cfg[];
  chk `trade`quote!(0=count get ` sv (wdbpart[];`trade;`);0=count get ` sv (wdbpart[];`quote;`))
  };

tabsizes:{[]
  freshwdb cfg[],(enlist`immediate)!enlist 1b;
  upd[`quote;([]time:.z.D+0D01*til 5;sym:5#`ibm;bid:5?10f)];
  upd[`trade;([]time:.z.D+0D01*til 2;sym:2#`ibm;price:2?10f)];
  .m.di.0torq.0proc.0wdb.savetodisk[];
  `quote`trade~2#.m.di.0torq.0proc.0wdb.tablelist[]
  };

manipulation:{[]
  freshwdb cfg[],(enlist`savedownmanipulation)!enlist (enlist`trade)!enlist {update price:2*price from x};
  upd[`trade;([]time:enlist .z.D+0D01;sym:enlist`ibm;price:enlist 5f)];
  endofday today[];
  10f~first (get hdbpart`trade)`price
  };

postreplay:{[]
  `POST set ();
  freshwdb cfg[],(enlist`postreplay)!enlist {[d;p] `POST set (d;p)};
  feed[];
  endofday today[];
  (last POST)~today[]
  };

compression:{[]
  freshwdb cfg[],(enlist`compression)!enlist 17 2 6;
  feed[];
  endofday today[];
  chk `compressed`reset!(
    0<count -21!` sv hdbpart[`trade],`price;
    (16 0 0)~.z.zd)
  };

fixpartition:{[]
  freshwdb cfg[];
  y:today[]-1;
  .m.di.0torq.0proc.0wdb.fixpartition y;
  chk `moved`current!(
    `quote`trade~asc key hsym `$BASE,"/wdb/",string y;
    y~.m.di.0torq.0proc.0wdb.currentpartition)
  };

tpretry:{[]
  `TPUP set 0b;
  r:@[wdb.init[;recdeps[]];cfg[],(enlist`tpwaittimeout)!enlist 100;{x}];
  `TPUP set 1b;
  (10h=type r) and 0<count r ss "connection within 100ms"
  };

pattrcheck:{[]
  (hsym `$BASE,"/appconfig/nop.csv") 0: ("tabname,att,column,sort";"default,,time,1");
  freshwdb cfg[],`writedownmode`sortcsv!(`partbyattr;"appconfig/nop.csv");
  loggedlike[`error;"default table not defined in sort.csv*"]
  };

replaythreshold:{[]
  freshwdb cfg[],`replaynumrows`numrows!(2;100000);
  chk `replay`live!(2=.m.di.0torq.0proc.0wdb.replaymaxrows`trade;100000=.m.di.0torq.0proc.0wdb.maxrows`trade)
  };

/ --- peer processes: real q processes, each on a fresh port ---

NEXTPORT:25971;
PEERH:`int$();

mockserversq:"`startup`getservers!({[c]};{[pt] ([]w:`int$())})";
logq:("LOGS:([]lvl:`symbol$();ctx:`symbol$();msg:());";"lg:{[l;c;m] `LOGS upsert `lvl`ctx`msg!(l;c;m);};";"ld:`info`warn`error!(lg`info;lg`warn;lg`error);");

peerscript:(!) . flip (
  (`sortworker;logq,("w:use`di.torq.proc.wdb;";"w.init[(((enlist`mode)!enlist`sort),`tickerplanttypes`hdbtypes`rdbtypes`idbtypes`gatewaytypes`sorttypes`sortworkertypes`wdbtypes!8#enlist`symbol$()),(enlist`sortcsv)!enlist \"appconfig/sort.csv\";`log`timer`servers!(ld;(`symbol$())!();",mockserversq,")];"));
  (`sort;logq,("s:use`di.torq.proc.wdb;";"s.init[`mode`savedir`hdbdir`sortcsv`eodwaittime`reloadorder!(`sort;\"wdb\";\"hdb\";\"appconfig/sort.csv\";0;`hdb);`log`timer`servers!(ld;(`symbol$())!();",mockserversq,")];"));
  (`hdb;enlist "RELOADS:0;.hdb.reload:{[] RELOADS+:1;};"));

startpeer:{[kind]
  port:NEXTPORT;`NEXTPORT set NEXTPORT+1;
  f:BASE,"/peer_",(string kind),(string port),".q";
  (hsym `$f) 0: peerscript kind;
  system "timeout 300 ",(first .z.X)," ",f," -p ",(string port)," -q </dev/null >/dev/null 2>&1 &";
  h:0Ni;n:0;
  while[(null h) and 50>n+:1;h:@[hopen;(`$"::",string port;200);{0Ni}];if[null h;system "sleep 0.1"]];
  `PEERH set PEERH,h;
  h
  };

stoppeers:{[]
  {@[{neg[x](exit;0);neg[x][]};x;::];@[hclose;x;::]} each PEERH;
  `PEERH set `int$();
  `PEERS set (`symbol$())!();
  };

/ a saveandsort wdb started with a negative -s merges on its sortworkers
workermerge:{[]
  `PEERS set enlist[`sortworker]!enlist h:startpeer each `sortworker`sortworker;
  system "s -2";
  r:eodok cfg[],`writedownmode`mergemode!(`partbyattr;`hybrid);
  system "s 0";
  merged:{[h] count h"select from LOGS where ctx=`merge,msg like \"*merge complete\""} each h;
  stoppeers[];
  r and all 0<merged
  };

/ a save-mode wdb hands the day to the sort process, partsizes included
savemode:{[wm]
  `PEERS set enlist[`sort]!enlist enlist h:startpeer`sort;
  r:eodok cfg[],`mode`writedownmode`mergemode!(`save;wm;`part);
  stoppeers[];
  r and not loggedlike[`error;"can't connect to the sortandreload*"]
  };

/ the sort waits on the sort process's queue: an async call is finished once a later sync one returns
eodok:{[c]
  freshwdb c;
  feed[];
  endofday today[];
  if[`sort in key PEERS;(first PEERS`sort)""];
  t:select from get hdbpart`trade;
  / enum on disk, but select resolves it once the sym domain is loaded - take the column as-is
  s:t`sym;
  chk `rows`psym`grouped`quote`wdbgone!(
    8=count t;
    `p=attr (get hdbpart`trade)`sym;
    (count distinct s)=sum differ s;
    2=count get hdbpart`quote;
    0=count key wdbpart[])
  };

/ with eodwaittime on, the hdb reloads asynchronously and calls .wdb.handler back
handshake:{[]
  `PEERS set enlist[`hdb]!enlist enlist h:startpeer`hdb;
  freshwdb cfg[],(enlist`eodwaittime)!enlist 5;
  feed[];
  endofday today[];
  h"";
  r:chk `reloaded`released`logged!(
    1=h"RELOADS";
    .m.di.0torq.0proc.0wdb.reloadcomplete;
    loggedlike[`info;"1 out of 1 processes successfully reloaded"]);
  stoppeers[];
  r
  };

/ with eodwaittime off, the reload is a sync call
syncreload:{[]
  `PEERS set enlist[`hdb]!enlist enlist h:startpeer`hdb;
  freshwdb cfg[];
  feed[];
  endofday today[];
  r:chk `reloaded`logged!(1=h"RELOADS";loggedlike[`info;"the hdb successfully reloaded"]);
  stoppeers[];
  r
  };

/ tablelist[] orders by bytes from tabsizes, so a partitioned writedown must populate it too
tabsizestracked:{[]
  freshwdb cfg[],`writedownmode`mergemode`numrows!(`partbyattr;`part;1);
  feed[];
  (mv`savetodisk)[];
  ts:mv`tabsizes;
  chk `populated`bothtables`bytespositive`largestfirst!(
    0<count ts;
    `quote`trade~asc exec tablename from ts;
    all 0<exec bytes from ts;
    `trade~first (mv`tablelist)[])
  };

/ tabsizes is populated in every mode now, so end of day has to clear it in every mode
tabsizescleared:{[]
  freshwdb cfg[],`writedownmode`mergemode`numrows!(`partbyattr;`part;1);
  feed[];
  (mv`savetodisk)[];
  before:count mv`tabsizes;
  endofday today[];
  chk `wastracked`nowempty!(0<before;0=count mv`tabsizes)
  };

/ a deployment with no gateway is normal, so an absent gateway must not log an error every eod
nogatewayquiet:{[]
  freshwdb cfg[];
  feed[];
  endofday today[];
  chk `noerror`saidso!(not loggedlike[`error;"*gateway*"];loggedlike[`info;"no gateway detected*"])
  };

/ legacy exposed getpartition as an overridable setting, so a config value must win over the default
getpartitionoverride:{[]
  freshwdb cfg[],(enlist`getpartition)!enlist {[] 2001.09.11};
  chk `used`notthedefault!(2001.09.11~(mv`getpartition)[];not 2001.09.11~(mv`defaultgetpartition)[])
  };

