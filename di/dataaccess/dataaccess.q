/ di.dataaccess - data access query layer.
/ routes queries to appropriate processes based on partition ranges, splits
/ queries across shards to avoid time-range overlap, and reduces the shard
/ results back to the client via a user-supplied join function.
/ hard deps: di.asyncdispatch (execution), di.serverselect (routing).
/ injected via init: log (required), timer (required), plus optional config.

/ --- hard dependencies ---
asyncdispatch:use`di.asyncdispatch;
serverselect:use`di.serverselect;

/ --- constants ---
errorprefix:"error: ";

/ keyed-table schema template (constant); the live mutable copy is .z.m.requests, set in init
schema:([requestid:`u#`long$()]
  time:`timestamp$();
  clienth:`int$();
  remaining:`long$();
  joinfn:();
  postback:();
  timeout:`timespan$();
  returntime:`timestamp$();
  error:`boolean$();
  sync:`boolean$()
  );

/ --- logger normalisation (module standard - keep identical across modules) ---

normlog:{[logdict]
  / internal - normalise the injected logger to a binary `info`warn`error!{[c;m]} dict
  / kx.log instances expose getlvl/sinks/fmts and have monadic functions, so wrap each and
  / fold the context into the message; an already-binary {[c;m]} dict passes through unchanged
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.log[`error][ctx;msg];
  '"di.dataaccess: ",string[ctx],": ",msg;
  };

getopt:{[deps;k;dflt]
  / internal - read an optional config key from the deps dict, falling back to a default
  $[k in key deps;deps k;dflt]
  };

/ --- shard result accumulation ---

shardresult:{[reqid;result]
  / fill one shard slot; when all slots are filled, apply the join function and reply to the client
  if[not reqid in key .z.m.requests;:()];
  req:.z.m.requests reqid;
  if[not null req`returntime;:()];
  .z.m.shardresults[reqid],:enlist result;
  newremaining:req[`remaining]-1;
  .z.m.requests:update remaining:newremaining from .z.m.requests where requestid=reqid;
  if[0=newremaining;checkresults reqid];
  };

sharderror:{[reqid;err]
  / short-circuit the request on any shard error; send the error to the client and clean up
  if[not reqid in key .z.m.requests;:()];
  req:.z.m.requests reqid;
  if[not null req`returntime;:()];
  .z.m.log[`error][`sharderror;"shard error for request ",string[reqid],": ",err];
  sendreply[reqid;errorprefix,err;0b];
  finishrequest[reqid;1b];
  };

checkresults:{[reqid]
  / all shards received; apply the user join function across the shard results and reply
  req:.z.m.requests reqid;
  accumulated:.z.m.shardresults reqid;
  res:.[{(0b;x y)};(req`joinfn;accumulated);{(1b;errorprefix,"join failed: ",x)}];
  if[res 0;.z.m.log[`error][`checkresults;"join failed for request ",string[reqid],": ",last res]];
  sendreply[reqid;last res;not res 0];
  finishrequest[reqid;res 0];
  };

sendreply:{[reqid;result;status]
  / deliver the result or error to the original client; status 1b success, 0b error
  req:.z.m.requests reqid;
  if[req`error;:()];
  tosend:$[()~req`postback;result;req[`postback],enlist result];
  $[req`sync;
    @[-30!;(req`clienth;not status;result);{}];
    @[neg req`clienth;tosend;()]];
  };

finishrequest:{[reqid;err]
  / stamp completion and drop the shard result accumulator; keep the requests row for audit
  .z.m.shardresults:(reqid,()) _ .z.m.shardresults;
  .z.m.requests:update error:err,returntime:.z.m.cp[] from .z.m.requests where requestid=reqid;
  };

/ --- dispatch ---

submitshards:{[reqid;shards;timeout]
  / fan out one asyncdispatch query per shard; results return via the shardresult/sharderror postbacks
  {[reqid;timeout;stype;q]
    asyncdispatch.execquery[q;enlist stype;first;(.z.m.resultcallback;reqid);timeout;0b]
    }[reqid;timeout]'[shards`servertype;shards`shardquery];
  };

/ --- public API ---

execquery:{[query;starttime;endtime;joinfn;postback;timeout;sync]
  / route a query across partition ranges, scatter to shards, gather and reduce the results
  if[not `log in key .z.m;'"di.dataaccess: init must be called before execquery"];
  if[sync;
    if[not .z.m.synccallsallowed;raiseerror[`execquery;"synchronous calls are not allowed"]];
    if[not @[{-30!x;1b};(::);0b];raiseerror[`execquery;"deferred response not supported on this connection"]]];
  shards:serverselect.getrouting[starttime;endtime];
  if[0=count shards;
    tosend:$[()~postback;();postback,enlist enlist[]];
    $[sync;@[-30!;(.z.w;0b;());{}];@[neg .z.w;tosend;()]];
    .z.m.requestid:1+.z.m.requestid;
    :.z.m.requestid];
  postback:{$[11h=type x;enlist x;x]}postback;
  shardqueries:serverselect.buildshardquery[query;;]'[shards`starttime;shards`endtime];
  shards:shards,'flip(enlist`shardquery)!enlist shardqueries;
  reqid:.z.m.requestid;
  .z.m.requests:.z.m.requests upsert (reqid;.z.m.cp[];.z.w;count shards;joinfn;postback;timeout;0Np;0b;sync);
  .z.m.shardresults[reqid]:();
  submitshards[reqid;shards;timeout];
  .z.m.requestid:1+.z.m.requestid;
  };

removerequests:{[age]
  / purge completed request rows older than age to prevent unbounded table growth
  .z.m.requests:delete from .z.m.requests where not null returntime, .z.m.cp[]>returntime+age;
  };

init:{[deps]
  / wire the required injectables (log, timer) and optional config; there is NO silent fallback.
  / deps keys:
  /   log              (required) kx.log instance or `info`warn`error!{[c;m]} dict
  /   timer            (required) di.timer instance - uses `addjob` to schedule housekeeping
  /   cp               (optional) current-time fn, default {.z.p} (override for sim/backtest)
  /   synccallsallowed (optional) allow deferred-sync execquery, default 0b
  /   requestkeeptime  (optional) retain completed rows for this long, default 0D00:30
  /   resultcallback   (optional) postback symbol for shard success, default `shardresult
  /   errorcallback    (optional) postback symbol for shard error,   default `sharderror
  if[99h<>type deps;
    '"di.dataaccess: deps must be a dict with `log and `timer keys"];
  if[not `log in key deps;
    '"di.dataaccess: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.dataaccess: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.dataaccess: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[not `timer in key deps;
    '"di.dataaccess: timer dependency is required; pass a di.timer instance keyed on `timer"];
  .z.m.log:normlog deps`log;
  .z.m.timer:deps`timer;
  .z.m.cp:getopt[deps;`cp;{.z.p}];
  .z.m.synccallsallowed:getopt[deps;`synccallsallowed;0b];
  .z.m.requestkeeptime:getopt[deps;`requestkeeptime;0D00:30];
  .z.m.resultcallback:getopt[deps;`resultcallback;`shardresult];
  .z.m.errorcallback:getopt[deps;`errorcallback;`sharderror];
  .z.m.requests:schema;
  .z.m.shardresults:()!();
  .z.m.requestid:0;
  .z.m.log[`info][`init;"dataaccess initialised; scheduling request housekeeping"];
  .z.m.timer[`addjob][`default][`dataaccesspurge;removerequests;enlist .z.m.requestkeeptime;1800i;1];
  };
