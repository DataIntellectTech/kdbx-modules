// async scatter-gather query coordinator: queue, dispatch to backends, join results, reply

// ============================================================
// module state and defaults
// ============================================================

// error prefix prepended to all error strings returned to clients
errorprefix:"error: ";

// how long completed queries are kept in queryqueue before being purged
querykeeptime:0D00:30;

// how long disconnected servers are kept in the servers table before being removed
clearinactivetime:0D01:00;

// whether synchronous calls via -30! are permitted
synccallsallowed:0b;

// injectable clock - replaced in tests to control time without sleeping
cp:{.z.p};

// symbols backend servers call back via
resultcallback:`addserverresult;
errorcallback:`addservererror;

// reply formatting; sync errors are signalled
formatresponse:{[status;sync;result]$[not[status]and sync;'result;result]};

// scheduling strategy - pick oldest FIFO-eligible query by default
getnextqueryid:{
  avail:exec distinct servertype from availableservers 1b;
  // unkeyed so runnextquery can take queryid via first
  runnable:0!select from .z.m.queryqueue where null returntime, not queryid in key .z.m.results, {all x in y}[;avail] each servertype;
  1 sublist select from runnable where time=min time
  };

// server routing strategy - active and idle by default
availableservers:{[excludeinuse]
  $[excludeinuse;
    select from servers where active, not inuse;
    select from servers where active]
  };

// ============================================================
// module tables
// ============================================================

// registered backend servers
servers:([handle:`u#`int$()] servertype:`symbol$(); inuse:`boolean$(); active:`boolean$(); disconnecttime:`timestamp$());

// pending and in-flight client queries
queryqueue:([queryid:`u#`long$()] time:`timestamp$(); clienth:`int$(); query:(); servertype:(); join:(); postback:(); timeout:`timespan$(); returntime:`timestamp$(); error:`boolean$(); sync:`boolean$(); local:`boolean$());

// connected client tracking
clients:([] time:`timestamp$(); clienth:`int$(); user:`symbol$(); ip:`int$(); host:`symbol$());

// per-query result accumulator: queryid -> (clienth; servertype!(handle;result;done))
results:()!();

// auto-incrementing query id counter
queryid:0;

// ============================================================
// internal helpers
// ============================================================

sendclientreply:{[qid;result;status]
  // deliver result or error to the client, handling sync vs async send and postback wrapping
  // local replies skip formatresponse
  qd:queryqueue[qid];
  if[qd`error;:()];
  tosend:$[()~qd`postback;result;qd[`postback],enlist[qd`query],enlist result];
  $[qd`sync;
    @[-30!;(qd`clienth;not status;$[status;formatresponse[1b;1b;result];result]);{}];
    $[qd`local;
      @[value;tosend;{.z.m.logerr[`asyncdispatch;"local postback failed: ",x]}];
      @[neg qd`clienth;formatresponse[status;0b;tosend];()]]];
  };

finishquery:{[qid;err]
  // remove query from the live results accumulator and stamp its completion time
  .z.m.results:(qid,())_results;
  update error:err,returntime:.z.m.cp[] from .z.M.queryqueue where queryid in qid;
  };

serverexecute:{[rescb;errcb;qid;query]
  // runs on the backend: post the result, or the trapped error, back via the given callback symbols
  res:@[{(0b;value x)};query;{(1b;"server ",(string .z.h),":",(string system"p"),": ",x)}];
  @[neg .z.w;$[res 0;(errcb;qid;res 1);(rescb;qid;res 1)];
    {@[neg .z.w;(x;y;"failed to return result: ",z);()]}[errcb;qid]];
  };

sendquerytoserver:{[qid;query;handles]
  // send the query with the callback symbols to each required handle and mark them in use
  (neg handles,:())@\:(serverexecute[.z.m.resultcallback;.z.m.errorcallback];qid;query);
  update inuse:1b from .z.M.servers where handle in handles;
  };

runnextquery:{[]
  // dispatch the next eligible query to one idle server per required servertype
  if[0=count torun:getnextqueryid[];:()];
  torun:first torun;
  avail:exec first handle by servertype from availableservers 1b;
  types:torun`servertype;
  handles:avail types;
  qid:torun`queryid;
  slots:types!count[types]#enlist(0Ni;(::);0b);
  slots[types;0]:handles;
  results[qid]:(torun`clienth;slots);
  sendquerytoserver[qid;torun`query;handles];
  };

addqueryto:{[query;servertype;join;postback;timeout;sync;replyto;local]
  // enqueue a query with an explicit reply target
  .z.M.queryqueue upsert (queryid;.z.m.cp[];replyto;query;servertype;join;{$[11h=type x;enlist x;x]}postback;timeout;0Np;0b;sync;local);
  .z.m.queryid:queryid+1;
  };

addquery:{[query;servertype;join;postback;timeout;sync]
  // enqueue a query without dispatching - caller must call runnextquery[] to trigger dispatch
  addqueryto[query;servertype;join;postback;timeout;sync;.z.w;0b];
  };

removequeries:{[age]
  // purge completed queries older than age
  delete from .z.M.queryqueue where not null returntime, .z.m.cp[]>returntime+age;
  };

removeinactive:{[age]
  // purge disconnected servers older than age
  delete from .z.M.servers where not active, .z.m.cp[]>disconnecttime+age;
  };

removeclients:{[age]
  // purge client rows older than age
  delete from .z.M.clients where .z.m.cp[]>time+age;
  };

checktimeout:{[]
  // periodic scan to error queries that have waited beyond their timeout
  qids:exec queryid from .z.m.queryqueue where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[count qids;
    .z.m.logwarn[`asyncdispatch;"queries timed out: ",", " sv string qids];
    sendclientreply[;errorprefix,"query timed out";0b] each qids;
    finishquery[qids;1b]];
  };

