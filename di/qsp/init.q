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

tree:use`.core.tree;
pol:use`.policy;
ord:use`.core.order;
walker:use`.core.walk;
f:use`.policy.f;
api:use`.api;
polfiles:use`.policy.files;
rev:use`.policy.review;
suite:use`.policy.suite;
admin:use`.admin;

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
toparse:{[x] :$[10h=abs type x;@[parse;(),x;{'"qsp: not valid q (",tree.described[x],")"}];x];};

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

/ the base queries of rewritten tree rw that read table t
readsof:{[rw;t] b:tree.basequeries rw; :b where t~/:b[;1];};

/ does a query on t bound its partition column, but not first? Only the policy's row filter puts
/ a constraint ahead of the user's: placement `first, or a filter that reads other rows
buried:{[p;rw;t] ti:pol.info[p;t]; :any {[ti;x] any ord.prunesby[ti] each tree.getc x 2}[ti] each readsof[rw;t];};

/ the refusal for table t, scanned end to end. The column must be bounded: a one-sided range reads
/ every partition on one side of it
needs:{[p;rw;t]
  c:string p[`tabs;t];
  if[buried[p;rw;t];
    :string[t]," - this user's row filter must run before the constraint on `",c,
      $[`first=p[`config;`placement];" (placement is `first)";" (it reads other rows)"],
      ", and q prunes by the first constraint only, so every partition is read whatever the query says"];
  :string[t]," needs a constraint on `",c," - ",c,"=d, ",c," in ds or ",c," within d0 d1";
  };

partitioncheck:{[p;rw]
  / the one check that bounds the work, run before anything is evaluated. The refusal names the
  / table and the column it needs, because the caller is usually a query generator that can
  / repair the query given those two facts
  if[not p[`config;`requirepartition];:""];
  if[0=count s:scanned[p;rw];:""];
  :"full table scan: ","; " sv needs[p;rw] each s;
  };

/ how many partitions base query x reads: every one, unless its leading constraint bounds the
/ partition column, and then as many as that constraint selects. Evaluated against .Q.pv, the
/ partitions of the database this process has loaded, before the query runs
partsread:{[p;pv;x]
  ti:pol.info[p;x 1];
  if[null ti`partition;:0];
  cons:tree.getc x 2;
  if[not ord.prunes[ti;cons];:count pv];
  c:first cons;
  :@[{sum eval x};(first c;enlist pv;c 2);{[pv;e] count pv}[pv]];
  };

pin:{[p;x]
  / base query x with the value of its leading partition constraint computed, and written into
  / the tree in its place. partsread counts the partitions that value selects, and the query must
  / then read those and no others: left as an expression, it would be computed again as the query
  / runs - and 1?2, or anything else that need not give the same answer twice, could select one
  / partition to be counted and every partition to be read. A value that cannot be computed
  / before the query runs is left alone, and partsread counts every partition for it
  ti:pol.info[p;x 1];
  if[null ti`partition;:x];
  cons:tree.getc x 2;
  if[not ord.prunes[ti;cons];:x];
  c:first cons;
  r:@[{(1b;eval x)};c 2;{(0b;x)}];
  if[not r 0;:x];
  x[2]:tree.setc @[cons;0;:;@[c;2;:;tree.lit r 1]];
  :x;
  };

/ rw with every leading partition constraint computed, where maxpartitions is checked
pinparts:{[p;rw]
  if[0W=p[`config;`maxpartitions];:rw];
  if[0=count @[value;`.Q.pv;()];:rw];
  :tree.mapbase[pin p;rw];
  };

/ q chooses the partitions it reads by the leading constraint alone. Any other constraint on the
/ partition column is tested row by row, in every partition the first one chose: an embargo,
/ "date<cutoff", placed after the user's "date within a b" reads and tests every row from a to b,
/ slower than the range alone. fold[p;pv;x] is base query x with its leading run of constraints
/ that compare the partition column with literal data - the user's, once pin has computed it, and
/ an aged filter's cutoff, computed at rewrite - replaced by one: the partition column in the
/ partitions of pv they select together. The same rows, from only the partitions that hold them
inop:first parse"x in y";
fold:{[p;pv;x]
  ti:pol.info[p;x 1];
  if[null ti`partition;:x];
  cons:tree.getc x 2;
  if[2>count cons;:x];
  / the length of the leading run: mins turns every flag after the first 0b to 0b
  k:sum mins ord.partfixed[ti] each cons;
  if[k<2;:x];
  keep:all {[pv;c] :eval (first c;enlist pv;c 2);}[pv] each k#cons;
  x[2]:tree.setc (enlist (inop;ti`partition;tree.lit pv where keep)),k _ cons;
  :x;
  };

/ rw with the leading partition constraints of each base query folded into one
foldparts:{[p;rw]
  if[0=count pv:@[value;`.Q.pv;()];:rw];
  :tree.mapbase[fold[p;pv];rw];
  };

/ rewritten tree rw as it will run: partition constraints pinned and folded. Either step that
/ cannot be taken leaves the tree as it was, which reads at least what the user asked for
settle:{[p;rw] rw:@[pinparts p;rw;{[rw;e] rw}rw]; :@[foldparts p;rw;{[rw;e] rw}rw];};

partitionlimit:{[p;rw]
  / requirepartition asks for a bounding constraint; maxpartitions caps how many partitions it
  / may select - "date within 0001.01.01 9999.12.31" bounds the column and reads everything
  if[0W=m:p[`config;`maxpartitions];:""];
  if[0=count pv:@[value;`.Q.pv;()];:""];
  b:tree.basequeries rw;
  n:partsread[p;pv] each b;
  if[not any k:n>m;:""];
  i:first where k;
  t:b[i;1];
  :"too many partitions: ",string[t]," would read ",string[n i],", more than maxpartitions ",string[m],
    " - narrow the constraint on `",string p[`tabs;t];
  };

isqsp:{[m] :(10h=type m)and(5<=count m)and"qsp: "~5#m;};

refuse:{[p;u;q;rw;d;m]
  / record a refusal, and signal it. A user that is not a single name is logged as `
  m:tree.prefix tree.described tree.clean m;
  record[p;$[-11h=type u;u;`];q;rw;d;m];
  'm;
  };

/ a query is run as a user the policy names - never a group, a name it has never heard of, or
/ anything that is not one symbol. A name with no grants can otherwise still run whatever reads no
/ table, and a list of names would union their grants. serve's .z.pw already turns such a login
/ away; this holds the same line for run, rewrite and the rest when called in process
chkuser:{[p;u] tree.chk[isuser[p;u];"not a user of this policy: ",-3!u];};

/ (1b;the rewritten tree)
tryrewrite:{[p;u;q] :(1b;walker.rewrite[walker.ctx[p;u;q];q]);};

go:{[ev;p;u;q]
  / parse, rewrite, pre-check, evaluate, bound - recording the decision. Every gate lives here,
  / and the decision kind follows from the stage that refused. Returns (result; rewritten tree).
  / ev evaluates the rewritten tree: eval, or over IPC the handler that was there before serve
  chkpolicy p;
  if[not isuser[p;u];refuse[p;u;q;();`denied;"not a user of this policy: ",-3!u]];
  s:@[{(1b;toparse x)};q;{(0b;x)}];
  if[not s 0;refuse[p;u;q;();`error;s 1]];
  r:@[tryrewrite[p;u];s 1;{(0b;x)}];
  if[not r 0;refuse[p;u;q;();$[tree.isfault r 1;`error;`denied];r 1]];
  rw:r 1;
  if[count m:partitioncheck[p;rw];refuse[p;u;q;rw;`denied;m]];
  rw:settle[p;rw];
  if[count m:partitionlimit[p;rw];refuse[p;u;q;rw;`denied;m]];
  v:@[{(1b;x y)}[ev];rw;{(0b;x)}];
  / a qsp check the walker placed in the tree refused a value the query computed
  if[not v 0;refuse[p;u;q;rw;$[isqsp v 1;`denied;`error];v 1]];
  if[count m:sizecheck[p`config;v 1];refuse[p;u;q;rw;`denied;m]];
  record[p;u;q;rw;`allowed;""];
  :(v 1;rw);
  };

/ ------------------------------------------------------------------ the api

/ run[p;u;q] -> the result of q, as user u under policy p. Signals a refusal
run:{[p;u;q] :first go[eval;p;u;q];};
/ runx[p;u;q] -> (result; what actually ran, rendered) - for a caller that must show its user
/ what its query was turned into
runx:{[p;u;q] r:go[eval;p;u;q]; :(r 0;render r 1);};
/ rewrite[p;u;q] -> the safe parse tree. Signals a refusal. Evaluates nothing
rewrite:{[p;u;q] chkpolicy p; chkuser[p;u]; q:toparse q; :@[walker.rewrite[walker.ctx[p;u;q]];q;{'tree.clean x}];};
/ explain[p;u;q] -> what would run, as text - the thing to paste into a ticket when someone asks
/ why they saw fewer rows than they expected
explain:{[p;u;q] :render rewrite[p;u;q];};
/ validate[p;u;q] -> (allowed;reason): every check run makes before it evaluates the query - the
/ rewrite, requirepartition and maxpartitions - each refusing with run's message. Records
/ nothing, and evaluates nothing but the value of a leading partition constraint, as run does to
/ count the partitions it selects. What depends on the data - a value the query computes, the
/ size of its result - is known only once it runs
validate:{[p;u;q]
  r:@[{(1b;rewrite[x;y;z])}[p;u];q;{(0b;x)}];
  if[not r 0;:r];
  m:partitioncheck[p;r 1];
  if[not count m;m:partitionlimit[p;settle[p;r 1]]];
  :$[count m;(0b;tree.prefix tree.described tree.clean m);(1b;"")];
  };
/ fullscans[p;u;q] -> tables q would read every partition of
fullscans:{[p;u;q] :scanned[p;rewrite[p;u;q]];};

/ ------------------------------------------------------------------ a policy's tests (policy/suite.q)

/ tests[d] -> the tests in policy directory d, from its tests.csv. Signals what is wrong with it
tests:{[d] :suite.fromdir d;};
/ checktests[d] -> every problem with policy directory d's tests.csv, as (file;line;error). Never
/ signals
checktests:{[d] :suite.problems d;};

/ runtests[p;t] -> tests t run under policy p, each as its user, with whether it passed, what it
/ got and how long it took. Nothing is recorded in the audit log: a test run is not a query
runtests:{[p;t]
  chkpolicy p;
  p:pol.configure[p;([audit:0b])];
  one:{[p;x]
    t0:.z.p;
    r:@[{(1b;run[x;y`user;y`query])}[p];x;{(0b;x)}];
    v:suite.verdict[x;r];
    :`pass`got`ms!(v 0;v 1;(`long$.z.p-t0)%1e6);
    }[p];
  :t,'one each t;
  };

/ ------------------------------------------------------------------ the admin UI (admin/)

/ adminui[x] -> the address of a web page to write, test and explore a policy in, served by this
/ process: x is `local (this machine only), `public, `stop, or a dictionary of access, port and
/ dir (the policy directory). It lends the page the pipeline - nothing else in admin/ can run a
/ query - and refuses a process that serves a policy
adminui:{[x]
  :admin.start[([run;runx;rewrite;runtests;audit;version;apis;serving:{[] installed}]);x];
  };

/ ------------------------------------------------------------------ serving
/ serve[p] polices every IPC query with p. Call it again with a new policy to swap it in
/ atomically; unserve[] puts the handlers back. The local console (.z.w=0) is not policed:
/ whoever holds the console holds the data
/ a gateway authenticates the end user and queries over its own login, so it forwards the caller
/ explicitly, as (`.qsp.execas;query;user). That is honoured only for logins the policy names with
/ qsp.gateway; from anyone else it is an ordinary - and refused - call. The wire format is fixed
/ and never resolved as a name, so it needs no global to exist

execas:`.qsp.execas;
execasx:`.qsp.execasx;
apimsg:`.qsp.api;
limitsmsg:`.qsp.limits;
served:(::);
installed:0b;

/ is message x a gateway, named in policy p, running a query as another user?
isgatewaycall:{[p;x]
  / (`.qsp.execas;`sym;`alice) - a query that is one name - is a symbol vector, as q stores a list
  / of symbols
  if[not ((type x) in 0 11h)&3=count x;:0b];
  if[not .z.u in p`gateways;:0b];
  :any (first x)~/:(execas;execasx);
  };

/ ------------------------------------------------------------------ the api
/ qsp.api: api/init.q's endpoints, and the pipeline's own, each taking a format last - `q or `json (see
/ api/init.q). validate gives a dictionary here, ([allowed;reason]), so it reads the same in JSON
apiversion:{[f] :api.encode[f;version];};
apivalidate:{[p;u;q;f] :api.encode[f;`allowed`reason!validate[p;u;q]];};
apiexplain:{[p;u;q;f] :api.encode[f;explain[p;u;q]];};
apis:``version`limits`memstats`users`functions`rules`access`describe`validate`explain!(::;
  apiversion;api.limits;api.memstats;api.users;api.functions;api.rules;api.access;api.describe;
  apivalidate;apiexplain);

/ ------------------------------------------------------------------ the api over IPC
/ (`.qsp.api;name;...) calls the api by name against the served policy: process facts, and the
/ policy as it applies to one user, for a gateway or a query generator to read before writing q.
/ A gateway names the user - (`.qsp.api;`describe;`alice) - and may make every call. A user's own
/ login may make the calls about itself, with no user: (`.qsp.api;`describe). A format may follow
/ the arguments - (`.qsp.api;`describe;`json), (`.qsp.api;`describe;`alice;`json) - and is `q
/ when it does not. `.qsp.limits alone is (`.qsp.api;`limits), as the original qsp answered it

/ each call: which only a gateway may make, which name a user, and how many arguments follow
apinames:`version`limits`memstats`users`functions`rules`access`describe`validate`explain;
apigwonly:`limits`memstats`users;
apiuser:`access`describe`validate`explain;
apinargs:apinames!0 0 0 0 0 0 0 0 1 1;
/ and what it does, as [policy;user;arguments;format]
apifns:apinames!(
  {[p;u;a;f] apiversion f};{[p;u;a;f] api.limits[p;f]};{[p;u;a;f] api.memstats f};
  {[p;u;a;f] api.users[p;f]};{[p;u;a;f] api.functions[p;f]};{[p;u;a;f] api.rules[p;f]};
  {[p;u;a;f] api.access[p;u;f]};{[p;u;a;f] api.describe[p;u;f]};
  {[p;u;a;f] apivalidate[p;u;first a;f]};{[p;u;a;f] apiexplain[p;u;first a;f]});

/ (`.qsp.api;`limits) is a symbol vector - q stores a list of symbols as one - and a call with
/ a string argument is a general list
isapicall:{[x] :$[(type x) in 0 11h;(2<=count x)&(first x)~apimsg;0b];};

apicall:{[p;x]
  n:x 1;
  tree.chk[$[-11h=type n;n in apinames;0b];"unknown api call: ",-3!n];
  gw:.z.u in p`gateways;
  tree.chk[gw or not n in apigwonly;"api call ",string[n]," is for gateway logins only"];
  / a gateway names the user; from a user's own login, the user is the caller
  named:gw and n in apiuser;
  u:$[not n in apiuser;`;named;$[2<count x;x 2;`];.z.u];
  if[n in apiuser;tree.chk[isuser[p;u];"not a user of this policy: ",-3!u]];
  a:(2+named)_x;
  k:apinargs n;
  / the format is told apart by where it is, after the arguments, and never by its value alone:
  / a query or a user that happens to be `json is not read as one
  f:`q;
  if[((count a)=k+1)and $[-11h=type last a;(last a) in api.formats;0b];f:last a;a:-1_a];
  tree.chk[(count a)=k;"api call ",string[n]," takes ",string[k]," argument",$[1=k;"";"s"],
    $[named;" after the user";""],", then optionally a format, `q or `json"];
  :apifns[n][p;u;a;f];
  };

/ ------------------------------------------------------------------ logins
/ qsp authorises; it does not authenticate. It trusts .z.u, the name a client logged in as, and q
/ accepts any name unless something checks it. serve installs a .z.pw that admits only the served
/ policy's users and its gateway logins: a name the policy doesn't know, or a group's name, cannot
/ connect. A user is a name in members or grants that is not a group (review.users), so `sales`
/ cannot log in and pick up the sales group's grants. It checks names, not passwords. -u/-U run
/ before .z.pw, and a .z.pw defined before the first serve - LDAP, say - is kept and called after
/ the name check, so put real authentication there

/ may u connect to, or be named in a gateway call to, a process serving policy p?
isuser:rev.isuser;
islogin:{[p;u] :(u in p`gateways) or isuser[p;u];};
login:{[u;pw] :$[not islogin[served;u];0b;(::)~f:before`.z.pw;1b;f[u;pw]];};

/ ------------------------------------------------------------------ the handlers
/ serve keeps what each handler was and runs it, rather than replacing it: a query is evaluated
/ by the .z.pg or .z.ps that was there before, so a wrapper installed first - a query log, client
/ tracking - still sees every policed query, as (eval;the rewritten tree). .z.pw runs after the
/ name check. HTTP and websockets are refused outright: q's own handlers for them evaluate what
/ they are sent, unpoliced, and a wrapper of them would do the same

handlers:`.z.pw`.z.pg`.z.ps`.z.pi`.z.ph`.z.pp`.z.pm`.z.ws;
/ each handler as it was before the first serve: (::) where it was q's own
before:handlers!count[handlers]#(::);
/ the evaluator a handler had before serve: q's own is value
priorof:{[h] :$[(::)~f:before h;value;f];};

pi:{[x]
  / a line of console input. From a remote handle - qcon - it is policed as a sync message; the
  / process's own console (.z.w=0) is not
  if[0<.z.w;:.Q.s req[`.z.pg;x]];
  if[not (::)~f:before`.z.pi;:f x];
  :.Q.s value x;
  };
chain:{[h;x] :priorof[h] (eval;x);};

serverun:{[h;p;u;q] :first go[chain h;p;u;q];};
serverunx:{[h;p;u;q] r:go[chain h;p;u;q]; :(r 0;render r 1);};

req:{[h;x]
  / the handler h: run message x as the caller, under the served policy
  if[0=.z.w;:priorof[h] x];
  p:served;
  / .z.pw admits only logins of the policy served when the connection opened. Check again: the
  / policy may have been swapped since, or .z.pw replaced
  if[not islogin[p;.z.u];refuse[p;.z.u;x;();`denied;"not a user of this policy: ",-3!.z.u]];
  if[x~limitsmsg;x:(apimsg;`limits)];
  if[isapicall x;:@[apicall[p];x;{[p;x;e] refuse[p;.z.u;x;();$[isqsp e;`denied;`error];e]}[p;x]]];
  if[isgatewaycall[p;x];
    / a user that is not a single symbol is refused, and logged against the gateway's own login
    if[not isuser[p;x 2];refuse[p;$[-11h=type x 2;x 2;.z.u];x 1;();`denied;"not a user of this policy: ",-3!x 2]];
    :$[execas~first x;serverun;serverunx][h;p;x 2;x 1]];
  :serverun[h;p;.z.u;x];
  };

install:{[]
  / keep every handler as it is, then install: logins are checked, queries are policed - console
  / lines from a remote handle too - and HTTP (every method) and websockets are refused
  .z.m.before:handlers!{@[value;x;{(::)}]} each handlers;
  .z.pw:login;
  .z.pg:req[`.z.pg];
  .z.ps:req[`.z.ps];
  .z.pi:pi;
  .z.ph:{'"qsp: HTTP access is not permitted"};
  .z.pp:{'"qsp: HTTP access is not permitted"};
  .z.pm:{'"qsp: HTTP access is not permitted"};
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

unserve:{[]
  / put every handler back as it was before the first serve, and serve nothing
  if[not installed;:()];
  {[h] $[(::)~f:before h;system"x ",string h;set[h;f]];} each handlers;
  .z.m.before:handlers!count[handlers]#(::);
  .z.m.served:(::);
  .z.m.installed:0b;
  };

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
  fromfiles:polfiles.fromfiles;check:polfiles.check;scaffold:polfiles.scaffold;schemadrift:polfiles.schemadrift;
  / inspect one
  columnsfor:pol.columnsfor;filterfor:pol.filterfor;access:rev.access;diff:rev.diff;api:apis;
  / enforce it
  run;runx;rewrite;explain;validate;fullscans;
  / test it
  tests;checktests;runtests;adminui;
  / serve it
  serve;unserve;active;audit;clearaudit;audittable;auditto;gatewaywrap;gatewaywrapx;
  / write filters
  f;ALL:pol.allcols;USER:tree.usermark;NOW:tree.nowmark;
  version]);
