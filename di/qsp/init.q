/ di.qsp - qSQL security policy, as a KDB-X module
/   qsp:use`di.qsp
/   p:qsp.policy[]
/   p:qsp.table[p;`trade;::]
/   p:qsp.grant[p;`llm;`trade;`date`sym`size;enlist qsp.f.isin[`account;`A1`A2]]
/   p:qsp.member[p;`alice;`llm]
/   qsp.run[p;`alice;"select sum size by sym from trade"]
/   qsp.serve p                 / police every IPC query with p
/ row- and column-level permissioning for q written by something you do not trust: an LLM, a
/ notebook, a reporting tool. A query is parsed - never evaluated - and every node of its tree
/ must be explicitly permitted; the tree is then rewritten to pin the caller's row filter and
/ column projection before it runs. Anything qsp does not understand is refused
/ the pieces, each a submodule:
/   tree    the shape of a parse tree, detected from q's own parser
/   fns     the function whitelist
/   policy  a policy as a value, and what it resolves to per user
/   order   where the row filter goes in a where clause
/   walk    the walker and rewriter
/   f       row filter builders
/   files   a policy kept as a directory of CSVs
/   review  what a policy means: who can read what, what a change changes
/ this file is the pipeline (parse, rewrite, pre-checks, evaluate, bound), the audit log, and the
/ message handlers

tree:use`.tree;
pol:use`.policy;
ord:use`.order;
walker:use`.walk;
f:use`.f;
polfiles:use`.files;
rev:use`.review;

/ module version from the VERSION file
version:first read0`:::VERSION;

ispolicy:{[x] :(99h=type x)and all `tabs`schema`grants`members`fns`config in key x;};
chkpolicy:{[x] tree.chk[ispolicy x;"not a qsp policy - build one with qsp.policy[]"];};

/ ------------------------------------------------------------------ rendering

render:{[x]
  / x as text at q's widest: -3! obeys the console width (\c), and at the default 80 a long
  / projection - exactly where the masking shows - is cut to ".."
  c:system"c";
  system"c 25 2000";
  r:@[-3!;x;{"<unrenderable>"}];
  system"c ",(" " sv string c);
  :r;
  };

/ ------------------------------------------------------------------ audit
/ every decision taken by run: who, what was asked, the tree that ran (as a parse tree - lossless,
/ and eval-able), and the decision:
/   `allowed  the query ran and returned
/   `denied   a permission decision: a column, table, function, write, limit
/   `error    nothing was withheld: the text was not q, or q itself could not evaluate a query
/             qsp had already permitted
/ the log is a table held in a global, private to the module by default. auditto moves it to a
/ name of your choosing - which can then be registered in a policy and granted to an auditor like
/ any other table

decisions:([]time:`timestamp$();user:`symbol$();query:();rewritten:();
  allowed:`boolean$();decision:`symbol$();reason:());
/ the global name the log is kept under
logname:.z.M.decisions;

record:{[p;u;q;rw;d;m]
  / add a decision to the audit log, keeping at most auditmax rows
  if[not p[`config;`audit];:()];
  logname upsert ([]time:enlist .z.p;user:enlist u;query:enlist $[10h=abs type q;q;render q];
    rewritten:enlist rw;allowed:enlist d=`allowed;decision:enlist d;reason:enlist m);
  if[p[`config;`auditmax]<count get logname;logname set neg[p[`config;`auditmax]] sublist get logname];
  };

audit:{[] :get logname;};
clearaudit:{[] logname set 0#get logname;};
audittable:{[] :logname;};

auditto:{[n]
  / keep the log under global n from now on, carrying over what is there
  tree.chk[(-11h=type n)and not null n;"auditto takes a global name"];
  if[n~logname;:()];
  n set get logname;
  .z.m.logname:n;
  };

/ ------------------------------------------------------------------ pipeline

/ a query that does not parse is q rejecting it, not qsp withholding anything: name it as such,
/ so a caller knows a bracket would fix it
toparse:{[x] :$[10h=abs type x;@[parse;x;{'"qsp: not valid q (",tree.described[x],")"}];x];};

/ the rows in a result: a table's rows, the items of a list, and the longest column of a
/ dictionary or list of columns - exec a,b from t is a dictionary of two columns
rows:{[v]
  t:type v;
  if[t<0;:1];
  if[t=98h;:count v];
  if[t=99h;:$[98h=type key v;count v;max (count v),count each value v]];
  if[t=0h;:max (count v),count each v];
  :count v;
  };

sizecheck:{[cfg;v]
  / maxsize and maxrows bound the result, not the work: by the time they are consulted the query
  / has run. See requirepartition for the work
  if[not cfg[`maxsize]>-22!v;:"result exceeds the maximum permitted size"];
  if[cfg[`maxrows]<rows v;:"result exceeds the maximum permitted row count"];
  :"";
  };

/ does base query x prune its table's partitions?
prunedby:{[p;x] :ord.prunes[pol.info[p;x 1];tree.getc x 2];};

/ the tables a rewritten query would read end to end - every partition
scanned:{[p;rw] b:tree.basequeries rw; :`symbol$distinct {x 1} each b where not prunedby[p] each b;};

/ the refusal for table t, scanned end to end
needs:{[p;t] :string[t]," needs a constraint on `",string p[`tabs;t];};

partitioncheck:{[p;rw]
  / the one check that bounds the work, run before anything is evaluated. The refusal names the
  / table and the column it needs, because the caller is usually a query generator that can
  / repair the query given those two facts
  if[not p[`config;`requirepartition];:""];
  if[0=count s:scanned[p;rw];:""];
  :"full table scan: ","; " sv needs[p] each s;
  };

isqsp:{[m] :(10h=type m)and(5<=count m)and"qsp: "~5#m;};

refuse:{[p;u;q;rw;d;m]
  / record a refusal, and signal it
  m:tree.prefix tree.described tree.clean m;
  record[p;u;q;rw;d;m];
  'm;
  };

/ (1b;the rewritten tree)
tryrewrite:{[p;u;q] :(1b;walker.rewrite[walker.ctx[p;u;q];q]);};

go:{[p;u;q]
  / parse, rewrite, pre-check, evaluate, bound - recording the decision. Every gate lives here,
  / and the decision kind follows from the stage that refused. Returns (result; rewritten tree)
  chkpolicy p;
  s:@[{(1b;toparse x)};q;{(0b;x)}];
  if[not s 0;refuse[p;u;q;();`error;s 1]];
  r:@[tryrewrite[p;u];s 1;{(0b;x)}];
  if[not r 0;refuse[p;u;q;();$[tree.isfault r 1;`error;`denied];r 1]];
  rw:r 1;
  if[count m:partitioncheck[p;rw];refuse[p;u;q;rw;`denied;m]];
  v:@[{(1b;eval x)};rw;{(0b;x)}];
  / a qsp check the walker placed in the tree refused a value the query computed
  if[not v 0;refuse[p;u;q;rw;$[isqsp v 1;`denied;`error];v 1]];
  if[count m:sizecheck[p`config;v 1];refuse[p;u;q;rw;`denied;m]];
  record[p;u;q;rw;`allowed;""];
  :(v 1;rw);
  };

/ ------------------------------------------------------------------ the api

/ run[p;u;q] -> the result of q, as user u under policy p. Signals a refusal
run:{[p;u;q] :first go[p;u;q];};
/ runx[p;u;q] -> (result; what actually ran, rendered) - for a caller that must show its user
/ what its query was turned into
runx:{[p;u;q] r:go[p;u;q]; :(r 0;render r 1);};
/ rewrite[p;u;q] -> the safe parse tree. Signals a refusal. Evaluates nothing
rewrite:{[p;u;q] chkpolicy p; q:toparse q; :@[walker.rewrite[walker.ctx[p;u;q]];q;{'tree.clean x}];};
/ explain[p;u;q] -> what would run, as text - the thing to paste into a ticket when someone asks
/ why they saw fewer rows than they expected
explain:{[p;u;q] :render rewrite[p;u;q];};
/ validate[p;u;q] -> (allowed;reason). Evaluates nothing, records nothing
validate:{[p;u;q] :2#@[{(1b;"";rewrite[x;y;z])}[p;u];q;{(0b;x)}];};
/ fullscans[p;u;q] -> tables q would read every partition of
fullscans:{[p;u;q] :scanned[p;rewrite[p;u;q]];};

/ ------------------------------------------------------------------ serving
/ serve[p] polices every IPC query with p. Call it again with a new policy to swap it in
/ atomically. The local console (.z.w=0) is not policed: whoever holds the console holds the data
/ a gateway authenticates the end user and queries over its own login, so it forwards the caller
/ explicitly, as (`.qsp.execas;query;user). That is honoured only for logins the policy names with
/ qsp.gateway; from anyone else it is an ordinary - and refused - call. The wire format is fixed
/ and never resolved as a name, so it needs no global to exist

execas:`.qsp.execas;
execasx:`.qsp.execasx;
served:(::);
installed:0b;

/ is message x a gateway, named in policy p, running a query as another user?
isgatewaycall:{[p;x]
  if[not (0h=type x)&3=count x;:0b];
  if[not .z.u in p`gateways;:0b];
  :any (first x)~/:(execas;execasx);
  };

/ ------------------------------------------------------------------ logins
/ qsp authorises; it does not authenticate. It trusts .z.u, the name a client logged in as, and q
/ accepts any name unless something checks it. serve installs a .z.pw that admits only the served
/ policy's users and its gateway logins: a name the policy doesn't know, or a group's name, cannot
/ connect. A user is a name in members or grants that is not a group (review.users), so `sales`
/ cannot log in and pick up the sales group's grants. It checks names, not passwords. -u/-U run
/ before .z.pw, and a .z.pw defined before the first serve - LDAP, say - is kept and called after
/ the name check, so put real authentication there

priorpw:{[u;pw] 1b};
/ may u connect to, or be named in a gateway call to, a process serving policy p?
isuser:{[p;u] :$[-11h=type u;u in rev.users p;0b];};
islogin:{[p;u] :(u in p`gateways) or isuser[p;u];};
login:{[u;pw] :$[islogin[served;u];priorpw[u;pw];0b];};

req:{[x]
  / a message handler: run x as the caller, under the served policy
  if[0=.z.w;:value x];
  p:served;
  / .z.pw admits only logins of the policy served when the connection opened. Check again: the
  / policy may have been swapped since, or .z.pw replaced
  if[not islogin[p;.z.u];refuse[p;.z.u;x;();`denied;"not a user of this policy: ",-3!.z.u]];
  if[isgatewaycall[p;x];
    / a user that is not a single symbol is refused, and logged against the gateway's own login
    if[not isuser[p;x 2];refuse[p;$[-11h=type x 2;x 2;.z.u];x 1;();`denied;"not a user of this policy: ",-3!x 2]];
    :$[execas~first x;run;runx][p;x 2;x 1]];
  :run[p;.z.u;x];
  };

install:{[]
  / the message handlers: logins are checked, queries are policed; HTTP and websockets are refused
  .z.m.priorpw:@[get;`.z.pw;{{[u;pw] 1b}}];
  .z.pw:login;
  .z.pg:req;
  .z.ps:req;
  .z.pi:{$[x in (1#"\n";"");.Q.s value x;.Q.s req x]};
  .z.ph:{'"qsp: HTTP access is not permitted"};
  .z.pp:{'"qsp: HTTP access is not permitted"};
  .z.ws:{'"qsp: websocket access is not permitted"};
  .z.m.installed:1b;
  };

serve:{[p]
  / police every IPC query with p, swapping it in for any policy served before
  chkpolicy p;
  .z.m.served:p;
  if[not installed;install[]];
  };
active:{[] :served;};

/ what a gateway sends a qsp backend, to run q as user u
gatewaywrap:{[q;u] :(execas;q;u);};
gatewaywrapx:{[q;u] :(execasx;q;u);};

export:([
  / build a policy - each returns a new policy
  policy:pol.new;table:pol.table;partition:pol.partition;refresh:pol.refresh;
  droptable:pol.droptable;grant:pol.grant;revoke:pol.revoke;member:pol.member;
  unmember:pol.unmember;allowfunction:pol.allowfunction;denyfunction:pol.denyfunction;
  allowcall:pol.allowcall;allowjoincall:pol.allowjoincall;denycall:pol.denycall;
  gateway:pol.gateway;configure:pol.configure;
  / keep one as files
  fromfiles:polfiles.fromfiles;check:polfiles.check;scaffold:polfiles.scaffold;
  / inspect one
  columnsfor:pol.columnsfor;filterfor:pol.filterfor;access:rev.access;diff:rev.diff;
  / enforce it
  run;runx;rewrite;explain;validate;fullscans;
  / serve it
  serve;active;audit;clearaudit;audittable;auditto;gatewaywrap;gatewaywrapx;
  / write filters
  f;ALL:pol.allcols;USER:tree.usermark;NOW:tree.nowmark;
  version]);
