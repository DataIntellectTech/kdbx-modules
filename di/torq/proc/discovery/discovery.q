/ di.torq.proc.discovery - TorQ's discovery service (code/processes/discovery.q) as a kdb-x module

/ subscriptions - handles to list of required proc types
subs:(`int$())!()

register:{
  / add the new handle
  .servers.addw .z.w;
  / If there already was an entry for the same host:port as the supplied handle, close it and delete the entry
  if[count toclose:exec i from .servers.SERVERS where not w=.z.w,hpup in exec hpup from .servers.SERVERS where w=.z.w;
    .servers.removerows toclose];
  / publish the updates
  new:select proctype,procname,hpup,attributes from .servers.SERVERS where w=.z.w;
  (neg ((where ((first new`proctype) in/: .z.m.subs) or .z.m.subs~\:enlist`ALL) inter key .z.W) except .z.w)@\:(`.servers.procupdate;new);
  }

/ get a list of services
getservices:{[proctypes;subscribe]
  .servers.cleanup[];
  if[subscribe;.z.m.subs[.z.w]:proctypes,()];
  distinct select procname,proctype,hpup,attributes from .servers.SERVERS where proctype in ?[(proctypes~`ALL) or proctypes~enlist`ALL;proctype;proctypes],not proctype=`discovery}

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.discovery: log dependency is required - see di.util.log"];
  if[not `handlers in key deps;'"di.torq.proc.discovery: handlers dependency is required - see di.torq.handlers"];
  .z.m.log:deps`log;
  / initialise connections
  .servers.startup config;
  set[`register;register];
  set[`getservices;getservices];
  / add each handle
  @[.servers.addw;;{.z.m.log[`error][`discovery;x]}] each exec w from .servers.SERVERS where .dotz.liveh w,not hpup in exec hpup from .servers.nontorqprocesstab;
  / try to make each server connect back in
  (neg exec w from .servers.SERVERS where .dotz.liveh w,not hpup in exec hpup from .servers.nontorqprocesstab)@\:(`.servers.autodiscovery;`);
  / drop items out of the subscription dictionary on close
  (deps[`handlers]`register)[`.z.pc;`;`discovery;0j;{[W] .z.m.subs:(enlist W) _ .z.m.subs}];
  }