// ============================================================
// public api
// ============================================================

setcp:{[f]
  // replace the clock function - used in tests to control time without sleeping
  .z.m.cp:f;
  };

setformatresponse:{[f]
  // override reply formatting - e.g. to wrap results in a standard envelope
  .z.m.formatresponse:f;
  };

setcallbacks:{[resfn;errfn]
  // update callback symbols when module is mounted under a non-default namespace
  .z.m.resultcallback:resfn;
  .z.m.errorcallback:errfn;
  };

setavailableservers:{[f]
  // swap in a custom routing strategy without forking core dispatch
  .z.m.availableservers:f;
  };

setgetnextqueryid:{[f]
  // inject a priority or custom scheduling strategy
  .z.m.getnextqueryid:f;
  };

addserver:{[h;st]
  // register a backend handle and servertype for dispatch
  .z.m.loginfo[`asyncdispatch;"server registered: ",string[st]," handle ",string h];
  .z.M.servers upsert (h;st;0b;1b;0Np);
  };

removeserverhandle:{[serverh]
  // on backend disconnect, error its in-flight queries and queued queries that can no longer run
  if[null st:first exec servertype from .z.m.servers where handle=serverh;:()];
  err:errorprefix,"backend ",string[st]," server disconnected";
  .z.m.logwarn[`asyncdispatch;"backend disconnected: ",string st];
  // in-flight: queries where this handle was assigned to a slot
  qids:where {[h;qid]h in value[.z.m.results[qid;1]][;0]}[serverh] each key .z.m.results;
  sendclientreply[;err," during query";0b] each qids;
  finishquery[qids;1b];
  // queued: queries that can no longer be satisfied by remaining active servers
  activetypes:exec distinct servertype from .z.m.servers where active, handle<>serverh;
  qids2:exec queryid from .z.m.queryqueue where null returntime, not queryid in key .z.m.results,
    not {all x in y}[;activetypes] each servertype;
  sendclientreply[;err,", query cannot be satisfied";0b] each qids2;
  finishquery[qids2;1b];
  update active:0b,disconnecttime:.z.m.cp[] from .z.M.servers where handle=serverh;
  runnextquery[];
  };

