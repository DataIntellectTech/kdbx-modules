/ downstream child for test_integration.csv - not a test file itself; test_integration.q launches it. Runs a REAL
/ di.torq.proc.rdb wired as di.torq wires it (real di.util.log, di.timer, di.torq.handlers, di.torq.servers), pointed at
/ the chained tickerplant as its tickerplant type - so the chained tp's surface is exercised by the consumer it is meant
/ to be indistinguishable to, through di.subscriptions' real subscribe-and-replay. Every -flag value on the command line
/ becomes a config setting as a STRING: -tickerplanttypes -hdbdir -processcsv -proctype -procname -replaylog

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
