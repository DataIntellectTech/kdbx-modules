/ di.proc.rdb - real-time database. Subscribes to a tickerplant (via di.subscriptions),
/ replays the day's tp log to recover intraday state, accumulates live updates in memory,
/ and at end of day writes each table down to the HDB (via di.dbwrite), clears it, and
/ tells the HDB(s) to reload. Ported from the CRITICAL path of TorQ/code/processes/rdb.q.
/ ---
/ Scope (v1, critical only - see the rdb.q Chesterton's-Fence audit): subscribe -> replay
/ -> accumulate -> savedown -> hdb reload. Two EOD modes, selected by config reloadenabled:
/   - standalone   (0b, default): save every table to the hdb, clear it, reload the hdb(s).
/   - wdb-fronted  (1b): a wdb owns the writedown; at EOD we only SNAPSHOT the per-table row
/     counts and escape (data stays live+queryable), then the wdb calls reload[date] over
/     IPC and we drop exactly the prior day, keeping the new day's ticks (dropfirstnrows).
/ NOT included (future/other-process): gateway attribute push, query-partition tracking
/ (rdbpartition/parvaluesrc - that exists only for a gateway), subscription filters, and
/ (deprecated) all finspace/aws paths.
/ ---
/ Module-namespace notes (see di.subscriptions for the full story): reads of root tables
/ use bare `value t` (bare reads fall through to root); writes/clears target root
/ explicitly via @[`.;..] because a bare write from a use-loaded module (or under -11!)
/ lands in the module's private namespace.

/ config coercion (values are symbols from .q settings or strings from .toml)
assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}

/ base dirs: CODE/CONFIG under TORQXAPPHOME, runtime DATA under TORQXDATAHOME (falls back to
/ TORQXAPPHOME when unset - fine for a sample app where they coincide).
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative dir setting to an absolute path STRING under `base`
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ root-namespace-safe upd: append to the ROOT table t. Handles a table payload (live, from
/ di.pubsub) and a list-of-columns payload (replay, from di.tplogmgr's -11!). @[`.;..] targets
/ root explicitly so it works from the module / -11! context.
updfn:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]]}