addclientdetails:{[h]
  // record client identity on connect for audit and orphan-query cleanup on disconnect
  .z.m.loginfo[`asyncdispatch;"client connected: handle ",string h];
  .z.M.clients insert (.z.m.cp[];h;.z.u;.z.a;.z.h);
  };

removeclienthandle:{[h]
  // on client disconnect, error its pending queries, free its servers and re-dispatch
  .z.m.loginfo[`asyncdispatch;"client disconnected: handle ",string h];
  inflightqids:(exec queryid from .z.m.queryqueue where clienth=h, null returntime) inter key .z.m.results;
  if[count inflightqids;
    inflighthandles:distinct raze {value[.z.m.results[x;1]][;0]} each inflightqids;
    update inuse:0b from .z.M.servers where handle in inflighthandles];
  update error:1b,returntime:.z.m.cp[] from .z.M.queryqueue where clienth=h, null returntime;
  .z.m.results:(exec queryid from .z.m.queryqueue where clienth=h)_results;
  runnextquery[];
  };

addserverresult:{[qid;data]
  // fill one result slot; once all are filled, join and reply
  if[not qid in key results;:()];
  slots:results[qid;1];
  // servertype of the responding handle, from this query's dispatch record
  st:first where .z.w=slots[;0];
  slots[st]:(.z.w;data;1b);
  results[qid]:(results[qid;0];slots);
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  if[not qid in key results;:()];
  vals:value results[qid;1];
  if[not all vals[;2];:()];
  qd:queryqueue[qid];
  res:@[{(0b;x y)}[qd`join];vals[;1];{(1b;.z.m.errorprefix,"join failed: ",x)}];
  if[res 0;.z.m.logerr[`asyncdispatch;"join failed for query ",string qid,": ",last res]];
  sendclientreply[qid;last res;not res 0];
  finishquery[qid;res 0];
  };

addservererror:{[qid;err]
  // short-circuit a query on backend failure - free the server and notify the client
  .z.m.logerr[`asyncdispatch;"backend error for query ",string[qid],": ",err];
  sendclientreply[qid;errorprefix,err;0b];
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  finishquery[qid;1b];
  };

execquery:{[query;servertype;join;postback;timeout;sync]
  // public entry point - validate sync constraints then enqueue and kick dispatch
  if[sync;
    if[not ()~postback;.z.m.logwarn[`asyncdispatch;"execquery: postback ignored for sync call"]];
    if[not synccallsallowed;'"syncexec: synchronous calls are not allowed"];
    if[not @[{-30!x;1b};(::);0b];'"syncexec: deferred response not supported on this connection"];
    .[{[q;s;j;t]addquery[q;s;j;();t;1b];runnextquery[]};(query;servertype;join;timeout);{-30!(.z.w;1b;x)}];
    :()];
  addquery[query;servertype;join;postback;timeout;0b];
  runnextquery[];
  };

execqueryto:{[replyto;query;servertype;join;postback;timeout;sync]
  // in-process execquery: async only, with a required mount-qualified postback e.g. `da.shardresult
  if[0Ni~replyto;
    if[()~postback;'"di.asyncdispatch: local invocation requires a non-empty postback"];
    if[sync;'"di.asyncdispatch: local invocation does not support sync mode"]];
  local:0Ni~replyto;
  addqueryto[query;servertype;join;postback;timeout;sync;replyto;local];
  runnextquery[];
  };

init:{[deps]
  // validate deps and apply config: `log (required), optional `errorprefix`querykeeptime`clearinactivetime`synccallsallowed
  if[99h<>type deps;
    '"di.asyncdispatch: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.asyncdispatch: log dependency is required; pass `info`warn`error!(infofn;warnfn;errfn) keyed on `log"];
  if[99h<>type deps`log;
    '"di.asyncdispatch: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.asyncdispatch: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  if[`errorprefix in key deps; .z.m.errorprefix:deps`errorprefix];
  if[`querykeeptime in key deps; .z.m.querykeeptime:deps`querykeeptime];
  if[`clearinactivetime in key deps; .z.m.clearinactivetime:deps`clearinactivetime];
  if[`synccallsallowed in key deps; .z.m.synccallsallowed:deps`synccallsallowed];
  .z.m.loginfo[`asyncdispatch;"di.asyncdispatch initialised"];
  };
