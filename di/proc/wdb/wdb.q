/ di.proc.wdb - the write database. Subscribes to a tickerplant (via di.subscriptions), replays
/ the day's tp log (flushing to disk as it goes so a full day never sits in RAM), then during
/ the day incrementally writes each in-memory table to a working partition when it exceeds a row
/ threshold. At end of day it flushes what remains, sorts each table on disk, MOVES the working
/ partition into the hdb, and triggers a reload of the hdb(s) and rdb(s). Ported from the
/ CRITICAL path of TorQ/code/processes/wdb.q (+ code/wdb/writedown.q).
/ ---
/ Scope (v1, classic saveandsort, in-process, `default` writedown mode - see the wdb.q
/ Chesterton's-Fence audit). NOT included (future/other-process): sort/sortworker as
/ separate processes (mode save/sort, .z.pd fan-out); advanced writedown modes
/ (partbyattr/partbyenum/partbyfirstchar) and all of merge.q; the IDB tier
/ (notifyidbs/idbreload/filldb); compression. REMOVED (deprecated): finspace/aws and the
/ .z.pd tempfix guards; the endofperiod STP stub.
/ ---
/ Why a working dir + move (not write-straight-to-hdb): the hdb partition only ever appears
/ complete AND sorted, after the move - a mid-day crash can't leave partial/unsorted data in
/ the hdb, and (later) an idb can read the working partition intraday. Enumeration is against
/ the HDB sym file (so the moved partition's enum indices already match hdb/sym), which is
/ also why di.dbwrite.savedown/appenddown (single enum==write dir) don't fit the write path;
/ we reuse di.dbwrite only for the EOD sort/attr. When a wdb is present the rdb must run
/ reloadenabled=1b (it then does NOT enumerate) so only ONE process writes hdb/sym.
/ ---
/ Module-namespace notes (see di.subscriptions): root tables are READ via bare `value t`
/ (bare reads fall through to root) but WRITTEN/cleared via @[`.;..] (a bare write from a
/ use-loaded module, or under -11! replay, lands in the module's private namespace).

/ config coercion (values are symbols from .q settings or strings from .toml)
assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}

/ a token-list config (e.g. reloadorder): accept a space-separated string ("hdb rdb"), a
/ single symbol, a symbol list, or a list of strings -> always a symbol list.
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}

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

/ bridge di.torq's DYADIC log dep (ctx;msg) to di.dbwrite's MONADIC (msg) contract
monadiclog:{[dl] `info`warn`error!({[f;m] f[`wdb;m]}[dl`info];{[f;m] f[`wdb;m]}[dl`warn];{[f;m] f[`wdb;m]}[dl`error])}

/ per-table flush threshold: numtab override if present, else the global numrows
maxrows:{[t] $[t in key .z.m.numtab;.z.m.numtab t;.z.m.numrows]}

/ tables the wdb is responsible for (root tables minus the ignore list)
tablelist:{[] tables[`.] except .z.m.ignorelist}

/ root-namespace-safe accumulate: upsert into the ROOT table t. Handles a table payload
/ (live, from di.pubsub) and a list-of-columns payload (replay, from -11!). Identical to
/ di.proc.rdb's updfn - @[`.;..] targets root explicitly so it works under -11! / from the module.
updfn:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]]}

/ replay-time upd (installed at root ONLY during subscribe/replay): accumulate, then flush if
/ over threshold - this is what bounds replay memory. After replay init swaps root upd -> updfn.
replayupd:{[t;x] updfn[t;x]; if[maxrows[t] < count value t;flushtable[0b;t]];}

/ create-or-append one root table's rows into its working partition, then clear it in memory.
/ force=1b writes regardless of count (EOD flush); else only when over maxrows. Enumerates
/ against the HDB sym file (NOT the working dir) so the partition can later move into the hdb.
flushtable:{[force;t]
  n:count value t;
  if[not force; if[not maxrows[t] < n; :0b]];
  if[0=n; :0b];
  data:.Q.en[.z.m.hdbdir;0!value t];                      / enumerate syms vs hdb/sym (persists it)
  path:` sv (.Q.par[.z.m.savedir;.z.m.currentpartition;t];`);
  $[count @[key;path;{`$()}];
    .[path;();,;data];                                    / append to existing splayed partition
    path set data];                                       / create the partition
  @[`.;t;0#];                                             / clear the in-memory table (root-safe)
  .z.m.log[`info][`wdb;"flushed ",(string n)," rows of ",(string t)," to ",string path];
  1b
  }

/ timer job: flush every table over threshold (or all of them when immediate)
savetodisk:{[] flushtable[.z.m.immediate;] each tablelist[];}

/ remove any pre-existing working data for the current partition before replay (replay rebuilds
/ it from the log, so stale data from a previous run would be double-counted). Scoped to the
/ wdb's own working partition dir.
clearwdbdata:{[]
  pdir:.Q.par[.z.m.savedir;.z.m.currentpartition;`];
  if[count key pdir;
    d:1_string pdir;
    system "rm -rf ",d;
    .z.m.log[`info][`wdb;"cleared existing wdb working data at ",d]];
  }

/ EOD sort: sort + apply attributes on the working partition for table t (di.dbwrite, driven by
/ the sort config / its time-asc default). In-process, so the sym file this process enumerated
/ against is already current - no reloadsymfile needed (that is a separate-sort-worker concern).
sortpart:{[date;t]
  dir:` sv (.Q.par[.z.m.savedir;date;t];`);
  if[count key dir;(.z.m.dbw`sort)[t;dir]];
  }

/ move the working partition into the hdb, one table dir at a time. A table already present in the
/ hdb partition is skipped (never overwrite - that would corrupt the hdb), mirroring TorQ.
movetohdb:{[date]
  src:.Q.par[.z.m.savedir;date;`];
  if[not count key src;.z.m.log[`warn][`wdb;"no working partition to move for ",string date];:()];
  dst:.Q.par[.z.m.hdbdir;date;`];
  srcs:1_string src; dsts:1_string dst;
  system "mkdir -p ",dsts;
  {[srcs;dsts;t]
    s:srcs,"/",string t; d:dsts,"/",string t;
    $[count key hsym `$d;
      .z.m.log[`error][`wdb;"table ",(string t)," already in hdb partition ",dsts," - skipped to avoid corruption"];
      [system "mv ",s," ",d;.z.m.log[`info][`wdb;"moved ",(string t)," -> ",d]]];
   }[srcs;dsts;] each key src;
  if[0=count key src;system "rm -rf ",srcs];
  }

/ inform the gateway(s) that a reload is starting/ending. POC has no gateway (and di.proc.gateway
/ is not built yet), so this is a no-op when none is connected - the hook is kept for when it
/ lands. TorQ's protocol is (`reloadstart;`) / (`reloadend;`) to block/unblock in-flight queries.
informgateway:{[msg]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.gatewaytypes;
  if[0=count h;:()];
  {[wh;msg] @[neg wh;(`.gw.reload;msg);{[e] .z.m.log[`error][`wdb;"gateway inform failed: ",e]}]}[;msg] each h;
  }

/ tell every hdb of these types to reload (pick up the just-moved partition)
reloadhdbs:{[date]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.hdbtypes;
  {[wh] @[wh;".hdb.reload[]";{[e] .z.m.log[`error][`wdb;"hdb reload failed: ",e]}]} each h;
  }

/ tell every rdb of these types to reload[date] (drop the prior day it was holding in memory).
/ async - the rdb's root reload[date] does the dropfirstnrows (see di.proc.rdb, reloadenabled=1b).
reloadrdbs:{[date]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.rdbtypes;
  {[wh;date] @[neg wh;(`reload;date);{[e] .z.m.log[`error][`wdb;"rdb reload send failed: ",e]}]}[;date] each h;
  }

/ reload downstream in the configured order (default `hdb`rdb: hdb first so it sees the new
/ partition, then rdb so it drops the prior day), bracketed by the gateway block/unblock.
doreload:{[date]
  informgateway[`reloadstart];
  {[date;pt] $[pt in .z.m.hdbtypes;reloadhdbs[date];pt in .z.m.rdbtypes;reloadrdbs[date];.z.m.log[`warn][`wdb;"reloadorder entry ",(string pt)," is neither an hdb nor rdb type - skipped"]]}[date;] each .z.m.reloadorder;
  informgateway[`reloadend];
  }

/ end of day: called by the tickerplant as endofday[date] (di.pubsub's dated broadcast, same
/ trigger as di.proc.rdb). Flush what remains, sort each working partition, move it into the hdb, then
/ reload downstream. Advance the partition for the new day.
endofday:{[date]
  .z.m.log[`info][`wdb;"end of day for partition ",string date];
  flushtable[1b;] each tablelist[];                       / flush all remaining rows
  st:tablelist[];
  sortpart[date] each st;
  movetohdb[date];
  doreload[date];
  .z.m.currentpartition:date+1;
  .z.m.log[`info][`wdb;"end of day complete, wrote+moved: ",(", " sv string st)];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.proc.wdb: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.proc.wdb: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.proc.wdb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.tptypes:$[`tickerplanttypes in key config;aslist assym config`tickerplanttypes;enlist`tickerplant];
  .z.m.hdbtypes:$[`hdbtypes in key config;aslist assym config`hdbtypes;enlist`hdb];
  .z.m.rdbtypes:$[`rdbtypes in key config;aslist assym config`rdbtypes;enlist`rdb];
  .z.m.gatewaytypes:$[`gatewaytypes in key config;aslist assym config`gatewaytypes;enlist`gateway];
  .z.m.reloadorder:$[`reloadorder in key config;astoklist config`reloadorder;`hdb`rdb];
  .z.m.ignorelist:$[`ignorelist in key config;aslist assym config`ignorelist;`heartbeat`logmsg];
  .z.m.hdbdir:hsym `$$[`hdbdir in key config;resolvedir[datahome[];config`hdbdir];datahome[],"/hdb"];
  .z.m.savedir:hsym `$$[`savedir in key config;resolvedir[datahome[];config`savedir];datahome[],"/wdb"];
  .z.m.numrows:$[`numrows in key config;"j"$config`numrows;100000];
  .z.m.numtab:$[`numtab in key config;config`numtab;(`symbol$())!`long$()];
  .z.m.immediate:$[`immediate in key config;`boolean$config`immediate;0b];
  settimer:$[`settimer in key config;"j"$config`settimer;10];
  subscribeto:$[`subscribeto in key config;assym config`subscribeto;`];
  subscribesyms:$[`subscribesyms in key config;assym config`subscribesyms;`];
  replaylog:$[`replaylog in key config;`boolean$config`replaylog;1b];
  timeout:$[`tpwaittimeout in key config;"j"$config`tpwaittimeout;30000];

  / v1 uses today's date as the partition; the tp log date is checked against it after
  / subscribe. Cross-date replay (log date != today, needing the written working data moved to
  / the right partition - TorQ's fixpartition) is deferred; the POC runs same-day.
  .z.m.currentpartition:.z.D;
  system "mkdir -p ",1_string .z.m.savedir;
  clearwdbdata[];

  / di.dbwrite for the EOD sort/attr (monadic-log bridge; optional sort.csv config)
  .z.m.dbw:use`di.dbwrite;
  (.z.m.dbw`init)[enlist[`log]!enlist monadiclog deps`log];
  if[`sortcsv in key config;(.z.m.dbw`readcsv)[resolvedir[apphome[];config`sortcsv]]];

  / connect to the tickerplant + hdb(s) + rdb(s) (+ gateway) via the INJECTED di.torq.servers
  / (di.torq already ran init - shared once-init'd registry); we call only startup with our
  / own connection list, and use the lookup fns off the same injected instance.
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist distinct .z.m.tptypes,.z.m.hdbtypes,.z.m.rdbtypes,.z.m.gatewaytypes;
  (.z.m.svc`startup)[sconfig];

  / install the flushing replay upd at root BEFORE subscribing, so the -11! replay driven by
  / di.subscriptions flushes to disk as it goes (bounded memory). Swapped to updfn after.
  @[`.;`upd;:;replayupd];

  / block until a tickerplant is up, then subscribe (subdetails + replay)
  tpt:first .z.m.tptypes;
  if[not (.z.m.svc`waitfortype)[tpt;timeout;500];
    '"di.proc.wdb: no ",(string tpt)," connection within ",(string timeout),"ms - cannot start wdb"];
  tph:(.z.m.svc`gethandlebytype)[tpt;`any];
  .z.m.subs:use`di.subscriptions;
  (.z.m.subs`init)[config;deps];
  sd:(.z.m.subs`subscribe)[tph;subscribeto;subscribesyms;replaylog];
  if[not sd[`date]~.z.m.currentpartition;
    .z.m.log[`warn][`wdb;"tp log date ",(string sd`date)," != partition ",(string .z.m.currentpartition),"; using log date (cross-date working-dir move is deferred - see wdb.md)"];
    .z.m.currentpartition:sd`date];
  .z.m.log[`info][`wdb;"subscribed; replayed ",(string sd`rowcount)," message(s), partition date ",string sd`date];

  / swap to the live accumulate upd (the timer flushes over-threshold), publish EOD entries
  @[`.;`upd;:;updfn];
  @[`.;`endofday;:;endofday];
  @[`.;`.u.end;:;endofday];

  / timer job: check/flush to disk every settimer seconds (di.timer mode 1h period is seconds)
  (.z.m.timer`addjob)[`wdbsave;savetodisk;();settimer;1h;()!()];
  .z.m.log[`info][`wdb;"initialised, savedir=",(1_string .z.m.savedir),", hdbdir=",(1_string .z.m.hdbdir),", flush every ",(string settimer),"s"];
  }
