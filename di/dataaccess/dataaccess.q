/ di.dataaccess - data access query layer.
/ routes a time-ranged client query across partitions (one shard per servertype/sub-range),
/ rewrites each shard's query string with its time filter, scatters the shards via di.asyncdispatch,
/ then gathers and reduces the shard results back to the client via a user-supplied join function.
/ hard deps: di.asyncdispatch (execution), di.serverselect (which servertypes are reachable).
/ injected via init: log, timer and resultcallback (all required), plus optional config.

/ --- hard dependencies ---
asyncdispatch:use`di.asyncdispatch;
serverselect:use`di.serverselect;

/ --- constants ---
/ characters that can appear inside a q identifier - used to match `where` as a WHOLE word
identchars:.Q.an,"_.";

/ default client-error prefix; the live value is .z.m.errorprefix, set in init.
/ MUST match di.asyncdispatch's own errorprefix - shardresult detects backend errors by
/ comparing against it, and asyncdispatch makes its copy configurable too
defaulterrorprefix:"error: ";

/ default partition coverage - one hdb covering all time; override via init `partitions
defaultpartitions:([]servertype:enlist`hdb;coverfrom:enlist -0Wp;coverto:enlist 0Wp);

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

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.dataaccess: ",string[ctx],": ",msg;
  };

getopt:{[deps;k;dflt]
  / internal - read an optional config key from the deps dict, falling back to a default
  $[k in key deps;deps k;dflt]
  };

