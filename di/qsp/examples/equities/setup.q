/ the setup hdb.q and demo.q share: load qsp, build the example database if it is not there, load
/ it, the q the policy names, and the policy. Expects here, this directory, absolute, and leaves:
/   qsp   the module
/   o     the command line options
/   db    the database directory
/   pdir  the policy directory: policy/ here, or -policy DIR
/   p     the policy, from pdir
/ the database is built with mkhdb.q in -db DIR, or qsp-example-db in $TMPDIR (or /tmp) - never
/ inside the module, which is copied as a unit

/ kdb+ 4.x has no module system, and would fail below with a bare '.Q.m.SP
if[not @[{get x;1b};`.Q.m.SP;0b];
  -2"qsp needs KDB-X, and this is kdb+ ",string[.z.K]," - run the script with your KDB-X binary";exit 1];
.Q.m.SP:(enlist here,"../../../../"),.Q.m.SP;
qsp:use`di.qsp;
system"l ",here,"mkhdb.q";

/ ------------------------------------------------------------------ the database

o:.Q.opt .z.x;
db:$[`db in key o;first o`db;$[count t:getenv`TMPDIR;t;"/tmp"],"/qsp-example-db"];
if["/"<>first db;db:system["cd"],"/",db];
pdir:$[`policy in key o;first o`policy;here,"policy"];
if["/"<>first pdir;pdir:system["cd"],"/",pdir];
if[()~key hsym`$db;-1"building the example database in ",db;mkhdb[db;5]];
system"l ",db;

/ ------------------------------------------------------------------ what the policy names
/ the lookups its filters call and its clock. They live with the policy, so a change to them is
/ reviewed with the grants that call them, and CI loads the same file to check the policy

system"l ",pdir,"/defs.q";

/ qsp's decision log, under the name the policy grants to compliance
qsp.auditto`auditlog;

/ ------------------------------------------------------------------ the policy

p:qsp.fromfiles pdir;