/ save one root table down to the HDB partition (protected so one failure doesn't stop EOD)
savefn:{[dir;date;t]
  .[{(.z.m.dbw`savedown)[hsym`$x;y;z;value z]};(dir;date;t);
    {[t;e] .z.m.log[`error][`rdb;"savedown failed for ",(string t),": ",e]}[t]]
  }

/ tell every connected hdb to reload (pick up the just-written partition)
notifyhdbs:{[]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.hdbtypes;
  $[count h;
    {[wh] @[wh;".hdb.reload[]";{[e] .z.m.log[`error][`rdb;"hdb reload failed: ",e]}]} each h;
    .z.m.log[`warn][`rdb;"no hdb connected to notify for reload"]];
  }

/ end of day: called by the tickerplant as endofday[date] (di.pubsub's dated broadcast).
/ standalone mode: save every non-ignored root table to the HDB, clear it, reload the HDB(s).
/ wdb-fronted mode (reloadenabled=1b): the wdb owns the writedown - snapshot the per-table
/ row counts (so a later reload[] drops exactly the prior day) and escape, leaving the data
/ live and queryable until the wdb calls reload[date].
endofday:{[date]
  .z.m.log[`info][`rdb;"end of day for partition ",string date];
  st:tables[`.] except .z.m.ignorelist;
  if[.z.m.reloadenabled;
    .z.m.eodtabcount:st!count each value each st;
    .z.m.log[`info][`rdb;"reload enabled - wdb owns writedown; snapshotted EOD row counts: ",.Q.s1 .z.m.eodtabcount];
    :()];
  savefn[.z.m.hdbdir;date] each st;
  @[`.;;0#] each st;                          / clear the saved tables (root)
  notifyhdbs[];
  .z.m.log[`info][`rdb;"end of day complete, saved+cleared: ",(", " sv string st)];
  }

/ grab a col!attribute dict for the attributed columns of a root table (`_` drop loses attrs)
grabattrs:{[t] exec c!a from (0!meta value t) where not null a}

/ reapply captured attributes to root table t. Operates on the VALUE then writes it back to
/ root via @[`.;..], so it is safe from the module namespace (a bare in-place ! would not be).
reapplyattrs:{[t;attrs]
  if[count attrs;
    upd:(key attrs)!{[c;at] ((#);enlist at;c)}'[key attrs;value attrs];   / col!(`att#col) parse trees
    @[`.;t;:;![value t;();0b;upd]]];
  }

/ drop the first n rows (the prior day, per the EOD snapshot) from root table t
dropfirstnrows:{[t;n] @[`.;t;n _]}

/ reload[date] - called BY THE WDB over IPC once it has persisted the prior day. Drop exactly
/ the rows present at EOD (keeping the new day's rows that arrived since), reapply attributes,
/ gc, and clear the snapshot. Root-safe throughout (see the module-namespace notes above).
reload:{[date]
  .z.m.log[`info][`rdb;"reload called by wdb for partition ",string date];
  st:tables[`.] except .z.m.ignorelist;
  attrs:st!grabattrs each st;                  / capture before the drop wipes them
  dropfirstnrows'[st;0^.z.m.eodtabcount st];   / missing snapshot -> drop nothing
  reapplyattrs'[st;attrs st];
  .z.m.eodtabcount:()!();                       / so a repeat reload is a no-op
  .Q.gc[];
  .z.m.log[`info][`rdb;"reload complete, dropped prior-day rows for: ",(", " sv string st)];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.proc.rdb: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.proc.rdb: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.proc.rdb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.tptypes:$[`tickerplanttypes in key config;aslist assym config`tickerplanttypes;enlist`tickerplant];
  .z.m.hdbtypes:$[`hdbtypes in key config;aslist assym config`hdbtypes;enlist`hdb];
  .z.m.ignorelist:$[`ignorelist in key config;aslist assym config`ignorelist;`heartbeat`logmsg];
  .z.m.hdbdir:$[`hdbdir in key config;resolvedir[datahome[];config`hdbdir];datahome[],"/hdb"];
  .z.m.reloadenabled:$[`reloadenabled in key config;`boolean$config`reloadenabled;0b];
  .z.m.eodtabcount:()!();                       / prior-day snapshot, populated at EOD when reloadenabled
  subscribeto:$[`subscribeto in key config;assym config`subscribeto;`];
  subscribesyms:$[`subscribesyms in key config;assym config`subscribesyms;`];
  replaylog:$[`replaylog in key config;`boolean$config`replaylog;1b];
  timeout:$[`tpwaittimeout in key config;"j"$config`tpwaittimeout;30000];

  / publish the root-safe upd BEFORE subscribing (replay drives it too)
  @[`.;`upd;:;updfn];

  / connect to the tickerplant + hdb(s) via the INJECTED di.torq.servers (di.torq already ran its
  / init - a shared, once-init'd connection registry). We only call startup, handing it our
  / own connection list; the lookup fns (waitfortype/gethandlebytype/getservers) come off the
  / same injected instance.
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist distinct .z.m.tptypes,.z.m.hdbtypes;
  (.z.m.svc`startup)[sconfig];

  / block until a tickerplant is up, then subscribe (subdetails + replay)
  tpt:first .z.m.tptypes;
  if[not (.z.m.svc`waitfortype)[tpt;timeout;500];
    '"di.proc.rdb: no ",(string tpt)," connection within ",(string timeout),"ms - cannot start rdb"];
  tph:(.z.m.svc`gethandlebytype)[tpt;`any];
  .z.m.subs:use`di.subscriptions;
  (.z.m.subs`init)[config;deps];
  sd:(.z.m.subs`subscribe)[tph;subscribeto;subscribesyms;replaylog];
  .z.m.log[`info][`rdb;"subscribed; replayed ",(string sd`rowcount)," message(s), partition date ",string sd`date];

  / di.dbwrite for savedown (optional sort.csv sort/attr config). Takes the injected binary
  / (ctx;msg) log dep directly - no adapter, since di.dbwrite now uses the same contract.
  .z.m.dbw:use`di.dbwrite;
  (.z.m.dbw`init)[enlist[`log]!enlist deps`log];
  if[`sortcsv in key config;(.z.m.dbw`readcsv)[resolvedir[apphome[];config`sortcsv]]];

  / publish the EOD entry points at root (the TP calls endofday[date]; .u.end is the alias).
  / reload[date] is the wdb's IPC entry point when reloadenabled (harmless if never called).
  @[`.;`endofday;:;endofday];
  @[`.;`.u.end;:;endofday];
  @[`.;`reload;:;reload];
  .z.m.log[`info][`rdb;"initialised, hdbdir=",.z.m.hdbdir,", reloadenabled=",string .z.m.reloadenabled];
  }
