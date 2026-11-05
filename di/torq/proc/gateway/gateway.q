/ di.torq.proc.gateway - query gateway over di.torq.servers (connections), di.serverselect (registry and routing),
/ di.asyncdispatch (scatter-gather) and di.dataaccess (getdata); entry points are published at root as .gw.*
/ backends register with empty attributes

assym:{[x] $[11h=abs type x;x;`$x]}
aslist:{[x] $[0>type x;enlist x;x]}
/ a token-list config (space-separated string, symbol, symbol list or list of strings) as a symbol list
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}

/ di.dataaccess partition coverage from .z.d: rdb holds today, hdb holds earlier dates
buildpartitions:{[] mid:`timestamp$.z.d; ([]servertype:`rdb`hdb;coverfrom:(mid;-0Wp);coverto:(0Wp;mid-1))}

/ resolve a client's servertype argument (symbol, symbol list or attribute dict) to a servertype symbol list
resolvetypes:{[st]
  $[99h=type st;
    distinct exec servertype from (.z.m.srvsel`getserverstable)[] where serverid in raze (.z.m.srvsel`getserverids)[st];
    aslist assym st]
  }

/ register the connected backends from di.torq.servers into di.serverselect, skipping active handles
registerbackends:{[]
  ct:raze {[t] select w,proctype,procname,hpup from (.z.m.svc`getservers)[t] where not null w} each .z.m.backendtypes;
  if[count ct;
    ct:update attributes:count[ct]#enlist()!() from ct;
    (.z.m.srvsel`addserversfromtable)[.z.m.backendtypes;ct];
    .z.m.log[`info][`gateway;"registered ",(string count ct)," backend server(s): ",", " sv string exec distinct proctype from ct]];
  }

/ during an eod reload, reject a query spanning more than one server type with an error reply and return 1b
ineod:{[types] r:.z.m.eod and 1<count distinct types; if[r;@[neg .z.w;.z.m.errorprefix,"gateway in eod reload - retry shortly";()]]; r}

/ client entry point .gw.getdata: di.dataaccess's getdata behind the reload rule, typed by the partitions the range covers
getdata:{[tablename;starttime;endtime;by;aggs]
  if[ineod exec servertype from .z.m.partitions where coverfrom<=endtime,coverto>=starttime;:()];
  (.z.m.da`getdata)[tablename;starttime;endtime;by;aggs]}

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

/ `permissioned` and di.permissions' own `enabled` are independent, as TorQ's .gw.permissioned is
/ independent of .pm.enabled - a gateway may be permissioned while a backend is not. Setting the
/ one without the other leaves a gateway that believes it is enforcing and is not, so say so.
checkpermissioned:{[]
  if[.z.m.permissioned and not `allowed in key `.pm;
    .z.m.log[`warn][`gateway;"permissioned=1b but di.permissions is not loaded here - queries are NOT checked at this gateway"]];
  }

/ client entry point .gw.asyncexecjpt: join, postback and timeout; errors become a reply to the client
asyncexecjpt:{[query;servertype;join;postback;timeout]
  if[ineod @[resolvetypes;servertype;()];:()];
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

/ client entry point .gw.asyncexec: raze results, no postback, no timeout
asyncexec:{[query;servertype] asyncexecjpt[query;servertype;raze;();0Wn]}

/ eod reload gate .gw.reload: reloadstart rejects multi-type queries; reloadend lifts it and refreshes the
/ backend registry and partitions
reload:{[msg]
  $[msg~`reloadstart;
    [.z.m.eod:1b; .z.m.log[`info][`gateway;"eod reload start - rejecting multi-type queries until reloadend"]];
   msg~`reloadend;
    [.z.m.eod:0b; registerbackends[]; (.z.m.da`setpartitions)[.z.m.partitions:buildpartitions[]]; .z.m.log[`info][`gateway;"eod reload end - resuming queries"]];
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

  / di.serverselect - registry and routing
  .z.m.srvsel:use`di.serverselect;
  (.z.m.srvsel`init)[enlist[`log]!enlist deps`log];

  / di.asyncdispatch - servers from di.serverselect, result and error callbacks published at root .gw.*
  .z.m.ad:use`di.asyncdispatch;
  adcfg:()!();
  if[`synccallsallowed in key config;adcfg:adcfg,enlist[`synccallsallowed]!enlist`boolean$config`synccallsallowed];
  / log dep first, then config
  (.z.m.ad`init)[(enlist[`log]!enlist deps`log),adcfg];
  / param is sel, not ss, which is the built-in string search
  (.z.m.ad`setavailableservers)[{[sel;excludeinuse] select handle,servertype from sel[`getserverstable][] where active}[.z.m.srvsel]];
  set[`.gw.addserverresult;.z.m.ad`addserverresult];
  set[`.gw.addservererror;.z.m.ad`addservererror];
  (.z.m.ad`setcallbacks)[`.gw.addserverresult;`.gw.addservererror];

  / di.torq.servers - connect to the backend types and register them
  .z.m.svc:deps`servers;
  sconfig:config,(enlist`connections)!enlist .z.m.backendtypes;
  (.z.m.svc`startup)[sconfig];
  registerbackends[];
  / register backends that connect later through di.torq.servers' retry or discovery
  set[`.servers.connectcustom;{[rows] registerbackends[]}];

  / di.dataaccess on the same asyncdispatch, with partitions refreshed at reloadend
  .z.m.da:use`di.dataaccess;
  (.z.m.da`init)[`log`timer`partitions!(deps`log;deps`timer;.z.m.partitions:buildpartitions[])];

  / track client connects; on close clean up the handle as a backend and as a client
  hl:deps`handlers;
  (hl`register)[`.z.po;`;`gateway;10;{[wh] (.z.m.ad`addclientdetails)[wh]}];
  (hl`register)[`.z.pc;`;`gateway;10;{[wh] (.z.m.ad`removeserverhandle)[wh]; (.z.m.ad`removeclienthandle)[wh]; (.z.m.srvsel`setserveractive)[wh;0b]}];

  / publish the client entry points and the eod reload gate at root
  set[`.gw.asyncexec;asyncexec];
  set[`.gw.asyncexecjpt;asyncexecjpt];
  set[`.gw.getdata;getdata];
  set[`.gw.reload;reload];

  / housekeeping timers; mode 3h reschedules from the end of the previous run
  (.z.m.timer`addjob)[`gwtimeout;{(.z.m.ad`checktimeout)[]};();0D00:00:05;3h;()!()];
  (.z.m.timer`addjob)[`gwrmqueries;{(.z.m.ad`removequeries)[0D00:30]};();0D00:01;3h;()!()];
  (.z.m.timer`addjob)[`gwrminactive;{(.z.m.ad`removeinactive)[0D01:00]};();0D00:05;3h;()!()];
  (.z.m.timer`addjob)[`gwrmclients;{(.z.m.ad`removeclients)[0D01:00]};();0D00:05;1h;()!()];

  / di.torq calls .gateway.run[] after every module, the rule cascade and app code have loaded,
  / which is the earliest point at which di.permissions' root names are observable - init itself
  / runs before initpermissions, so the check cannot live there.
  set[`.gateway.run;checkpermissioned];
  .z.m.log[`info][`gateway;"initialised, backendtypes=",(", " sv string .z.m.backendtypes)];
  }
