/ child process for test_integration.csv - not a test file itself; test_integration.q launches it. Runs
/ di.torq.proc.discovery wired the way di.torq wires it: the REAL di.util.log, di.timer, di.torq.handlers and -
/ built last, as it consumes the other three - di.torq.servers, whose init takes this process's identity and the
/ process.csv phone book from the config. Every -flag value on the command line becomes a config setting as a
/ STRING (as a raw command-line override would deliver it), so the module's own coercions are exercised:
/ -processcsv -proctype -procname -retryperiod -tracknontorqprocess -nontorqprocessfile (and servers' -hopentimeout)

o:.Q.opt .z.x;
cfg:(key o)!first each value o;
/ di.torq.servers requires its self-identity as symbols (di.torq stamps them so)
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
serversdep:`startup`getservers`getallservers`removeprocs`gethandlebytype`waitfortype!(srv`startup;srv`getservers;srv`getallservers;srv`removeprocs;srv`gethandlebytype;srv`waitfortype);

disc:use`di.torq.proc.discovery;
disc[`init][cfg;`log`timer`handlers`servers!(logdep;timerdep;handlersdep;serversdep)];

/ root helpers for the parent suite to inspect this process
registry:{[] (srv`getallservers)[]};
live:{[] select procname,proctype,hpup from registry[] where not null w};
