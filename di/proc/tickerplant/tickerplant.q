/ di.proc.tickerplant - real-time capture root. Orchestrates three hard deps in their own
/ init idioms (none use init[config;deps]): di.pubsub (sub/pub, kdbx-modules), di.tplogmgr
/ (log lifecycle, TorqX), di.eodtime (roll timing, vendored). Injected deps: log, timer.
/ Ported from the tick/log/EOD logic inline in TorQ/code/processes/tickerplant.q; the
/ pure pubsub half is di.pubsub. Both publish modes supported: `immediate (publish each
/ update straight away) and `batched (buffer per table, flush on a timer period).

/ base dirs: CODE/CONFIG lives under TORQXAPPHOME, runtime DATA under TORQXDATAHOME (falls
/ back to TORQXAPPHOME when unset - fine for a sample app where they coincide).
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative dir setting to an absolute path STRING under `base` (for tplog /
/ shell). handles symbol (.q settings) or string (.toml) input, and a leading handle colon.
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ consumers coerce at point of use: config values may be symbols (.q) or strings (.toml)
astz:{[x] $[11h=abs type x;x;`$x]}          / to symbol (timezones, publishmode)

/ feed payloads may arrive as a table or as a list of columns; normalise to columns
tocols:{[x] $[98h=type x;value flip x;x]}

/ stamp columns x with a leading data-timezone-adjusted timestamp, unless the first
/ column is already a timestamp (so log replay, which carries already-stamped data, is
/ idempotent). Handles a single record (atom columns) and a batch (vector columns).
stamp:{[x]
  if[-12=type first first x;:x];
  a:.z.p+(.z.m.eod`getdailyadj)[];
  $[0>type first x;a,x;(enlist(count first x)#a),x]
  }

/ feed entry point (published at root as `upd`/`.u.upd`, called by feeds over IPC).
/ stamps, logs (unless replaying - logh is 0 during the replay inside tplog.open), then
/ publishes immediately or buffers into the root table for the flush job.
upd:{[t;x]
  x:stamp tocols x;
  if[.z.m.logh>0;(.z.m.tp`write)[.z.m.logh;(`upd;t;x)];.z.m.msgcount+:1];
  $[.z.m.publishmode=`batched;
    t insert x;
    (.z.m.ps`publish)[t;flip (cols value t)!$[0>type first x;enlist each x;x]]
    ];
  }

/ subscriber entry point (published at root as `.u.sub`). syms=` -> all data for the
/ table(s); a sym list -> a sym-filtered subscription. Delegates to di.pubsub, whose
/ .z.w-based registration sees the calling subscriber's handle.
sub:{[tabs;syms] (.z.m.ps`subscribe)[tabs;syms]}

/ subscription-details call (published at root as `.u.subdetails`) for a replaying
/ subscriber - di.proc.rdb via di.subscriptions. In ONE synchronous call it (a) registers the
/ calling handle for live updates via di.pubsub (keyed on .z.w) and (b) returns everything
/ needed to replay the pre-subscription history exactly once:
/   tables   - the tables actually subscribed to
/   schemas  - tablename!empty-schema dict, so the subscriber can define the tables
/   logfile  - the current tp log file (` if logging disabled), for -11! replay
/   rowcount - messages logged AT SUBSCRIPTION TIME. The subscriber replays exactly this
/              many (di.tplogmgr.replayupto), so live messages arriving after subscription -
/              which are ALSO delivered over the feed - are not double-processed. Captured
/              in the same synchronous call as the subscribe, so no upd interleaves.
/   date     - the log date
/ This is the clean single-call analogue of the segmented TP's `subdetails`, deliberately
/ NOT the classic standard-TP surface (.u.i/.u.L/.u.d global reads).
subdetails:{[tabs;syms]
  sub:(.z.m.ps`subscribe)[tabs;syms];
  d:(.z.m.eod`getd)[];
  lf:$[0<count .z.m.tplogdir;(.z.m.tp`logname)[.z.m.tplogdir;d];`];
  `tables`schemas`logfile`rowcount`date!(sub 0;(sub 0)!sub 1;lf;.z.m.msgcount;d)
  }

