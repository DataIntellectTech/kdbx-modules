/ downstream child for test_integration.csv - not a test file itself; test_integration.q launches it. Runs a REAL
/ di.torq.proc.rdb wired exactly as di.torq wires it (real di.util.log, di.timer, di.torq.handlers, di.torq.servers),
/ pointed at a REAL di.torq.proc.segmentedtp as its tickerplant type. That is the path a TorqX deployment takes, and
/ the one thing the rest of this suite does NOT cover: everywhere else in here, THIS process plays the subscriber, so
/ di.subscriptions is exercised but di.torq.proc.rdb never is. Owned by this suite rather than shared with
/ di.torq.proc.chainedtp's, matching the precedent that each suite owns its own children.
/ Every -flag value on the command line becomes a config setting as a STRING:
/ -tickerplanttypes -hdbdir -processcsv -proctype -procname

o:.Q.opt .z.x;
cfg:(key o)!first each value o;
cfg[`proctype]:`$cfg`proctype;
cfg[`procname]:`$cfg`procname;

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
serversdep:`startup`getservers`gethandlebytype`waitfortype!(srv`startup;srv`getservers;srv`gethandlebytype;srv`waitfortype);

rdb:use`di.torq.proc.rdb;
rdb[`init][cfg;`log`timer`handlers`servers!(logdep;timerdep;handlersdep;serversdep)];