checkopt:{[deps;k;ok;what]
  / internal - validate an optional config value's TYPE at init, so a misconfiguration fails loudly
  / at startup instead of silently at first use. an int requestkeeptime, for instance, used to be
  / accepted and then read as nanoseconds by the purge job
  if[k in key deps;
    if[not ok deps k;'"di.dataaccess: ",string[k]," must be ",what]];
  };

requireinit:{[ctx]
  / internal - every public entry point needs init to have run first. without this guard a bare read
  / of an unwritten .z.m name surfaces as a raw '.m.di.0dataaccess.<name> error naming module
  / internals. signals plainly rather than via raiseerror - there is no logger to log through yet
  if[not `logerr in key .z.m;'"di.dataaccess: ",string[ctx],": init must be called first"];
  };

partitionserror:{[parts]
  / internal - "" if parts is a valid partition coverage table, else the reason it is not.
  / shared by init and setpartitions so both enforce EXACTLY the same contract; they disagreed
  / before, init accepting a keyed table that setpartitions rejected
  $[not 98h=type parts;
    "partitions must be an unkeyed table";
    not all `servertype`coverfrom`coverto in cols parts;
    "partitions config must have columns servertype, coverfrom, coverto";
    ""]
  };

partitionsoverlap:{[parts]
  / internal - true if any two coverage ranges genuinely intersect, which makes one request fan out
  / to several shards covering the same slice and double-count every row in the overlap.
  / strict <: ranges that merely TOUCH (hdb coverto = rdb coverfrom, the documented rollover config)
  / are not an overlap. compares each range against the running max coverto, not just its neighbour,
  / so a wide early range still catches a later one nested inside it
  if[2>count parts;:0b];
  s:`coverfrom xasc select coverfrom,coverto from parts;
  any (1_s`coverfrom) < -1_ maxs s`coverto
  };

warnoverlap:{[ctx;parts]
  / internal - overlapping coverage is a caller decision, not an error, so warn rather than signal
  if[partitionsoverlap parts;
    .z.m.logwarn[ctx;"partition coverage ranges overlap; a query spanning the overlap fans out to multiple shards and double-counts rows"]];
  };

maskliterals:{[q]
  / internal - blank the contents of double-quoted string literals so a `where` inside one cannot be
  / mistaken for a real where clause. a char is inside a literal when an odd number of unescaped
  / double quotes precede or include it
  if[0=count q;:q];
  quotes:(q="\"") and not prev[q]="\\";
  @[q;where 1=(sums quotes) mod 2;:;" "]
  };

haswhereclause:{[q]
  / internal - true if the query carries a real where clause. replaces a bare q like "*where*",
  / which false-positived on any identifier merely CONTAINING where - a column named `wherever`, a
  / symbol `nowhere` - and then emitted "select wherever from t , time within (...)", invalid q.
  / matches `where` only as a whole word and only outside string literals
  m:maskliterals q;
  hits:m ss "where";
  if[0=count hits;:0b];
  n:count m;
  any {[m;n;i]
    $[i=0;1b;not m[i-1] in identchars] and $[(i+5)>=n;1b;not m[i+5] in identchars]
    }[m;n] each hits
  };

/ --- routing and query rewriting (dataaccess's own domain logic) ---

getrouting:{[starttime;endtime]
  / split [starttime;endtime] across the configured partitions, keeping only reachable servertypes;
  / each surviving partition yields one shard clipped to the overlap of its coverage and the request
  active:exec distinct servertype from serverselect.getservers[`servertype;`;()!()];
  parts:select from .z.m.partitions where servertype in active;
  shards:select servertype,rangestart:coverfrom|starttime,rangeend:coverto&endtime from parts;
  select from shards where rangestart<rangeend
  };

buildshardquery:{[query;rangestart;rangeend]
  / inject the shard's time range into the qSQL query string as a within filter on the time column;
  / appended as the last clause, so it works whether or not the query already has a where clause.
  / string-based by design - assumes a flat select string; not robust to subqueries.
  / where-detection is whole-word and literal-aware (see haswhereclause), so an identifier that
  / merely contains "where" no longer produces an invalid ", time within (...)" tail
  clause:(string .z.m.timecolumn)," within (",(string rangestart),";",(string rangeend),")";
  $[haswhereclause query;query," , ",clause;query," where ",clause]
  };

/ --- shard result accumulation ---

shardresult:{[reqid;query;result]
  requireinit`shardresult;
  / asyncdispatch postback callback - it delivers (reqid;query;result); query is echoed and unused.
  / asyncdispatch routes backend errors through this same postback as an errorprefix-prefixed string,
  / so detect that and short-circuit via the error path; otherwise accumulate the shard result
  if[(10h=type result) and .z.m.errorprefix~(count .z.m.errorprefix) sublist result;
    :sharderror[reqid;(count .z.m.errorprefix) _ result]];
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
  requireinit`sharderror;
  if[not reqid in key .z.m.requests;:()];
  req:.z.m.requests reqid;
  if[not null req`returntime;:()];
  .z.m.logerr[`sharderror;"shard error for request ",string[reqid],": ",err];
  sendreply[reqid;.z.m.errorprefix,err;0b];
  finishrequest[reqid;1b];
  };

checkresults:{[reqid]
  / all shards received; apply the user join function across the shard results and reply
  req:.z.m.requests reqid;
  accumulated:.z.m.shardresults reqid;
  res:.[{(0b;x y)};(req`joinfn;accumulated);{(1b;.z.m.errorprefix,"join failed: ",x)}];
  / a joinfn of the wrong arity does NOT throw - q returns a PROJECTION - so without this the client
  / silently receives a function object as its result. treat a callable result as a join failure
  if[not res 0;
    if[type[res 1] within 100 112h;
      res:(1b;.z.m.errorprefix,"join failed: joinfn returned a function - check its arity")]];
  if[res 0;.z.m.logerr[`checkresults;"join failed for request ",string[reqid],": ",last res]];
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
  / fan out one asyncdispatch query per shard; results return via the resultcallback postback.
  / execqueryto with replyto:0Ni, NOT execquery: execquery captures clienth:.z.w at call time, which
  / in-process is the end CLIENT's handle inherited through the call chain - so every shard reply
  / went to the client (which has no shardresult) and the join never ran. 0Ni makes asyncdispatch
  / invoke the postback locally via value instead, which is why resultcallback must be
  / mount-qualified. see dataaccess.md
  / NB local invocation is SYNCHRONOUS - shardresult can fire before this returns, so the request row
  / and its shardresults slot must already exist. execquery files both before calling here
  {[reqid;timeout;stype;q]
    asyncdispatch.execqueryto[0Ni;q;enlist stype;first;(.z.m.resultcallback;reqid);timeout;0b]
    }[reqid;timeout]'[shards`servertype;shards`shardquery];
  };

/ --- public API ---

execquery:{[query;starttime;endtime;joinfn;postback;timeout;sync]
  / route a query across partition ranges, scatter to shards, gather and reduce the results.
  / returns the requestid this call was filed under. both exits consume exactly one id and return
  / that id - not the next one - so a caller can correlate a postback reply with its request
  / every argument is validated up front and routed through raiseerror, so a caller mistake is
  / logged and named rather than surfacing later as a raw 'type out of a downstream upsert.
  / the range check is deliberate: an inverted or zero-width range used to route to zero shards and
  / return an empty result with no error at all, which reads as "no data" rather than "bad request"
  requireinit`execquery;
  if[not 10h=type query;raiseerror[`execquery;"query must be a string"]];
  if[0=count query;raiseerror[`execquery;"query must not be empty"]];
  if[not -12h=type starttime;raiseerror[`execquery;"starttime must be a timestamp"]];
  if[not -12h=type endtime;raiseerror[`execquery;"endtime must be a timestamp"]];
  if[null starttime;raiseerror[`execquery;"starttime must not be null"]];
  if[null endtime;raiseerror[`execquery;"endtime must not be null"]];
  if[starttime>=endtime;raiseerror[`execquery;"starttime must be earlier than endtime"]];
  if[not type[joinfn] within 100 112h;raiseerror[`execquery;"joinfn must be a function"]];
  if[not (type postback) in -11 0 11h;raiseerror[`execquery;"postback must be () or a symbol or a list of symbols"]];
  if[not -16h=type timeout;raiseerror[`execquery;"timeout must be a timespan"]];
  if[not -1h=type sync;raiseerror[`execquery;"sync must be a boolean"]];
  if[sync;
    if[not .z.m.synccallsallowed;raiseerror[`execquery;"synchronous calls are not allowed"]];
    if[not @[{-30!x;1b};(::);0b];raiseerror[`execquery;"deferred response not supported on this connection"]]];
  reqid:.z.m.requestid;
  shards:getrouting[starttime;endtime];
  if[0=count shards;
    tosend:$[()~postback;();postback,enlist enlist[]];
    $[sync;@[-30!;(.z.w;0b;());{}];@[neg .z.w;tosend;()]];
    .z.m.requestid:1+reqid;
    :reqid];
  postback:{$[11h=type x;enlist x;x]}postback;
  shardqueries:buildshardquery[query;;]'[shards`rangestart;shards`rangeend];
  shards:shards,'flip(enlist`shardquery)!enlist shardqueries;
  .z.m.requests:.z.m.requests upsert (reqid;.z.m.cp[];.z.w;count shards;joinfn;postback;timeout;0Np;0b;sync);
  .z.m.shardresults[reqid]:();
  / bump the counter BEFORE dispatching: local invocation runs shardresult synchronously inside
  / submitshards, so the id must already be consumed by the time any callback re-enters the module
  .z.m.requestid:1+reqid;
  submitshards[reqid;shards;timeout];
  :reqid;
  };

removerequests:{[age]
  / purge completed request rows older than age to prevent unbounded table growth
  requireinit`removerequests;
  .z.m.requests:delete from .z.m.requests where not null returntime, .z.m.cp[]>returntime+age;
  };

checktimeout:{[]
  / error any in-flight request that has passed the timeout execquery recorded for it.
  / without this a shard that never comes back leaves its request in flight forever: removerequests
  / only purges rows that ALREADY have a returntime, so an abandoned row is never reclaimed and the
  / client is never told. di.asyncdispatch runs an equivalent scan over its own queue, but only if
  / the caller scheduled it, and it cannot see this module's requests table - the timeout recorded
  / here has to be enforced here. init schedules this on the injected timer
  requireinit`checktimeout;
  expired:exec requestid from .z.m.requests where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[0=count expired;:()];
  .z.m.logwarn[`checktimeout;"requests timed out: ",", " sv string expired];
  sharderror[;"request timed out"] each expired;
  };

setpartitions:{[parts]
  / replace the live partition coverage table, e.g. from a gateway's end-of-day reload handler.
  / init sets this once; without a runtime path the rdb/hdb boundary goes stale at every roll.
  / validates the same columns init does, so a bad table cannot be installed after startup
  requireinit`setpartitions;
  if[count e:partitionserror parts;raiseerror[`setpartitions;e]];
  warnoverlap[`setpartitions;parts];
  .z.m.partitions:parts;
  .z.m.loginfo[`setpartitions;"partition coverage replaced: ",string[count parts]," partitions"];
  };

removeclient:{[h]
  / error and clean up any in-flight request belonging to a disconnected client.
  / di.asyncdispatch cannot do this for us: every shard we dispatch carries replyto:0Ni, and its
  / removeclienthandle explicitly skips local queries ("the in-process caller owns cleanup for its
  / own requests"). the real client handle exists only here, in our own requests table.
  / removerequests cannot do it either - it only purges rows that already have a returntime, so an
  / abandoned in-flight row would otherwise sit in requests/shardresults forever
  requireinit`removeclient;
  if[not -6h=type h;raiseerror[`removeclient;"handle must be an int"]];
  orphaned:exec requestid from .z.m.requests where clienth=h, null returntime;
  if[0=count orphaned;:()];
  .z.m.shardresults:orphaned _ .z.m.shardresults;
  .z.m.requests:update error:1b,returntime:.z.m.cp[] from .z.m.requests where requestid in orphaned;
  .z.m.loginfo[`removeclient;"client ",string[h]," disconnected; errored ",string[count orphaned]," in-flight request(s)"];
  };

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are omitted
  / as framework plumbing. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;        1b; "module version string";
       "[]";                                                        "string: version");
    (`execquery;      1b; "route a time-ranged query across partitions, scatter the shards and reduce the results back to the client";
       "[string: query; timestamp: starttime; timestamp: endtime; function: joinfn; list: postback; timespan: timeout; boolean: sync]";
       "long: requestid the call was filed under");
    (`setpartitions;  1b; "replace the live partition coverage table, e.g. at an end-of-day roll";
       "[table: partitions with servertype, coverfrom, coverto]";   "null");
    (`removeclient;   1b; "error and clean up any in-flight request belonging to a disconnected client handle";
       "[int: client handle]";                                      "null");
    (`shardresult;    1b; "asyncdispatch postback - accumulate one shard result and join once all shards are in";
       "[long: requestid; string: query echoed by asyncdispatch; any: shard result]"; "null");
    (`sharderror;     1b; "short-circuit a request on a shard failure and reply the error to the client";
       "[long: requestid; string: error]";                          "null");
    (`removerequests; 1b; "purge completed request rows older than age";
       "[timespan: age]";                                           "null");
    (`checktimeout;   1b; "error any in-flight request that has passed the timeout execquery recorded for it";
       "[]";                                                        "null"));
  };

init:{[deps]
  / wire the required injectables (log, timer, resultcallback) and optional config; there is NO
  / silent fallback for any of them.
  / deps keys:
  /   log              (required) `info`warn`error!{[c;m]} dict - binary, already conforming.
  /                    a raw monadic kx.log instance is NOT adapted here and will 'rank at first use
  /   timer            (required) di.timer instance - uses `addjob` to schedule housekeeping
  /   resultcallback   (required) MOUNT-QUALIFIED postback symbol for shard replies, e.g.
  /                    `da.shardresult. required, not defaulted: submitshards dispatches with
  /                    replyto:0Ni, so asyncdispatch resolves this symbol with value inside its OWN
  /                    namespace - a bare `shardresult does not resolve there, and the failure is
  /                    swallowed by asyncdispatch's local-postback trap rather than raised. there is
  /                    no orchestration harness yet to establish a canonical mount name, so there is
  /                    no safe default to bake in
  /   cp               (optional) current-time fn, default {.z.p} (override for sim/backtest)
  /   errorprefix      (optional) NON-EMPTY client-error prefix, default "error: ". MUST match the
  /                    prefix di.asyncdispatch is configured with - shardresult detects backend
  /                    errors by comparing against it
  /   timeoutcheckperiod (optional) int seconds between timeout sweeps, default 10i
  /   synccallsallowed (optional) allow deferred-sync execquery, default 0b
  /   requestkeeptime  (optional) retain completed rows for this long, default 0D00:30
  /   partitions       (optional) table (servertype;coverfrom;coverto) of partition coverage
  /   timecolumn       (optional) time column rewritten into shard queries, default `time
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
  if[not `resultcallback in key deps;
    '"di.dataaccess: resultcallback dependency is required; pass the mount-qualified postback symbol, e.g. `da.shardresult"];
  if[not -11h=type deps`resultcallback;
    '"di.dataaccess: resultcallback must be a symbol; got type ",string type deps`resultcallback];
  if[`partitions in key deps;
    if[count e:partitionserror deps`partitions;'"di.dataaccess: ",e]];
  / optional config is type-checked HERE so a misconfiguration fails at startup rather than silently
  / at first use. an empty errorprefix is rejected outright: shardresult detects a backend error with
  / prefix~(count prefix) sublist result, and with an empty prefix that matches EVERY string result,
  / so every ordinary string a shard returned would be misread as an error
  checkopt[deps;`errorprefix;{(10h=type x) and 0<count x};"a non-empty string"];
  checkopt[deps;`requestkeeptime;{-16h=type x};"a timespan"];
  checkopt[deps;`timeoutcheckperiod;{-6h=type x};"an int number of seconds"];
  checkopt[deps;`cp;{type[x] within 100 112h};"a function"];
  checkopt[deps;`timecolumn;{-11h=type x};"a symbol"];
  checkopt[deps;`synccallsallowed;{-1h=type x};"a boolean"];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  / init is re-callable, and a re-init resets requests/shardresults/requestid wholesale. say so when
  / that throws away live work: those clients are never replied to and never find out. read the OLD
  / table before it is replaced below
  if[`requests in key .z.m;
    if[count inflight:select from .z.m.requests where null returntime;
      .z.m.logwarn[`init;"re-init discarded ",string[count inflight]," in-flight request(s); their clients will not be replied to"]]];
  .z.m.timer:deps`timer;
  .z.m.resultcallback:deps`resultcallback;
  .z.m.cp:getopt[deps;`cp;{.z.p}];
  .z.m.errorprefix:getopt[deps;`errorprefix;defaulterrorprefix];
  .z.m.synccallsallowed:getopt[deps;`synccallsallowed;0b];
  .z.m.requestkeeptime:getopt[deps;`requestkeeptime;0D00:30];
  .z.m.timeoutcheckperiod:getopt[deps;`timeoutcheckperiod;10i];
  .z.m.partitions:getopt[deps;`partitions;defaultpartitions];
  .z.m.timecolumn:getopt[deps;`timecolumn;`time];
  warnoverlap[`init;.z.m.partitions];
  .z.m.requests:schema;
  .z.m.shardresults:()!();
  .z.m.requestid:0;
  .z.m.loginfo[`init;"dataaccess initialised; scheduling request housekeeping and timeout checks"];
  .z.m.timer[`addjob][`default][`dataaccesspurge;removerequests;enlist .z.m.requestkeeptime;1800i;1];
  .z.m.timer[`addjob][`default][`dataaccesstimeout;checktimeout;();.z.m.timeoutcheckperiod;1];
  };
