/ check and review a policy kept as files - for CI, and for pull requests
/   q di/qsp/bin/policy.q -dir policy                             check, then who can read what
/   q di/qsp/bin/policy.q -dir new/policy -was old/policy         ...and what the change changes
/   q di/qsp/bin/policy.q -dir p -init defs.q -user alice bob     load q first; only these users
/ exits 1 if the policy would not load, so a broken policy fails the build. Tables not loaded here
/ are described by the policy's schema.csv, so no data is needed. -init loads q that the policy
/ names: fn: filters, clock functions, functions in functions.csv - or the data itself, if you
/ would rather

.Q.m.SP:(enlist {[f] $[count i:where f="/";(1+last i)#f;"./"],"../../../"} string .z.f),.Q.m.SP;
qsp:use`di.qsp;
\c 50 250

o:.Q.opt .z.x;
if[not `dir in key o;-2"usage: q di/qsp/bin/policy.q -dir DIR [-was DIR] [-init FILE ...] [-user U ...]";exit 2];
if[`init in key o;{system"l ",x} each o`init];

/ one problem with a policy, to stderr
showproblem:{[x] -2"  ",string[x`file],$[x`line;":",string x`line;""],": ",x`error;};

problems:{[d]
  / the policy in d, or exit 1 listing what is wrong with it
  if[count e:qsp.check d;
    -2"policy in ",d," does not load:";
    showproblem each e;
    exit 1];
  :qsp.fromfiles d;
  };

p:problems first o`dir;
-1"policy in ",(first o`dir)," loads.\n";
-1"== who can read what";
show qsp.access[p;$[`user in key o;`$o`user;`]];
if[`was in key o;
  w:problems first o`was;
  -1"\n== what changes, from ",first[o`was]," to ",first o`dir;
  show $[count d:qsp.diff[w;p];d;"nothing"]];
exit 0;
