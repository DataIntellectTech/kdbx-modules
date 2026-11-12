/ harden/server.q - the policed HDB server harden.sh attacks, with harmless canaries planted.
/ Args: -modroot DIR -db HDB -poldir DIR -rundir DIR [-p PORT] [-T N]

o:.Q.opt .z.x;
modroot:first o`modroot;
db:first o`db;
poldir:first o`poldir;
rundir:first o`rundir;

.Q.m.SP:(enlist modroot),.Q.m.SP;
qsp:use`di.qsp;

system"l ",db;
system"l ",poldir,"/defs.q";

/ Plant harmless defensive test canaries:
/ 1. A canary function that records whether any query managed to invoke it
canary_file:hsym`$rundir,"/canary_called";
canaryfn:{[x] canary_file 0: enlist "called"; :42;};

/ 2. An unregistered in-memory table that no policy grants access to
secret_table:([]secret_id:1 2 3;pass:`alpha`beta`gamma);

/ 3. A harmless marker file on disk to test whether file deletion (hdel/not) is blocked
keep_file:hsym`$rundir,"/canary_keep_file";
keep_file 0: enlist "keep";

qsp.auditto`auditlog;
p:qsp.fromfiles poldir;
qsp.serve p;
if[0=system"p";-2"FATAL: failed to bind port";exit 1];

/ Fail-safe shutdown after 180 seconds so an orphaned server never lingers
.t.start:.z.p;
.z.ts:{if[.z.p>.t.start+0D00:03;exit 0];};
\t 1000
