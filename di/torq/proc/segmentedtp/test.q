/ fixture helpers for di.torq.proc.segmentedtp's unit tests. Assumes cwd is the kdbx-modules repo root.
/ Uses REAL di.pubsub / di.eodtime / di.tplogmgr with a recording mock log, timer and handlers - the timer
/ never runs a cycle, so tick/rolls fire only when a test calls them. Each scenario helper inits the module
/ against its own log dir and returns 1b only if every named check passes; the per-check dict is left in LAST
/ so a failing row can be diagnosed with `show LAST`. Helpers live here because CSV fields cannot hold commas.

BASE:"/tmp/di_segmentedtp_k4unit";
MOD:`.m.di.0torq.0proc.0segmentedtp;

/ read / write module state and reach internal functions
mv:{[n] get .Q.dd[MOD;n]};
mset:{[n;v] .Q.dd[MOD;n] set v;};

chk:{[d] `LAST set d; all value d};
errmsg:{[f] @[f;::;{x}]};

/ 1b only if f throws AND the error names the expected reason - a bare `fail` row would also pass on an
/ unrelated error (a fixture bug), proving nothing about the path under test
throws:{[f;s] r:errmsg f; (10h=type r) and 0<count r ss s};

/ --- mocks ---

calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklogfn:{[lvl;ctx;msg] `calls upsert `lvl`ctx`msg!(lvl;ctx;msg);};
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])};

