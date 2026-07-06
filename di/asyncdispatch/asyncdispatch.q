// di.asyncdispatch - async scatter-gather query coordinator
// queues queries, dispatches to available backends, collects results per server,
// applies a join function, and replies to the client
// routing (which servers satisfy a query) is di.serverselect's responsibility
// the log dependency is required - init errors immediately if absent or malformed
// log functions are binary {[c;m]} where c is a symbol context and m is a string

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

// symbols backend servers call back via - stored as symbols so names survive IPC serialisation
resultcallback:`addserverresult;
errorcallback:`addservererror;

// reply formatting - sync errors must be signalled with ' so the client receives a trapped error
formatresponse:{[status;sync;result]$[not[status]and sync;'result;result]};

// scheduling strategy - pick oldest FIFO-eligible query by default
getnextqueryid:{
  avail:exec distinct servertype from availableservers 1b;
  // 0! is required - select from a keyed table stays keyed in kdb-x, and runnextquery needs queryid via first
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

normlog:{[logdict]
  // detect kx.log instance by presence of kx.log-specific keys (getlvl, sinks, fmts)
  // kx.log functions are monadic - wrap each into binary {[c;m]} and embed context in the message
  // plain {[c;m]} log dicts (info`warn`error only) pass through unchanged
  $[all `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
  };

sendclientreply:{[qid;result;status]
  // deliver result or error to the client, handling sync vs async send and postback wrapping
  // local path invokes value tosend directly - formatresponse is not applied (it is a pass-through
  // for async by default; consumers that override setformatresponse should not use local invocation)
  qd:queryqueue[qid];
  if[qd`error;:()];
  tosend:$[()~qd`postback;result;qd[`postback],enlist[qd`query],enlist result];
  $[qd`sync;
    @[-30!;(qd`clienth;not status;$[status;formatresponse[1b;1b;result];result]);{}];
    $[qd`local;
      @[value;tosend;{.z.m.log[`error][`asyncdispatch;"local postback failed: ",x]}];
      @[neg qd`clienth;formatresponse[status;0b;tosend];()]]];
  };

finishquery:{[qid;err]
  // remove query from the live results accumulator and stamp its completion time
  .z.m.results:(qid,())_results;
  update error:err,returntime:.z.m.cp[] from .z.M.queryqueue where queryid in qid;
  };

serverexecute:{[qid;query]
  // runs on the backend - traps errors so a crash posts an error reply rather than dropping the result
  res:@[{(0b;value x)};query;{(1b;"server ",(string .z.h),":",(string system"p"),": ",x)}];
  @[neg .z.w;$[res 0;(errorcallback;qid;res 1);(resultcallback;qid;res 1)];
    {@[neg .z.w;(errorcallback;x;"failed to return result: ",y);()]}[qid]];
  };

sendquerytoserver:{[qid;query;handles]
  // fan the query out to all required handles and mark them in-use atomically
  (neg handles,:())@\:(serverexecute;qid;query);
  update inuse:1b from .z.M.servers where handle in handles;
  };

runnextquery:{[]
  // pick the next dispatchable query and fan out to one idle server per required servertype
  // called after any state change that may unblock work
  if[0=count torun:getnextqueryid[];:()];
  torun:first torun;
  avail:exec first handle by servertype from availableservers 1b;
  types:torun`servertype;
  handles:avail types;
  qid:torun`queryid;
  slots:types!count[types]#enlist(0Ni;(::);0b);
  slots[types;0]:handles;
  // indexed assignment on bare results propagates through to .z.m in kdb-x (empirically verified)
  results[qid]:(torun`clienth;slots);
  sendquerytoserver[qid;torun`query;handles];
  };

addqueryto:{[query;servertype;join;postback;timeout;sync;replyto;local]
  // enqueue a query with an explicit reply target - used by execqueryto for local in-process routing
  .z.M.queryqueue upsert (queryid;.z.m.cp[];replyto;query;servertype;join;{$[11h=type x;enlist x;x]}postback;timeout;0Np;0b;sync;local);
  .z.m.queryid:queryid+1;
  };

addquery:{[query;servertype;join;postback;timeout;sync]
  // enqueue a query without dispatching - caller must call runnextquery[] to trigger dispatch
  addqueryto[query;servertype;join;postback;timeout;sync;.z.w;0b];
  };

removequeries:{[age]
  // prevent queryqueue growing unboundedly - purge completed queries older than age
  delete from .z.M.queryqueue where not null returntime, .z.m.cp[]>returntime+age;
  };

removeinactive:{[age]
  // prune stale disconnected-server rows to stop the servers table growing forever
  delete from .z.M.servers where not active, .z.m.cp[]>disconnecttime+age;
  };

removeclients:{[age]
  // prune stale client audit rows to stop the clients table growing forever
  // clients are recorded on every connect by addclientdetails and never removed otherwise
  delete from .z.M.clients where .z.m.cp[]>time+age;
  };

checktimeout:{[]
  // periodic scan to error queries that have waited beyond their timeout
  qids:exec queryid from .z.m.queryqueue where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[count qids;
    .z.m.log[`warn][`asyncdispatch;"queries timed out: ",", " sv string qids];
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
  // register a backend handle and servertype so it becomes eligible for dispatch.
  // this is the default (built-in) server source; to dispatch against di.serverselect's view instead,
  // inject it via setavailableservers - no registration and no di.serverselect dependency required
  .z.m.log[`info][`asyncdispatch;"server registered: ",string[st]," handle ",string h];
  .z.M.servers upsert (h;st;0b;1b;0Np);
  };

removeserverhandle:{[serverh]
  // on backend disconnect, error in-flight queries using that handle and queued queries
  // that can no longer be satisfied
  if[null st:first exec servertype from .z.m.servers where handle=serverh;:()];
  err:errorprefix,"backend ",string[st]," server disconnected";
  .z.m.log[`warn][`asyncdispatch;"backend disconnected: ",string st];
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
  .z.m.log[`info][`asyncdispatch;"client connected: handle ",string h];
  .z.M.clients insert (.z.m.cp[];h;.z.u;.z.a;.z.h);
  };

removeclienthandle:{[h]
  // on client disconnect, mark their pending queries errored so result slots are not leaked
  // free any servers in-flight for this client before removing result slots, then re-dispatch
  // local queries store clienth:0Ni and are not matched here - the in-process caller owns cleanup for its own requests
  .z.m.log[`info][`asyncdispatch;"client disconnected: handle ",string h];
  inflightqids:(exec queryid from .z.m.queryqueue where clienth=h, null returntime) inter key .z.m.results;
  if[count inflightqids;
    inflighthandles:distinct raze {value[.z.m.results[x;1]][;0]} each inflightqids;
    update inuse:0b from .z.M.servers where handle in inflighthandles];
  update error:1b,returntime:.z.m.cp[] from .z.M.queryqueue where clienth=h, null returntime;
  .z.m.results:(exec queryid from .z.m.queryqueue where clienth=h)_results;
  runnextquery[];
  };

addserverresult:{[qid;data]
  // fill one result slot - once all slots for a query are filled, run the join and reply
  // bare indexed assignment on results propagates through to .z.m in kdb-x (empirically verified)
  if[not qid in key results;:()];
  slots:results[qid;1];
  // map the responding handle to its servertype from THIS query's own dispatch record, not a server
  // registry - so any server source (built-in or an injected di.serverselect view) works unchanged
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
  if[res 0;.z.m.log[`error][`asyncdispatch;"join failed for query ",string qid,": ",last res]];
  sendclientreply[qid;last res;not res 0];
  finishquery[qid;res 0];
  };

addservererror:{[qid;err]
  // short-circuit a query on backend failure - free the server and notify the client
  .z.m.log[`error][`asyncdispatch;"backend error for query ",string[qid],": ",err];
  sendclientreply[qid;errorprefix,err;0b];
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  finishquery[qid;1b];
  };

execquery:{[query;servertype;join;postback;timeout;sync]
  // public entry point - validate sync constraints then enqueue and kick dispatch
  if[sync;
    if[not ()~postback;.z.m.log[`warn][`asyncdispatch;"execquery: postback ignored for sync call"]];
    if[not synccallsallowed;'"syncexec: synchronous calls are not allowed"];
    if[not @[{-30!x;1b};(::);0b];'"syncexec: deferred response not supported on this connection"];
    .[{[q;s;j;t]addquery[q;s;j;();t;1b];runnextquery[]};(query;servertype;join;timeout);{-30!(.z.w;1b;x)}];
    :()];
  addquery[query;servertype;join;postback;timeout;0b];
  runnextquery[];
  };

execqueryto:{[replyto;query;servertype;join;postback;timeout;sync]
  // in-process variant of execquery - replyto is 0Ni for local invocation via value
  // postback must be non-empty when replyto is 0Ni - there is no handle to send a bare result to
  // sync is not supported for local invocation
  // mount-qualified postback symbols required for local invocation e.g. `da.shardresult not `shardresult
  if[0Ni~replyto;
    if[()~postback;'"di.asyncdispatch: local invocation requires a non-empty postback"];
    if[sync;'"di.asyncdispatch: local invocation does not support sync mode"]];
  local:0Ni~replyto;
  addqueryto[query;servertype;join;postback;timeout;sync;replyto;local];
  runnextquery[];
  };

init:{[deps]
  // initialise the asyncdispatch module - validate deps and apply config overrides
  // deps: dict containing `log (required) plus optional config keys:
  //   `log               - required: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) binary loggers
  //   `errorprefix       - optional: string prefix for client error messages. default: "error: "
  //   `querykeeptime     - optional: timespan to keep completed queries. default: 0D00:30
  //   `clearinactivetime - optional: timespan to keep disconnected servers. default: 0D01:00
  //   `synccallsallowed  - optional: boolean, whether sync calls are permitted. default: 0b
  // housekeeping (checktimeout; removequeries; removeinactive; removeclients) is the caller's
  // responsibility - wire them into your timer after init; the exported defaults for age params are
  // querykeeptime and clearinactivetime
  // examples:
  //   ad.init[enlist[`log]!enlist logdep]
  //   ad.init[`log`querykeeptime!(logdep;0D01:00)]
  if[99h<>type deps;
    '"di.asyncdispatch: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.asyncdispatch: log dependency is required; pass `info`warn`error!(infofn;warnfn;errfn) keyed on `log"];
  if[99h<>type deps`log;
    '"di.asyncdispatch: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.asyncdispatch: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:normlog deps`log;
  if[`errorprefix in key deps; .z.m.errorprefix:deps`errorprefix];
  if[`querykeeptime in key deps; .z.m.querykeeptime:deps`querykeeptime];
  if[`clearinactivetime in key deps; .z.m.clearinactivetime:deps`clearinactivetime];
  if[`synccallsallowed in key deps; .z.m.synccallsallowed:deps`synccallsallowed];
  .z.m.log[`info][`asyncdispatch;"di.asyncdispatch initialised"];
  };
