/ di.torq.proc.tickerplant - tickerplant built on di.pubsub, di.tplogmgr and di.eodtime; injected deps: log, timer, handlers
/ publishes each update immediately, or in batched mode buffers per table and flushes on a timer

/ base dirs: code and config under TORQXAPPHOME, data under TORQXDATAHOME (default TORQXAPPHOME)
apphome:{getenv[`TORQXAPPHOME]}
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative dir setting (symbol or string, optional leading colon) to an absolute path string under base
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ config values may be symbols (.q) or strings (.toml)
astz:{[x] $[11h=abs type x;x;`$x]}          / to symbol (timezones)
/ a timespan, string, symbol or number of seconds as a timespan; null if not convertible
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;type[x] in -5 -6 -7h;0D00:00:01*x;0Nn]};

/ feed payloads may arrive as a table or as a list of columns; normalise to columns
tocols:{[x] $[98h=type x;value flip x;x]}

/ prefix columns x with a data-timezone-adjusted timestamp unless the first column already is one
/ handles a single record (atom columns) and a batch (vector columns)
stamp:{[x]
  if[-12=type first first x;:x];
  a:.z.p+(.z.m.eod`getdailyadj)[];
  $[0>type first x;a,x;(enlist(count first x)#a),x]
  }

/ feed entry point, published at root as upd and .u.upd: stamps, logs (logh is 0 during replay),
/ then publishes immediately or buffers into the root table for the flush job
upd:{[t;x]
  x:tocols x;
  / roll the day first if past the roll: always when immediate, for unstamped data when batched
  if[$[.z.m.batchms>0;not -12=type first first x;1b];eodcheck[]];
  x:stamp x;
  if[.z.m.logh>0;(.z.m.tp`write)[.z.m.logh;(`upd;t;x)];.u.i+:1];
  if[count .z.m.tplogdir;.u.icounts[t]+:count first x];
  $[.z.m.batchms>0;
    t insert x;
    (.z.m.ps`publish)[t;flip (cols value t)!$[0>type first x;enlist each x;x]]
    ];
  }

/ subscriber entry point, published at root as .u.sub: syms ` subscribes to all syms, a sym list filters
sub:{[x;y]
  if[x~`;:sub[;y] each .z.m.tables];
  if[not x in .z.m.tables;'x];
  / batched: flush first, so a replaying subscriber doesn't receive the buffer twice
  if[.z.m.batchms>0;(.z.m.ps`pubclear)[.z.m.tables]];
  r:(.z.m.ps`subscribe)[x;y];
  (first r 0;first r 1)}

/ subscription details, published at root as .u.subdetails: registers the caller via di.pubsub and returns
/ tables, schemas (tablename!empty schema), logfile (` if logging is off), rowcount (messages logged at
/ subscription time, for di.tplogmgr.replayupto) and date
subdetails:{[tabs;syms]
  / batched: flush to existing subscribers first so the caller does not get logged rows twice
  if[.z.m.batchms>0;(.z.m.ps`pubclear)[.z.m.tables]];
  sub:(.z.m.ps`subscribe)[tabs;syms];
  d:(.z.m.eod`getd)[];
  lf:$[0<count .z.m.tplogdir;(.z.m.tp`logname)[.z.m.tplogdir;d];`];
  `tables`schemas`logfile`rowcount`date!(sub 0;(sub 0)!sub 1;lf;.u.i;d)
  }

/ batched-mode flush (timer job): publish every buffered table and clear it.
flush:{[] (.z.m.ps`pubclear)[.z.m.tables];}

