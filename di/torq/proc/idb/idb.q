/ symbol config that may arrive as a string
astz:{[x] $[11h=abs type x;x;`$(),x]}
/ long config that may arrive as a string
tolong:{[x] $[10h=abs type x;"J"$(),x;"j"$x]}

/ checks if the sym file has changed; hcount trapped as hdb/sym is absent until the wdb's first .Q.en
symfilehaschanged:{[]
  .z.m.symsize<>@[hcount;.z.m.symfilepath;0]
  }

/ loads the sym file and records its size; replaces root sym as on-disk enums are positions in it
readsym:{[f]
  load f;
  .z.m.log[`info][`loadsym;"loaded sym domain (",(string count get `sym),") from ",string f];
  .z.m.symsize:@[hcount;f;0];
  }

/ force loads the sym file
loadsym:{[]
  .z.m.log[`info][`loadsym;"loading the sym file"];
  @[readsym;.z.m.symfilepath;{.z.m.log[`error][`loadsym;"failed to load sym file: ",(1_string .z.m.symfilepath),", with error: ",x]}];
  }

/ force loads the idb from the wdb's working directory
domount:{[]
  d:1_string .z.m.savedir;
  $[count key .z.m.savedir;
    [system "l ",d; .z.m.log[`info][`domount;"loaded tables: ",", " sv string tables[]]];
    .z.m.log[`warn][`domount;"no working directory at ",d," yet - nothing to mount"]];
  }

/ sets the current partition and reloads the idb. Called by the wdb after EOD.
rollover:{[pt]
  .z.m.partition:pt;
  .z.m.log[`info][`rollover;"wdb rolled to partition ",string pt];
  intradayreload[];
  }

/ reloads the idb. Called by the wdb after an intraday flush.
intradayreload:{[]
  .z.m.log[`info][`reload;"reloading idb from ",1_string .z.m.savedir];
  if[symfilehaschanged[];loadsym[]];
  domount[];
  }

/ reads savedir, hdbdir and the current partition from the wdb
setparametersfromwdb:{[config]
  wt:$[`wdbtypes in key config;astz config`wdbtypes;`wdb];
  t:$[`connecttimeoutms in key config;tolong config`connecttimeoutms;30000];
  (.z.m.svc`startup)[config,(enlist`connections)!enlist enlist wt];
  if[not (.z.m.svc`waitfortype)[wt;t;500];
    '"di.torq.proc.idb: no ",(string wt)," connection within ",(string t),"ms - cannot resolve savedir/hdbdir"];
  h:(.z.m.svc`gethandlebytype)[wt;`any];
  p:@[h;(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition);{'"di.torq.proc.idb: could not read from the wdb: ",x}];
  .z.m.savedir:p 0;
  .z.m.symfilepath:.Q.dd[p 1;`sym];
  .z.m.partition:p 2;
  .z.m.log[`info][`setparametersfromwdb;"savedir=",(1_string .z.m.savedir),", partition=",string .z.m.partition];
  }

/ reads deps and the wdb's parameters, loads the sym file and mounts the idb
init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.idb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `servers in key deps;'"di.torq.proc.idb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.svc:deps`servers;
  setparametersfromwdb config;
  .z.m.log[`info][`init;"mounting idb from ",1_string .z.m.savedir];
  .z.m.symsize:0;
  loadsym[];
  domount[];
  / use-loading compiles into a private namespace, so publish the IPC surface at root
  set[`.idb.intradayreload;intradayreload];
  set[`.idb.rollover;rollover];
  }
