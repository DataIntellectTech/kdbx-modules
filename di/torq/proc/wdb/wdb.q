/ di.torq.proc.wdb - the write database. Subscribes to a tickerplant (via di.subscriptions), replays
/ the day's tp log (flushing to disk as it goes so a full day never sits in RAM), then during
/ the day incrementally writes each in-memory table to a working partition when it exceeds a row
/ threshold. At end of day it flushes what remains, sorts each table on disk, MOVES the working
/ partition into the hdb, and triggers a reload of the hdb(s) and rdb(s). Ported from the
/ CRITICAL path of TorQ/code/processes/wdb.q (+ code/wdb/writedown.q).
/ ---
/ Scope (v1, classic saveandsort, in-process, `default` writedown mode - see the wdb.q
/ Chesterton's-Fence audit). NOT included (future/other-process): sort/sortworker as
/ separate processes (mode save/sort, .z.pd fan-out); advanced writedown modes
/ (partbyattr/partbyenum/partbyfirstchar) and all of merge.q; compression. REMOVED
/ (deprecated): finspace/aws and the .z.pd tempfix guards. NOTE: the endofperiod STP stub was
/ also removed here, and has since been RESTORED - di.torq.proc.segmentedtp sends it on every
/ period roll and an undefined root callback throws. See endofperiod below.
/ ---
/ idb (di.torq.proc.idb) is notified through notifyidbs, as legacy TorQ: .idb.intradayreload after any
/ intraday flush that wrote something, and .idb.rollover with the new partition at EOD (opt in by
/ putting idb in reloadorder). No partition on the intraday leg - the idb mounts the savedir root.
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

/ boolean config. A raw `boolean$ cannot do this job: on a string it returns one boolean PER
/ CHARACTER (`boolean$"false" is 11111b) and using that in a conditional throws 'type, and on a
/ symbol it throws outright - so an immediate or replaylog set from a .toml file or a command-line
/ override could not be read at all. An unrecognised word SIGNALS rather than defaulting to false:
/ a typo is a configuration error, and reading it as "off" silently is how a setting gets ignored
/ NB the `1 and `0 words are LOAD-BEARING - do not trim them in a tidy-up. A command-line override
/ arrives as a STRING, and di.torq.proc.chainedtp's integration suite passes `-replay 1
/ -clearlogonsubscription 1` (test_integration.q:175,238) precisely to exercise that path, as
/ test_integration_ctp.q:4-7 states. Two integration tests depend on "1" coercing to true.
truewords:`true`yes`on`t`y`1
falsewords:`false`no`off`f`n`0

tobool:{[x]
  if[-1h=type x;:x];
  if[type[x] in -4 -5 -6 -7 -8 -9h;:0<>x];
  if[not type[x] in -11 -10 10h;
    '"di.torq.proc.wdb: cannot read ",(-3!x)," as a boolean"];
  w:`$lower $[-11h=type x;string x;(),x];
  if[w in truewords;:1b];
  if[w in falsewords;:0b];
  '"di.torq.proc.wdb: cannot read ",(-3!x)," as a boolean; expected one of ",
    ", " sv string truewords,falsewords
  }

