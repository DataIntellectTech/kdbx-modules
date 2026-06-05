/ heartbeat module for kdb-x
/ every process can publish a periodic heartbeat over pub/sub so that downstream
/ monitors can detect when a process has stopped beating - i.e. it is stalled or
/ blocked - even when the underlying connection is still valid
/ module-local state convention: read via .z.M, mutate via .z.m

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

/ minimal default dependencies so the module works standalone (with less functionality)
/ injected real implementations replace these in init, matched key-for-key
defaultlog:`info`warn`error!(
  {[ctx;msg] -1 "INFO  ",(string ctx),": ",msg;};
  {[ctx;msg] -1 "WARN  ",(string ctx),": ",msg;};
  {[ctx;msg] -2 "ERROR ",(string ctx),": ",msg;});

defaulttimer:`addjob`deletejobs`enablejobs`disablejobs`getactivejobs`cp!(
  {[id;func;params;period;mode;opts]};
  {[ids]};
  {[ids]};
  {[ids]};
  {[] 0#`id`func`params`period!(`$();();();`int$())};
  {[] .z.p});

defaulthandlers:`register`remove`list!(
  {[event;name;func]};
  {[event;name]};
  {[event] ()});

defaultpubsub:`publish`subscribe!(
  {[tbl;data]};
  {[handle]});

defaultservers:enlist[`getservers]!enlist {[proctype] `int$()};

extractdep:{[deps;name]
  / pull a named dependency dictionary out of deps, empty dict when absent or null
  $[(name in key deps) and not (::)~deps name;deps name;()!()]
  };

setdeps:{[deps]
  / store injected dependencies, merging over the minimal defaults per key
  if[not 99h=type deps;deps:()!()];
  .z.m.log:defaultlog,extractdep[deps;`log];
  .z.m.timer:defaulttimer,extractdep[deps;`timer];
  .z.m.handlers:defaulthandlers,extractdep[deps;`handlers];
  .z.m.pubsub:defaultpubsub,extractdep[deps;`pubsub];
  .z.m.servers:defaultservers,extractdep[deps;`servers];
  };

setconfig:{[config]
  / apply recognised configuration overrides (a dictionary) on top of current values
  if[not 99h=type config;:()];
  ks:configkeys inter key config;
  {[k;v] (` sv `.z.m,k) set v}'[ks;config ks];
  };

tosecs:{[span]
  / convert a timespan into whole seconds for the timer period
  `int$span%0D00:00:01
  };

registertimers:{
  / schedule the periodic heartbeat jobs via the injected timer (mode 1 = fixed interval)
  if[enabled;
    .z.M.timer[`addjob][`hbpublish;publishheartbeat;();tosecs publishinterval;1;()!()];
    .z.M.timer[`addjob][`hbcheck;checkheartbeat;();tosecs checkinterval;1;()!()]];
  if[subenabled;
    .z.M.timer[`addjob][`hbsubscribe;hbsubscriptions;();60;1;()!()]];
  };

registerhandlers:{
  / wire the connection-close cleanup through the injected handler manager
  if[subenabled;
    .z.M.handlers[`register][`.z.pc;`heartbeat;closeconnection]];
  };

init:{[config;deps]
  / initialise the module with configuration and injected dependencies - see heartbeat.md
  / config - dictionary of configuration overrides (see configkeys), or (::) for defaults
  / deps   - dictionary of injected dependencies keyed by name, each a dictionary of functions
  setdeps deps;
  setconfig config;
  registertimers[];
  registerhandlers[];
  .z.M.log[`info][`heartbeat;"di.heartbeat initialised"];
  };

publishheartbeat:{
  / publish a single heartbeat row over pub/sub and bump the counter
  if[not enabled;:()];
  .z.M.pubsub[`publish][`heartbeat;enlist `time`sym`procname`counter`pid`host`port!(.z.M.timer[`cp][];proctype;procname;.z.M.hbcounter;pid;host;port)];
  .z.m.hbcounter:.z.M.hbcounter+1;
  };

storeheartbeat:{[batch]
  / store one or more incoming heartbeats, keeping the latest per process and
  / clearing warning / error state - call this from upd when a heartbeat arrives
  .z.m.hb:.z.M.hb upsert update warning:0b,error:0b from select by sym,procname from batch;
  };

addprocs:{[proctypes;procnames]
  / seed the store with expected processes so a never-seen process is flagged
  / real heartbeats arriving later override these seeded rows
  seed:2!([]sym:proctypes,();procname:procnames,();time:.z.M.timer[`cp][];counter:0N;pid:0Ni;host:`;port:0Ni;warning:0b;error:0b);
  .z.m.hb:seed,.z.M.hb;
  };

logwarnproc:{[r]
  / log a single process moving into warning state
  .z.M.log[`warn][`heartbeat;"process ",(string r`procname)," (type ",(string r`sym),") has not heartbeated since ",string r`time];
  };

logerrproc:{[r]
  / log a single process moving into error state
  .z.M.log[`error][`heartbeat;"process ",(string r`procname)," (type ",(string r`sym),") has not heartbeated since ",string r`time];
  };

warn:{[procs]
  / move processes into warning state, log and fire the warning callback
  if[debug;logwarnproc each 0!procs];
  .z.m.hb:.z.M.hb upsert select sym,procname,warning:1b from procs;
  .z.M.onwarning procs;
  };

err:{[procs]
  / move processes into error state, log and fire the error callback
  if[debug;logerrproc each 0!procs];
  .z.m.hb:.z.M.hb upsert select sym,procname,error:1b from procs;
  .z.M.onerror procs;
  };

warningperiod:{[processtype] `timespan$warningtolerance*publishinterval};
errorperiod:{[processtype] `timespan$errortolerance*publishinterval};

checkheartbeat:{
  / flag processes that have not heartbeated within the warning / error grace periods
  / status: 0 healthy, 1 warning, 2+ error
  now:.z.M.timer[`cp][];
  stats:0!update
    status:(`short$now>time+warningperiod each sym)+`short$2*now>time+errorperiod each sym
    from .z.M.hb;
  newwarn:select sym,procname,time from stats where status=1,not warning;
  newerr:select sym,procname,time from stats where status>1,not error;
  if[count newwarn;warn newwarn];
  if[count newerr;err newerr];
  };

subscribeone:{[h]
  / subscribe to a single remote heartbeat publisher, logging and skipping on failure
  ok:.[{.z.M.pubsub[`subscribe] x;1b};h;{[h;e] .z.M.log[`error][`heartbeat;"failed to subscribe to heartbeats on handle ",(string h),": ",e];0b}[h]];
  if[ok;.z.m.subscribedhandles:distinct .z.M.subscribedhandles,h];
  };

subscribe:{[handles]
  / subscribe to heartbeats on the given remote handle(s), tracking successful subscriptions
  subscribeone each (),handles;
  };

getheartbeats:{[proctype]
  / subscribe to publishers of the given process type(s) that are not yet subscribed
  handles:(.z.M.servers[`getservers] proctype) except .z.M.subscribedhandles;
  if[count handles;
    .z.M.log[`info][`heartbeat;"subscribing to new heartbeat handle(s) ",", " sv string handles];
    subscribe handles];
  };

hbsubscriptions:{
  / subscribe to all configured heartbeat publishers (by configured process type)
  getheartbeats connections;
  };

closeconnection:{[h]
  / drop a closed handle from the tracked subscriptions - registered against .z.pc
  .z.m.subscribedhandles:.z.M.subscribedhandles except h;
  };

gethb:{
  / return the current heartbeat store for inspection
  .z.M.hb
  };