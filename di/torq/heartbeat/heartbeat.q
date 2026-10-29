/ publish heartbeats, and check that subscribed heartbeats arrive in time

/ published heartbeats; sym is the proctype
heartbeat:([]time:`timestamp$();sym:`symbol$();procname:`symbol$();counter:`long$();pid:`int$();host:`$();port:`int$());

pid:.z.i;
host:.z.h;
port:system"p";

/ received heartbeats by sym and procname
hb:update warning:0b,error:0b from `sym`procname xkey heartbeat;

hbcounter:0j;
subscribedhandles:0 0Ni;

/ a timespan, string, symbol or number of seconds as a timespan; null if not convertible
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;type[x] in -5 -6 -7h;0D00:00:01*x;0Nn]};

warningperiod:{[processtype] `timespan$warningtolerance*publishinterval};
errorperiod:{[processtype] `timespan$errortolerance*publishinterval};

publishheartbeat:{
  if[@[value;`.ps.initialised;0b];
    .ps.publish[`heartbeat;enlist `time`sym`procname`counter`pid`host`port!(.z.p;.z.m.proctype;.z.m.procname;hbcounter;pid;host;port)];
    .z.m.hbcounter+:1];
  };

/ seed hb with process types and names
addprocs:{[proctypes;procnames]
  .z.m.hb:(2!([]sym:proctypes,();procname:procnames,();time:.z.p;counter:0Nj;pid:0Nj;host:`;port:0Nj;warning:0b;error:0b)),.z.m.hb
  };

storeheartbeat:{[hb]
  .z.m.hb:.z.m.hb upsert update warning:0b,error:0b from select by sym,procname from hb;
  };

checkheartbeat:{
  / flag processes that have not heartbeated within their warning or error period
  now:.z.p;
  stats:update status+`short$2*now>time+.z.m.errorperiod[sym] from
    update status:`short$now>time+.z.m.warningperiod[sym] from .z.m.hb;
  warn[select from stats where status=1,not warning];
  err[select from stats where status>1,not error];
  };

warn:{
  if[debug;
    {.z.m.log[`info][`heartbeat;"processtype ",(string x`sym),", processname ",(string x`procname),
      " has not heartbeated since ",(string x`time)," and has status WARNING"]} each 0!x];
  .z.m.hb:update warning:1b from .z.m.hb where ([]sym;procname) in key x;
  processwarning[x];
  };

err:{
  if[debug;
    {.z.m.log[`error][`heartbeat;"processtype ",(string x`sym),", processname ",(string x`procname),
      " has not heartbeated since ",(string x`time)," and has status ERROR"]} each 0!x];
  .z.m.hb:update error:1b from .z.m.hb where ([]sym;procname) in key x;
  processerror[x];
  };

subscribe:{[handle]
  @[{x(`.ps.subscribe;`heartbeat;`); .z.m.subscribedhandles,:x};handle;
    {.z.m.log[`error][`hbsub;"failed to subscribe to heartbeat on handle ",(string x),": ",y]}[handle]];
  };

hbsubscriptions:{[] getheartbeats CONNECTIONS};

getheartbeats:{[proctype]
  if[`ALL in proctype;proctype:`];
  / handles not yet subscribed to
  handles:(.servers.getservers[`proctype;proctype;()!();0b;0b]`w) except subscribedhandles;
  if[count handles;
    .z.m.log[`info][`hbsub;"subscribing to new handle(s) ",", " sv string handles];
    subscribe each handles];
  };

connectcustom:{[func;connectiontab]
  / subscribe to newly connected processes of CONNECTIONS (all if `ALL), then run the wrapped func
  connectiontab:$[`ALL in .z.m.CONNECTIONS;connectiontab;select from connectiontab where proctype in .z.m.CONNECTIONS];
  connectiontab:select from connectiontab where not w in .z.m.subscribedhandles;
  if[count connectiontab;subscribe each connectiontab`w];
  func@connectiontab
  };

init:{[config;deps]
  if[not `log in key deps;'"di.torq.heartbeat: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.heartbeat: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.torq.heartbeat: handlers dependency is required - see di.torq.handlers"];
  req:`proctype`procname`heartbeatenabled`heartbeatsubscribeenabled`heartbeatdebug`heartbeatpublishinterval`heartbeatcheckinterval,
    `heartbeatwarningtolerance`heartbeaterrortolerance`heartbeatsubscribetypes;
  if[count m:req except key config;'"di.torq.heartbeat: missing settings: ",", " sv string m];
  .z.m.log:deps`log;
  .z.m.proctype:config`proctype;
  .z.m.procname:config`procname;
  .z.m.enabled:config`heartbeatenabled;
  .z.m.subenabled:config`heartbeatsubscribeenabled;
  .z.m.debug:config`heartbeatdebug;
  .z.m.publishinterval:totimespan config`heartbeatpublishinterval;
  if[null publishinterval;'"di.torq.heartbeat: heartbeatpublishinterval must be a timespan"];
  .z.m.checkinterval:totimespan config`heartbeatcheckinterval;
  if[null checkinterval;'"di.torq.heartbeat: heartbeatcheckinterval must be a timespan"];
  .z.m.warningtolerance:config`heartbeatwarningtolerance;
  .z.m.errortolerance:config`heartbeaterrortolerance;
  .z.m.CONNECTIONS:$[11h=abs type c:config`heartbeatsubscribetypes;c;`$c];
  .z.m.processwarning:$[`processwarning in key config;config`processwarning;{[x]}];
  .z.m.processerror:$[`processerror in key config;config`processerror;{[x]}];
  use`di.pubsub;
  @[`.;`heartbeat;:;heartbeat];
  addjob:deps[`timer]`addjob;
  register:deps[`handlers]`register;
  register[`.z.pc;`;`hbpubsub;0j;.stpps.closesub];
  if[(not @[value;`.proc.lowpowermode;0b]) & enabled;
    .z.m.log[`info][`init;"adding heartbeat functions to the timer"];
    addjob[`publishheartbeat;publishheartbeat;();publishinterval;3h;enlist[`description]!enlist "publish heartbeats"];
    addjob[`checkheartbeat;checkheartbeat;();checkinterval;3h;
      enlist[`description]!enlist "check the heartbeats have been received in a timely manner"]];
  if[subenabled;
    @[`.;`upd;:;{[f;t;x] if[t=`heartbeat;storeheartbeat[x]]; f . (t;x)}@[value;`..upd;{{[t;x]}}]];
    register[`.z.pc;`;`heartbeat;0j;{if[x;.z.m.subscribedhandles:subscribedhandles except x]}];
    addjob[`hbsubscriptions;hbsubscriptions;();0D00:01:00;1h;`dupcheck`description!(0b;"subscribe to heartbeats")];
    set[`.servers.connectcustom;connectcustom@[value;`.servers.connectcustom;{{[x]}}]]];
  };
