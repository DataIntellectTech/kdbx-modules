/ the process test.csv talks to over IPC:   q di/qsp/test/server.q -p PORT
/ serves the fixtures' policy, and exits when its last client disconnects
/ (an exit sent over IPC would be refused - it is not on the whitelist)

.Q.m.SP:(enlist {[f] $[count i:where f="/";(1+last i)#f;"./"],"../../../"} string .z.f),.Q.m.SP;
qsp:use`di.qsp;
system"l ",.Q.m.mp[`di.qsp],"/test.q";

/ what was on the handlers before serve must still see every policed query: a wrapper that
/ keeps each message in a table the fixtures' user may read
seen:([]h:`symbol$();m:());
.z.pg:{[x] `seen upsert `h`m!(`pg;x); value x};
.z.ps:{[x] `seen upsert `h`m!(`ps;x); value x};
P:qsp.grant[qsp.table[P;`seen;::];`llm;`seen;qsp.ALL;()];
/ a second gateway, scoped to the llm group: it may name llmu and junior, and no one else
P:qsp.scopegateway[P;`gwllm;`llm];
qsp.serve P;
/ .z.pc also fires for handle 0 when stdin closes, so only a client counts
.z.pc:{if[(x>0)&0=count .z.W;exit 0];};
/ never outlive a crashed test run (the first tick fires at once, so time it)
.t.start:.z.p;
.z.ts:{if[.z.p>.t.start+0D00:01;exit 1];};
\t 1000
