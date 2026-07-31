/ standalone helper, spawned as a genuine separate q process by di.torq.logroll's
/ k4unit tests (test.csv/test.q) to exercise the real fd 1/2 redirect without
/ corrupting the parent test runner's own stdout/stderr - logroll.init reassigns
/ whichever process calls it, and the k4unit harness itself needs its own fd 1/2
/ intact to report results. Same "spawn a genuine separate process" precedent
/ di/torq/servers/test.q uses for its own similarly disruptive (self-connect) case.
/ usage: q di/torq/logroll/test_childinit.q -cfg <test.q config-builder fn name> -resultdir <dir>
/ Assumes cwd is the TorqX repo root (same assumption test.q itself documents).

args:.Q.opt .z.x;
cfgname:first args`cfg;
resultdir:first args`resultdir;

system "l di/torq/logroll/test.q";
logroll:use`di.torq.logroll;

cfg:(value cfgname)[];
logroll.init[cfg;mockdeps[]];

/ addjobcalls only exists in this throwaway process's memory - serialize it so the
/ parent test process can load and assert on it after this process exits.
(hsym `$resultdir,"/addjobcalls_result") set addjobcalls;

exit 0
