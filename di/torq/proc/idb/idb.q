/ di.torq.proc.idb - intraday database process type. Mounts the WDB's *working* directory (the
/ same `savedir` the wdb writes/appends into during the day, before EOD sort+move into the
/ hdb - see di.torq.proc.wdb) so queries can see today's not-yet-persisted-to-hdb data intraday.
/ ---
/ v1 is a minimal, di.torq.proc.hdb-shaped mount + remount: di.torq.proc.idb only exposes a
/ remotely-triggerable `.idb.intradayreload[]`, same shape as di.torq.proc.hdb's `.hdb.reload[]` -
/ something else has to call it after data changes on disk. idb itself never polls or pushes;
/ that something else is the wdb, which calls `.idb.intradayreload[]` on every idbtypes connection two
/ ways - after any intraday flush that actually wrote something (unconditional), and again at
/ EOD if `idb` is opted into `reloadorder` (see di.torq.proc.wdb's wdb.q/wdb.md).
/ ---
/ It mounts savedir ITSELF, as a partitioned database, exactly as legacy TorQ's idb does in
/ default writedown mode (idbdir::.Q.dd[savedir;`]). So the tables carry a virtual `date` column
/ and the idb never needs to know which date the wdb is on - a new day's partition simply appears
/ under the root and the next reload picks it up. Mounting a single date directory instead would
/ mean tracking the wdb's partition, which wall-clock .z.d gets wrong for any end of day that is
/ not at midnight.
/ ---
/ The wdb enumerates every flushed table against ITS hdbdir, not against savedir (see
/ di.torq.proc.wdb's flushtable, `.Q.en[.z.m.hdbdir;...]`) - live, on every flush, not just at
/ EOD (`.Q.en` extends the domain AND rewrites hdbdir/sym on disk whenever it sees a symbol
/ that domain doesn't already have). So the mounted working-partition tables' symbol columns
/ are enumerated (foreign-keyed) against that SAME hdbdir/sym, not anything under savedir -
/ idb needs `hdbdir` as its own config, purely to load that file into its own session's root
/ `sym`, independently of mounting savedir. Without it, `` `sym `` never exists in the idb's
/ session and a symbol column reads back as raw enum indices instead of symbols.

astz:{[x] $[11h=abs type x;x;`$(),x]}
tolong:{[x] $[10h=abs type x;"J"$(),x;"j"$x]}

/ legacy TorQ's symfilehaschanged. Size, not mtime: .Q.en only ever appends.
/ hcount is trapped where legacy calls it bare: the wdb creates hdb/sym on its first .Q.en, so a
/ wdb that is up but has not flushed yet leaves us statting a file that is not there.
symfilehaschanged:{[]
  .z.m.symsize<>@[hcount;.z.m.symfilepath;0]
  }

/ legacy TorQ's `load symfilepath` - it names the variable after the file, so it sets root `sym`
/ even from inside a use-loaded module (verified). REPLACES rather than merges: the file is the
/ enumeration domain and the on-disk columns are positions in it, so root sym must match its order
/ exactly - a union against a reordered sym resolves every symbol column to the wrong value.
readsym:{[f]
  load f;
  .z.m.log[`info][`loadsym;"loaded sym domain (",(string count get `sym),") from ",string f];
  .z.m.symsize:@[hcount;f;0];
  }

/ force-load the sym domain; the caller decides whether to skip, as legacy splits loaddb from
/ intradayreload. A missing file is logged and survived - symsize stays 0 so the next reload
/ picks it up once a wdb has flushed.
loadsym:{[]
  .z.m.log[`info][`loadsym;"loading the sym file"];
  @[readsym;.z.m.symfilepath;{.z.m.log[`error][`loadsym;"failed to load sym file: ",(1_string .z.m.symfilepath),", with error: ",x]}];
  }

/ (re)mount savedir as a partitioned db. Empty or absent is normal - the wdb creates it on its
/ first flush - so warn and leave what is loaded rather than let system "l" take the process down.
domount:{[]
  d:1_string .z.m.savedir;
  $[count key .z.m.savedir;
    [system "l ",d; .z.m.log[`info][`domount;"loaded tables: ",", " sv string tables[]]];
    .z.m.log[`warn][`domount;"no working directory at ",d," yet - nothing to mount"]];
  }

/ the wdb has rolled to a new day (legacy's .idb.rollover). The root mount finds the new day by
/ itself, so .z.m.partition drives nothing today - it is kept for the two things that will need it:
/ gateway routing (legacy's .proc.getattributes) and the partition-scoped writedown modes, where
/ the mount is savedir/<partition> rather than the root. Not exposed until one of them lands.
rollover:{[pt]
  .z.m.partition:pt;
  .z.m.log[`info][`rollover;"wdb rolled to partition ",string pt];
  intradayreload[];
  }

intradayreload:{[]
  .z.m.log[`info][`reload;"reloading idb from ",1_string .z.m.savedir];
  if[symfilehaschanged[];loadsym[]];
  domount[];
  }

/ ask the wdb where it is writing and set our state from it - same name and job as legacy's.
/ The two must agree on savedir and hdbdir, and config on both sides drifts apart.
setparametersfromwdb:{[config]
  wt:$[`wdbtypes in key config;astz config`wdbtypes;`wdb];
  t:$[`connecttimeoutms in key config;tolong config`connecttimeoutms;30000];
  (.z.m.svc`startup)[config,(enlist`connections)!enlist enlist wt];
  if[not (.z.m.svc`waitfortype)[wt;t;500];
    '"di.torq.proc.idb: no ",(string wt)," connection within ",(string t),"ms - cannot resolve savedir/hdbdir"];
  h:(.z.m.svc`gethandlebytype)[wt;`any];
  / the error carries the offending name, so it needs no interpolation of our own
  p:@[h;(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition);{'"di.torq.proc.idb: could not read from the wdb: ",x}];
  / the wdb's paths are already hsyms; keep them as such and build the sym path with .Q.dd, as
  / legacy's symfilepath does. It is never partition-scoped - every day enumerates against the one.
  .z.m.savedir:p 0;
  .z.m.symfilepath:.Q.dd[p 1;`sym];
  .z.m.partition:p 2;
  .z.m.log[`info][`setparametersfromwdb;"savedir=",(1_string .z.m.savedir),", partition=",string .z.m.partition];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.idb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `servers in key deps;'"di.torq.proc.idb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.svc:deps`servers;
  setparametersfromwdb config;
  .z.m.log[`info][`init;"mounting idb from ",1_string .z.m.savedir];
  / symsize starts at 0, which is also what a missing sym file stats as - so the first load always
  / happens, and readsym only records a size on success
  .z.m.symsize:0;
  loadsym[];
  domount[];
  / publish the IPC-callable surface at a real root-level name - use-loading this file
  / compiles it into a private namespace (see di.torq.proc.hdb.init's identical note: a remote
  / `.idb.intradayreload[]` call would otherwise hit an undefined-function error).
  set[`.idb.intradayreload;intradayreload];
  set[`.idb.rollover;rollover];
  }
