/ di.dataaccess - data access query layer.
/ Routes queries to appropriate processes based on partition ranges, splits
/ queries across shards to avoid time-range overlap, and handles map-reduce
/ aggregation. Uses di.asyncdispatch for execution, di.serverselect for routing.

errorprefix:"error: ";
requestkeeptime:0D00:30;
synccallsallowed:0b;

cp:{.z.p};
setcp:{.z.m.cp:x};

/ handle to di.asyncdispatch - must be set via setdispatch before calling execquery
dispatch:(::);
setdispatch:{.z.m.dispatch:x};

/ injectable logger
logfn:{[lvl;msg] -1 (string lvl)," ",msg;};
setlogfn:{.z.m.logfn:x};

/ symbols that asyncdispatch postbacks resolve to on this process;
/ update via setshardcallbacks after mounting to match the module's mount path
shardresultcallback:`shardresult;
sharderrorcallback:`sharderror;
setshardcallbacks:{[resfn;errfn].z.m.shardresultcallback:resfn;.z.m.sharderrorcallback:errfn};

/ active request tracking - one row per in-flight client query
requests:([requestid:`u#`long$()] time:`timestamp$(); clienth:`int$(); remaining:`long$(); joinfn:(); postback:(); timeout:`timespan$(); returntime:`timestamp$(); error:`boolean$(); sync:`boolean$());

/ accumulates per-shard results until all shards for a request have reported
shardresults:()!();

requestid:0;

/ --- di.serverselect stub ---
/ returns table ([] servertype:`symbol$(); starttime:`timestamp$(); endtime:`timestamp$())
/ each row is one shard: the process type to query and its covered time range.
/ stub returns a single hdb shard for the full requested range.
/ replace body by wiring to di.serverselect once that module is available.
getrouting:{[starttime;endtime]
  ([] servertype:enlist`hdb; starttime:enlist starttime; endtime:enlist endtime)};
setgetrouting:{.z.m.getrouting:x};

/ builds the sub-query for one shard, injecting the shard's time range as a filter.
/ stub passes the query through unchanged.
/ di.serverselect will supply the real implementation that modifies the functional where clause.
buildshardquery:{[query;starttime;endtime] query};
setbuildshardquery:{.z.m.buildshardquery:x};

/ --- shard result accumulation ---

shardresult:{[reqid;result]
  / fill one shard slot; when all slots are filled, apply the join function and reply to client
  if[not reqid in key requests;:()];
  req:requests[reqid];
  if[not null req`returntime;:()];
  .z.m.shardresults[reqid],:enlist result;
  newremaining:req[`remaining]-1;
  update remaining:newremaining from .z.M.requests where requestid=reqid;
  if[0=newremaining;checkresults reqid]};

sharderror:{[reqid;err]
  / short-circuit the request on any shard error; send error to client and clean up
  if[not reqid in key requests;:()];
  req:requests[reqid];
  if[not null req`returntime;:()];
  logfn[`error;"shard error for request ",string[reqid],": ",err];
  sendreply[reqid;errorprefix,err;0b];
  finishrequest[reqid;1b]};

checkresults:{[reqid]
  / all shards received; apply the user join function across shard results and reply
  req:requests[reqid];
  accumulated:.z.m.shardresults[reqid];
  res:.[{(0b;x y)};(req`joinfn;accumulated);{(1b;errorprefix,"join failed: ",x)}];
  sendreply[reqid;last res;not res 0];
  finishrequest[reqid;res 0]};

sendreply:{[reqid;result;status]
  / deliver result or error to the original client; status: 1b success, 0b error
  req:requests[reqid];
  if[req`error;:()];
  tosend:$[()~req`postback;result;req[`postback],enlist result];
  $[req`sync;
    @[-30!;(req`clienth;not status;result);{}];
    @[neg req`clienth;tosend;()]]};

finishrequest:{[reqid;err]
  / stamp completion and drop the shard result accumulator; keeps requests row for audit
  .z.m.shardresults:(reqid,())_shardresults;
  update error:err,returntime:.z.m.cp[] from .z.M.requests where requestid=reqid};

/ --- dispatch ---

submitshards:{[reqid;shards;timeout]
  / fan out one asyncdispatch query per shard; results return via shardresult/sharderror postbacks
  {[reqid;timeout;stype;q]
    dispatch.execquery[q;enlist stype;first;(shardresultcallback;reqid);timeout;0b]
  }[reqid;timeout]'[shards`servertype;shards`shardquery]};

/ --- public API ---

execquery:{[query;starttime;endtime;joinfn;postback;timeout;sync]
  / route a query across partition ranges, scatter to shards, gather and reduce results
  if[(::)~dispatch;'"dataaccess: call setdispatch before execquery"];
  if[sync;
    if[not synccallsallowed;'"dataaccess: synchronous calls are not allowed"];
    if[not @[{-30!x;1b};(::);0b];'"dataaccess: deferred response not supported on this connection"]];
  shards:getrouting[starttime;endtime];
  if[0=count shards;
    tosend:$[()~postback;();postback,enlist enlist[]];
    $[sync;@[-30!;(.z.w;0b;());{}];@[neg .z.w;tosend;()]];
    :.z.m.requestid:requestid+1];
  postback:{$[11h=type x;enlist x;x]}postback;
  shardqueries:.z.m.buildshardquery[query;;]'[shards`starttime;shards`endtime];
  shards:shards,'flip(enlist`shardquery)!enlist shardqueries;
  reqid:requestid;
  .z.M.requests upsert (reqid;cp[];.z.w;count shards;joinfn;postback;timeout;0Np;0b;sync);
  .z.m.shardresults[reqid]:();
  submitshards[reqid;shards;timeout];
  .z.m.requestid:requestid+1};

removerequests:{[age]
  / purge completed request rows older than age to prevent unbounded table growth
  .z.m.requests:0!delete from .z.m.requests where not null returntime, .z.m.cp[]>returntime+age};

init:{[timerrepeat]
  / wire recurring housekeeping into a provided timer; pass (::) to skip
  if[not timerrepeat~(::);
    timerrepeat[cp[];0Wp;0D00:30:00;(`removerequests;requestkeeptime);"dataaccess: remove old requests"]]};
