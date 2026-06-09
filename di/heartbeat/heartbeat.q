/ heartbeat module for kdb-x
/ every process can publish a periodic heartbeat over pub/sub so that downstream
/ monitors can detect when a process has stopped beating - i.e. it is stalled or
/ blocked - even when the underlying connection is still valid
/ the module handles both publishing heartbeats and, on the monitoring side,
/ storing received heartbeats and raising warnings / errors when they stop
/ runtime dependencies are injected via init and are required - the module errors
/ immediately if a required dependency is missing - see heartbeat.md
/ module-local state convention: read config bare, mutate via .z.m, and access
/ injected dependencies via .z.m at every call site

/ table used to publish heartbeats - sym holds the publishing process type
heartbeat:([] time:`timestamp$(); sym:`symbol$(); procname:`symbol$(); counter:`long$(); pid:`int$(); host:`symbol$(); port:`int$());

/ keyed store of the latest received heartbeat per process, with warning / error state
hb:update warning:0b,error:0b from `sym`procname xkey heartbeat;

/ remote handles we have already subscribed to for heartbeats
subscribedhandles:`int$();

/ heartbeat counter
hbcounter:0;

/ configuration defaults - overridden by the config dictionary passed to init
enabled:1b;             / whether heartbeat publishing / checking is enabled
subenabled:0b;          / whether this process monitors (subscribes to) other heartbeats
debug:1b;               / whether to log warning / error transitions
publishinterval:0D00:00:30;   / how often heartbeats are published
checkinterval:0D00:00:10;     / how often received heartbeats are checked
warningtolerance:1.5;   / warning after warningtolerance*publishinterval without a beat
errortolerance:2f;      / error after errortolerance*publishinterval without a beat
proctype:`unknown;      / this process's type (published as sym)
procname:.z.h;          / this process's name
pid:.z.i;               / this process's pid
host:.z.h;              / this process's host
port:`int$system"p";    / this process's port
connections:`$();       / process types this monitor should subscribe to
onwarning:{[procs]};    / callback fired with the rows entering warning state
onerror:{[procs]};      / callback fired with the rows entering error state

/ recognised configuration keys - anything else passed via config is ignored
configkeys:`enabled`subenabled`debug`publishinterval`checkinterval`warningtolerance`errortolerance`proctype`procname`pid`host`port`connections`onwarning`onerror;

/ warning / error grace periods - vary by process type if required
warningperiod:{[processtype] `timespan$warningtolerance*publishinterval};
errorperiod:{[processtype] `timespan$errortolerance*publishinterval};

requiredep:{[deps;name]
  / extract a required dependency dictionary, erroring immediately if absent or null
  d:$[99h=type deps;$[(name in key deps) and not (::)~deps name;deps name;()!()];()!()];
  if[not count d;
    '"di.heartbeat: ",(string name)," dependency is required; pass it via init deps - see di.",string name];
  d
  };

setdeps:{[deps]
  / extract and store the required dependencies, flattened for access via .z.m
  / log, timer and pubsub are always required; servers and handlers only when monitoring
  logdict:requiredep[deps;`log];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  timerdict:requiredep[deps;`timer];
  .z.m.timeraddjob:timerdict`addjob;
  .z.m.timercp:timerdict`cp;
  pubsubdict:requiredep[deps;`pubsub];
  .z.m.pubsubpublish:pubsubdict`publish;
  .z.m.pubsubsubscribe:pubsubdict`subscribe;
  if[subenabled;
    serversdict:requiredep[deps;`servers];
    .z.m.serversgetservers:serversdict`getservers;
    handlersdict:requiredep[deps;`handlers];
    .z.m.handlersregister:handlersdict`register];
  };

setconfig:{[config]
  / apply recognised configuration overrides (a dictionary) on top of current values
  cfg:$[99h=type config;config;()!()];
  ks:configkeys inter key cfg;
  (.Q.dd[.z.M] each ks) set' cfg ks;
  };

tosecs:{[span]
  / convert a timespan into whole seconds for the timer period
  `int$span%0D00:00:01
  };

registertimers:{
  / schedule the periodic heartbeat jobs via the injected timer (mode 1 = fixed interval)
  if[enabled;
    .z.m.timeraddjob[`hbpublish;publishheartbeat;();tosecs publishinterval;1;()!()];
    .z.m.timeraddjob[`hbcheck;checkheartbeat;();tosecs checkinterval;1;()!()]];
  if[subenabled;
    .z.m.timeraddjob[`hbsubscribe;hbsubscriptions;();60;1;()!()]];
  };

registerhandlers:{
  / wire the connection-close cleanup through the injected handler manager
  if[subenabled;
    .z.m.handlersregister[`.z.pc;`heartbeat;closeconnection]];
  };

init:{[config;deps]
  / initialise the module with configuration and injected dependencies - see heartbeat.md
  / config - dictionary of configuration overrides (see configkeys), or (::) for defaults
  / deps   - dictionary of injected dependencies keyed by name, each a dictionary of functions:
  /   `log      - `info`warn`error                                          - required
  /   `timer    - `addjob`deletejobs`enablejobs`disablejobs`getactivejobs`cp - required
  /   `pubsub   - `publish`subscribe                                        - required
  /   `servers  - `getservers                                              - required when subenabled
  /   `handlers - `register`remove`list                                     - required when subenabled
  / example:
  /   heartbeat.init[`proctype`procname!(`rdb;`rdb1); `log`timer`pubsub!(logdep;timerdep;psdep)]
  setconfig config;
  setdeps deps;
  registertimers[];
  registerhandlers[];
  .z.m.loginfo[`heartbeat;"di.heartbeat initialised"];
  };

publishheartbeat:{
  / publish a single heartbeat row over pub/sub and bump the counter
  if[not enabled;:()];
  .z.m.pubsubpublish[`heartbeat;enlist `time`sym`procname`counter`pid`host`port!(.z.m.timercp[];proctype;procname;hbcounter;pid;host;port)];
  .z.m.hbcounter:hbcounter+1;
  };

storeheartbeat:{[batch]
  / store one or more incoming heartbeats, keeping the latest per process and
  / clearing warning / error state - call this from upd when a heartbeat arrives
  .z.m.hb:hb upsert update warning:0b,error:0b from select by sym,procname from batch;
  };

addprocs:{[proctypes;procnames]
  / seed the store with expected processes so a never-seen process is flagged
  / real heartbeats arriving later override these seeded rows
  seed:2!([]sym:proctypes,();procname:procnames,();time:.z.m.timercp[];counter:0N;pid:0Ni;host:`;port:0Ni;warning:0b;error:0b);
  .z.m.hb:seed,hb;
  };

logwarnproc:{[r]
  / log a single process moving into warning state
  .z.m.logwarn[`heartbeat;"process ",(string r`procname)," (type ",(string r`sym),") has not heartbeated since ",string r`time];
  };

logerrproc:{[r]
  / log a single process moving into error state
  .z.m.logerr[`heartbeat;"process ",(string r`procname)," (type ",(string r`sym),") has not heartbeated since ",string r`time];
  };

warn:{[procs]
  / move processes into warning state, log and fire the warning callback
  if[debug;logwarnproc each 0!procs];
  .z.m.hb:hb upsert select sym,procname,warning:1b from procs;
  onwarning procs;
  };

err:{[procs]
  / move processes into error state, log and fire the error callback
  if[debug;logerrproc each 0!procs];
  .z.m.hb:hb upsert select sym,procname,error:1b from procs;
  onerror procs;
  };

checkheartbeat:{
  / flag processes that have not heartbeated within the warning / error grace periods
  / status: 0 healthy, 1 warning, 2+ error
  / grace periods are computed as locals first - module functions do not resolve inside qsql
  now:.z.m.timercp[];
  t:0!hb;
  wp:warningperiod each t`sym;
  ep:errorperiod each t`sym;
  stats:update status:(`short$now>time+wp)+`short$2*now>time+ep from t;
  newwarn:select sym,procname,time from stats where status=1,not warning;
  newerr:select sym,procname,time from stats where status>1,not error;
  if[count newwarn;warn newwarn];
  if[count newerr;err newerr];
  };

subscribeone:{[h]
  / subscribe to a single remote heartbeat publisher, logging and skipping on failure
  ok:@[{.z.m.pubsubsubscribe x;1b};h;{[h;e] .z.m.logerr[`heartbeat;"failed to subscribe to heartbeats on handle ",(string h),": ",e];0b}[h]];
  if[ok;.z.m.subscribedhandles:distinct subscribedhandles,h];
  };

subscribe:{[handles]
  / subscribe to heartbeats on the given remote handle(s), tracking successful subscriptions
  subscribeone each (),handles;
  };

getheartbeats:{[proctype]
  / subscribe to publishers of the given process type(s) that are not yet subscribed
  handles:(.z.m.serversgetservers proctype) except subscribedhandles;
  if[count handles;
    .z.m.loginfo[`heartbeat;"subscribing to new heartbeat handle(s) ",", " sv string handles];
    subscribe handles];
  };

hbsubscriptions:{
  / subscribe to all configured heartbeat publishers (by configured process type)
  getheartbeats connections;
  };

closeconnection:{[h]
  / drop a closed handle from the tracked subscriptions - registered against .z.pc
  .z.m.subscribedhandles:subscribedhandles except h;
  };

gethb:{
  / return the current heartbeat store for inspection
  hb
  };