/ batched-mode flush (timer job): publish every buffered table and clear it.
flush:{[] (.z.m.ps`pubclear)[.z.m.tables];}

/ EOD roll: flush any buffer, tell subscribers, roll the log, advance eodtime state.
endofday:{[]
  if[.z.m.publishmode=`batched;(.z.m.ps`pubclear)[.z.m.tables]];
  d:(.z.m.eod`getd)[];
  / tell subscribers (e.g. di.proc.rdb) to end the day for partition d - AFTER any final flush
  / above, so they save exactly the day's data. Carries the date (vendored pubsub patch).
  (.z.m.ps`callendofday)[d];
  if[.z.m.logh>0;r:(.z.m.tp`roll)[.z.m.logh;.z.m.tplogdir;d];.z.m.logh:r 0;.z.m.msgcount:r 1];
  (.z.m.eod`setd)[d+1];
  (.z.m.eod`setnextroll)[(.z.m.eod`getroll)[.z.p]];
  (.z.m.eod`setdailyadj)[(.z.m.eod`getdailyadjustment)[]];
  .z.m.log[`info][`tickerplant;"end of day complete, rolled ",(string d)," -> ",string d+1];
  }

/ EOD check (timer job, ~1s): roll when the next-roll time has passed.
eodcheck:{[] if[(.z.m.eod`getnextroll)[]<.z.p;endofday[]];}

/ builds eodtime's merged init dict from the log dep + any tz config present, coercing
/ timezone values to symbols. rolltimeoffset only passed if already a timespan (TOML has
/ no timespan type, so a .toml settings file leaves it at eodtime's default).
eoddeps:{[config;logdep]
  d:enlist[`log]!enlist logdep;
  if[`rolltimezone in key config;d[`rolltimezone]:astz config`rolltimezone];
  if[`datatimezone in key config;d[`datatimezone]:astz config`datatimezone];
  if[(`rolltimeoffset in key config) and -16h=type config`rolltimeoffset;d[`rolltimeoffset]:config`rolltimeoffset];
  d
  }

init:{[config;deps]
  if[not `log in key deps;'"di.proc.tickerplant: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.proc.tickerplant: timer dependency is required - see di.timer"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.cfg:config;
  .z.m.publishmode:$[`publishmode in key config;astz config`publishmode;`immediate];
  .z.m.pubperiod:$[`pubperiod in key config;"j"$config`pubperiod;1];
  .z.m.tplogdir:$[`tplogdir in key config;resolvedir[datahome[];config`tplogdir];""];

  / schema: load the schema file at root; publishable tables are the UNKEYED ones with
  / time,sym as their first two columns. Shape-filtering (rather than asserting every
  / root table qualifies) keeps the TP robust to ambient root tables that aren't part of
  / the schema - in a clean di.torq process root holds only the schema tables, but this
  / avoids a sharp edge if anything else is defined at root. A schema that yields no
  / publishable table is an error. Trade-off vs TorQ: a single malformed schema table is
  / skipped rather than erroring - flagged in the docs.
  schemafile:$[`schemafile in key config;resolvedir[apphome[];config`schemafile];apphome[],"/database.q"];
  system "l ",schemafile;
  allt:tables[];
  tabs:allt where {(98h=type value x) and `time`sym~2#cols x} each allt;
  if[0=count tabs;'"di.proc.tickerplant: schema file loaded no publishable tables (need unkeyed with time,sym as the first two columns): ",schemafile];
  {@[x;`sym;`g#]} each tabs;
  .z.m.tables:tabs;

  / pubsub: set the subscribable table list, then build its schema state from root tables
  .z.m.ps:use`di.pubsub;
  (.z.m.ps`setsubtables)[tabs];
  (.z.m.ps`init)[];

  / eodtime: single merged dict (log + tz config)
  .z.m.eod:use`di.eodtime;
  (.z.m.eod`init)[eoddeps[config;.z.m.log]];

  / tplog: prepared now; log opened after the root upd is published (replay needs it)
  .z.m.tp:use`di.tplogmgr;
  .z.m.logh:0;
  .z.m.msgcount:0;

  / publish the IPC surface at real root names (use mangles module code into a private
  / namespace, so a remote/replayed `upd`/`.u.sub` must resolve at root). Done BEFORE
  / opening the log so tplog.open's -11! replay finds `upd`.
  set[`upd;upd];
  set[`.u.upd;upd];
  set[`.u.sub;sub];
  set[`.u.subdetails;subdetails];
  set[`endofday;endofday];
  set[`.u.end;endofday];

  if[0<count .z.m.tplogdir;
    system "mkdir -p ",.z.m.tplogdir;
    r:(.z.m.tp`open)[.z.m.tplogdir;(.z.m.eod`getd)[]];
    .z.m.logh:r 0;
    .z.m.msgcount:r 1;
    .z.m.log[`info][`tickerplant;"opened tp log, replayed ",(string r 1)," message(s)"];
    ];

  / timer jobs: EOD roll check every second; batched flush every pubperiod seconds
  (.z.m.timer`addjob)[`tpeodcheck;eodcheck;();1;1h;()!()];
  if[.z.m.publishmode=`batched;
    (.z.m.timer`addjob)[`tpflush;flush;();.z.m.pubperiod;1h;()!()]];

  .z.m.log[`info][`tickerplant;"initialised, mode=",(string .z.m.publishmode),", tables=",", " sv string tabs];
  }
