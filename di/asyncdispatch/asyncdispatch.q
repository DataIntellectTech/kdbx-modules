/ di.asyncdispatch - async scatter-gather query coordinator.
/ Queues queries, dispatches to available backends, collects results per server,
/ applies a join function, and replies to the client.
/ Routing (which servers satisfy a query) is di.serverselect's responsibility.

errorprefix:"error: ";
querykeeptime:0D00:30;
clearinactivetime:0D01:00;
synccallsallowed:0b;

cp:{.z.p};
setcp:{.z.m.cp:x};

/ on a sync error signal result back to client; otherwise pass result through unchanged
formatresponse:{[status;sync;result]$[not[status]and sync;'result;result]};
setformatresponse:{.z.m.formatresponse:x};

/ symbols backend servers call back via; set to wherever this module is mounted
resultcallback:`addserverresult;
errorcallback:`addservererror;
setcallbacks:{[resfn;errfn].z.m.resultcallback:resfn;.z.m.errorcallback:errfn};

/ registered backend servers
servers:([handle:`u#`int$()] servertype:`symbol$(); inuse:`boolean$(); active:`boolean$(); disconnecttime:`timestamp$())

/ pending and in-flight client queries
queryqueue:([queryid:`u#`long$()] time:`timestamp$(); clienth:`int$(); query:(); servertype:(); join:(); postback:(); timeout:`timespan$(); returntime:`timestamp$(); error:`boolean$(); sync:`boolean$())

/ connected client tracking
clients:([] time:`timestamp$(); clienth:`int$(); user:`symbol$(); ip:`int$(); host:`symbol$())

/ per-query result accumulator: queryid -> (clienth; servertype!(handle;result;done))
results:()!()

queryid:0;

addserver:{[h;st].z.M.servers upsert (h;st;0b;1b;0Np)};

/ returns a table of available servers; excludeinuse=1b returns only idle servers
availableservers:{[excludeinuse]
  $[excludeinuse;
    select from servers where active, not inuse;
    select from servers where active]};
setavailableservers:{.z.m.availableservers:x};

addclientdetails:{[h].z.M.clients insert (cp[];h;.z.u;.z.a;.z.h)};

removeclienthandle:{[h]
  update error:1b,returntime:.z.m.cp[] from .z.M.queryqueue where clienth=h, null returntime;
  .z.m.results:(exec queryid from .z.m.queryqueue where clienth=h)_results};

addquery:{[query;servertype;join;postback;timeout;sync]
  / enqueue a query - does not dispatch; call runnextquery[] after
  .z.M.queryqueue upsert (queryid;cp[];.z.w;query;servertype;join;{$[11h=type x;enlist x;x]}postback;timeout;0Np;0b;sync);
  .z.m.queryid:queryid+1};

removequeries:{[age]
  / purge completed queries older than age from queryqueue
  .z.m.queryqueue:0!delete from .z.m.queryqueue where not null returntime, .z.m.cp[]>returntime+age};

getnextqueryid:{
  avail:exec distinct servertype from availableservers 1b;
  runnable:0!select from .z.m.queryqueue where null returntime, not queryid in key .z.m.results, {all x in y}[;avail] each servertype;
  1 sublist select from runnable where time=min time};
setgetnextqueryid:{.z.m.getnextqueryid:x};

addserverresult:{[qid;data]
  / backend posted a successful result - fill slot, free server, try next; reply once all slots received
  if[not qid in key results;:()];
  st:first exec servertype from .z.m.servers where handle=.z.w;
  slots:results[qid;1];
  slots[st]:(.z.w;data;1b);
  results[qid]:(results[qid;0];slots);
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  if[not qid in key results;:()];
  vals:value results[qid;1];
  if[not all vals[;2];:()];
  qd:queryqueue[qid];
  res:@[{(0b;x y)}[qd`join];vals[;1];{(1b;errorprefix,"join failed: ",x)}];
  sendclientreply[qid;last res;not res 0];
  finishquery[qid;res 0]};

addservererror:{[qid;err]
  sendclientreply[qid;errorprefix,err;0b];
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  finishquery[qid;1b]};

