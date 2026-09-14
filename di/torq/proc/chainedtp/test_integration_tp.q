/ upstream child for test_integration.csv - not a test file itself; test_integration.q launches it. Runs a REAL
/ di.torq.proc.tickerplant wired to the real di.timer, di.torq.handlers and di.util.log (built as di.torq builds them),
/ so the chained tickerplant under test subscribes to, replays from and is cut off by a genuine tickerplant. Every
/ -flag value on the command line becomes a config setting as a STRING: -tplogdir -schemafile -publishmode -pubperiod

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