/ numeric config. Same trap as the boolean one, other half: a .toml bare number parses to a long,
/ but a command-line override arrives as a STRING and `"j"$"30000"` is the five CHARACTER CODES
/ 51 48 48 48 48, not 30000 - a list, silently wrong, which then reaches a timeout or a row
/ threshold. Strings are parsed, not cast. Same shape as di.torq.proc.tickerplant's
tolong:{[x]
  r:$[10h=abs type x;"J"$(),x;"j"$x];
  if[null r;'"di.torq.proc.wdb: could not parse \"",$[10h=abs type x;x;string x],"\" as a number"];
  r
  }

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

/ per-table flush threshold: numtab override if present, else the global numrows
maxrows:{[t] $[t in key .z.m.numtab;.z.m.numtab t;.z.m.numrows]}

/ tables the wdb is responsible for (root tables minus the ignore list)
tablelist:{[] tables[`.] except .z.m.ignorelist}

/ a logged payload is either one column per field or one ATOM per field; enlist the atoms so both
/ shapes flip into the table. Same test di.torq.proc.tickerplant applies before it publishes
ascols:{[d] $[0>type first d;enlist each d;d]}

/ root-namespace-safe accumulate: upsert into the ROOT table t. Handles a table payload
/ (live, from di.pubsub), a list-of-columns payload and a single row of ATOMS (both from replay,
/ via -11!). Identical to di.torq.proc.rdb's updfn - @[`.;..] targets root explicitly so it works
/ under -11! / from the module.
/ NB the atom-row case is not hypothetical: a feed may send a row of atoms, di.torq.proc.tickerplant's
/ stamp[] deliberately keeps it atomic and LOGS it that way, enlisting it only on the publish path. So
/ live delivery hides the shape and replay is where it lands - `flip (cols tab)!d` on atoms throws
/ 'rank, and a restart is exactly when replay runs
updfn:{[t;x] @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!ascols d]}[;x]]}

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

