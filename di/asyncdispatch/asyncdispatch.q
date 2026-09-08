/ di.asyncdispatch - async scatter-gather query coordinator
/ queues queries, dispatches to available backends, collects results per server,
/ applies a join function, and replies to the client
/ routing (which servers satisfy a query) is di.serverselect's responsibility
/ the log dependency is required - init errors immediately if absent or malformed
/ log functions are binary {[c;m]} where c is a symbol context and m is a string

/ ============================================================
/ module state and defaults
/ ============================================================

/ error prefix prepended to all error strings returned to clients
errorprefix:"error: ";

/ how long completed queries are kept in queryqueue before being purged
querykeeptime:0D00:30;

/ how long disconnected servers are kept in the servers table before being removed
clearinactivetime:0D01:00;

/ whether synchronous calls via -30! are permitted
synccallsallowed:0b;

/ injectable clock - replaced in tests to control time without sleeping
cp:{.z.p};

/ end-of-day reload suspension. runtime state, not config - TorQ never made it settable either
/ (gateway.q:91). while set, a query needing MORE THAN ONE servertype is held in the queue rather
/ than dispatched: during a roll, data is moving between e.g. the rdb and the hdb, so a query
/ straddling both can double-count or miss rows. single-servertype queries are unaffected.
/ held queries are NOT errored - they run once the suspension clears
eod:0b;

/ symbols backend servers call back via - stored as symbols so names survive IPC serialisation
resultcallback:`addserverresult;
errorcallback:`addservererror;