/ EOD roll: flush any buffer, tell subscribers, roll the log, advance eodtime state.
endofday:{[]
  if[.z.m.batchms>0;(.z.m.ps`pubclear)[.z.m.tables]];
  d:(.z.m.eod`getd)[];
  / tell subscribers to end the day for partition d
  (.z.m.ps`callendofday)[d];
  if[.z.m.logh>0;r:(.z.m.tp`roll)[.z.m.logh;.z.m.tplogdir;d];.z.m.logh:r 0;.u.i:r 1;.u.L:(.z.m.tp`logname)[.z.m.tplogdir;d+1]];
  .u.icounts:(`symbol$())!0#0;
  (.z.m.eod`setd)[.u.d:d+1];
  (.z.m.eod`setnextroll)[(.z.m.eod`getroll)[.z.p]];
  (.z.m.eod`setdailyadj)[(.z.m.eod`getdailyadjustment)[]];
  .z.m.log[`info][`tickerplant;"end of day complete, rolled ",(string d)," -> ",string d+1];
  }

/ EOD check (timer job, ~1s): roll when the next-roll time has passed.
eodcheck:{[] if[(.z.m.eod`getnextroll)[]<.z.p;endofday[]];}

/ di.eodtime init dict: timezones as symbols, rolltimeoffset as a timespan
eoddeps:{[config;logdep]
  d:()!();
  if[`rolltimezone in key config;d:d,enlist[`rolltimezone]!enlist astz config`rolltimezone];
  if[`datatimezone in key config;d:d,enlist[`datatimezone]!enlist astz config`datatimezone];
  if[`rolltimeoffset in key config;
    if[null o:totimespan config`rolltimeoffset;'"di.torq.proc.tickerplant: rolltimeoffset must be a timespan"];
    d:d,enlist[`rolltimeoffset]!enlist o];
  / log first, then the eodtime keys
  (enlist[`log]!enlist logdep),d
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.tickerplant: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.tickerplant: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.torq.proc.tickerplant: handlers dependency is required - see di.torq.handlers"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.cfg:config;
  / batched every timerms ms (q's -t) when set, immediate otherwise
  .z.m.batchms:$[`timerms in key config;0^config`timerms;0];
  .z.m.tplogdir:$[`tplogdir in key config;resolvedir[datahome[];config`tplogdir];""];

  / schema: load the schema file at root; publishable tables are the unkeyed ones with time,sym first
  / other root tables are skipped; none publishable is an error
  schemafile:$[`schemafile in key config;resolvedir[apphome[];config`schemafile];apphome[],"/database.q"];
  system "l ",schemafile;
  allt:tables[];
  tabs:allt where {(98h=type value x) and `time`sym~2#cols x} each allt;
  if[0=count tabs;'"di.torq.proc.tickerplant: schema file loaded no publishable tables (need unkeyed with time,sym as the first two columns): ",schemafile];
  {@[x;`sym;`g#]} each tabs;
  .z.m.tables:tabs;

  / pubsub: subscribable tables, schema state from root tables, closesub on .z.pc via the handlers dep
  .z.m.ps:use`di.pubsub;
  (.z.m.ps`setsubtables)[tabs];
  (.z.m.ps`init)[enlist[`log]!enlist .z.m.log];
  (.z.m.handlers`register)[`.z.pc;`;`pubsub;0;.z.m.ps`closesub];

  / eodtime: single merged dict (log + tz config)
  .z.m.eod:use`di.eodtime;
  (.z.m.eod`init)[eoddeps[config;.z.m.log]];

  / tplog: prepared now; log opened after the root upd is published (replay needs it)
  .z.m.tp:use`di.tplogmgr;
  .z.m.logh:0;
  / table names only, read by .sub.subscribe; di.pubsub holds the subscribers
  .u.w:tabs!(count tabs)#();
  .u.i:0;
  .u.icounts:(`symbol$())!0#0;
  .u.L:`;
  .u.d:(.z.m.eod`getd)[];

  / publish the IPC surface at root, before opening the log so its replay finds upd
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
    .u.i:r 1;
    .u.L:(.z.m.tp`logname)[.z.m.tplogdir;.u.d];
    .z.m.log[`info][`tickerplant;"opened tp log, replayed ",(string r 1)," message(s)"];
    ];

  / timer jobs: EOD roll check every second; batched flush every -t ms
  (.z.m.timer`addjob)[`tpeodcheck;eodcheck;();0D00:00:01;1h;()!()];
  if[.z.m.batchms>0;
    (.z.m.timer`addjob)[`tpflush;flush;();0D00:00:00.001*.z.m.batchms;1h;()!()]];

  .z.m.log[`info][`tickerplant;"initialised, mode=",$[.z.m.batchms>0;"batched every ",(string .z.m.batchms),"ms";"immediate"],", tables=",", " sv string tabs];
  }
