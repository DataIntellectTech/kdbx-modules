/ child process for test_integration.csv - not a test file itself; test_integration.q launches it. A SUBSCRIBER:
/ an ordinary process running the REAL di.torq.servers (so it carries the root .torq.servers.addprocs push target)
/ whose only phone-book connection is a discovery service. Once connected it calls .discovery.getservices over
/ that handle with subscribe=1b for the proctypes in -want (`ALL for everything; the literal "none" means never
/ subscribe - the control case that must receive nothing). Its own retry job then opens whatever discovery pushes.
/ Flags: -processcsv -proctype -procname -want

o:.Q.opt .z.x;
cfg:(key o)!first each value o;
cfg[`proctype]:`$cfg`proctype;
cfg[`procname]:`$cfg`procname;
want:`$" " vs cfg`want;

lg:use`di.util.log;
logdep:`info`warn`error!(lg`info;lg`warn;lg`error);

tm:use`di.timer;
tm[`init][()!()];
timerdep:`addjob`deletejobs`enablejobs`disablejobs`getactivejobs!((tm`addjob)`custom;tm`deletejobs;tm`enablejobs;tm`disablejobs;tm`getactivejobs);

hz:use`di.torq.handlers;
hz[`init][enlist[`log]!enlist logdep];
handlersdep:`register`remove`list!(hz`register;hz`remove;hz`list);

srv:use`di.torq.servers;
srv[`init][cfg,`log`timer`handlers!(logdep;timerdep;handlersdep)];
(srv`startup)[cfg,enlist[`connections]!enlist enlist`discovery];

/ the one thing a consumer does to be told about services: one getservices call with subscribe on
subscribe:{[types]
  h:(srv`gethandlebytype)[`discovery;`any];
  if[null h;'"sub: no discovery connection"];
  h(`.discovery.getservices;types;1b)
  };
ANSWER:();
if[not `none in want;
  if[not (srv`waitfortype)[`discovery;30000;250];'"sub: discovery never came up"];
  ANSWER:subscribe want];

/ root helpers for the parent suite to inspect this process
registry:{[] (srv`getallservers)[]};
known:{[] select procname,proctype,hpup,w from registry[] where not proctype=`discovery};