sendclientreply:{[qid;result;status]
  qd:queryqueue[qid];
  if[qd`error;:()];
  tosend:$[()~qd`postback;result;qd[`postback],enlist[qd`query],enlist result];
  $[qd`sync;
    @[-30!;(qd`clienth;not status;$[status;formatresponse[1b;1b;result];result]);{}];
    @[neg qd`clienth;formatresponse[status;0b;tosend];()]]};

finishquery:{[qid;err]
  .z.m.results:(qid,())_results;
  update error:err,returntime:.z.m.cp[] from .z.M.queryqueue where queryid in qid};

serverexecute:{[qid;query]
  / runs on the backend; traps errors and posts result back via resultcallback/errorcallback
  res:@[{(0b;value x)};query;{(1b;"server ",(string .z.h),":",(string system"p"),": ",x)}];
  @[neg .z.w;$[res 0;(errorcallback;qid;res 1);(resultcallback;qid;res 1)];
    {@[neg .z.w;(errorcallback;x;"failed to return result: ",y);()]}[qid]]};

sendquerytoserver:{[qid;query;handles]
  (neg handles,:())@\:(serverexecute;qid;query);
  update inuse:1b from .z.M.servers where handle in handles};

runnextquery:{
  / pick next runnable query and dispatch to one idle server per required servertype
  if[0=count torun:getnextqueryid[];:()];
  torun:first torun;
  avail:exec first handle by servertype from availableservers 1b;
  types:torun`servertype;
  handles:avail types;
  qid:torun`queryid;
  slots:types!(count[types],())#enlist(0Ni;(::);0b);
  slots[types;0]:handles;
  results[qid]:(torun`clienth;slots);
  sendquerytoserver[qid;torun`query;handles]};

checktimeout:{
  qids:exec queryid from .z.m.queryqueue where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[count qids;
    sendclientreply[;errorprefix,"query timed out";0b] each qids;
    finishquery[qids;1b]]};

removeserverhandle:{[serverh]
  / call from .z.pc for backend handles; errors queries that depended on this server
  if[null st:first exec servertype from .z.m.servers where handle=serverh;:()];
  err:errorprefix,"backend ",string[st]," server disconnected";

  / in-flight: queries where this handle was assigned to a slot
  qids:where {[h;qid]h in value[.z.m.results[qid;1]][;0]}[serverh] each key .z.m.results;
  sendclientreply[;err," during query";0b] each qids;
  finishquery[qids;1b];

  / queued: queries that can no longer be satisfied by remaining active servers
  activetypes:exec distinct servertype from .z.m.servers where active, handle<>serverh;
  qids2:exec queryid from .z.m.queryqueue where null returntime, not queryid in key .z.m.results,
    not {all x in y}[;activetypes] each servertype;
  sendclientreply[;err,", query cannot be satisfied";0b] each qids2;
  finishquery[qids2;1b];

  update active:0b,disconnecttime:.z.m.cp[] from .z.M.servers where handle=serverh;
  runnextquery[]};

removeinactive:{[age]delete from .z.M.servers where not active, .z.m.cp[]>disconnecttime+age};

execquery:{[query;servertype;join;postback;timeout;sync]
  if[sync;
    if[not synccallsallowed;'"syncexec: synchronous calls are not allowed"];
    if[not @[{-30!x;1b};(::);0b];'"syncexec: deferred response not supported on this connection"];
    .[{[q;s;j;t]addquery[q;s;j;();t;1b];runnextquery[]};(query;servertype;join;timeout);{-30!(.z.w;1b;x)}];
    :()];
  addquery[query;servertype;join;postback;timeout;0b];
  runnextquery[]};

/ wire housekeeping into a timer - pass (::) to skip
init:{[timerrepeat]
  if[not timerrepeat~(::);
    timerrepeat[cp[];0Wp;0D00:05:00;(`removequeries;querykeeptime);"asyncdispatch: remove old queries"];
    timerrepeat[cp[];0Wp;0D00:00:05;(`checktimeout;`);"asyncdispatch: timeout expired queries"];
    timerrepeat[cp[];0Wp;0D00:05:00;(`removeinactive;clearinactivetime);"asyncdispatch: remove inactive servers"]]};
