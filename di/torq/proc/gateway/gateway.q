/ di.torq.proc.gateway - query gateway. Orchestration glue wiring three pieces into a queryable front end:
/   di.torq.servers        - discover + connect to backend processes (rdb/hdb)
/   di.serverselect   - registry of backends + servertype/attribute routing (VENDORED)
/   di.asyncdispatch  - async scatter-gather: queue -> dispatch -> collect -> join -> reply (VENDORED)
/ Publishes .gw.* entry points; a client sends a query + a list of servertypes, the gateway routes it
/ to one backend of each type, joins the per-server results, and replies (deferred-sync/async).
/ Ported from the .gw orchestration in TorQ/code/processes/gateway.q; the engine + routing are the
/ two vendored modules, so di.torq.proc.gateway is thin glue.
/ ---
/ Scope (v1): async / deferred-sync only. Routing by servertype list (the happy path) and by
/ attribute dict (via di.serverselect) - but attribute routing needs backends to REPORT attributes
/ (tables/date-ranges), which di.torq.servers/di.torq.proc.rdb/di.torq.proc.hdb don't do yet, so v1 registers backends with
/ EMPTY attributes and attribute-dict queries degrade/err until that plumbing lands. Deferred:
/ di.dataaccess (typed getdata + map-reduce), pure-sync syncexec, permissions, kxdash. Removed:
/ finspace. Known v1 limitation: with the server source pointed at di.serverselect (which has no
/ inuse state), there is no per-backend one-query-at-a-time serialisation - fine for POC volumes.
/ ---
/ Module-namespace note: the .gw.* functions and the asyncdispatch callbacks are published at REAL
/ root names (set[`.gw...;...]) - use mangles module code into a private namespace, so a remote
/ client call or a backend's async result reply must resolve at root. Same pattern as .hdb.reload.

assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}
/ a token-list config (e.g. backendtypes/reloadorder): space-separated string, single symbol,
/ symbol list, or list of strings -> always a symbol list
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}

/ di.dataaccess routing coverage from the current date: rdb holds today (>= midnight), hdb holds
/ history (< midnight). Built at init and re-evaluated at EOD reloadend (after the wdb moves today's
/ partition into the hdb, ".z.d" has advanced so "today" now correctly falls to the hdb).
buildpartitions:{[] mid:`timestamp$.z.d; ([]servertype:`rdb`hdb;coverfrom:(mid;-0Wp);coverto:(0Wp;mid-1))}

/ resolve a client's servertype argument to a plain servertype symbol list.
/ symbol / symbol list -> itself. attribute dict (99h) -> the distinct servertypes of the servers
/ di.serverselect matches (asyncdispatch dispatches by servertype, one handle per type).
resolvetypes:{[st]
  $[99h=type st;
    distinct exec servertype from (.z.m.srvsel`getserverstable)[] where serverid in raze (.z.m.srvsel`getserverids)[st];
    aslist assym st]
  }

/ (re)register the connected backends from di.torq.servers into di.serverselect (idempotent - it skips
/ already-active handles). v1 registers with empty attributes (no backend attribute reporting yet).
registerbackends:{[]
  ct:raze {[t] select w,proctype,procname,hpup from (.z.m.svc`getservers)[t] where not null w} each .z.m.backendtypes;
  if[count ct;
    ct:update attributes:count[ct]#enlist()!() from ct;
    (.z.m.srvsel`addserversfromtable)[.z.m.backendtypes;ct];
    .z.m.log[`info][`gateway;"registered ",(string count ct)," backend server(s): ",", " sv string exec distinct proctype from ct]];
  }

/ --- permission hooks (di.permissions) ---------------------------------------------------
/ di.permissions publishes .pm.allowed and .pm.execas at root when it is loaded and enabled.
/ Both are tested for presence, as TorQ's gateway does, so a gateway running without the module
/ behaves exactly as it did before.

/ may this user run this query through the gateway at all
permitted:{[u;query] $[`allowed in key `.pm;.pm.allowed[u;query];1b]}

/ rewrite a query so the BACKEND re-checks it as the original user, rather than trusting the
/ gateway as the enforcement point. The guard runs at the backend, not here: the gateway cannot
/ know whether a given backend has permissions loaded, so the test travels with the query.
execas:{[query;u] ({[u;q] $[`execas in key `.pm;.pm.execas[q;u];$[`valp in key `.pm;.pm.valp q;value q]]};u;query)}

/ client entry point (published at root as .gw.asyncexecjpt): full control over join/postback/timeout.
/ protected so a routing/dispatch error becomes a formatted reply to the client rather than an
/ uncaught error on the async handler.
asyncexecjpt:{[query;servertype;join;postback;timeout]
  if[.z.m.eod;@[neg .z.w;.z.m.errorprefix,"gateway in eod reload - retry shortly";()];:()];
  u:.z.u;
  if[.z.m.permissioned;
    if[not permitted[u;query];
      @[neg .z.w;.z.m.errorprefix,"user is not permissioned to run this query from the gateway";()];
      :();
    ]];
  / unpermissioned, execas is the identity on the query, so the dispatch is unchanged
  q:$[.z.m.permissioned;execas[query;u];query];
  .[{[q;s;j;p;t] (.z.m.ad`execquery)[q;resolvetypes s;j;p;t;0b]};
    (q;servertype;join;postback;timeout);
    {[e] @[neg .z.w;.z.m.errorprefix,e;()]}];
  }

/ client entry point (published at root as .gw.asyncexec): raze results, no postback, no timeout.
asyncexec:{[query;servertype] asyncexecjpt[query;servertype;raze;();0Wn]}

/ EOD reload gate (published at root as .gw.reload) - the wdb calls (`.gw.reload;`reloadstart) before
/ moving its partition into the hdb and (`.gw.reload;`reloadend) after the hdb/rdb have reloaded.
/ While gated, new queries are rejected (client retries) so none straddle the rdb-drop/hdb-reload
/ window. v1 rejects rather than queues-and-resumes; on reloadend it refreshes the backend registry.
reload:{[msg]
  $[msg~`reloadstart;
    [.z.m.eod:1b; .z.m.log[`info][`gateway;"eod reload start - holding new queries"]];
   msg~`reloadend;
    [.z.m.eod:0b; registerbackends[]; (.z.m.da`setpartitions)[buildpartitions[]]; .z.m.log[`info][`gateway;"eod reload end - resuming queries"]];
   .z.m.log[`warn][`gateway;"unknown .gw.reload message: ",string msg]];
  }

init:{[config;deps]
  if[not all `log`timer`handlers`servers in key deps;'"di.torq.proc.gateway: log, timer, handlers and servers dependencies are required (servers is injected by di.torq)"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.backendtypes:$[`backendtypes in key config;astoklist config`backendtypes;`rdb`hdb];
  .z.m.errorprefix:$[`errorprefix in key config;config`errorprefix;"error: "];
  / check queries against di.permissions before dispatching, and run them on the backends as the
  / calling user. Independent of di.permissions' own `enabled`, as TorQ's .gw.permissioned is
  / independent of .pm.enabled - a gateway may be permissioned while a backend is not.
  .z.m.permissioned:$[`permissioned in key config;`boolean$config`permissioned;0b];
  .z.m.eod:0b;

  / di.serverselect - registry + routing. log dep is binary {[c;m]}, matching di.torq's inject.
  .z.m.srvsel:use`di.serverselect;
  (.z.m.srvsel`init)[enlist[`log]!enlist deps`log];

  / di.asyncdispatch - scatter-gather engine. Point its server SOURCE at di.serverselect (no inuse
  / column there, so excludeinuse is ignored - see the scope note). Publish its result/error
  / callbacks at root .gw.* and tell it to reply to those names (baked into the shipped executor by
  / the vendor patch, so backends need no cooperating code).
  .z.m.ad:use`di.asyncdispatch;
  adcfg:enlist[`log]!enlist deps`log;
  if[`synccallsallowed in key config;adcfg[`synccallsallowed]:`boolean$config`synccallsallowed];
  (.z.m.ad`init)[adcfg];
  / NB: param is `sel`, NOT `ss` - `ss` is the built-in string-search function and q would
  / resolve ss[...] to the builtin instead of the projected serverselect dict (throws 'match).
  (.z.m.ad`setavailableservers)[{[sel;excludeinuse] select handle,servertype from sel[`getserverstable][] where active}[.z.m.srvsel]];
  set[`.gw.addserverresult;.z.m.ad`addserverresult];
  set[`.gw.addservererror;.z.m.ad`addservererror];
  (.z.m.ad`setcallbacks)[`.gw.addserverresult;`.gw.addservererror];

  / di.torq.servers - connect out to the backend process types, then register them into serverselect.
  / Uses the INJECTED di.torq.servers (di.torq already ran init); we call only startup with our own
  / backend connection list, and getservers off the same injected instance (registerbackends).
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist .z.m.backendtypes;
  (.z.m.svc`startup)[sconfig];
  registerbackends[];
  / a backend that was down at startup connects later through di.torq.servers' retry/discovery,
  / which fires .servers.connectcustom - hook it so serverselect learns about the late arrival.
  / Without this the gateway holds a live handle it can never route to until a restart or EOD.
  set[`.servers.connectcustom;{[rows] registerbackends[]}];

  / di.dataaccess - the getdata query-normalisation layer, on top of the SAME asyncdispatch
  / instance (idempotent use) so it dispatches via the callbacks/registry set up above. Partition
  / coverage for routing is built from .z.d (buildpartitions) and refreshed at EOD reloadend via
  / (.z.m.da`setpartitions), so post-roll queries for the just-saved day route to the hdb not the rdb.
  .z.m.da:use`di.dataaccess;
  (.z.m.da`init)[`log`timer`partitions!(deps`log;deps`timer;buildpartitions[])];

  / handler callbacks via the injected handlers dep (di.torq.handlers): track client connect, and on any
  / handle close clean up whichever role it was - backend (asyncdispatch in-flight cleanup +
  / serverselect deactivate) or client (asyncdispatch orphan-query cleanup). Each is a no-op for
  / the other role, so calling all three on every close is safe.
  hl:deps`handlers;
  (hl`register)[`.z.po;`;`gateway;10;{[wh] (.z.m.ad`addclientdetails)[wh]}];
  (hl`register)[`.z.pc;`;`gateway;10;{[wh] (.z.m.ad`removeserverhandle)[wh]; (.z.m.ad`removeclienthandle)[wh]; (.z.m.srvsel`setserveractive)[wh;0b]}];

  / publish the client entry points + the eod reload gate at root. .gw.getdata is the
  / normalised query layer (di.dataaccess); the raw asyncexec/asyncexecjpt route query strings.
  set[`.gw.asyncexec;asyncexec];
  set[`.gw.asyncexecjpt;asyncexecjpt];
  set[`.gw.getdata;.z.m.da`getdata];
  set[`.gw.reload;reload];

  / housekeeping timers (asyncdispatch leaves scheduling to the caller). mode 1h period = seconds.
  (.z.m.timer`addjob)[`gwtimeout;{(.z.m.ad`checktimeout)[]};();5;1h;()!()];
  (.z.m.timer`addjob)[`gwrmqueries;{(.z.m.ad`removequeries)[0D00:30]};();60;1h;()!()];
  (.z.m.timer`addjob)[`gwrminactive;{(.z.m.ad`removeinactive)[0D01:00]};();300;1h;()!()];
  (.z.m.timer`addjob)[`gwrmclients;{(.z.m.ad`removeclients)[0D01:00]};();300;1h;()!()];

  .z.m.log[`info][`gateway;"initialised, backendtypes=",(", " sv string .z.m.backendtypes)];
  }
