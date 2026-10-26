/ di.torq.proc.rdb - real-time database: subscribes to a tickerplant, replays its log, holds the day's
/ data in root tables and at end of day saves them to the hdb (reloadenabled 0b) or snapshots row counts for
/ a wdb's later reload[date] (reloadenabled 1b). Root tables are written via @[`.;..]

/ config coercion (values are symbols from .q settings or strings from .toml)
assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}

/ base dirs: code and config under TORQXAPPHOME, data under TORQXDATAHOME (default TORQXAPPHOME)
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative dir setting to an absolute path string under base
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ upd: append to the root table t, from a table (live) or a list of columns (replay)
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

/ end of day for a date: save, clear and reapply attributes to every non-ignored root table, run postreplay
/ and reload the hdbs; with reloadenabled only snapshot the row counts for reload[date]
endofday:{[date]
  .z.m.log[`info][`rdb;"end of day for partition ",string date];
  st:tables[`.] except .z.m.ignorelist;
  if[.z.m.reloadenabled;
    .z.m.eodtabcount:st!count each value each st;
    .z.m.log[`info][`rdb;"reload enabled - wdb owns writedown; snapshotted EOD row counts: ",.Q.s1 .z.m.eodtabcount];
    :()];
  attrs:st!grabattrs each st;                  / capture before the clear wipes them
  savefn[.z.m.hdbdir;date] each st;
  @[`.;;0#] each st;                          / clear the saved tables (root)
  reapplyattrs'[st;attrs st];
  / call the postreplay hook unprotected
  (.z.m.dbw`postreplay)[hsym`$.z.m.hdbdir;date];
  notifyhdbs[];
  .z.m.log[`info][`rdb;"end of day complete, saved+cleared: ",(", " sv string st)];
  }

/ grab a col!attribute dict for the attributed columns of a root table (`_` drop loses attrs)
grabattrs:{[t] exec c!a from (0!meta value t) where not null a}

/ reapply captured attributes to root table t
reapplyattrs:{[t;attrs]
  if[count attrs;
    upd:(key attrs)!{[c;at] ((#);enlist at;c)}'[key attrs;value attrs];   / col!(`att#col) parse trees
    @[`.;t;:;![value t;();0b;upd]]];
  }

/ drop the first n rows (the prior day, per the EOD snapshot) from root table t
dropfirstnrows:{[t;n] @[`.;t;n _]}

/ reload[date] - called by the wdb: drop the rows counted at end of day, reapply attributes, gc and clear the snapshot
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
  if[not `log in key deps;'"di.torq.proc.rdb: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.rdb: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.torq.proc.rdb: servers dependency is required - injected by di.torq, see di.torq.servers"];
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

  / di.dbwrite for savedown (optional sort.csv sort/attr config)
  .z.m.dbw:use`di.dbwrite;
  / the save down hooks from config go to di.dbwrite
  sdm:$[`savedownmanipulation in key config;config`savedownmanipulation;()!()];
  pr:$[`postreplay in key config;config`postreplay;{[d;p]}];
  (.z.m.dbw`init)[`log`savedownmanipulation`postreplay!(deps`log;sdm;pr)];
  if[`sortcsv in key config;(.z.m.dbw`readcsv)[resolvedir[apphome[];config`sortcsv]]];

  / publish the root upd before subscribing (replay drives it too)
  @[`.;`upd;:;updfn];

  / connect to the tickerplant and hdbs via the injected di.torq.servers
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist distinct .z.m.tptypes,.z.m.hdbtypes;
  (.z.m.svc`startup)[sconfig];

  / block until a tickerplant is up, then subscribe (subdetails + replay)
  tpt:first .z.m.tptypes;
  if[not (.z.m.svc`waitfortype)[tpt;timeout;500];
    '"di.torq.proc.rdb: no ",(string tpt)," connection within ",(string timeout),"ms - cannot start rdb"];
  .z.m.subs:use`di.subscriptions;
  (.z.m.subs`init)[config;deps];
  sd:.sub.subscribe[subscribeto;subscribesyms;1b;replaylog;first .sub.getsubscriptionhandles[tpt;`;()!()]];
  if[count sd;.z.m.log[`info][`rdb;"subscribed, partition date ",string sd`d]];

  / publish the end-of-day entry points and reload[date] at root
  set[`.u.end;endofday];
  / segmented tickerplant entry points
  @[`.;`endofday;:;{[d;x] endofday d}];
  @[`.;`endofperiod;:;{[currp;nextp;data] .z.m.log[`info][`endofperiod;"Received endofperiod. currentperiod, nextperiod and data are ",(string currp),", ", (string nextp),", ", .Q.s1 data]}];
  @[`.;`reload;:;reload];
  .z.m.log[`info][`rdb;"initialised, hdbdir=",.z.m.hdbdir,", reloadenabled=",string .z.m.reloadenabled];
  }
