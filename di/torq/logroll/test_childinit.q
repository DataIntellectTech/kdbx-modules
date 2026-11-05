/ child process for logroll's redirect tests, run from the repo root
/ usage: q di/torq/logroll/test_childinit.q -cfg <config-builder fn name> -resultdir <dir>

args:.Q.opt .z.x;
cfgname:first args`cfg;
resultdir:first args`resultdir;

system "l di/torq/logroll/test.q";
logroll:use`di.torq.logroll;

cfg:(value cfgname)[];
logroll.init[cfg;mockdeps[]];

/ save addjobcalls for the parent to assert on
(hsym `$resultdir,"/addjobcalls_result") set addjobcalls;

exit 0