tcalls:([]fn:`symbol$();arg:());
mockaddjob:{[id;func;params;period;mode;opts] `tcalls upsert `fn`arg!(`addjob;(id;period;mode;opts));};
mocktimerfn:{[fn;ids] `tcalls upsert `fn`arg!(fn;ids);};
mocktimer:{[] `addjob`deletejobs`enablejobs`disablejobs!(mockaddjob;mocktimerfn[`deletejobs];mocktimerfn[`enablejobs];mocktimerfn[`disablejobs])};

hcalls:([]fn:`symbol$();arg:());
mockregister:{[event;phase;name;priority;func] `hcalls upsert `fn`arg!(`register;(event;phase;name));};
mockremove:{[event;phase;name] `hcalls upsert `fn`arg!(`remove;(event;phase;name));};
mockhandlers:{[] `register`remove!(mockregister;mockremove)};

deps:{[] `log`timer`handlers!(mocklog[];mocktimer[];mockhandlers[])};
resetmocks:{[] delete from `calls; delete from `tcalls; delete from `hcalls;};

/ root callbacks a subscriber would define: in-process subscriptions register handle 0, and di.pubsub's
/ end-of-period / end-of-day broadcasts to handle 0 evaluate these synchronously
endofperiod:{[x] `EOP set x;};
endofday:{[d] `EOD set d;};
/ replaying an error log executes (`upderr;t;x)
upderr:{[t;x] `ERRS set ERRS,enlist (t;x);};

/ --- fixture ---

setupfixture:{[]
  system "rm -rf ",BASE;
  system "mkdir -p ",BASE;
  setenv[`TORQXAPPHOME;BASE];
  setenv[`TORQXDATAHOME;BASE];
  (hsym`$BASE,"/database.q") 0: (
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$())";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$())";
    "depth:([]time:`timestamp$();sym:`symbol$();lvl:`long$())");
  (hsym`$BASE,"/badschema.q") 0: enlist "widgets:([]id:`int$();name:`symbol$())";
  (hsym`$BASE,"/custom.csv") 0: ("table,mode";"trade,singular";"quote,singular";"depth,tabperiod");
  (hsym`$BASE,"/partial.csv") 0: ("table,mode";"trade,tabular");
  (hsym`$BASE,"/badmode.csv") 0: ("table,mode";"trade,hourly");
  (hsym`$BASE,"/badheader.csv") 0: ("tab,kind";"trade,tabular");
  };

teardownfixture:{[]
  if[mv`initdone;(st`teardown)[]];
  system "rm -rf ",BASE;
  };

/ config for a log dir (relative to TORQXDATAHOME) plus scenario settings
cfg:{[dir;extra] (`kdbtplog`schemafile!(dir;BASE,"/database.q")),extra};

/ empty the schema tables at root - only those loaded so far (the first init has not loaded them yet)
clearroot:{[] {x set 0#get x} each `trade`quote`depth inter tables[];};

doinit:{[c]
  resetmocks[];
  clearroot[];
  (use`di.pubsub)[`closesub][0];
  (st`init)[c;deps[]];
  };

/ --- lookups ---

daydir:{[dir] BASE,"/",dir,"/stp_",string (mv[`eod]`getd)[]};
metaof:{[dir] get hsym`$daydir[dir],"/stpmeta"};
fileof:{[t] exec first logname from mv[`currlog] where tbl=t};
logcount:{[f] c:-11!(-2;f); $[0>type c;c;first c]};
cnt:{[t;col] ct:0!((st`getcounts)[])`tables; first (ct col) where ct[`tbl]=t};
tf:{[] (mv`gentimeformat) mv`currperiod};
dayerrname:{[] `$"stp_segmentederrorlogfile",(mv`gentimeformat)"p"$(mv[`eod]`getd)[]};

/ open file descriptors of this process pointing exactly at a file (0 once closed)
fdcount:{[f] count @[system;"ls -l /proc/",(string .z.i),"/fd 2>/dev/null | awk '$NF==\"",(1_string f),"\"'";{()}]};

/ feed n rows of table t through the published root upd (column-list form, one record each)
feed:{[t;n] {[t;i] upd[t;(`$"S",string i;$[t=`depth;i;1.0*i])]}[t] each til n;};

/ truncate a log mid-message
smash:{[f] n:hcount f; f 1: read1 (f;0;n-5);};

/ --- init validation ---

initbadschema:{[] throws[{(st`init)[`kdbtplog`schemafile!("tplog/v";BASE,"/badschema.q");deps[]]};"no publishable tables"]};
initnotdict:{[] throws[{(st`init)[cfg["tplog/v";()!()];(::)]};"deps must be a dict"]};
initnolog:{[] throws[{(st`init)[cfg["tplog/v";()!()];`timer`handlers#deps[]]};"log dependency is required"]};
initnotimer:{[] throws[{(st`init)[cfg["tplog/v";()!()];`log`handlers#deps[]]};"timer dependency is required"]};
initnohandlers:{[] throws[{(st`init)[cfg["tplog/v";()!()];`log`timer#deps[]]};"handlers dependency is required"]};
initlogkeys:{[] throws[{(st`init)[cfg["tplog/v";()!()];@[deps[];`log;:;`info`warn#mocklog[]]]};"missing error"]};
initnokdbtplog:{[] throws[{(st`init)[enlist[`schemafile]!enlist BASE,"/database.q";deps[]]};"kdbtplog is required"]};
initbad:{[k;v] resetmocks[]; (st`init)[cfg["tplog/v";enlist[k]!enlist v];deps[]]};
initrejects:{[k;v;s] throws[{[k;v;x] initbad[k;v]}[k;v];s]};

badmsgnames:{[]
  m:errmsg each ({initbad[`multilog;`hourly]};{initbad[`batchmode;`sometimes]};{initbad[`replayperiod;`prior]});
  all 0<count each m ss' ("multilog";"batchmode";"replayperiod")
  };

fix7:{[]
  resetmocks[];
  clearroot[];
  / a throw from the very last dependency call, after logs were opened and the job added
  bad:@[deps[];`handlers;:;`register`remove!({[event;phase;name;priority;func] '"boom"};mockremove)];
  r:@[(st`init)[cfg["tplog/fix7";()!()]];bad;{x}];
  notdone:not mv`initdone;
  resetmocks[];
  (st`init)[cfg["tplog/fix7";()!()];deps[]];
  chk `threw`notdone`done`onejob`onehandler`deletedfirst`onefd!(
    10h=type r;
    notdone;
    mv`initdone;
    1=count select from tcalls where fn=`addjob;
    1=count select from hcalls where fn=`register;
    (exec first i from tcalls where fn=`deletejobs)<exec first i from tcalls where fn=`addjob;
    1=fdcount fileof`trade)
  };

reinit:{[]
  doinit cfg["tplog/reinit";()!()];
  doinit cfg["tplog/reinit";()!()];
  chk `onejob`onehandler`removed`onefd!(
    1=count select from tcalls where fn=`addjob;
    1=count select from hcalls where fn=`register;
    `remove in exec fn from hcalls;
    1=fdcount fileof`trade)
  };

defaults:{[]
  doinit cfg["tplog/defaults";()!()];
  chk `multilog`multilogperiod`errmode`batchmode`replayperiod`errorlogname`createlogs`logprefix`tickinterval`kdbtplog!(
    `tabperiod=mv`multilog;
    0D01=mv`multilogperiod;
    mv`errmode;
    `defaultbatch=mv`batchmode;
    `day=mv`replayperiod;
    `segmentederrorlogfile=mv`errorlogname;
    mv`createlogs;
    "stp"~mv`logprefix;
    1=mv`tickinterval;
    (BASE,"/tplog/defaults")~mv`kdbtplog)
  };

/ the job survives a failing run: di.timer's disableonfail default would stop it silently on the first throw
jobok:{[] j:exec first arg from tcalls where fn=`addjob; chk `idperiodmode`survivesfailure!((`segmentedtp;1;1h)~3#j;0b~(j 3)`disableonfail)};

tickprotected:{[]
  doinit cfg["tplog/tickp";()!()];
  saved:mv`flushfn;
  mset[`flushfn;{'"disk full"}];
  r:@[{(mv`tick)[];1b};::;{x}];
  mset[`flushfn;saved];
  chk `nothrow`logged!(1b~r;0<count select from calls where lvl=`error,ctx=`tick)
  };

stringconfig:{[]
  / .toml / command-line overrides deliver strings and plain numbers - each must reach state as the right type
  doinit cfg["tplog/strcfg";`errmode`createlogs`tickinterval`multilogperiod`multilog`batchmode!("false";"true";"5";1800;"periodic";"immediate")];
  chk `errmode`createlogs`tickinterval`multilogperiod`multilog`batchmode!(
    0b~mv`errmode;
    1b~mv`createlogs;
    5=mv`tickinterval;
    0D00:30=mv`multilogperiod;
    `periodic=mv`multilog;
    `immediate=mv`batchmode)
  };

shortfile:{[]
  / a log truncated inside its 8-byte header (a crash mid-create) holds nothing; it is recovered as an empty .good
  dir:"tplog/short";
  c:cfg[dir;`multilog`batchmode!(`tabular;`immediate)];
  doinit c;
  f:fileof`trade;
  (st`teardown)[];
  f 1: 0x0102030405;
  doinit c;
  g:fileof`trade;
  feed[`trade;2];
  chk `good`emptybase`appends`origuntouched!(g~(mv`goodname) f;0=(mv`basecount) g;2=logcount g;5=hcount f)
  };

stringtablename:{[]
  doinit cfg["tplog/strtab";enlist[`batchmode]!enlist`immediate];
  upd["trade";(`A;1.0)];
  1=cnt[`trade;`msgcount]
  };
handlerok:{[] (`.z.exit;`;`segmentedtp)~exec first arg from hcalls where fn=`register};

forced:{[]
  doinit cfg["tplog/forceds";`multilog`multilogperiod!(`singular;0D00:10)];
  s:mv`multilogperiod;
  doinit cfg["tplog/forcedt";`multilog`multilogperiod!(`tabular;0D00:10)];
  t:mv`multilogperiod;
  doinit cfg["tplog/forcedc";`multilog`multilogperiod`customcsv!(`custom;0D00:10;"custom.csv")];
  chk `singular`tabular`custom!(1D=s;1D=t;0D00:10=mv`multilogperiod)
  };

/ timezone / roll-offset settings reach di.eodtime - symbol and string (.toml) forms; GMT keeps the expected
/ roll time independent of daylight saving
tzconfigok:{[]
  doinit cfg["tplog/tz";`rolltimezone`datatimezone`rolltimeoffset!(`GMT;"GMT";0D10:00)];
  nr:(mv[`eod]`getnextroll)[];
  / time of day of the next roll - via longs, as timespan mod timespan throws 'type
  chk `initialised`offsetapplied`rollahead!(mv`initdone;0D10:00=`timespan$(`long$"n"$nr) mod `long$1D;nr>.z.p)
  };

/ a TOML-style string offset is parsed and reaches di.eodtime; a value that cannot be parsed is dropped with a warning
tzstringok:{[]
  doinit cfg["tplog/tzs";`rolltimezone`rolltimeoffset!("GMT";"0D10:00:00")];
  nr:(mv[`eod]`getnextroll)[];
  a:enlist[`stringoffset]!enlist 0D10:00=`timespan$(`long$"n"$nr) mod `long$1D;
  doinit cfg["tplog/tzb";enlist[`rolltimeoffset]!enlist `notatimespan];
  chk a,`badignored`badwarned!(0D=`timespan$(`long$"n"$(mv[`eod]`getnextroll)[]) mod `long$1D;0<count select from calls where lvl=`warn,ctx=`init)
  };

/ file names carry procname when di.torq supplies one, so two processes sharing a kdbtplog cannot collide
prefixok:{[]
  dir:"tplog/prefix";
  doinit cfg[dir;`procname`multilog!(`stp7;`singular)];
  a:`procname`dir!("stp7"~mv`logprefix;(BASE,"/",dir,"/stp7_",string (mv[`eod]`getd)[])~mv`dldir);
  doinit cfg["tplog/prefix2";`procname`logprefix!(`stp7;"custom")];
  chk a,enlist[`explicitwins]!enlist "custom"~mv`logprefix
  };

prefixempty:{[] throws[{doinit cfg["tplog/prefixe";enlist[`logprefix]!enlist ""]};"logprefix must not be empty"]};

logdictwiring:{[]
  resetmocks[];
  clearroot[];
  lg:use`di.util.log;
  (st`init)[cfg["tplog/logdict";()!()];lg[`logdict],`timer`handlers!(mocktimer[];mockhandlers[])];
  mv`initdone
  };

versionok:{[]
  v:st`version;
  chk `exported`semver`nonewline!(`version in key st;3=count "." vs v;not any v in "\n\r")
  };

/ --- naming modes ---

nameok:{[mode]
  dir:"tplog/names",string mode;
  doinit cfg[dir;`multilog`batchmode!(mode;`immediate)];
  f:tf[];
  ex:$[mode in `tabperiod`tabular;`$("stp_depth";"stp_quote";"stp_trade"),\:f;mode=`singular;enlist`$"stp_",f;enlist`$"stp_periodic",f];
  got:asc key hsym`$daydir dir;
  `LAST set `got`ex!(got;ex);
  (asc ex,dayerrname[],`stpmeta)~got
  };

sharedhandle:{[]
  doinit cfg["tplog/shared";enlist[`multilog]!enlist`singular];
  1=count distinct exec handle from mv`currlog
  };

customnames:{[]
  dir:"tplog/namescustom";
  doinit cfg[dir;`multilog`batchmode`customcsv!(`custom;`immediate;"custom.csv")];
  f:tf[];
  got:asc key hsym`$daydir dir;
  `LAST set `got`f!(got;f);
  (asc (`$("stp_",f;"stp_depth",f)),dayerrname[],`stpmeta)~got
  };

/ --- batch modes and updates ---

immediateok:{[]
  doinit cfg["tplog/imm";enlist[`batchmode]!enlist`immediate];
  feed[`trade;2];
  chk `norows`logged`msgcount`rowcount`pending`seqnum!(
    0=count trade;
    2=logcount fileof`trade;
    2=cnt[`trade;`msgcount];
    2=cnt[`trade;`rowcount];
    0=cnt[`trade;`pendingmsgcount];
    2=((st`getcounts)[])`seqnum)
  };

defaultok:{[]
  doinit cfg["tplog/default";()!()];
  feed[`trade;3];
  a:`rows`logged`msgcount`pending!(3=count trade;3=logcount fileof`trade;0=cnt[`trade;`msgcount];3=cnt[`trade;`pendingmsgcount]);
  (mv`tick)[];
  chk a,`cleared`counted`nopending!(0=count trade;3=cnt[`trade;`msgcount];0=cnt[`trade;`pendingmsgcount])
  };

memoryok:{[]
  doinit cfg["tplog/memory";enlist[`batchmode]!enlist`memorybatch];
  feed[`trade;3];
  a:`rows`notlogged!(3=count trade;0=logcount fileof`trade);
  (mv`tick)[];
  chk a,`onemsg`msgcount`rowcount`cleared!(1=logcount fileof`trade;1=cnt[`trade;`msgcount];3=cnt[`trade;`rowcount];0=count trade)
  };

stampok:{[]
  doinit cfg["tplog/stamp";()!()];
  upd[`trade;(`A;1.0)];
  upd[`trade;(2020.01.01D00:00:00;`B;2.0)];
  upd[`trade;([]sym:`C`D;price:3 4.0)];
  upd[`trade`quote;((`E;5.0);(`F;6.0))];
  chk `stamped`kept`tablein`multi`quote!(
    0D00:00:05>abs .z.p-first trade`time;
    2020.01.01D00:00:00=trade[1;`time];
    `C`D~trade[2 3;`sym];
    `E~last trade`sym;
    `F~first quote`sym)
  };

errmodeok:{[]
  doinit cfg["tplog/err";()!()];
  upd[`nosuch;(`A;1.0)];
  upd[`trade;(`A;"notafloat")];
  `ERRS set ();
  -11!mv`errlog;
  chk `twoerrs`unknowntable`badtype`warned!(
    2=count ERRS;
    `nosuch~first first ERRS;
    `trade~first last ERRS;
    2=count select from calls where lvl=`warn,ctx=`upd)
  };

noerrmode:{[]
  doinit cfg["tplog/noerr";`errmode`batchmode!(0b;`immediate)];
  throws[{upd[`nosuch;(`A;1.0)]};"not a publishable table"]
  };

nologsok:{[]
  doinit cfg["tplog/nologs";`createlogs`errmode`batchmode!(0b;0b;`immediate)];
  r:@[{feed[`trade;2];1b};::;{x}];
  chk `nothrow`counted`nodir`nologs!(1b~r;2=cnt[`trade;`msgcount];()~key hsym`$BASE,"/tplog/nologs";0=count mv`currlog)
  };

unlistedok:{[]
  doinit cfg["tplog/unlisted";`multilog`errmode`batchmode`customcsv!(`custom;0b;`immediate;"partial.csv")];
  r:@[{feed[`quote;2];1b};::;{x}];
  chk `nothrow`counted`noquotelog`tradelog!(1b~r;2=cnt[`quote;`msgcount];not `quote in exec tbl from mv`currlog;`trade in exec tbl from mv`currlog)
  };

/ --- fixes ---

fix1:{[]
  dir:"tplog/fix1";
  c:cfg[dir;`multilog`batchmode!(`tabular;`immediate)];
  doinit c;
  feed[`trade;3];
  orig:fileof`trade;
  (st`teardown)[];
  smash orig;
  osize:hcount orig;
  doinit c;
  g:fileof`trade;
  m:metaof dir;
  a:`usesgood`goodcount`basecount`warned`origuntouched`metarenamed!(
    g~(mv`goodname) orig;
    2=logcount g;
    2=(mv`basecount) g;
    0<count select from calls where lvl=`warn,ctx=`openlog;
    osize=hcount orig;
    (g in m`logname) and not orig in m`logname);
  feed[`trade;1];
  a:a,enlist[`appends]!enlist 3=logcount g;
  (st`teardown)[];
  doinit c;
  chk a,`stillgood`nodataloss!(g~fileof`trade;3=logcount g)
  };

fix2:{[]
  doinit cfg["tplog/fix2";enlist[`batchmode]!enlist`immediate];
  pt:system"t";
  cp:mv`currperiod;
  mset[`currperiod;cp-3*0D01];
  mset[`nextperiod;cp-2*0D01];
  mset[`nextendutc;.z.p-1];
  r:@[{(mv`tick)[];1b};::;{x}];
  a:`tickcaught`errorlogged`ownjobonly`processtimer!(
    1b~r;
    0<count select from calls where lvl=`error,ctx=`endofperiod;
    (enlist`segmentedtp)~exec first arg from tcalls where fn=`disablejobs;
    pt=system"t");
  / each further tick catches up one period; the first to reach a current period rolls and re-enables the job
  {@[mv`tick;::;{x}]} each til 4;
  chk a,`reenabled`onlyown`caughtup!(
    `enablejobs=last exec fn from tcalls where fn in `disablejobs`enablejobs;
    all (enlist`segmentedtp)~/:exec arg from tcalls where fn in `disablejobs`enablejobs;
    (mv`nextperiod)>.z.p+(mv[`eod]`getdailyadj)[])
  };

fix3:{[]
  dir:"tplog/fix3";
  doinit cfg[dir;`multilog`batchmode!(`tabular;`immediate)];
  olderr:mv`errlog;
  oldtrade:fileof`trade;
  olddir:daydir dir;
  a:enlist[`erropen]!enlist 1=fdcount olderr;
  (mv[`eod]`setnextroll)[.z.p-1];
  mset[`nextendutc;.z.p-1];
  (mv`tick)[];
  chk a,`errclosed`tradeclosed`newerropen`newerrfile`oldmetaclosed!(
    0=fdcount olderr;
    0=fdcount oldtrade;
    1=fdcount mv`errlog;
    not olderr~mv`errlog;
    all not null (get hsym`$olddir,"/stpmeta")`end)
  };

fix4resume:{[]
  dir:"tplog/fix4";
  c:cfg[dir;`multilog`batchmode!(`tabular;`immediate)];
  doinit c;
  feed[`trade;2];
  m0:metaof dir;
  / an unclean exit: handles abandoned, segments never closed
  (mv`releaselogs)[];
  mset[`initdone;0b];
  doinit c;
  m:metaof dir;
  chk `norowadded`stillopen`seqkept`countresumed!(count[m0]=count m;all null m`end;(m0`seq)~m`seq;2=cnt[`trade;`msgcount]+(mv`basecount) fileof`trade)
  };

fix4orphan:{[]
  dir:"tplog/fix4o";
  c:cfg[dir;`multilog`batchmode!(`tabular;`immediate)];
  doinit c;
  (st`teardown)[];
  ghost:hsym`$daydir[dir],"/stp_ghost20000101000000";
  m:metaof dir;
  m:m,enlist `seq`logname`start`end`tbls`msgcount`schema`additional!(0i;ghost;.z.p;0Np;enlist`trade;5i;()!();()!());
  (hsym`$daydir[dir],"/stpmeta") set m;
  doinit c;
  n:metaof dir;
  r:first select from n where logname=ghost;
  chk `closed`nullcount`warned`othersresumed!(
    not null r`end;
    null r`msgcount;
    0<count select from calls where lvl=`warn,ctx=`reconcilemeta;
    all null exec end from n where logname<>ghost)
  };

fix5:{[]
  doinit cfg["tplog/fix5";`multilog`batchmode`replayperiod!(`singular;`immediate;`period)];
  feed[`trade;3];
  feed[`quote;2];
  f:fileof`trade;
  both:(mv`getlogsperiod)`trade`quote;
  one:(mv`getlogsperiod) enlist`trade;
  sd:(st`subdetails)[enlist`trade;`];
  (use`di.pubsub)[`closesub][0];
  chk `sharedfile`onepair`summed`tradeonly`subdetails!(
    f~fileof`quote;
    1=count both;
    (5;f)~first both;
    (5;f)~first one;
    (enlist(5;f))~sd`logfilelist)
  };

fix6:{[]
  dir:"tplog/fix6";
  doinit cfg[dir;`multilog`batchmode`customcsv!(`custom;`immediate;"custom.csv")];
  m:metaof dir;
  chk `tworows`shared`pertable!(
    2=count m;
    1=count select from m where {`quote`trade~asc x} each tbls;
    1=count select from m where {(enlist`depth)~x} each tbls)
  };

/ --- rolls ---

periodroll:{[]
  dir:"tplog/proll";
  doinit cfg[dir;enlist[`batchmode]!enlist`immediate];
  feed[`trade;3];
  old:fileof`trade;
  oldseq:mv`seq;
  oldcp:mv`currperiod;
  `EOP set ();
  (st`subdetails)[`;`];
  np:.z.p+(mv[`eod]`getdailyadj)[]-0D00:00:01;
  mset[`nextperiod;np];
  mset[`nextendutc;.z.p-1];
  (mv`tick)[];
  (use`di.pubsub)[`closesub][0];
  new:fileof`trade;
  oldrow:first select from metaof[dir] where logname=old;
  day:(mv`getlogsday) enlist`trade;
  chk `newfile`oldclosed`oldcount`reset`seq`subscriber`daylist!(
    not old~new;
    not null oldrow`end;
    3i=oldrow`msgcount;
    0=cnt[`trade;`msgcount];
    (1i+oldseq)=mv`seq;
    (oldcp;np)~2#EOP;
    ((0W;old);(0;new))~day)
  };

dayroll:{[]
  dir:"tplog/droll";
  doinit cfg[dir;enlist[`batchmode]!enlist`immediate];
  feed[`trade;2];
  d0:(mv[`eod]`getd)[];
  olddir:daydir dir;
  old:fileof`trade;
  `EOD set 0Nd;
  (st`subdetails)[`;`];
  (mv[`eod]`setnextroll)[.z.p-1];
  mset[`nextendutc;.z.p-1];
  (mv`tick)[];
  (use`di.pubsub)[`closesub][0];
  chk `subscriber`nextdate`newdir`oldclosed`reset`oldfdclosed!(
    d0~EOD;
    (d0+1)=(mv[`eod]`getd)[];
    not ()~key hsym`$daydir dir;
    all not null (get hsym`$olddir,"/stpmeta")`end;
    0=cnt[`trade;`msgcount];
    0=fdcount old)
  };

/ --- subscriber surface, custom mode, lifecycle ---

subdetailsok:{[]
  dir:"tplog/subd";
  doinit cfg[dir;enlist[`batchmode]!enlist`immediate];
  feed[`trade;4];
  feed[`quote;1];
  sd:(st`subdetails)[`;`];
  (use`di.pubsub)[`closesub][0];
  chk `keys`schemas`rowcounts`pairs`tradepair`logdir`date!(
    `schemalist`logfilelist`rowcounts`date`logdir~key sd;
    (asc `trade`quote`depth)~asc first each sd`schemalist;
    4 1~sd[`rowcounts]`trade`quote;
    all {(-7h=type x 0) and -11h=type x 1} each sd`logfilelist;
    (4;fileof`trade) in sd`logfilelist;
    (`$BASE,"/",dir)~sd`logdir;
    (mv[`eod]`getd)[]~sd`date)
  };

subbad:{[]
  doinit cfg["tplog/subbad";()!()];
  throws[{(st`subdetails)[enlist`nosuch;`]};"not available"]
  };

tablelistok:{[]
  doinit cfg["tplog/tablelist";()!()];
  `depth`quote`trade~asc (st`tablelist)[]
  };

readcsvok:{[]
  ex:`trade`quote`depth!`singular`singular`tabperiod;
  chk `string`symbol!(ex~(st`readcustomcsv) BASE,"/custom.csv";ex~(st`readcustomcsv) hsym`$BASE,"/custom.csv")
  };
readcsvmissing:{[] throws[{(st`readcustomcsv) BASE,"/nosuch.csv"};"not found"]};
readcsvbadmode:{[] throws[{(st`readcustomcsv) BASE,"/badmode.csv"};"unrecognised mode"]};
readcsvbadheader:{[] throws[{(st`readcustomcsv) BASE,"/badheader.csv"};"table,mode header"]};

setcustomok:{[]
  dir:"tplog/setcustom";
  doinit cfg[dir;`multilog`batchmode!(`custom;`immediate)];
  a:`warned`nologs!(0<count select from calls where lvl=`warn,ctx=`init;0=count mv`currlog);
  (st`setcustommode)[`trade`quote!`periodic`tabular];
  f:tf[];
  a:a,`periodic`tabular!(fileof[`trade]~hsym`$daydir[dir],"/stp_periodic",f;fileof[`quote]~hsym`$daydir[dir],"/stp_quote",f);
  feed[`trade;2];
  (st`setcustommode)[enlist[`trade]!enlist`tabular];
  chk a,`reassigned`quotedropped`kept!(
    fileof[`trade]~hsym`$daydir[dir],"/stp_trade",f;
    not `quote in exec tbl from mv`currlog;
    2=logcount hsym`$daydir[dir],"/stp_periodic",f)
  };

setcustomnotcustom:{[]
  doinit cfg["tplog/scnc";()!()];
  throws[{(st`setcustommode)[enlist[`trade]!enlist`tabular]};"not custom"]
  };

setcustomunknown:{[]
  doinit cfg["tplog/scun";enlist[`multilog]!enlist`custom];
  throws[{(st`setcustommode)[enlist[`widgets]!enlist`tabular]};"not publishable"]
  };

setcustombadmode:{[]
  doinit cfg["tplog/scbm";enlist[`multilog]!enlist`custom];
  throws[{(st`setcustommode)[enlist[`trade]!enlist`hourly]};"unrecognised mode"]
  };

exitok:{[]
  doinit cfg["tplog/exit";`multilog`batchmode!(`tabular;`memorybatch)];
  feed[`trade;2];
  f:fileof`trade;
  (mv`exithandler)[1i];
  a:enlist[`badexitleavesopen]!enlist (1=fdcount f) and 0=logcount f;
  (mv`exithandler)[0i];
  chk a,`flushed`closed!(1=logcount f;0=fdcount f)
  };

teardownok:{[]
  dir:"tplog/teardown";
  doinit cfg[dir;`multilog`batchmode!(`tabular;`memorybatch)];
  feed[`trade;2];
  f:fileof`trade;
  e:mv`errlog;
  (st`teardown)[];
  chk `flushed`closed`errclosed`metaclosed`job`handler`notinit!(
    1=logcount f;
    0=fdcount f;
    0=fdcount e;
    all not null (metaof dir)`end;
    (enlist`segmentedtp)~exec last arg from tcalls where fn=`deletejobs;
    (`.z.exit;`;`segmentedtp)~exec last arg from hcalls where fn=`remove;
    not mv`initdone)
  };

afterteardown:{[]
  chk `getcounts`upd!(throws[{(st`getcounts)[]};"init must be called"];throws[{upd[`trade;(`A;1.0)]};"init must be called"])
  };
