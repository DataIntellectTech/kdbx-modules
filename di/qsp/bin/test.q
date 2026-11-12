/ run di.qsp's k4unit tests, and exit 1 if any fail - for CI
/   QPATH=/path/to/kdbx-modules q di/qsp/bin/test.q -q
/ di.k4unit comes from the kdbx-modules repository; this repository is found from this file

.Q.m.SP:(enlist {[f] $[count i:where f="/";(1+last i)#f;"./"],"../../../"} string .z.f),.Q.m.SP;
k4unit:use`di.k4unit;
k4unit.verbose 1;
k4unit.moduletest`di.qsp;
r:k4unit.getresults[];
-1"\npassed: ",string[sum r`ok],"  failed: ",string sum not r`ok;
exit `long$not all r`ok;