/ timer job: flush every table over threshold (or all of them when immediate), then notify any
/ connected idb(s) IF that actually changed something on disk (flushtable returns 1b per table
/ it wrote, 0b for one it skipped as empty/under-threshold) - an all-skipped tick stays silent,
/ so an idle wdb doesn't spam idb reloads. This is the per-flush leg from the header note above;
/ notifyidbs no-ops when no idb is connected, so this is safe to call unconditionally.
savetodisk:{[]
  changes:flushtable[.z.m.immediate;] each tablelist[];
  if[any changes;notifyidbs[`.idb.intradayreload;enlist()]];
  }

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
sortpart:{[pt;t]
  dir:` sv (.Q.par[.z.m.savedir;pt;t];`);
  if[count key dir;(.z.m.dbw`sort)[t;dir]];
  }

/ move the working partition into the hdb, one table dir at a time. A table already present in the
/ hdb partition is skipped (never overwrite - that would corrupt the hdb), mirroring TorQ.
movetohdb:{[pt]
  src:.Q.par[.z.m.savedir;pt;`];
  if[not count key src;.z.m.log[`warn][`wdb;"no working partition to move for ",string pt];:()];
  dst:.Q.par[.z.m.hdbdir;pt;`];
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

/ inform the gateway(s) that a reload is starting/ending. POC has no gateway (and di.torq.proc.gateway
/ is not built yet), so this is a no-op when none is connected - the hook is kept for when it
/ lands. TorQ's protocol is (`reloadstart;`) / (`reloadend;`) to block/unblock in-flight queries.
informgateway:{[msg]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.gatewaytypes;
  if[0=count h;:()];
  {[wh;msg] @[neg wh;(`.gw.reload;msg);{[e] .z.m.log[`error][`wdb;"gateway inform failed: ",e]}]}[;msg] each h;
  }

/ tell every hdb of these types to reload (pick up the just-moved partition). `pt` (the
/ partition being reloaded) is unused - kept so the doreload dispatch below can call every
/ reload*[pt] uniformly.
reloadhdbs:{[pt]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.hdbtypes;
  {[wh] @[wh;".hdb.reload[]";{[e] .z.m.log[`error][`wdb;"hdb reload failed: ",e]}]} each h;
  }

/ tell every rdb of these types to reload[pt] (drop the prior day it was holding in memory).
/ async - the rdb's root reload[pt] does the dropfirstnrows (see di.torq.proc.rdb, reloadenabled=1b).
reloadrdbs:{[pt]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.rdbtypes;
  {[wh;pt] @[neg wh;(`reload;pt);{[e] .z.m.log[`error][`wdb;"rdb reload send failed: ",e]}]}[;pt] each h;
  }

/ one path for both idb notifications, as legacy's notifyidbs. Async: the intraday leg fires after
/ every flush, so it must not block; the trap therefore only sees send failures.
notifyidbs:{[func;params]
  h:raze {exec w from (.z.m.svc`getservers)[x]} each .z.m.idbtypes;
  if[0=count h;:()];
  .z.m.log[`info][`notifyidbs;"notifying ",(string count h)," idb(s) with ",string func];
  {[wh;func;params] @[neg wh;enlist[func],params;{[e] .z.m.log[`error][`wdb;"idb notify send failed: ",e]}]}[;func;params] each h;
  }

/ reload downstream in the configured order (default `hdb`rdb: hdb first so it sees the new
/ partition, then rdb so it drops the prior day), bracketed by the gateway block/unblock.
/ `idb` is a valid reloadorder entry too (opt in by adding it, e.g. "hdb rdb idb") but is not
/ in the default order - existing apps that don't run an idb see no behaviour change here (the
/ separate, always-on intraday notify leg in savetodisk is unaffected by reloadorder either way).
/ pt is the day just closed - the hdb and rdb want that; the idb wants the one now being written
doreload:{[pt]
  informgateway[`reloadstart];
  {[pt;ptype]
    $[ptype in .z.m.hdbtypes;reloadhdbs[pt];
      ptype in .z.m.rdbtypes;reloadrdbs[pt];
      ptype in .z.m.idbtypes;notifyidbs[`.idb.rollover;pt+1];
      .z.m.log[`warn][`wdb;"reloadorder entry ",(string ptype)," is neither an hdb, rdb, nor idb type - skipped"]]
    }[pt;] each .z.m.reloadorder;
  informgateway[`reloadend];
  }

/ end of day: called by the tickerplant as endofday[pt] (di.pubsub's dated broadcast, same
/ trigger as di.torq.proc.rdb). Flush what remains, sort each working partition, move it into the hdb, then
/ reload downstream. Advance the partition for the new day.
endofday:{[pt]
  .z.m.log[`info][`wdb;"end of day for partition ",string pt];
  flushtable[1b;] each tablelist[];                       / flush all remaining rows
  st:tablelist[];
  sortpart[pt] each st;
  movetohdb[pt];
  doreload[pt];
  .z.m.currentpartition:pt+1;
  set[`.wdb.currentpartition;.z.m.currentpartition];
  .z.m.log[`info][`wdb;"end of day complete, wrote+moved: ",(", " sv string st)];
  }

/ a segmented tickerplant broadcasts endofperiod to EVERY subscriber on each period roll
/ (di.pubsub.callendofperiod). It is monadic, so the (currentperiod;nextperiod;data) triple
/ arrives as ONE list - see segmentedtp.md "End-of-period payload shape". Log-only, exactly as
/ legacy TorQ's stub (code/wdb/writedown.q:52): a period boundary is NOT a writedown trigger -
/ this wdb flushes on its own row threshold (see the timer) and rolls the partition on
/ endofday. This restores the stub the header records as REMOVED (deprecated): it was dropped
/ when no segmented tickerplant existed, and without it the wdb throws 'endofperiod on every
/ roll. A classic tickerplant simply never sends it.
endofperiod:{[x]
  .z.m.log[`info][`wdb;"received endofperiod, current/next period ",(string x 0),"/",(string x 1),", data ",.Q.s1 x 2];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.wdb: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.wdb: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.torq.proc.wdb: servers dependency is required - injected by di.torq, see di.torq.servers"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.tptypes:$[`tickerplanttypes in key config;aslist assym config`tickerplanttypes;enlist`tickerplant];
  .z.m.hdbtypes:$[`hdbtypes in key config;aslist assym config`hdbtypes;enlist`hdb];
  .z.m.rdbtypes:$[`rdbtypes in key config;aslist assym config`rdbtypes;enlist`rdb];
  .z.m.idbtypes:$[`idbtypes in key config;aslist assym config`idbtypes;enlist`idb];
  .z.m.gatewaytypes:$[`gatewaytypes in key config;aslist assym config`gatewaytypes;enlist`gateway];
  .z.m.reloadorder:$[`reloadorder in key config;astoklist config`reloadorder;`hdb`rdb];
  .z.m.ignorelist:$[`ignorelist in key config;aslist assym config`ignorelist;`heartbeat`logmsg];
  .z.m.hdbdir:hsym `$$[`hdbdir in key config;resolvedir[datahome[];config`hdbdir];datahome[],"/hdb"];
  .z.m.savedir:hsym `$$[`savedir in key config;resolvedir[datahome[];config`savedir];datahome[],"/wdb"];
  .z.m.numrows:$[`numrows in key config;tolong config`numrows;100000];
  .z.m.numtab:$[`numtab in key config;config`numtab;(`symbol$())!`long$()];
  .z.m.immediate:$[`immediate in key config;tobool config`immediate;0b];
  settimer:$[`settimer in key config;tolong config`settimer;10];
  subscribeto:$[`subscribeto in key config;assym config`subscribeto;`];
  subscribesyms:$[`subscribesyms in key config;assym config`subscribesyms;`];
  replaylog:$[`replaylog in key config;tobool config`replaylog;1b];
  timeout:$[`tpwaittimeout in key config;tolong config`tpwaittimeout;30000];

  / v1 uses today's date as the partition; the tp log date is checked against it after
  / subscribe. Cross-date replay (log date != today, needing the written working data moved to
  / the right partition - TorQ's fixpartition) is deferred; the POC runs same-day.
  .z.m.currentpartition:.z.D;
  system "mkdir -p ",1_string .z.m.savedir;
  clearwdbdata[];

  / di.dbwrite for the EOD sort/attr (optional sort.csv config). Takes the injected binary
  / (ctx;msg) log dep directly - no adapter, since di.dbwrite now uses the same contract.
  .z.m.dbw:use`di.dbwrite;
  (.z.m.dbw`init)[enlist[`log]!enlist deps`log];
  if[`sortcsv in key config;(.z.m.dbw`readcsv)[resolvedir[apphome[];config`sortcsv]]];

  / connect to the tickerplant + hdb(s) + rdb(s) (+ gateway) via the INJECTED di.torq.servers
  / (di.torq already ran init - shared once-init'd registry); we call only startup with our
  / own connection list, and use the lookup fns off the same injected instance.
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist distinct .z.m.tptypes,.z.m.hdbtypes,.z.m.rdbtypes,.z.m.idbtypes,.z.m.gatewaytypes;
  (.z.m.svc`startup)[sconfig];

  / install the flushing replay upd at root BEFORE subscribing, so the -11! replay driven by
  / di.subscriptions flushes to disk as it goes (bounded memory). Swapped to updfn after.
  @[`.;`upd;:;replayupd];

  / block until a tickerplant is up, then subscribe (subdetails + replay)
  tpt:first .z.m.tptypes;
  if[not (.z.m.svc`waitfortype)[tpt;timeout;500];
    '"di.torq.proc.wdb: no ",(string tpt)," connection within ",(string timeout),"ms - cannot start wdb"];
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
  @[`.;`endofperiod;:;endofperiod];        / only a SEGMENTED tp sends this, on every period roll
  / the idb reads these directly at startup, as legacy's setparametersfromwdb does. savedir and
  / hdbdir are fixed for the life of the process; currentpartition is republished whenever it
  / moves (see endofday), or the copy here goes stale from the first roll.
  set[`.wdb.savedir;.z.m.savedir];
  set[`.wdb.hdbdir;.z.m.hdbdir];
  set[`.wdb.currentpartition;.z.m.currentpartition];

  / timer job: check/flush to disk every settimer seconds (di.timer mode 1h period is seconds)
  (.z.m.timer`addjob)[`wdbsave;savetodisk;();settimer;1h;()!()];
  .z.m.log[`info][`wdb;"initialised, savedir=",(1_string .z.m.savedir),", hdbdir=",(1_string .z.m.hdbdir),", flush every ",(string settimer),"s"];
  }
