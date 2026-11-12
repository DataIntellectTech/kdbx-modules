/ the process test.csv talks to over IPC:   q di/qsp/testserver.q -p PORT
/ serves the fixtures' policy, and exits when its last client disconnects
/ (an exit sent over IPC would be refused - it is not on the whitelist)

.Q.m.SP:(enlist {[f] $[count i:where f="/";(1+last i)#f;"./"],"../../"} string .z.f),.Q.m.SP;
qsp:use`di.qsp;
system"l ",.Q.m.mp[`di.qsp],"/test.q";

qsp.serve P;
/ .z.pc also fires for handle 0 when stdin closes, so only a client counts
.z.pc:{if[(x>0)&0=count .z.W;exit 0];};
/ never outlive a crashed test run (the first tick fires at once, so time it)
.t.start:.z.p;
.z.ts:{if[.z.p>.t.start+0D00:01;exit 1];};
\t 1000
