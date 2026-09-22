/ child process for test_integration.csv - not a test file itself; test_integration.q launches it.
/ Runs a REAL di.torq.proc.segmentedtp wired to the real di.timer, di.torq.handlers and di.util.log (as di.torq
/ builds them), so the subscriber under test talks to the genuine segmented protocol over IPC rather than a mock.
/ Every -flag value on the command line becomes a config setting as a STRING, as a .toml or command-line override
/ would deliver it. Owned by this suite rather than shared with di.torq.proc.segmentedtp's, matching the precedent
/ di.torq.proc.chainedtp set with its own test_integration_tp.q.

o:.Q.opt .z.x;
cfg:(key o)!first each value o;
if[not `tickinterval in key cfg;cfg[`tickinterval]:1];

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
