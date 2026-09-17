/ child process for test_integration.csv - not a test file itself; test_integration.q launches it.
/ Runs di.torq.proc.segmentedtp wired to the REAL di.timer, di.torq.handlers and di.util.log (built as di.torq
/ builds them). Every -flag value on the command line becomes a config setting as a STRING (as a .toml or a
/ command-line override would deliver it), so the module's own coercions are exercised: -kdbtplog -schemafile
/ -multilog -batchmode -multilogperiod -rolltimeoffset -replayperiod -tickinterval ...

o:.Q.opt .z.x;
cfg:(key o)!first each value o;
if[not `tickinterval in key cfg;cfg[`tickinterval]:1];
if[`rolltimeoffset in key cfg;cfg[`rolltimeoffset]:"N"$cfg`rolltimeoffset];

lg:use`di.util.log;
logdep:`info`warn`error!(lg`info;lg`warn;lg`error);

tm:use`di.timer;
tm[`init][()!()];
timerdep:`addjob`deletejobs`enablejobs`disablejobs`getactivejobs!((tm`addjob)`custom;tm`deletejobs;tm`enablejobs;tm`disablejobs;tm`getactivejobs);

hz:use`di.torq.handlers;
hz[`init][enlist[`log]!enlist logdep];
handlersdep:`register`remove`list!(hz`register;hz`remove;hz`list);

sp:use`di.torq.proc.segmentedtp;
sp[`init][cfg;`log`timer`handlers!(logdep;timerdep;handlersdep)];
