/ di.torq.proc.wdb - ported from TorQ's wdb.q
/ subscribes to the tickerplant and appends data to disk after the in-memory table exceeds a specified number of rows
/ at eod the on-disk data is sorted and attributes applied as specified in the sort.csv file
/ modes: saveandsort, save (the sort is handed to a sort process) and sort (proctypes sort and sortworker)

/ config coercion: toml and command-line values arrive as strings, which must be parsed not cast
assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}
tolong:{[x]
  r:$[10h=abs type x;"J"$(),x;"j"$x];
  if[null r;'"di.torq.proc.wdb: could not parse \"",$[10h=abs type x;x;string x],"\" as a number"];
  r
  }
tobool:{[x] $[-1h=type x;x;10h=abs type x;(lower (),x) in ("true";(),"1";(),"t";(),"y";"yes");`boolean$x]}
astimespan:{[x] $[10h=abs type x;$[any ((),x) in "D:";"N"$(),x;`timespan$1000000000*"J"$(),x];-16h=type x;x;`timespan$1000000000*x]}

/ a token-list config (e.g. reloadorder) as a symbol list
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}

/ base dirs: code/config under TORQXAPPHOME, runtime data under TORQXDATAHOME falling back to TORQXAPPHOME
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolves a possibly-relative dir setting to an absolute path string under base
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

partwritemodes:`partbyattr`partbyenum`partbyfirstchar

/ initialise reloadsummary, keyed table to track status of local reloads
reloadsummary:([handle:`int$()]process:`symbol$();status:`boolean$();result:`symbol$())
reloadcomplete:1b
countreload:0
timeouttime:0Np

/ extract user defined row counts
maxrows:{[t] $[t in key .z.m.numtab;.z.m.numtab t;.z.m.numrows]}
replaymaxrows:{[t] $[t in key .z.m.replaynumtab;.z.m.replaynumtab t;.z.m.replaynumrows]}
/ extract user defined row counts for merge process
mergemaxrows:{[t] $[t in key .z.m.mergenumtab;.z.m.mergenumtab t;.z.m.mergenumrows]}

/ function to determine the partition value
/ the partition value; legacy exposed this as an overridable setting, so config may replace it
defaultgetpartition:{[] $[null .z.m.currentpartition;(`date^.z.m.partitiontype)$.z.D;.z.m.currentpartition]}
getpartition:{[] .z.m.getpartition[]}

/ function to return a list of tables that the wdb process has been configured to deal within
tablelist:{[] ((exec tablename from `bytes xdesc .z.m.tabsizes) union tables[`.]) except .z.m.ignorelist}

/ function that ensures a list of syms is returned no matter what is passed to it
ensuresymlist:{[s] -1 _ `${@[x; where not ((type each x) in (10 -10h));string]} s,(::)}

/ applies the table's savedownmanipulation function, if any, before a save
manipulate:{[t;x]
  $[t in key .z.m.savedownmanipulation;
    @[.z.m.savedownmanipulation t;x;{[x;e] .z.m.log[`error][`manipulate;"save down manipulation failed : ",e];x}[x]];
    x]
  }

/ saves a table to the partition once over its row limit; cleared with @[`.;...] as bare writes land in the module
savetables:{[dir;pt;forcesave;tabname]
  / check row count
  / forcesave will flush the data to disk irrespective of counts
  if[forcesave or maxrows[tabname] < arows:count value tabname;
    .z.m.log[`info][`rowcheck;"the ",(string tabname)," table consists of ",(string arows)," rows"];
    .z.m.log[`info][`save;"saving ",(string tabname)," data to partition ",string pt];
    / upsert data to partition
    .[upsert;(` sv .Q.par[dir;pt;tabname],`;.Q.en[.z.m.hdbdir;r:0!manipulate[tabname;`. tabname]]);{[e] .z.m.log[`error][`savetables;"Failed to save table to disk : ",e];'e}];
    / make addition to tabsizes
    .z.m.log[`info][`track;"appending table details to tabsizes"];
    .z.m.tabsizes+:([tablename:enlist tabname]rowcount:enlist arows;bytes:enlist -22!r);
    / empty the table
    .z.m.log[`info][`delete;"deleting ",(string tabname)," data from in-memory table"];
    @[`.;tabname;0#];
    / run a garbage collection (if enabled)
    if[.z.m.gc;.Q.gc[]];
    :1b];
  0b
  }

/ vectorized function to map partition value(s) to int partition(s) in partbyenum mode
maptoint:{[val]
  $[(abs type val) in 5 6 7h;
    / if using an integer column, clamp value between 0 and max int (null maps to 0)
    0|2147483647&`long$val;
    / if using a symbol column, enumerate against the hdb sym file
    `long$(` sv .z.m.hdbdir,`sym)?`TORQNULLSYMBOL^val]
  }

/ maps a value's first character to an int partition in partbyfirstchar mode
mapfctoint:{[val] .Q.an?$[0<type val;first each;first] string val}

/ function to upsert to specified directory
upserttopartition:{[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
  / enumerate first extra partition value
  if[writedownmode~`partbyenum;i:maptoint first expt];
  if[writedownmode~`partbyfirstchar;i:mapfctoint first expt];
  / create directory location for selected partition
  / replace non-alphanumeric characters in symbols with _
  / convert to symbols and replace any null values with `TORQNULLSYMBOL
  directory:$[writedownmode in `partbyenum`partbyfirstchar;
    ` sv .Q.par[dir;pt;`$string i],tablename,`;
    ` sv .Q.par[dir;pt;tablename],(`$"_"^.Q.an .Q.an?"_" sv string `TORQNULLSYMBOL^ensuresymlist[expt]),`];
  .z.m.log[`info][`save;"saving ",(string tablename)," data to partition ",string directory];
  / selecting rows of table with matching partition
  r:?[tabdata;$[writedownmode in `partbyenum`partbyfirstchar;enlist(in;first expttype;enlist expt);{(x;y;(),z)}[in;;]'[expttype;expt]];0b;()];
  / upsert selected data matched on partition to specific directory
  .[upsert;(directory;r);{[e] .z.m.log[`error][`savetablesbypart;"Failed to save table to disk : ",e];'e}];
  .z.m.log[`info][`track;"appending details to partsizes"];
  / key in partsizes are directory to partition, need to drop trailing slash in directory key
  (.z.m.mrg`trackpartition)[first ` vs directory;count r;-22!r];
  }

/ saves a table split by its extra partition once over its row limit
savetablesbypart:{[dir;pt;forcesave;tablename;writedownmode]
  / check row count and save if maxrows exceeded
  / forcesave will flush the data to disk irrespective of counts
  if[forcesave or maxrows[tablename] < arows:count value tablename;
    .z.m.log[`info][`rowcheck;"the ",(string tablename)," table consists of ",(string arows)," rows"];
    / get additional partition(s) defined by parted attribute in sort.csv
    extrapartitiontype:getextrapartitiontype[tablename];
    if[(writedownmode in `partbyenum`partbyfirstchar) and 1<c:count extrapartitiontype;
      .z.m.log[`error][writedownmode;"only 1 parted attribute should be defined on table when using partbyenum and partbyfirstchar writedown modes, but we have ",string c]];
    / check each partition type actually is a column in the selected table
    (.z.m.mrg`checkpartitiontype)[tablename;extrapartitiontype];
    / check if provided column extrapartitiontype indeed has an enumerable type in table
    if[writedownmode~`partbyenum;(.z.m.mrg`checkenumerabletype)[tablename;extrapartitiontype]];
    / get list of distinct combinations for partition directories
    extrapartitions:$[writedownmode~`partbyfirstchar;.z.m.mrg`getfirstcharpartitions;.z.m.mrg`getextrapartitions][tablename;extrapartitiontype];
    / enumerate data to be upserted
    enumdata:.Q.en[.z.m.hdbdir;0!manipulate[tablename;`. tablename]];
    .z.m.log[`info][`save;"enumerated ",(string tablename)," table"];
    / upsert data to specific partition directory
    upserttopartition[dir;tablename;enumdata;pt;extrapartitiontype;;writedownmode] each extrapartitions;
    / tablelist[] orders by bytes from tabsizes, so the partitioned modes must track it as well
    .z.m.tabsizes+:([tablename:enlist tablename]rowcount:enlist arows;bytes:enlist -22!enumdata);
    / empty the table
    .z.m.log[`info][`delete;"deleting ",(string tablename)," data from in-memory table"];
    @[`.;tablename;0#];
    / run a garbage collection (if enabled)
    if[.z.m.gc;.Q.gc[]];
    :1b];
  0b
  }

/ savetables or savetablesbypart, depending on writedown mode
savetab:{[dir;pt;forcesave;t] $[.z.m.writedownmode in .z.m.partwritemodes;savetablesbypart[;;;;.z.m.writedownmode];savetables][dir;pt;forcesave;t]}

/ flushes a table to disk during replay if it exceeds the replay row limit
replaymaxrowcheck:{[t;lmt]
  if[(rpc:count value t) > lmt;
    .z.m.log[`info][`replayupd;"row limit (",(string lmt),") exceeded for ",(string t),". Table count is : ",(string rpc),". Flushing table to disk..."];
    savetab[.z.m.savedir;getpartition[];0b;t]];
  }

/ will check on each upd to determine where data should be flushed to disk (if max row limit has been exceeded)
replayupd:{[t;x] .z.m.upd[t;x]; replaymaxrowcheck[t;replaymaxrows t];}

/ saves each table over its row limit, then notifies the idbs
savetodisk:{[]
  changes:savetab[.z.m.savedir;getpartition[];.z.m.immediate;] each tablelist[];
  / we have to let the idbs know of the changes in the wdbhdb. using filldb[] to make sure it is a db with all the tables
  if[any[changes] and .z.m.writedownmode in `partbyenum`partbyfirstchar`default;
    filldb getpartition[];
    notifyidbs[`.idb.intradayreload;enlist()]];
  }

/ if there is data in the wdb directory for the partition remove it before replay
clearwdbdata:{[]
  $[not ()~key wdbpart:.Q.par[.z.m.savedir;getpartition[];`];
    [.z.m.log[`info][`deletewdbdata;"removing wdb data (",(delstrg:1_string wdbpart),") prior to log replay"];
     @[.z.m.os`deldir;delstrg;{[e] .z.m.log[`error][`deletewdbdata;"Failed to delete existing wdb data.  Error was : ",e];'e}];
     .z.m.log[`info][`deletewdbdata;"finished removing wdb data prior to log replay"]];
    .z.m.log[`info][`deletewdbdata;"no directory found at ",1_string wdbpart]];
  }

/ function to rectify data written to wrong partition
fixpartition:{[tplogdate]
  / check if the tp logdate matches current date
  if[not tplogdate~orig:.z.m.currentpartition;
    .z.m.log[`info][`fixpartition;"Current partition date does not match the ticker plant log date"];
    / set the current partition date to the log date
    .z.m.currentpartition:tplogdate;
    / move the data that has been written to correct partition
    pth1:1_string .Q.par[.z.m.savedir;orig;`];
    pth2:1_string .Q.par[.z.m.savedir;tplogdate;`];
    if[count key hsym `$pth1;
      / delete any data in the current partition directory
      clearwdbdata[];
      .z.m.log[`info][`fixpartition;"Moving data from partition ",pth1," to partition ",pth2];
      .[.z.m.os`mv;(pth1;pth2);{[p1;p2;e] .z.m.log[`error][`fixpartition;"Failed to move data from wdb partition ",p1," to wdb partition ",p2," : ",e]}[pth1;pth2]]]];
  }

/ fills missing tables in the partition so it is usable intraday
filldb:{[pt] .Q.chk .Q.par[.z.m.savedir;pt;`];}

/ initialises table t in db with its schema in part
inittable:{[t;pt]
  tdir:` sv $[.z.m.writedownmode in `partbyenum`partbyfirstchar;.Q.par[.Q.dd[.z.m.savedir;pt];0;t];.Q.par[.z.m.savedir;pt;t]],`;
  if[()~key tdir;tdir set .Q.en[.z.m.hdbdir;0#value t]];
  }

/ makes sure partition 0/currentpartition has all the tables for partbyenum/partbyfirstchar/default
initmissingtables:{[pt]
  .z.m.log[`info][`fixpartition;"Adding missing tables(empty) to partition ",string pt];
  inittable[;pt] each tablelist[];
  filldb pt;
  }

/ eod - flush remaining data to disk
endofdaysave:{[dir;pt]
  / save remaining table rows to disk
  .z.m.log[`info][`save;"saving the ",(", " sv string tl:tablelist[],())," table(s) to disk"];
  savetab[dir;pt;1b;] each tl;
  .z.m.log[`info][`savefinish;"finished saving data to disk"];
  }

/ add entries to table of callbacks. if timeout has expired or d now contains all expected rows then it releases each waiting process
handler:{[x]
  .z.m.reloadsummary[.z.w]:x;
  .z.m.log[`info][`reloadproc;"the ",(string x 0)," process ",string x 2];
  if[(.z.p>.z.m.timeouttime) or count[.z.m.reloadsummary]=.z.m.countreload;
    .z.m.log[`info][`handler;"releasing processes"];
    .z.m.log[`info][`reload;(string count select from .z.m.reloadsummary where status)," out of ",(string count .z.m.reloadsummary)," processes successfully reloaded"];
    flushend[];
    .z.m.reloadsummary:0#.z.m.reloadsummary];
  }

/ evaluate contents of d dictionary asynchronously; notify the gateway that we are done
flushend:{[]
  if[not .z.m.reloadcomplete;
    if[.z.m.eodwaittime>0;@[{neg[x]"";neg[x][]};;()] each exec handle from .z.m.reloadsummary];
    informgateway`reloadend;
    .z.m.log[`info][`sort;"end of day sort is now complete"];
    .z.m.reloadcomplete:1b];
  / run a garbage collection (if enabled)
  if[.z.m.gc;.Q.gc[]];
  }

/ triggers the reload of each reloadorder type in turn
doreload:{[pt]
  .z.m.reloadcomplete:0b;
  / inform gateway of reload start
  informgateway`reloadstart;
  ro:.z.m.reloadorder inter knowntypes[];
  .z.m.countreload:sum {count (.z.m.svc`getservers) x} each ro where not (::)~/:reloadexpr each ro;
  .z.m.timeouttime:.z.p+.z.m.eodwaittime;
  getprocs[;pt] each ro;
  $[.z.m.eodwaittime>0;
    [@[.z.m.timer`deletejobs;`sortflushend;{}];
     (.z.m.timer`addjob)[`sortflushend;flushend;();1;1h;`startattime`maxruns!(.z.m.timeouttime;1)]];
    flushend[]];
  }

/ a segmented tickerplant broadcasts end of period to its subscribers through di.pubsub, which
/ sends the (current;next;data) triple as ONE argument - the wdb has nothing to do on a period
/ roll, but the callback has to exist or the publish fails
endofperiod:{[x] .z.m.log[`info][`endofperiod;"received endofperiod, (current;next;data) is ",.Q.s1 x];}

/ set .z.zd to control how data gets compressed
setcompression:{[compression]
  if[3=count compression;
    .z.m.log[`info][`compression;$[compression~16 0 0;"resetting";"setting"]," compression level to (",(";" sv string compression),")"];
    @[`.z;`zd;:;compression]];
  }

resetcompression:{[] setcompression 16 0 0}

/ check if the hdb directory contains current partition
/ if yes check if partition is empty and if it is not see if any of the tables exist in both the
/ temporary partition and the hdb partition. If there is a clash abort operation otherwise copy
/ each table to the hdb partition
movetohdb:{[dw;hw;pt]
  (.z.m.os`mkdir) hdbroot:(neg count string pt)_hw;
  $[not (`$string pt) in key hsym `$hdbroot;
    .[.z.m.os`mv;(dw;hw);{[dw;hw;e] .z.m.log[`error][`mvtohdb;"Failed to move data from wdb ",dw," to hdb directory ",hw," : ",e]}[dw;hw]];
    not any a[dw] in (a:{key hsym `$x}) hw;
    [{[y;x]
       $[not (b:`$last "/" vs x) in key y;
         [.[.z.m.os`mv;(x;y);{[x;y;e] .z.m.log[`error][`mvtohdb;"Table ",(string x)," has failed to copy to ",(string y)," with error: ",e];'e}[b;y]];
          .z.m.log[`info][`mvtohdb;"Table ",(string b)," has been successfully moved to ",string y]];
         .z.m.log[`error][`mvtohdb;"Table ",(string b)," was skipped because it already exists in ",string y]];
       }[hsym `$hw]'[dw,/:"/",/:string key hsym `$dw];
     $[0=count key hsym `$dw;
       @[.z.m.os`deldir;dw;{[x;y] .z.m.log[`error][`mvtohdb;"Failed to delete folder ",x," with error: ",y]}[dw]];
       .z.m.log[`error][`mvtohdb;"Table(s) ",(", " sv string key hsym `$dw)," are still in ",dw," - the partition is split across the wdb and the hdb"]]];
    .z.m.log[`error][`mvtohdb;raze "Table(s) ",string[(key hsym `$hw) inter key hsym `$dw]," is present in both location. Operation will be aborted to avoid corrupting the hdb"]]
  }

/ root sym is set with @[`.;...]: a bare load from a use-loaded module lands in its private namespace
reloadsymfile:{[symfilepath]
  if[not count key symfilepath;
    .z.m.log[`warn][`reloadsymfile;"no sym file at ",(1_string symfilepath)," - nothing to load"];
    :()];
  .z.m.log[`info][`reloadsymfile;"reloading the sym file from ",1_string symfilepath];
  @[{@[`.;`sym;:;get x]};symfilepath;{[e] .z.m.log[`error][`sort;"failed to reload sym file: ",e]}]
  }

/ legacy's .sort.sorttab: x is (table;dir)
sorttab:{[x] (.z.m.dbw`sort)[x 0;x 1]}

/ as legacy, workers are only used when this process was started with a negative -s
useworkers:{[] (0<count .z.pd[]) and 0>system"s"}

/ sends each worker the sym file to reload, async then flushed
reloadworkersym:{[hdbsettings] {(neg x)(`.wdb.reloadsymfile;y);(neg x)(::)}[;.Q.dd[hdbsettings`hdbdir;`sym]] each .z.pd[]}

/ sorts each (table;dir), on the sortworkers when there are any
sortall:{[tnds;hdbsettings]
  $[useworkers[];
    [.z.m.log[`info][`sort;"sorting on worker sort ",string .z.p];
     reloadworkersym hdbsettings;
     / sort the table and garbage collect (if enabled)
     {[x;compression] .wdb.setcompression compression;.sort.sorttab x;if[.wdb.gc;.Q.gc[]]}[;hdbsettings`compression] peach tnds];
    [.z.m.log[`info][`sort;"sorting on main sort"];
     reloadsymfile .Q.dd[hdbsettings`hdbdir;`sym];
     {[x] sorttab x;if[.z.m.gc;.Q.gc[]]} each tnds]];
  }

/ sorts the working partition, moves it into the hdb and reloads
endofdaysortdate:{[dir;pt;tablist;hdbsettings]
  / sort permitted tables in database
  .z.m.log[`info][`sort;"starting to sort data"];
  sortall[tablist,'.Q.par[dir;pt;] each tablist;hdbsettings];
  .z.m.log[`info][`sort;"finished sorting data"];
  / move data into hdb
  .z.m.log[`info][`mvtohdb;"Moving partition from the temp wdb ",(dw:(.z.m.os`topath) -1_string .Q.par[dir;pt;`])," directory to the hdb directory ",hw:(.z.m.os`topath) -1_string .Q.par[hdbsettings`hdbdir;pt;`]];
  .z.m.log[`info][`mvtohdb;"Attempting to move ",(", " sv string key hsym `$dw)," from ",dw," to ",hw];
  .[movetohdb;(dw;hw;pt);{[e] .z.m.log[`error][`mvtohdb;"Function movetohdb failed with error: ",e]}];
  / call the posteod function
  postreplay[hdbsettings`hdbdir;pt];
  if[.z.m.permitreload;doreload pt];
  }

/ post eod function, invoked after all the tables have been written down
postreplay:{[hdbdir;pt]
  @[.z.m.posteod .;(hdbdir;pt);{[e] .z.m.log[`error][`postreplay;"postreplay failed: ",e]}];
  }

/ the loaded sort config, or an empty one as legacy's .sort.params
sortparams:{[] $[(::)~c:(.z.m.dbw`getconfig)[];([] tabname:`symbol$(); att:`symbol$(); column:`symbol$(); sort:`boolean$());c]}

/ the parted column(s) for a table from the sort config, falling back to the default row
getextrapartitiontype:{[tablename]
  params:sortparams[];
  if[count tabparts:distinct exec column from params where tabname=tablename,sort,att=`p;
    .z.m.log[`info][`getextraparttype;"parted attribute p found in sort.csv for ",(string tablename)," table"];
    :tabparts];
  if[count defaultparts:distinct exec column from params where tabname=`default,sort,att=`p;
    .z.m.log[`info][`getextraparttype;"parted attribute p not found in sort.csv for ",(string tablename)," table, using default instead"];
    :defaultparts];
  .z.m.log[`error][`getextraparttype;"parted attribute p not found in sort.csv for ",(string tablename)," table and default not defined"];
  `symbol$()
  }

/ merges one table's segments into the hdb partition
merge:{[dir;pt;tableinfo;mergelimits;hdbsettings;mergemethod;writedownmode]
  setcompression hdbsettings`compression;
  / get tablename
  tabname:tableinfo 0;
  ep:getextrapartitiontype tabname;
  / get list of partition directories for specified table - partbyenum & partbyfirstchar use different folder structures vs partbyattr/default
  partdirs:$[writedownmode in `partbyenum`partbyfirstchar;
    p where 0<count each key each p:` sv' ((-1_` vs p),/:key p:.Q.par[dir;pt;`]),\:tabname;
    ` sv' tdir,/:key tdir:.Q.par[dir;pt;tabname]];
  / we only really have to merge those partitions where we have received some updates, otherwise table is empty
  partdirs:partdirs inter exec ptdir from (.z.m.mrg`getpartsizes)[];
  / get directory destination for permanent storage
  dest:.Q.par[hdbsettings`hdbdir;pt;tabname];
  .z.m.log[`info][`merge;"merging ",(string tabname)," to ",string dest];
  if[0=count partdirs;
    .z.m.log[`warn][`merge;"no records found for ",(string tabname),", merging empty table"];
    (` sv dest,`) set @[.Q.en[hdbsettings`hdbdir;tableinfo 1];ep;`p#];
    :()];
  / if there are partitions to merge - merge with correct function
  .z.m.log[`info][`merge;"mergemethod: ",string mergemethod];
  $[mergemethod~`part;
    / get chunks to partitions to merge in batch
    (.z.m.mrg`mergebypart)[ep;dest:` sv dest,`]'[(.z.m.mrg`getpartchunks)[partdirs;mergelimits tabname]];
    mergemethod~`col;
    [(.z.m.mrg`mergebycol)[tableinfo;dest]'[partdirs];
     / merging data column at a time means no .d file is created so need to create one after function executed
     .z.m.log[`info][`merge;"creating file ",string ` sv dest,`.d];
     (` sv dest,`.d) set cols tableinfo 1];
    (.z.m.mrg`mergehybrid)[ep;tableinfo;dest;partdirs;mergelimits tabname]];
  .z.m.log[`info][`merge;"removing segments ",", " sv string partdirs];
  $[writedownmode in `partbyenum`partbyfirstchar;
    removetablefromenumdir each partdirs;
    (.z.m.os`deldir) tdir];
  / set the attributes
  .z.m.log[`info][`merge;"setting attributes"];
  @[dest;;`p#] each ep;
  .z.m.log[`info][`merge;(string tabname)," merge complete"];
  }

/ enumerated partitions have a directory structure of: db/<partition>/<enumerated extra partition>/<table>
/ this function deletes <table> folder or the whole <enumerated extra partition> if it only has one element
removetablefromenumdir:{[partdir]
  enumdir:` sv -1_` vs partdir;
  (.z.m.os`deldir) $[1=count key enumdir;enumdir;partdir];
  }

/ merges each table into the hdb, on the sortworkers when there are any, then reloads
endofdaymerge:{[dir;pt;tablist;mergelimits;hdbsettings;mergemethod;writedownmode]
  / merge data from partitions
  ti:flip (key tablist;value tablist);
  $[useworkers[];
    [.z.m.log[`info][`merge;"merging on worker"];
     reloadworkersym hdbsettings;
     / upsert .merge.partsize data to sort workers, only needed for part and hybrid method
     if[.z.m.mergemode in `hybrid`part;
       {(neg x)(`.merge.syncpartsizes;y);(neg x)(::)}[;(.z.m.mrg`getpartsizes)[]] each .z.pd[]];
     {[dir;pt;ml;hs;mm;wm;x] .wdb.merge[dir;pt;x;ml;hs;mm;wm]}[dir;pt;mergelimits;hdbsettings;mergemethod;writedownmode] peach ti;
     / clear out in memory table, .merge.partsizes, and call sort worker processes to do the same
     .z.m.log[`info][`eod;"Delete from partsizes"];
     (.z.m.mrg`clearpartsizes)[];
     {(neg x)({[x] .merge.clearpartsizes[];if[.wdb.gc;.Q.gc[]]};`);(neg x)(::)} each .z.pd[]];
    [.z.m.log[`info][`merge;"merging on main"];
     reloadsymfile .Q.dd[hdbsettings`hdbdir;`sym];
     merge[dir;pt;;mergelimits;hdbsettings;mergemethod;writedownmode] each ti;
     .z.m.log[`info][`eod;"Delete from partsizes"];
     (.z.m.mrg`clearpartsizes)[]]];
  / if path exists, delete it
  if[count key p:.Q.par[dir;pt;`];
    .z.m.log[`info][`merge;"attempting to delete temp storage directory"];
    @[.z.m.os`deldir;p;{[p;e] .z.m.log[`info][`eod;"could not delete directory: ",(1_string p)," - maybe something(IDB?) gets hold of it."]}[p]]];
  / call the posteod function
  postreplay[hdbsettings`hdbdir;pt];
  $[.z.m.permitreload;doreload pt;if[.z.m.gc;.Q.gc[]]];
  }

/ end of day sort and merge only used by writedown mode partbyfirstchar, requiring sort pre-merge
endofdaysortandmerge:{[dir;pt;tablist;mergelimits;hdbsettings;mergemethod;writedownmode]
  / sort permitted tables in database
  .z.m.log[`info][`sort;"starting to sort data"];
  tnds:raze {y,/:.Q.dd[x;] each key[x],\:y}[.Q.dd[dir;pt]] each key tablist;
  tnds:tnds where tnds[;1] in exec ptdir from (.z.m.mrg`getpartsizes)[];
  if[count tnds;sortall[tnds;hdbsettings]];
  .z.m.log[`info][`sort;"finished sorting data"];
  endofdaymerge[dir;pt;tablist;mergelimits;hdbsettings;mergemethod;writedownmode];
  }

/ end of day sort [depends on writedown mode]; dir, tablist and hdbsettings may be null to use this process's own config
endofdaysort:{[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]
  sd:$[0=count s:$[10h=abs type dir;(),dir;string dir];.z.m.savedirs;resolvedir[datahome[];s]];
  dir:hsym `$sd;
  if[not 99h=type hdbsettings;hdbsettings:()!()];
  hdbsettings:.z.m.hdbsettings,hdbsettings;
  hdbsettings[`hdbdir]:hsym `$resolvedir[datahome[];hdbsettings`hdbdir];
  if[not 99h=type tablist;
    t:(),tablist;
    t:$[(0=count t) or t~enlist`;key .Q.par[dir;pt;`];t];
    tablist:t!(count t)#enlist ()];
  writedownmode:$[null writedownmode;`default;assym writedownmode];
  mergemethod:$[null mergemethod;.z.m.mergemode;assym mergemethod];
  .z.m.log[`info][`endofdaysort;"starting for partition ",(string pt)," in ",sd,": ",$[count tablist;", " sv string key tablist;"no tables"]];
  / set compression level (.z.zd)
  setcompression hdbsettings`compression;
  $[writedownmode in .z.m.partwritemodes;
    $[writedownmode~`partbyfirstchar;endofdaysortandmerge;endofdaymerge][dir;pt;tablist;mergelimits;hdbsettings;mergemethod;writedownmode];
    endofdaysortdate[dir;pt;key tablist;hdbsettings]];
  / reset compression level (.z.zd)
  resetcompression[];
  / run steps to rollover idb
  idbreload[pt+1;writedownmode];
  .z.m.log[`info][`endofdaysort;"complete for partition ",string pt];
  }

/ the call each reloadorder type makes on the far side
reloadexpr:{[ptype]
  $[ptype in .z.m.hdbtypes;{[d] .hdb.reload[]};
    ptype in .z.m.rdbtypes;{[d] `. [`reload] d};
    ptype in .z.m.idbtypes;{[d] .idb.intradayreload[]};
    (::)]
  }

/ function to send reload message to rdbs/hdbs/idbs
reloadproc:{[h;d;ptype;f]
  / async call back function executed when eodwaittime>0
  sendfunc:{[x;y;ptype] @[neg y;x;{[ptype;e] .z.m.log[`error][`reloadproc;"failed to reload the ",string ptype]}[ptype]]};
  / reload function sent to processes by sendfunc; runs there, so it calls back .wdb.handler with the outcome
  reloadfunc:{[f;d;ptype] r:@[{(1b;x y)}[f];d;{(0b;x)}];
    (neg .z.w)(`.wdb.handler;(ptype;first r;$[first r;`$"reloaded successfully";`$"reload failed with error ",last r]));(neg .z.w)[]};
  / reload function to be executed if eodwaitime = 0 - sync message processes to reload and log if reload was successful or failed
  syncreloadfunc:{[h;f;d;ptype] r:@[h;({[f;d] (1b;f d)};f;d);{[ptype;e] .z.m.log[`error][`reloadproc;"failed to reload the ",(string ptype),". The error was : ",e];(0b;e)}[ptype]];
    .z.m.log[`info][`reloadproc;"the ",(string ptype)," ",$[first r;"successfully reloaded";"failed to reload"]]};
  .z.m.log[`info][`reloadproc;"sending reload call to ",string ptype];
  $[.z.m.eodwaittime>0;sendfunc[(reloadfunc;f;d;ptype);h;ptype];syncreloadfunc[h;f;d;ptype]];
  }

/ function to discover rdbs/hdbs and attempt to reconnect
getprocs:{[x;y]
  if[(::)~f:reloadexpr x;
    .z.m.log[`warn][`doreload;"reloadorder entry ",(string x)," is neither an hdb, rdb, nor idb type - skipped"];
    :()];
  a:exec w from (.z.m.svc`getservers) x;
  / exit if no valid handle
  if[0=count a;.z.m.log[`error][`connection;"no connection to the ",(string x)," could be established... failed to reload ",string x];:()];
  .z.m.log[`info][`connection;"connection to the ",(string x)," has been located"];
  / send message along each handle
  reloadproc[;y;x;f] each a;
  }

/ the proctypes in the phone book, or the reloadorder when the servers dep cannot list them
knowntypes:{[] $[`getallservers in key .z.m.svc;exec distinct proctype from (.z.m.svc`getallservers)[];.z.m.reloadorder]}

/ function to send messages to gateway
informgateway:{[msg]
  .z.m.log[`info][`informgateway;"sending message to gateway(s)"];
  if[0=count h:raze {exec w from x} each (.z.m.svc`getservers) each .z.m.gatewaytypes;
    :.z.m.log[`info][`informgateway;"no gateway detected - nothing to reload"]];
  {[wh;msg] @[neg wh;(`.gw.reload;msg);{[e] .z.m.log[`error][`informgateway;"unable to run command on gateway: ",e]}]}[;msg] each h;
  .z.m.log[`info][`informgateway;"the message - ",(.Q.s1 msg)," was sent to the gateways"];
  }

/ function to call that will cause sort & reload process to sort data and reload rdb and hdbs; async so the wdb can take the new day
informsortandreload:{[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]
  .z.m.log[`info][`informsortandreload;"attempting to contact sort process to initiate data ",$[writedownmode~`default;"sort";"merge"]];
  if[0=count h:raze {exec w from x} each (.z.m.svc`getservers) each .z.m.sorttypes;
    .z.m.log[`error][`informsortandreload;"can't connect to the sortandreload - no sortandreload process detected"];
    / try to run the sort locally
    :endofdaysort[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]];
  / for part and hybrid method sort procs need access to partsizes table data
  if[mergemethod in `hybrid`part;
    {[p;h] neg[h](`.merge.syncpartsizes;p);neg[h][]}[(.z.m.mrg`getpartsizes)[]] each h];
  msg:(`.wdb.endofdaysort;dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod);
  {[msg;wh] @[{[msg;wh] neg[wh] msg;neg[wh][]}[msg];wh;{[e] .z.m.log[`error][`informsortandreload;"unable to run command on sort and reload process: ",e]}]}[msg] each h;
  }

/ send an intraday reload message to idbs
notifyidbs:{[func;params]
  ws:raze {exec w from x} each (.z.m.svc`getservers) each .z.m.idbtypes;
  .z.m.log[`info][`reload;"found ",(string count ws)," idb(s) to trigger reload with function ",string func];
  / send async message along each handle
  {[w;func;params] @[neg w;enlist[func],params;{[e] .z.m.log[`error][`notifyidbs;"idb notify send failed: ",e]}]}[;func;params] each ws;
  }

/ triggers idb reload steps; a sort process asks the wdb(s) to run initmissingtables
idbreload:{[pt;writedownmode]
  .z.m.log[`info][`idb;"starting idb reload"];
  if[writedownmode in `partbyenum`default`partbyfirstchar;
    .z.m.log[`info][`eod;"initialising wdbhdb for partition: ",string pt];
    $[.z.m.mode~`sort;
      {[pt;w] @[w;(`.wdb.initmissingtables;pt);{[e] .z.m.log[`error][`idb;"initmissingtables failed on the wdb: ",e]}]}[pt] each raze {exec w from x} each (.z.m.svc`getservers) each .z.m.wdbtypes;
      @[initmissingtables;pt;{[e] .z.m.log[`error][`idb;"initmissingtables failed: ",e]}]];
    .z.m.log[`info][`eod;"notifying idbs for newly created partition"];
    notifyidbs[`.idb.rollover;enlist pt]];
  .z.m.log[`info][`idb;"idb reload complete"];
  }

/ flushes, sorts or hands off the partition, and advances to the next
endofday:{[pt]
  .z.m.log[`info][`eod;"end of day message received - ",string pt];
  / set what type of merge method to be used
  mergemethod:.z.m.mergemode;
  / create a dictionary of tables and merge limits, byte or row count limit depending on settings
  .z.m.log[`info][`merge;"merging partitions by ",$[.z.m.mergebybytelimit;"byte estimate";"row count"]," limit"];
  tl:tablelist[],();
  mergelimits:tl!$[.z.m.mergebybytelimit;(count tl)#.z.m.mergenumbytes;mergemaxrows each tl],();
  tablist:tl!{0#value x} each tl;
  / if save mode is enabled then flush all data to disk
  if[.z.m.saveenabled;
    endofdaysave[.z.m.savedir;pt];
    / if sort mode enable call endofdaysort within the process, else inform the sort and reload process to do it
    $[.z.m.sortenabled;endofdaysort;informsortandreload] . (.z.m.savedirs;pt;tablist;.z.m.writedownmode;mergelimits;.z.m.hdbsettings;mergemethod)];
  .z.m.log[`info][`eod;"deleting data from ",$[.z.m.writedownmode in .z.m.partwritemodes;"partsizes and tabsizes";"tabsizes"]];
  if[.z.m.writedownmode in .z.m.partwritemodes;(.z.m.mrg`clearpartsizes)[]];
  .z.m.tabsizes:0#.z.m.tabsizes;
  .z.m.currentpartition:pt+1;
  set[`.wdb.currentpartition;.z.m.currentpartition];
  .z.m.log[`info][`eod;"end of day is now complete"];
  }

/ checks sort.csv sets the p attribute every partitioned writedown mode needs
checksortparams:{[]
  if[not .z.m.writedownmode in .z.m.partwritemodes;:()];
  params:sortparams[];
  / check that default table is defined
  $[count exec distinct tabname from params where tabname=`default,att=`p,sort;
    .z.m.log[`info][`init;"default table defined in sort.csv and with at least one `p attribute and sort=1b"];
    .z.m.log[`error][`init;"default table not defined in sort.csv with at least one `p attribute and sort=1b"]];
  / check for `p attributes
  $[count notparted:distinct params[`tabname] except distinct exec tabname from params where att in `p;
    .z.m.log[`error][`init;"parted attribute p not set at least once in sort.csv for table(s): ",", " sv string notparted];
    .z.m.log[`info][`init;"parted attribute p set at least once for each table in sort.csv"]];
  }

/ reads the sort.csv, as legacy the app's sort.csv when no sortcsv is set
initdbwrite:{[config;deps]
  .z.m.dbw:use`di.dbwrite;
  (.z.m.dbw`init)[enlist[`log]!enlist deps`log];
  f:$[`sortcsv in key config;resolvedir[apphome[];config`sortcsv];getenv[`TORQXAPPCONFIG],"/sort.csv"];
  if[(`sortcsv in key config) or count key hsym `$f;(.z.m.dbw`readcsv) f];
  }

/ reads every setting from config into the module
setconfig:{[config]
  .z.m.tptypes:$[`tickerplanttypes in key config;aslist assym config`tickerplanttypes;enlist`tickerplant];
  .z.m.hdbtypes:$[`hdbtypes in key config;aslist assym config`hdbtypes;enlist`hdb];
  .z.m.rdbtypes:$[`rdbtypes in key config;aslist assym config`rdbtypes;enlist`rdb];
  .z.m.idbtypes:$[`idbtypes in key config;aslist assym config`idbtypes;enlist`idb];
  .z.m.gatewaytypes:$[`gatewaytypes in key config;aslist assym config`gatewaytypes;enlist`gateway];
  .z.m.sorttypes:$[`sorttypes in key config;aslist assym config`sorttypes;enlist`sort];
  .z.m.sortworkertypes:$[`sortworkertypes in key config;aslist assym config`sortworkertypes;enlist`sortworker];
  .z.m.wdbtypes:$[`wdbtypes in key config;aslist assym config`wdbtypes;enlist`wdb];
  .z.m.ignorelist:$[`ignorelist in key config;aslist assym config`ignorelist;`heartbeat`logmsg];
  .z.m.hdbdir:hsym `$$[`hdbdir in key config;resolvedir[datahome[];config`hdbdir];datahome[],"/hdb"];
  .z.m.savedir:hsym `$$[`savedir in key config;resolvedir[datahome[];config`savedir];datahome[],"/wdb"];
  .z.m.savedirs:1_string .z.m.savedir;
  .z.m.mode:$[`mode in key config;assym config`mode;`saveandsort];
  if[not .z.m.mode in `saveandsort`save`sort;'"di.torq.proc.wdb: mode must be saveandsort, save or sort, got ",string .z.m.mode];
  .z.m.saveenabled:.z.m.mode in `save`saveandsort;
  .z.m.sortenabled:.z.m.mode in `saveandsort`sort;
  .z.m.writedownmode:$[`writedownmode in key config;assym config`writedownmode;`default];
  if[not .z.m.writedownmode in `default,.z.m.partwritemodes;
    '"di.torq.proc.wdb: writedownmode must be default, partbyattr, partbyenum or partbyfirstchar, got ",string .z.m.writedownmode];
  .z.m.mergemode:$[`mergemode in key config;assym config`mergemode;`part];
  if[not .z.m.mergemode in `part`col`hybrid;'"di.torq.proc.wdb: mergemode must be part, col or hybrid, got ",string .z.m.mergemode];
  .z.m.mergebybytelimit:$[`mergebybytelimit in key config;tobool config`mergebybytelimit;0b];
  .z.m.mergenumbytes:$[`mergenumbytes in key config;tolong config`mergenumbytes;500000000];
  .z.m.mergenumrows:$[`mergenumrows in key config;tolong config`mergenumrows;100000];
  .z.m.mergenumtab:$[`mergenumtab in key config;config`mergenumtab;`quote`trade!10000 50000];
  .z.m.numrows:$[`numrows in key config;tolong config`numrows;100000];
  .z.m.numtab:$[`numtab in key config;config`numtab;(`symbol$())!`long$()];
  .z.m.replaynumrows:$[`replaynumrows in key config;tolong config`replaynumrows;.z.m.numrows];
  .z.m.replaynumtab:$[`replaynumtab in key config;config`replaynumtab;.z.m.numtab];
  .z.m.immediate:$[`immediate in key config;tobool config`immediate;0b];
  .z.m.gc:$[`gc in key config;tobool config`gc;1b];
  .z.m.partitiontype:$[`partitiontype in key config;assym config`partitiontype;`date];
  .z.m.savedownmanipulation:$[`savedownmanipulation in key config;config`savedownmanipulation;()!()];
  .z.m.getpartition:$[`getpartition in key config;config`getpartition;defaultgetpartition];
  .z.m.upd:$[`upd in key config;config`upd;insert];
  .z.m.posteod:$[`postreplay in key config;config`postreplay;{[d;p]}];
  .z.m.reloadorder:$[`reloadorder in key config;astoklist config`reloadorder;`hdb`rdb`idb];
  .z.m.permitreload:$[`permitreload in key config;tobool config`permitreload;1b];
  .z.m.eodwaittime:$[`eodwaittime in key config;astimespan config`eodwaittime;0D00:00:10];
  .z.m.hdbsettings:`compression`hdbdir!($[`compression in key config;config`compression;()];.z.m.hdbdir);
  .z.m.tabsizes:([tablename:`symbol$()] rowcount:`long$(); bytes:`long$());
  .z.m.settimer:$[`settimer in key config;tolong config`settimer;10];
  .z.m.subscribeto:$[`subscribeto in key config;assym config`subscribeto;`];
  .z.m.subscribesyms:$[`subscribesyms in key config;assym config`subscribesyms;`];
  .z.m.replaylog:$[`replaylog in key config;tobool config`replaylog;1b];
  .z.m.tpwaittimeout:$[`tpwaittimeout in key config;tolong config`tpwaittimeout;30000];
  .z.m.currentpartition:0N;
  }

/ publishes the root names other processes and legacy's peach lambdas call
setroot:{[]
  set[`.wdb.endofdaysort;endofdaysort];
  set[`.wdb.handler;handler];
  set[`.wdb.reloadsymfile;reloadsymfile];
  set[`.wdb.setcompression;setcompression];
  set[`.wdb.merge;merge];
  set[`.wdb.gc;.z.m.gc];
  set[`.wdb.initmissingtables;initmissingtables];
  set[`.sort.sorttab;sorttab];
  set[`.merge.syncpartsizes;.z.m.mrg`syncpartsizes];
  set[`.merge.clearpartsizes;.z.m.mrg`clearpartsizes];
  / define .z.pd in order to connect to any worker processes
  @[`.z;`pd;:;{[] `u#raze {exec w from x} each (.z.m.svc`getservers) each .z.m.sortworkertypes}];
  @[`.;`upd;:;.z.m.upd];
  @[`.;`endofday;:;endofday];
  @[`.;`endofperiod;:;endofperiod];
  set[`.u.end;endofday];
  / the idb reads these at startup; currentpartition is republished at each end of day
  set[`.wdb.savedir;.z.m.savedir];
  set[`.wdb.hdbdir;.z.m.hdbdir];
  set[`.wdb.currentpartition;.z.m.currentpartition];
  set[`.wdb.writedownmode;.z.m.writedownmode];
  }

/ reads deps and config; a save mode then connects, subscribes and replays the tp log, a sort mode waits to be called
init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.wdb: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.wdb: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.torq.proc.wdb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.svc:deps`servers;
  setconfig config;
  / legacy passes -s -N on the command line; torqx.sh has no per-process flags, so it is a setting
  if[0<w:$[`workers in key config;tolong config`workers;0];system "s -",string w];

  / not in deps.toml: di.os has no VERSION, which fails depcheck
  .z.m.os:use`di.os;
  initdbwrite[config;deps];
  .z.m.mrg:use`di.merge;
  (.z.m.mrg`init)[`log`mergebybytelimit!(deps`log;.z.m.mergebybytelimit)];
  checksortparams[];

  if[.z.m.mode~`sort;
    conns:distinct .z.m.hdbtypes,.z.m.rdbtypes,.z.m.idbtypes,.z.m.gatewaytypes,.z.m.sortworkertypes,.z.m.wdbtypes;
    (.z.m.svc`startup)[config,(enlist`connections)!enlist conns];
    setroot[];
    .z.m.log[`info][`init;"initialised, mode=sort, savedir=",.z.m.savedirs,", hdbdir=",(1_string .z.m.hdbdir),", waiting to be called at .wdb.endofdaysort"];
    :()];

  .z.m.subs:use`di.subscriptions;
  (.z.m.subs`init)[config;deps];
  .z.m.currentpartition:getpartition[];
  (.z.m.os`mkdir) .z.m.savedir;
  clearwdbdata[];

  conns:distinct .z.m.tptypes,.z.m.hdbtypes,.z.m.rdbtypes,.z.m.idbtypes,.z.m.gatewaytypes,.z.m.sorttypes,.z.m.sortworkertypes;
  (.z.m.svc`startup)[config,(enlist`connections)!enlist conns];

  @[`.;`upd;:;replayupd];
  tpt:first .z.m.tptypes;
  if[not (.z.m.svc`waitfortype)[tpt;.z.m.tpwaittimeout;500];
    '"di.torq.proc.wdb: no ",(string tpt)," connection within ",(string .z.m.tpwaittimeout),"ms - cannot start wdb"];
  tph:(.z.m.svc`gethandlebytype)[tpt;`any];
  sd:(.z.m.subs`subscribe)[tph;.z.m.subscribeto;.z.m.subscribesyms;.z.m.replaylog];
  fixpartition sd`date;
  .z.m.log[`info][`wdb;"subscribed; replayed ",(string sd`rowcount)," message(s), partition ",string .z.m.currentpartition];
  if[.z.m.writedownmode in `default`partbyenum;initmissingtables .z.m.currentpartition];
  if[(not .z.m.numtab~.z.m.replaynumtab) or .z.m.numrows<>.z.m.replaynumrows;
    {replaymaxrowcheck[x;maxrows x]} each tablelist[]];

  setroot[];
  (.z.m.timer`addjob)[`wdbsave;savetodisk;();.z.m.settimer;1h;()!()];
  msg:"initialised, mode=",(string .z.m.mode),", writedownmode=",(string .z.m.writedownmode),", savedir=",.z.m.savedirs;
  msg,:", hdbdir=",(1_string .z.m.hdbdir),", flush every ",(string .z.m.settimer),"s";
  .z.m.log[`info][`wdb;msg,$[.z.m.sortenabled;"";", sort handed to ",", " sv string .z.m.sorttypes]];
  }
