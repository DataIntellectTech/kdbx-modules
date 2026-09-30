/ di.torq.proc.idb - ported from TorQ's idb.q
/ mounts the wdb's working directory so today's data can be queried before it reaches the hdb

astz:{[x] $[11h=abs type x;x;`$(),x]}
tolong:{[x] $[10h=abs type x;"J"$(),x;"j"$x]}

/ force loads sym file; the size is only recorded once the load succeeds, so a failed read is retried
loadsym:{[]
  .z.m.log[`info][`load;"loading the sym file"];
  @[{load x;.z.m.symsize:@[hcount;x;0]};.z.m.symfilepath;{.z.m.log[`error][`load;"failed to load sym file: ",(string .z.m.symfilepath)," error: ",x]}];
  }

/ force loads IDB
loadidb:{[]
  .z.m.log[`info][`load;"loading the db"];
  @[system;"l ",1_string .z.m.idbdir;{.z.m.log[`error][`load;"failed to load IDB: ",(string .z.m.idbdir)," error: ",x]}];
  .z.m.partitionsize:count key .z.m.idbdir;
  }

/ force loads the idb and the sym file
loaddb:{[]
  starttime:.z.t;
  loadsym[];
  loadidb[];
  .z.m.log[`info][`load;"IDB load has been finished for partition: ",(string .z.m.currentpartition),". Time taken(ms): ",string .z.t-starttime];
  }

/ sets current partition and force loads the idb and the sym file. Called by the wdb after EOD.
rollover:{[pt]
  .z.m.currentpartition:pt;
  .z.m.idbdir:.Q.dd[.z.m.savedir;$[.z.m.writedownmode~`default;`;pt]];
  .z.m.log[`info][`rollover;"IDB folder has been set to: ",string .z.m.idbdir];
  loaddb[];
  }

/ reloads the db. Called by the wdb after an intraday flush.
intradayreload:{[]
  starttime:.z.t;
  if[symfilehaschanged[];loadsym[]];
  if[partitioncounthaschanged[];loadidb[]];
  clearrowcountcache[];
  .z.m.log[`info][`intradayreload;"IDB reload has been finished for partition: ",(string .z.m.currentpartition),". Time taken(ms): ",string .z.t-starttime];
  }

/ checks if sym file has changed since last load of the IDB; hcount trapped as hdb/sym is absent until the wdb's first .Q.en
symfilehaschanged:{[] .z.m.symsize<>@[hcount;.z.m.symfilepath;0]}

/ checks if count of partitions has changed since last reload of the IDB. Records new partition count if changed.
/ the default writedown method doesn't need db reloading as no new directory is being created there.
partitioncounthaschanged:{[]
  if[(1j~.z.m.partitionsize) and .z.m.writedownmode~`default;:0b];
  $[.z.m.partitionsize<>c:count key .z.m.idbdir;[.z.m.partitionsize:c;1b];0b]
  }

/ this makes sure running "count trade" queries will return correct row count
clearrowcountcache:{[] set[`.Q.pn;.Q.pt!(count .Q.pt)#()]}

/ reads savedir, hdbdir, the current partition and the writedown mode from the wdb
setparametersfromwdb:{[config]
  wt:$[`wdbtypes in key config;astz config`wdbtypes;`wdb];
  t:$[`connecttimeoutms in key config;tolong config`connecttimeoutms;30000];
  (.z.m.svc`startup)[config,(enlist`connections)!enlist enlist wt];
  if[not (.z.m.svc`waitfortype)[wt;t;500];
    '"di.torq.proc.idb: no ",(string wt)," connection within ",(string t),"ms - cannot resolve savedir/hdbdir"];
  h:(.z.m.svc`gethandlebytype)[wt;`any];
  .z.m.log[`info][`init;"querying WDB, HDB locations, current partition and writedown mode from WDB"];
  params:@[h;(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition`.wdb.writedownmode);{'"di.torq.proc.idb: could not read from the wdb: ",x}];
  .z.m.savedir:hsym params 0;
  .z.m.currentpartition:params 2;
  .z.m.symfilepath:.Q.dd[hsym params 1;`sym];
  .z.m.writedownmode:params 3;
  .z.m.idbdir:.Q.dd[.z.m.savedir;$[.z.m.writedownmode~`default;`;.z.m.currentpartition]];
  .z.m.log[`info][`init;"Current settings: db folder: ",(string .z.m.idbdir),", sym file: ",(string .z.m.symfilepath),", writedownmode: ",string .z.m.writedownmode];
  }

/ helper function to support queries against the sym column
maptoint:{[val]
  $[(abs type val) in 5 6 7h;
    / if using an integer column, clamp value between 0 and max int (null maps to 0)
    0|2147483647&`long$val;
    / if using a symbol column, enumerate against the hdb sym file
    (`. `sym)?`TORQNULLSYMBOL^val]
  }

/ helper function to support queries against the sym column in partbyfirstchar
mapfctoint:{[val] .Q.an?$[0<type val;first each;first] string val}

/ reads deps and the wdb's parameters, then loads the db and the sym file
init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.idb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `servers in key deps;'"di.torq.proc.idb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.svc:deps`servers;
  setparametersfromwdb config;
  .z.m.symsize:0;
  .z.m.partitionsize:0;
  .z.m.log[`info][`init;"loading the db and the sym file first time"];
  loaddb[];
  / use-loading compiles into a private namespace, so publish the IPC surface and query helpers at root
  set[`.idb.intradayreload;intradayreload];
  set[`.idb.rollover;rollover];
  set[`maptoint;maptoint];
  set[`mapfctoint;mapfctoint];
  .z.m.log[`info][`init;"Initialisation of the IDB is done."];
  }
