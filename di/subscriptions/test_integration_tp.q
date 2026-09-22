/ child process for test_integration.csv - not a test file itself; test_integration.q launches it.
/ Runs a REAL di.torq.proc.tickerplant, so the classic single-file protocol is exercised over genuine IPC too -
/ this is the regression half of the dual-protocol dispatch, and it is what proves the probe leads to
/ `.u.subdetails` (which this process publishes) rather than the bare name a segmented TP publishes.

o:.Q.opt .z.x;
cfg:(key o)!first each value o;

lg:use`di.util.log;
logdep:`info`warn`error!(lg`info;lg`warn;lg`error);

tm:use`di.timer;
tm[`init][()!()];
timerdep:`addjob`deletejobs`enablejobs`disablejobs`getactivejobs!((tm`addjob)`custom;tm`deletejobs;tm`enablejobs;tm`disablejobs;tm`getactivejobs);

hz:use`di.torq.handlers;
hz[`init][enlist[`log]!enlist logdep];
handlersdep:`register`remove`list!(hz`register;hz`remove;hz`list);

tp:use`di.torq.proc.tickerplant;
tp[`init][cfg;`log`timer`handlers!(logdep;timerdep;handlersdep)];
