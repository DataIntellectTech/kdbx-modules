/ a policed HDB on a port, for an agent to query:
/   q di/qsp/examples/agents/server.q [-p 5100] [-db DIR] [-policy DIR] [-audit FILE] [-T 30] [-w 4000] [-U PASSFILE]
/ builds the equities example database if DIR does not exist, loads it, policy/defs.q and the
/ policy, and serves the policy on -p (default 5100). Every IPC call is printed as it arrives, so
/ this terminal shows the agent calling `.qsp.api and running queries, what was rewritten, and
/ what was refused. Defaults to a 30s query timeout unless -T or -notimeout is passed.
/ Run it in the foreground: q exits when its console's input ends

here:{[f] d:$[count i:where f="/";(1+last i)#f;""]; if["/"<>first d;d:system["cd"],"/",d];
  while[d like "*/./*";d:ssr[d;"/./";"/"]]; :d;} string .z.f;
eqdir:here,"../equities/";

if[not @[{get x;1b};`.Q.m.SP;0b];
  -2"qsp needs KDB-X, and this is kdb+ ",string[.z.K]," - run the script with your KDB-X binary";exit 1];
.Q.m.SP:(enlist here,"../../../../"),.Q.m.SP;
qsp:use`di.qsp;
system"l ",eqdir,"mkhdb.q";

o:.Q.opt .z.x;
db:$[`db in key o;first o`db;$[count t:getenv`TMPDIR;t;"/tmp"],"/qsp-example-db"];
if["/"<>first db;db:system["cd"],"/",db];
pdir:$[`policy in key o;first o`policy;eqdir,"policy"];
if["/"<>first pdir;pdir:system["cd"],"/",pdir];
auditfile:$[`audit in key o;first o`audit;""];
if[(count auditfile) and "/"<>first auditfile;auditfile:system["cd"],"/",auditfile];
if[()~key hsym`$db;-1"building the example database in ",db;mkhdb[db;5]];
system"l ",db;
if[not ()~key hsym`$pdir,"/defs.q";system"l ",pdir,"/defs.q"];
qsp.auditto`auditlog;
p:qsp.fromfiles pdir;

\c 30 160
if[(0=system"T") and not `notimeout in key o;system"T 30"];
if[0=system"p";system"p ",$[`port in key o;first o`port;"5100"]];
qsp.serve p;

/ persistent JSONL audit appender
audith:$[count auditfile;hopen hsym`$auditfile;0Ni];
appendaudit:{[r]
  if[null audith;:()];
  rec:`time`user`allowed`decision`query`rewritten`reason!(
    string r`time;r`user;r`allowed;r`decision;r`query;
    $[10h=type r`rewritten;r`rewritten;-3!r`rewritten];r`reason);
  neg[audith] .j.j[rec],"\n";
  };

/ log each IPC request after qsp handles it: what the agent asked for and what happened
origpg:.z.pg;
shown:0;
lognew:{[]
  / print any new rows added to auditlog since the last message
  n:count auditlog;
  if[n<=shown;:()];
  rows:shown _ auditlog;
  shown::n;
  {[r]
    appendaudit r;
    tag:$[r`allowed;"ALLOWED";upper string r`decision];
    -1"\n[",string[`second$r`time],"] ",string[r`user],"  ",tag;
    -1"  sent: ",r`query;
    if[count r`rewritten;-1"  ran:  ",$[10h=type r`rewritten;r`rewritten;-3!r`rewritten]];
    if[count r`reason;-1"  why:  ",r`reason];
    } each rows;
  };

.z.pg:{[x]
  isapi:$[(type x) in 0 11h;(2<=count x)&(first x)~`.qsp.api;0b];
  if[isapi;
    -1"\n[",string[.z.t],"] ",string[.z.u],"  API  ",-3!x];
  if[not isapi;
    qtxt:$[(type x)=10h;x;((type x) in 0 11h)&(3=count x)&(first x) in `.qsp.execas`.qsp.execasx;x 1;-3!x];
    -1"\n[",string[.z.t],"] ",string[.z.u],"  RUN  ",200 sublist qtxt];
  r:@[{(1b;origpg x)};x;{(0b;x)}];
  lognew[];
  if[not r 0;'r 1];
  :r 1;
  };

-1"";
-1"  qsp server listening on port ",string[system"p"];
-1"  database   ",db,"  (",(" "sv string .Q.pv),")";
-1"  policy     ",pdir;
-1"  users      "," "sv string exec distinct user from qsp.access[p;`];
-1"  gateways   "," "sv string p`gateways;
-1"  limits     timeout=",string[system"T"],"s  memcap=",$[0=.Q.w[]`wmax;"none";string[`long$(.Q.w[]`wmax)%1e6],"MB"];
if[count auditfile;-1"  audit log  ",auditfile];
if[not any .z.X in ("-u";"-U");-1"  WARNING    no password file (-u/-U): add -U or .z.pw for production"];
-1"";
-1"  Waiting for queries (Ctrl+C to stop)...";
