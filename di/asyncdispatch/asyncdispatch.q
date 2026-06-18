/ di.asyncdispatch - async scatter-gather query coordinator.
/ Queues queries, dispatches to available backends, collects results per server,
/ applies a join function, and replies to the client.
/ Routing (which servers satisfy a query) is di.serverselect's responsibility.

errorprefix:"error: ";
querykeeptime:0D00:30;
clearinactivetime:0D01:00;
synccallsallowed:0b;

cp:{.z.p} / injectable clock; swap out in tests to control time
setcp:{.z.m.cp:x} / allows runtime replacement of the clock without editing the module

formatresponse:{[status;sync;result]$[not[status]and sync;'result;result]} / sync errors must be signalled with ' so the client receives a trapped error; async errors pass through unchanged
setformatresponse:{.z.m.formatresponse:x} / override reply formatting without editing the module

/ symbols backend servers call back via; set to wherever this module is mounted
resultcallback:`addserverresult; / stored as symbol so the name survives IPC serialization to backend processes
errorcallback:`addservererror;
setcallbacks:{[resfn;errfn].z.m.resultcallback:resfn;.z.m.errorcallback:errfn} / update callback symbols when module is mounted under a non-default namespace

/ registered backend servers
servers:([handle:`u#`int$()] servertype:`symbol$(); inuse:`boolean$(); active:`boolean$(); disconnecttime:`timestamp$())

/ pending and in-flight client queries
queryqueue:([queryid:`u#`long$()] time:`timestamp$(); clienth:`int$(); query:(); servertype:(); join:(); postback:(); timeout:`timespan$(); returntime:`timestamp$(); error:`boolean$(); sync:`boolean$())

/ connected client tracking
clients:([] time:`timestamp$(); clienth:`int$(); user:`symbol$(); ip:`int$(); host:`symbol$())

/ per-query result accumulator: queryid -> (clienth; servertype!(handle;result;done))
results:()!()

queryid:0;

addserver:{[h;st].z.M.servers upsert (h;st;0b;1b;0Np)} / register a backend handle and servertype so it becomes eligible for dispatch

availableservers:{[excludeinuse] / centralise the active+idle filter so dispatch and routing share one definition
  $[excludeinuse;
    select from servers where active, not inuse;
    select from servers where active]};
setavailableservers:{.z.m.availableservers:x} / swap in a custom routing strategy without forking core dispatch

addclientdetails:{[h].z.M.clients insert (cp[];h;.z.u;.z.a;.z.h)} / record client identity on connect for audit and orphan-query cleanup on disconnect

removeclienthandle:{[h] / on client disconnect, mark their pending queries errored so result slots are not leaked
  update error:1b,returntime:.z.m.cp[] from .z.M.queryqueue where clienth=h, null returntime;
  .z.m.results:(exec queryid from .z.m.queryqueue where clienth=h)_results};

addquery:{[query;servertype;join;postback;timeout;sync] / enqueue a query without dispatching; caller must call runnextquery[] to trigger dispatch
  .z.M.queryqueue upsert (queryid;cp[];.z.w;query;servertype;join;{$[11h=type x;enlist x;x]}postback;timeout;0Np;0b;sync);
  .z.m.queryid:queryid+1};

removequeries:{[age] / prevent queryqueue growing unboundedly; purge completed queries older than age
  .z.m.queryqueue:0!delete from .z.m.queryqueue where not null returntime, .z.m.cp[]>returntime+age};

getnextqueryid:{ / pick the oldest FIFO-eligible query whose required servertypes are all currently idle
  avail:exec distinct servertype from availableservers 1b;
  runnable:0!select from .z.m.queryqueue where null returntime, not queryid in key .z.m.results, {all x in y}[;avail] each servertype;
  1 sublist select from runnable where time=min time};
setgetnextqueryid:{.z.m.getnextqueryid:x} / inject a priority or custom scheduling strategy without forking the module

addserverresult:{[qid;data] / fill one result slot; once all slots for a query are filled, run the join function and reply to the client
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

addservererror:{[qid;err] / short-circuit a query on backend failure; free the server and notify the client before moving on
  sendclientreply[qid;errorprefix,err;0b];
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  finishquery[qid;1b]};

sendclientreply:{[qid;result;status] / deliver result or error to the client, handling sync vs async send and postback wrapping in one place
  qd:queryqueue[qid];
  if[qd`error;:()];
  tosend:$[()~qd`postback;result;qd[`postback],enlist[qd`query],enlist result];
  $[qd`sync;
    @[-30!;(qd`clienth;not status;$[status;formatresponse[1b;1b;result];result]);{}];
    @[neg qd`clienth;formatresponse[status;0b;tosend];()]]};

finishquery:{[qid;err] / remove query from the live results accumulator and stamp its completion time; keeps queryqueue and results consistent
  .z.m.results:(qid,())_results;
  update error:err,returntime:.z.m.cp[] from .z.M.queryqueue where queryid in qid};

serverexecute:{[qid;query] / runs on the backend; traps errors locally so a crash posts an error reply rather than silently dropping the result
  res:@[{(0b;value x)};query;{(1b;"server ",(string .z.h),":",(string system"p"),": ",x)}];
  @[neg .z.w;$[res 0;(errorcallback;qid;res 1);(resultcallback;qid;res 1)];
    {@[neg .z.w;(errorcallback;x;"failed to return result: ",y);()]}[qid]]};

sendquerytoserver:{[qid;query;handles] / fan the query out to all required handles and mark them in-use atomically to prevent double-dispatch
  (neg handles,:())@\:(serverexecute;qid;query);
  update inuse:1b from .z.M.servers where handle in handles};

runnextquery:{ / pick the next dispatchable query and fan out to one idle server per required servertype; called after any state change that may unblock work
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

checktimeout:{ / periodic scan to error queries that have waited beyond their timeout, preventing them from hanging indefinitely
  qids:exec queryid from .z.m.queryqueue where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[count qids;
    sendclientreply[;errorprefix,"query timed out";0b] each qids;
    finishquery[qids;1b]]};

removeserverhandle:{[serverh] / on backend disconnect, error in-flight queries using that handle and queued queries that can no longer be satisfied
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

removeinactive:{[age]delete from .z.M.servers where not active, .z.m.cp[]>disconnecttime+age} / prune stale disconnected-server rows to stop the servers table growing forever

execquery:{[query;servertype;join;postback;timeout;sync] / public entry point; validate sync constraints then enqueue and kick dispatch
  if[sync;
    if[not synccallsallowed;'"syncexec: synchronous calls are not allowed"];
    if[not @[{-30!x;1b};(::);0b];'"syncexec: deferred response not supported on this connection"];
    .[{[q;s;j;t]addquery[q;s;j;();t;1b];runnextquery[]};(query;servertype;join;timeout);{-30!(.z.w;1b;x)}];
    :()];
  addquery[query;servertype;join;postback;timeout;0b];
  runnextquery[]};

/ wire housekeeping into a timer - pass (::) to skip
init:{[timerrepeat] / wire recurring housekeeping (timeout scan, query purge, server purge) into a provided timer; pass (::) to skip registration
  if[not timerrepeat~(::);
    timerrepeat[cp[];0Wp;0D00:05:00;(.z.m.removequeries;querykeeptime);"asyncdispatch: remove old queries"];
    timerrepeat[cp[];0Wp;0D00:00:05;(.z.m.checktimeout;`);"asyncdispatch: timeout expired queries"];
    timerrepeat[cp[];0Wp;0D00:05:00;(.z.m.removeinactive;clearinactivetime);"asyncdispatch: remove inactive servers"]]};