/ reply formatting - sync errors must be signalled with ' so the client receives a trapped error
formatresponse:{[status;sync;result]$[not[status]and sync;'result;result]};

/ scheduling strategy - pick oldest FIFO-eligible query by default
getnextqueryid:{
  avail:exec distinct servertype from availableservers 1b;
  / 0! is required - select from a keyed table stays keyed in kdb-x, and runnextquery needs queryid via first
  / the trailing eod clause mirrors TorQ's canberun (gateway.q:147), which filters the queue to
  / single-servertype queries for as long as a reload is in progress
  / checkeod must be reached as .z.m.checkeod here: q-sql evaluates where-clause expressions in the
  / CALLING context, not the module namespace, so a bare module name throws 'checkeod. avail is a
  / function local, which is why it resolves bare
  runnable:0!select from .z.m.queryqueue where null returntime, not queryid in key .z.m.results,
    {all x in y}[;avail] each servertype, not .z.m.checkeod each servertype;
  1 sublist select from runnable where time=min time
  };

/ server routing strategy - active and idle by default
availableservers:{[excludeinuse]
  $[excludeinuse;
    select from servers where active, not inuse;
    select from servers where active]
  };

/ ============================================================
/ module tables
/ ============================================================

/ registered backend servers
servers:([handle:`u#`int$()] servertype:`symbol$(); inuse:`boolean$(); active:`boolean$(); disconnecttime:`timestamp$());

/ pending and in-flight client queries
/ submittime is stamped when the query is dispatched and is what separates a queued query from a
/ running one - it is the only thing status[] needs to report pending vs running, exactly as TorQ's
/ getqueue derived it (gateway.q:194, status:?[null submittime;`pending;`running])
queryqueue:([queryid:`u#`long$()]
  time:`timestamp$(); clienth:`int$(); query:(); servertype:(); join:(); postback:();
  timeout:`timespan$(); submittime:`timestamp$(); returntime:`timestamp$(); error:`boolean$();
  sync:`boolean$(); local:`boolean$());

/ connected client tracking
clients:([] time:`timestamp$(); clienth:`int$(); user:`symbol$(); ip:`int$(); host:`symbol$());

/ per-query result accumulator: queryid -> (clienth; servertype!(handle;result;done))
results:()!();

/ auto-incrementing query id counter
queryid:0;

/ ============================================================
/ internal helpers
/ ============================================================

requireinit:{[ctx]
  / internal - every public entry point needs init to have run first. without this guard a bare read
  / of an unwritten .z.m name surfaces as a raw '.m.di.0asyncdispatch.<name> error naming module
  / internals. signals plainly rather than via raiseerror - there is no logger to log through yet
  if[not `logerr in key .z.m;'"di.asyncdispatch: ",string[ctx],": init must be called first"];
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable in the log and not
  / only as a thrown exception the caller may swallow
  .z.m.logerr[ctx;msg];
  '"di.asyncdispatch: ",string[ctx],": ",msg;
  };

checkeod:{[types]
  / internal - 1b if an eod reload is in progress AND this query spans more than one servertype.
  / faithful to TorQ's checkeod (gateway.q:93): the suspension alone does not block anything, it is
  / the multi-servertype span that does. internal deliberately - TorQ's has no caller outside .gw
  / NB the explicit : is load-bearing. this function must RETURN a boolean, and a trailing statement
  / semicolon would make it return the generic null instead - `not (::)` then throws 'type
  :eod and 1<count distinct types,();
  };

checkopt:{[deps;k;ok;what]
  / internal - validate an optional config value's TYPE at init, so a misconfiguration fails loudly
  / at startup instead of silently at first use. querykeeptime and clearinactivetime both feed
  / cp[]>x+age comparisons, where an int is accepted and then read as nanoseconds by the purge jobs
  if[k in key deps;
    if[not ok deps k;'"di.asyncdispatch: ",string[k]," must be ",what]];
  };

sendclientreply:{[qid;result;status]
  / deliver result or error to the client, handling sync vs async send and postback wrapping
  / local path invokes value tosend directly - formatresponse is not applied (it is a pass-through
  / for async by default; consumers that override setformatresponse should not use local invocation)
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
  / remove query from the live results accumulator and stamp its completion time.
  / FIRST release any backend still assigned to these queries, so that finishing a query always
  / releases its servers - an invariant every caller can rely on rather than a per-call-site duty.
  / DELIBERATE DIVERGENCE FROM TorQ. TorQ's finishquery takes a serverh and frees it via
  / setserverstate (gateway.q:187), but checktimeout calls it as finishquery[qids;1b;0Ni]
  / (gateway.q:314) and `where handle in 0Ni` matches nothing - so TorQ leaks the slot too. Left
  / as-is, a timed-out in-flight query pins its backend inuse:1b until it eventually replies or
  / disconnects, and a run of timeouts against one stuck backend progressively starves the dispatch
  / pool with no recovery short of a disconnect. see asyncdispatch.md for the full reasoning
  held:(qid,()) inter key .z.m.results;
  if[count held;
    freed:distinct raze {value[.z.m.results[x;1]][;0]} each held;
    update inuse:0b from .z.M.servers where handle in freed];
  .z.m.results:(qid,())_results;
  update error:err,returntime:.z.m.cp[] from .z.M.queryqueue where queryid in qid;
  };

serverexecute:{[rescb;errcb;qid;query]
  / runs on the backend - traps errors so a crash posts an error reply rather than dropping the result.
  / the result/error callback symbols are passed in as parameters (baked by sendquerytoserver on the
  / dispatching side) rather than read as free variables here: read as free vars they would resolve in
  / the BACKEND's namespace, forcing every caller to first push the callback vars onto each backend.
  / baking them in keeps serverexecute fully self-contained, so backends need no cooperating code.
  res:@[{(0b;value x)};query;{(1b;"server ",(string .z.h),":",(string system"p"),": ",x)}];
  @[neg .z.w;$[res 0;(errcb;qid;res 1);(rescb;qid;res 1)];
    {@[neg .z.w;(x;y;"failed to return result: ",z);()]}[errcb;qid]];
  };

sendquerytoserver:{[qid;query;handles]
  / fan the query out to all required handles and mark them in-use atomically.
  / project the configured callback symbols into serverexecute so they ship to the backend as baked
  / literals - no backend-side variable lookup required.
  (neg handles,:())@\:(serverexecute[.z.m.resultcallback;.z.m.errorcallback];qid;query);
  update inuse:1b from .z.M.servers where handle in handles;
  };

runnextquery:{[]
  / pick the next dispatchable query and fan out to one idle server per required servertype
  / called after any state change that may unblock work
  if[0=count torun:getnextqueryid[];:()];
  torun:first torun;
  / backstop gate, matching TorQ's runquery (gateway.q:486). getnextqueryid already excludes these,
  / but it is PLUGGABLE via setgetnextqueryid and an injected scheduler need not implement the eod
  / rule - TorQ keeps both checks for exactly this reason
  if[checkeod torun`servertype;:()];
  avail:exec first handle by servertype from availableservers 1b;
  types:torun`servertype;
  handles:avail types;
  qid:torun`queryid;
  / stamp the dispatch time - fill-if-null so a redispatch never restamps, matching TorQ's
  / getnextquery (gateway.q:180, .proc.cp[]^submittime)
  update submittime:.z.m.cp[]^submittime from .z.M.queryqueue where queryid=qid;
  slots:types!count[types]#enlist(0Ni;(::);0b);
  slots[types;0]:handles;
  / indexed assignment on bare results propagates through to .z.m in kdb-x (empirically verified)
  results[qid]:(torun`clienth;slots);
  sendquerytoserver[qid;torun`query;handles];
  };

addqueryto:{[query;servertype;join;postback;timeout;sync;replyto;local]
  / enqueue a query with an explicit reply target - used by execqueryto for local in-process routing
  .z.M.queryqueue upsert (queryid;.z.m.cp[];replyto;query;servertype;join;
    {$[11h=type x;enlist x;x]}postback;timeout;0Np;0Np;0b;sync;local);
  .z.m.queryid:queryid+1;
  };

addquery:{[query;servertype;join;postback;timeout;sync]
  / enqueue a query without dispatching - caller must call runnextquery[] to trigger dispatch
  addqueryto[query;servertype;join;postback;timeout;sync;.z.w;0b];
  };

removequeries:{[age]
  / prevent queryqueue growing unboundedly - purge completed queries older than age
  requireinit`removequeries;
  delete from .z.M.queryqueue where not null returntime, .z.m.cp[]>returntime+age;
  };

removeinactive:{[age]
  / prune stale disconnected-server rows to stop the servers table growing forever
  requireinit`removeinactive;
  delete from .z.M.servers where not active, .z.m.cp[]>disconnecttime+age;
  };

removeclients:{[age]
  / prune stale client audit rows to stop the clients table growing forever
  / clients are recorded on every connect by addclientdetails and never removed otherwise
  requireinit`removeclients;
  delete from .z.M.clients where .z.m.cp[]>time+age;
  };

checktimeout:{[]
  / periodic scan to error queries that have waited beyond their timeout
  requireinit`checktimeout;
  qids:exec queryid from .z.m.queryqueue where not timeout=0Wn, null returntime, .z.m.cp[]>time+timeout;
  if[count qids;
    .z.m.logwarn[`asyncdispatch;"queries timed out: ",", " sv string qids];
    sendclientreply[;errorprefix,"query timed out";0b] each qids;
    finishquery[qids;1b]];
  };

/ ============================================================
/ public api
/ ============================================================

setcp:{[f]
  / replace the clock function - used in tests to control time without sleeping
  .z.m.cp:f;
  };

seteod:{[b]
  / start or end an end-of-day reload suspension. while set, queries spanning more than one
  / servertype are held in the queue rather than dispatched, and run once it clears.
  / di.gateway calls this - TorQ drives it from the wdb, which sends reloadstart/reloadend to the
  / gateway process (wdb.q:261,274 -> gateway.q:560,570). those two live at TorQ's ROOT namespace,
  / not in .gw, because they also refresh .servers attributes - so the orchestration is the process
  / module's job and only the suspension itself belongs here.
  / DIVERGENCE: clearing the suspension flushes the held queue here, where TorQ's reloadend does it
  / as a separate explicit runnextquery[] call (gateway.q:577). doing it here means the module
  / guarantees the flush rather than depending on every caller remembering; without it a held query
  / waits for whatever unrelated dispatch happens next
  requireinit`seteod;
  if[not -1h=type b;raiseerror[`seteod;"b must be a boolean"]];
  .z.m.eod:b;
  .z.m.loginfo[`asyncdispatch;"eod reload suspension ",$[b;"started";"ended"]];
  if[not b;runnextquery[]];
  };

setformatresponse:{[f]
  / override reply formatting - e.g. to wrap results in a standard envelope
  .z.m.formatresponse:f;
  };

setcallbacks:{[resfn;errfn]
  / update callback symbols when module is mounted under a non-default namespace
  .z.m.resultcallback:resfn;
  .z.m.errorcallback:errfn;
  };

setavailableservers:{[f]
  / swap in a custom routing strategy without forking core dispatch
  .z.m.availableservers:f;
  };

setgetnextqueryid:{[f]
  / inject a priority or custom scheduling strategy
  .z.m.getnextqueryid:f;
  };

addserver:{[h;st]
  / register a backend handle and servertype so it becomes eligible for dispatch.
  / this is the default (built-in) server source; to dispatch against di.serverselect's view instead,
  / inject it via setavailableservers - no registration and no di.serverselect dependency required
  requireinit`addserver;
  .z.m.loginfo[`asyncdispatch;"server registered: ",string[st]," handle ",string h];
  .z.M.servers upsert (h;st;0b;1b;0Np);
  };

removeserverhandle:{[serverh]
  / on backend disconnect, error in-flight queries using that handle and queued queries
  / that can no longer be satisfied
  requireinit`removeserverhandle;
  if[null st:first exec servertype from .z.m.servers where handle=serverh;:()];
  err:errorprefix,"backend ",string[st]," server disconnected";
  .z.m.logwarn[`asyncdispatch;"backend disconnected: ",string st];
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
  runnextquery[];
  };

addclientdetails:{[h]
  / record client identity on connect for audit and orphan-query cleanup on disconnect
  requireinit`addclientdetails;
  .z.m.loginfo[`asyncdispatch;"client connected: handle ",string h];
  .z.M.clients insert (.z.m.cp[];h;.z.u;.z.a;.z.h);
  };

removeclienthandle:{[h]
  / on client disconnect, mark their pending queries errored so result slots are not leaked
  / free any servers in-flight for this client before removing result slots, then re-dispatch
  / local queries store clienth:0Ni and are not matched here - the in-process caller owns cleanup for its own requests
  requireinit`removeclienthandle;
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
  / fill one result slot - once all slots for a query are filled, run the join and reply
  / bare indexed assignment on results propagates through to .z.m in kdb-x (empirically verified)
  requireinit`addserverresult;
  if[not qid in key results;:()];
  slots:results[qid;1];
  / map the responding handle to its servertype from THIS query's own dispatch record, not a server
  / registry - so any server source (built-in or an injected di.serverselect view) works unchanged
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
  / short-circuit a query on backend failure - free the server and notify the client
  requireinit`addservererror;
  .z.m.logerr[`asyncdispatch;"backend error for query ",string[qid],": ",err];
  sendclientreply[qid;errorprefix,err;0b];
  update inuse:0b from .z.M.servers where handle in .z.w;
  runnextquery[];
  finishquery[qid;1b];
  };

execquery:{[query;servertype;join;postback;timeout;sync]
  / public entry point - validate sync constraints then enqueue and kick dispatch
  requireinit`execquery;
  if[sync;
    if[not ()~postback;.z.m.logwarn[`asyncdispatch;"execquery: postback ignored for sync call"]];
    if[not synccallsallowed;raiseerror[`execquery;"synchronous calls are not allowed"]];
    if[not @[{-30!x;1b};(::);0b];raiseerror[`execquery;"deferred response not supported on this connection"]];
    .[{[q;s;j;t]addquery[q;s;j;();t;1b];runnextquery[]};(query;servertype;join;timeout);{-30!(.z.w;1b;x)}];
    :()];
  addquery[query;servertype;join;postback;timeout;0b];
  runnextquery[];
  };

execqueryto:{[replyto;query;servertype;join;postback;timeout;sync]
  / in-process variant of execquery - replyto is 0Ni for local invocation via value
  / postback must be non-empty when replyto is 0Ni - there is no handle to send a bare result to
  / sync is not supported for local invocation
  / mount-qualified postback symbols required for local invocation e.g. `da.shardresult not `shardresult
  requireinit`execqueryto;
  if[0Ni~replyto;
    if[()~postback;raiseerror[`execqueryto;"local invocation requires a non-empty postback"]];
    if[sync;raiseerror[`execqueryto;"local invocation does not support sync mode"]]];
  local:0Ni~replyto;
  addqueryto[query;servertype;join;postback;timeout;sync;replyto;local];
  runnextquery[];
  };

/ the raze / no-postback / no-timeout / async convenience form, TorQ's asyncexec
/ (gateway.q:419, asyncexecjpt[;;raze;();0Wn]). the most common client entry point in practice
asyncexec:execquery[;;raze;();0Wn;0b];

status:{[]
  / a snapshot of live dispatch state. .z.m is invisible over IPC - a remote query runs in the ROOT
  / context, whose .z.m is not this module's - so an export is the only way di.gateway or a monitor
  / can see the queue, the server pool or the wiring at all
  requireinit`status;
  live:select from .z.m.queryqueue where null returntime;
  :`queued`running`held`eod`servers`activeservers`clients`errorprefix`querykeeptime`clearinactivetime`synccallsallowed!
    (count select from live where null submittime;
     count select from live where not null submittime;
     count select from live where null submittime, .z.m.checkeod each servertype;
     .z.m.eod;
     count .z.m.servers;
     exec count i by servertype from .z.m.servers where active;
     count .z.m.clients;
     .z.m.errorprefix;
     .z.m.querykeeptime;
     .z.m.clearinactivetime;
     .z.m.synccallsallowed);
  };

teardown:{[]
  / clear all dispatch state so a re-init or a test starts clean.
  / NOT the di.servers teardown contract (withdraw process-global registrations) - this module
  / installs none: it registers no handler and schedules no timer job, both being the caller's job.
  / what it does own is four tables and a counter, so a state reset is the only shape that means
  / anything here.
  / WARNS about in-flight work rather than dropping it silently - those clients are never replied to
  / and never find out, the same hazard di.dataaccess.init warns about on re-init
  requireinit`teardown;
  if[count inflight:select from .z.m.queryqueue where null returntime;
    .z.m.logwarn[`teardown;"discarding ",string[count inflight],
      " in-flight query row(s); their clients will not be replied to"]];
  delete from .z.M.queryqueue;
  delete from .z.M.servers;
  delete from .z.M.clients;
  .z.m.results:()!();
  .z.m.queryid:0;
  / eod is RUNTIME state, not config (see its declaration), so a state reset has to clear it too.
  / left set, teardown hands back a module that looks clean but silently holds every multi-servertype
  / query - visible only through status[]`eod, and never surfaced as an error to whoever hits it
  .z.m.eod:0b;
  };

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to collect and register with di.api. init and
  / getapimeta are omitted as framework plumbing - di.torq calls both by convention, so neither
  / belongs in the registry. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;             1b; "module version string";
       "[]";                                                                        "string: version");
    (`status;              1b; "snapshot of live dispatch state - queue depth by pending/running/held, server and client counts, live config";
       "[]";                              "dict: queued, running, held, eod, servers, activeservers, clients, config");
    (`seteod;              1b; "start or end an end-of-day reload suspension - while set, queries spanning more than one servertype are held";
       "[boolean: b]";                                                              "null");
    (`teardown;            1b; "clear all dispatch state (queue, servers, clients, results) so a re-init or test starts clean";
       "[]";                                                                        "null");
    (`setcp;               1b; "replace the clock function after init - used to control time in tests without sleeping";
       "[function: {[]} returning a timestamp]";                                    "null");
    (`setformatresponse;   1b; "override reply formatting, e.g. to wrap results in a standard envelope";
       "[function: {[boolean: status; boolean: sync; any: result]}]";               "null");
    (`setcallbacks;        1b; "set the symbols backends call back through, for a non-default mount point";
       "[symbol: result callback; symbol: error callback]";                         "null");
    (`setavailableservers; 1b; "swap in a custom server source or routing strategy without forking core dispatch";
       "[function: {[boolean: excludeinuse]} returning a handle/servertype table]"; "null");
    (`setgetnextqueryid;   1b; "inject a priority or custom scheduling strategy";
       "[function: {[]} returning 0 or 1 rows of the query queue]";                 "null");
    (`addserver;           1b; "register a backend handle and servertype so it becomes eligible for dispatch";
       "[int: handle; symbol: servertype]";                                         "null");
    (`removeserverhandle;  1b; "mark a backend inactive on disconnect and error the queries it can no longer satisfy";
       "[int: handle]";                                                             "null");
    (`addclientdetails;    1b; "record client identity on connect, for audit and orphan-query cleanup";
       "[int: handle]";                                                             "null");
    (`removeclienthandle;  1b; "on client disconnect, free their in-flight servers and drop their pending result slots";
       "[int: handle]";                                                             "null");
    (`addserverresult;     1b; "backend callback - fill one result slot and, once all slots are in, join and reply";
       "[long: queryid; any: result]";                                              "null");
    (`addservererror;      1b; "backend callback - short-circuit a query on backend failure and reply the error";
       "[long: queryid; string: error]";                                            "null");
    (`execquery;           1b; "enqueue a query, scatter it to one backend per required servertype and join the results";
       "[any: query; symbol list: servertype; function: join; list: postback; timespan: timeout; boolean: sync]";
       "null: the reply is delivered asynchronously to the calling handle");
    (`execqueryto;         1b; "in-process variant of execquery - replyto is a client handle, or 0Ni to postback locally";
       "[int: replyto; any: query; symbol list: servertype; function: join; list: postback; timespan: timeout; boolean: sync]";
       "null: the reply is delivered asynchronously to replyto");
    (`asyncexec;           1b; "execquery with raze as the join, no postback and no timeout - the common client entry point";
       "[any: query; symbol list: servertype]";
       "null: the reply is delivered asynchronously to the calling handle");
    (`checktimeout;        1b; "error any in-flight query that has waited beyond the timeout execquery recorded for it";
       "[]";                                                                        "null");
    (`removequeries;       1b; "purge completed query rows older than age";
       "[timespan: age]";                                                           "null");
    (`removeinactive;      1b; "purge disconnected server rows older than age";
       "[timespan: age]";                                                           "null");
    (`removeclients;       1b; "purge client audit rows older than age";
       "[timespan: age]";                                                           "null"));
  };

init:{[deps]
  / initialise the asyncdispatch module - validate deps and apply config overrides
  / deps: dict containing `log (required) plus optional config keys:
  /   `log               - required: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) binary loggers
  /   `errorprefix       - optional: string prefix for client error messages. default: "error: "
  /   `querykeeptime     - optional: timespan to keep completed queries. default: 0D00:30
  /   `clearinactivetime - optional: timespan to keep disconnected servers. default: 0D01:00
  /   `synccallsallowed  - optional: boolean, whether sync calls are permitted. default: 0b
  /   `cp                - optional: current-time fn, default {.z.p}. override for sim/backtest.
  /                        setcp does the same thing after init, for a test that swaps the clock
  /                        mid-run; passing it here wins, since init runs later
  / housekeeping (checktimeout; removequeries; removeinactive; removeclients) is the caller's
  / responsibility - wire them into your timer after init; the exported defaults for age params are
  / querykeeptime and clearinactivetime
  / examples:
  /   ad.init[enlist[`log]!enlist logdep]
  /   ad.init[`log`querykeeptime!(logdep;0D01:00)]
  if[99h<>type deps;
    '"di.asyncdispatch: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.asyncdispatch: log dependency is required; pass `info`warn`error!(infofn;warnfn;errfn) keyed on `log"];
  if[99h<>type deps`log;
    '"di.asyncdispatch: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.asyncdispatch: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  / optional config is type-checked HERE so a misconfiguration fails at startup rather than silently
  / at first use. an empty errorprefix is rejected outright: di.dataaccess.shardresult detects a
  / backend error with prefix~(count prefix) sublist result, and an empty prefix matches EVERY string
  / result, so every ordinary string a shard returned would be misread as an error
  checkopt[deps;`errorprefix;{(10h=type x) and 0<count x};"a non-empty string"];
  checkopt[deps;`querykeeptime;{-16h=type x};"a timespan"];
  checkopt[deps;`clearinactivetime;{-16h=type x};"a timespan"];
  checkopt[deps;`synccallsallowed;{-1h=type x};"a boolean"];
  checkopt[deps;`cp;{type[x] within 100 112h};"a function"];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  if[`errorprefix in key deps; .z.m.errorprefix:deps`errorprefix];
  if[`querykeeptime in key deps; .z.m.querykeeptime:deps`querykeeptime];
  if[`clearinactivetime in key deps; .z.m.clearinactivetime:deps`clearinactivetime];
  if[`synccallsallowed in key deps; .z.m.synccallsallowed:deps`synccallsallowed];
  if[`cp in key deps; .z.m.cp:deps`cp];
  .z.m.loginfo[`asyncdispatch;"di.asyncdispatch initialised"];
  };
