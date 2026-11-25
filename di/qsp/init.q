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
codes:use`.core.codes;
rcpt:use`.receipt;
pol:use`.policy;
ord:use`.core.order;
walker:use`.core.walk;
qsql:use`.core.qsql;
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

/ x as q-SQL - what explain, runx and a gateway's execasx show - when that text parses back to x;
/ else as render prints it. Function names come from policy p's whitelist
readable:{[p;x] :qsql.text[p`fns;x];};

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

/ code is the refusal as data (core/codes.q), ` when allowed. A gateway's call adds who it was and
/ the context it sent - the conversation and question the query belongs to, and, for a query an
/ agent's tooling corrected before sending, what was written and the fixes applied - and a
/ receipt, when one was asked for, adds its id and the result's hash
decisions:([]time:`timestamp$();user:`symbol$();query:();rewritten:();
  allowed:`boolean$();decision:`symbol$();reason:();code:`symbol$();gateway:`symbol$();
  session:`guid$();turn:`long$();question:();model:`symbol$();client:`symbol$();
  original:();fixes:();receipt:`guid$();resulthash:());
/ the global name the log is kept under
logname:.z.M.decisions;

/ the context a gateway may send with a query, (`.qsp.execas;query;user;ctx), and what each key
/ holds when it is not sent. It is recorded, never interpreted: nothing in it changes a decision
nullctx:`session`turn`question`model`client`original`fixes!(0Ng;0N;"";`;`;"";`symbol$());
/ what a call adds to its decision: the gateway that asked (` for none), its context, whether it
/ wants a receipt, and the receipt issued
noextra:`gateway`ctx`wantreceipt`receipt`resulthash!(`;nullctx;0b;0Ng;"");

record:{[p;u;q;rw;d;m;x]
  / add a decision to the audit log, keeping at most auditmax rows
  if[not p[`config;`audit];:()];
  c:x`ctx;
  logname upsert ([]time:enlist .z.p;user:enlist u;query:enlist $[10h=abs type q;q;render q];
    rewritten:enlist rw;allowed:enlist d=`allowed;decision:enlist d;reason:enlist m;
    code:enlist $[d=`allowed;`;codes.classify[m]`code];gateway:enlist x`gateway;
    session:enlist c`session;turn:enlist c`turn;question:enlist c`question;model:enlist c`model;
    client:enlist c`client;original:enlist c`original;fixes:enlist c`fixes;
    receipt:enlist x`receipt;resulthash:enlist x`resulthash);
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
toparse:{[x] :$[10h=abs type x;@[parse;(),x;parsefail (),x];x];};

/ the names text s assigns that q reserves: an identifier just before a single colon, that names a
/ q function or keyword. q's parser rejects "select fills:count sym ..." with only 'assign, and
/ a column named after a function - fills, prev, next, rank - is the usual cause
reservednames:{[s]
  j:where s=":";
  j:j where (0<j)&not ":"=s 1+j;
  w:{[s;j] t:reverse j#s; :reverse (t?first t where not t in .Q.an)#t;}[s] each j;
  n:distinct `$w where 0<count each w;
  :n where n in (key `.q),.Q.res;
  };

parsefail:{[s;e]
  m:"qsp: not valid q (",tree.described[e],")";
  if[(e~"assign")and count r:reservednames s;
    one:1=count r;
    m,:": ",(", " sv string r),$[one;" is a q function, so it cannot";" are q functions, so they cannot"],
      " name a column - rename ",$[one;"it";"them"]];
  'm;
  };

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

/ the reads of t in rw that scan it end to end. Only these say why: another read of t in the same
/ query - a nested select that does bound the column - says nothing about them
scans:{[p;rw;t] b:readsof[rw;t]; :b where not prunedby[p] each b;};

/ does a query on t bound its partition column, but not first? Only the policy's row filter puts
/ a constraint ahead of the user's: placement `first, or a filter that reads other rows
buried:{[p;rw;t] ti:pol.info[p;t]; :any {[ti;x] any ord.prunesby[ti] each tree.getc x 2}[ti] each scans[p;rw;t];};

/ does a query on t constrain its partition column with a value computed as the query runs - a
/ nested select, an exec, max date - rather than one written in? q cannot prune by that
computed:{[p;rw;t]
  pc:pol.info[p;t]`partition;
  :any {[pc;x] any {[pc;c] $[0h=type c;$[3=count c;$[pc~c 1;not first ord.literal c 2;0b];0b];0b]}[pc] each tree.getc x 2}[pc] each scans[p;rw;t];
  };

/ the refusal for table t, scanned end to end. The column must be bounded: a one-sided range reads
/ every partition on one side of it
needs:{[p;rw;t]
  c:string p[`tabs;t];
  if[buried[p;rw;t];
    :string[t]," - this user's row filter must run before the constraint on `",c,
      $[`first=p[`config;`placement];" (placement is `first)";" (it reads other rows)"],
      ", and q prunes by the first constraint only, so every partition is read whatever the query says"];
  if[computed[p;rw;t];
    :string[t]," - the constraint on `",c," must be a value written into the query (",c,"=d, ",c," in ds or ",c,
      " within d0 d1): one computed from other rows (a nested select, an exec, max ",c,
      ") is known only as the query runs, so q cannot prune by it. Find the value with a query of its own first, then write it in"];
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

/ q's error from evaluating a query, made into one its writer can act on. A timeout or the memory
/ cap is the query's size, not a mistake in it, and q says only stop or wsfull
evalerror:{[e]
  if[e~"stop";:"stop: the query ran longer than the timeout (-T ",string[system"T"],"s) - narrow its dates or instruments, or filter both sides of a join before joining"];
  if[e~"wsfull";:"wsfull: the query needed more memory than the process may use (-w) - narrow it, or aggregate before joining"];
  if[codes.qname e;:"not found when the query ran: ",e," - q could not find this name: a join key missing from the left table, a column an earlier step did not keep, or a name never defined"];
  :e;
  };

refuse:{[p;u;q;rw;d;m] refusex[p;u;q;rw;d;m;noextra];};
refusex:{[p;u;q;rw;d;m;x]
  / record a refusal, and signal it. A user that is not a single name is logged as `
  m:tree.prefix tree.described tree.clean m;
  record[p;$[-11h=type u;u;`];q;rw;d;m;x];
  'm;
  };

/ a query is run as a user the policy names - never a group, a name it has never heard of, or
/ anything that is not one symbol. A name with no grants can otherwise still run whatever reads no
/ table, and a list of names would union their grants. serve's .z.pw already turns such a login
/ away; this holds the same line for run, rewrite and the rest when called in process
chkuser:{[p;u] tree.chk[isuser[p;u];"not a user of this policy: ",-3!u];};

/ (1b;the rewritten tree)
tryrewrite:{[p;u;q] :(1b;walker.rewrite[walker.ctx[p;u;q];q]);};

/ ------------------------------------------------------------------ rate
/ an agent retries, loops and follows up, and q runs one query at a time: one user's burst delays
/ everyone. maxqueries caps the queries a user may run in a minute; 0W, the default, is no cap.
/ Only what run evaluates counts - validate, estimate and describe run nothing
recent:()!();
ratecheck:{[p;u]
  n:p[`config;`maxqueries];
  if[0W=n;:""];
  t:$[u in key recent;recent u;`timestamp$()];
  t:t where t>.z.p-0D00:01;
  if[n<=count t;
    :"rate limit: ",string[count t]," queries in the last minute, the most maxqueries allows - wait ",
      string[1|ceiling (`long$(first t)+0D00:01-.z.p)%1e9],"s"];
  .z.m.recent[u]:t,.z.p;
  :"";
  };

/ ensure aj/aj0 and wj/wj1 right-hand tables have `p# or `g# on the first join key: multi-partition
/ selects drop `p#, which otherwise forces an O(N*M) linear scan that can block the process past -T
safeaj:{[f;k;l;r]
  if[(98h=type r)&(1<count k)&(-11h=type c:first k);
    if[(c in cols r)&not (attr r c) in `p`g; r:@[r;c;`g#]]];
  :f[k;l;r];
  };
safewj:{[f;w;k;l;rs]
  if[(0h=type rs)&(0<count rs)&(1<count k)&(-11h=type c:first k);
    r:first rs;
    if[(98h=type r)&(c in cols r)&not (attr r c) in `p`g; rs:@[rs;0;@[;c;`g#]]]];
  :f[w;k;l;rs];
  };
prepaj:{[x]
  if[0h<>type x;:x];
  if[0=count x;:x];
  if[(4=count x)&any (first x)~/:(aj;aj0); :(safeaj first x),.z.s each 1_x];
  if[(5=count x)&any (first x)~/:(wj;wj1); :(safewj first x),.z.s each 1_x];
  :.z.s each x;
  };

go:{[ev;p;u;q] :2#gox[ev;p;u;q;noextra];};

gox:{[ev;p;u;q;x]
  / parse, rewrite, pre-check, evaluate, bound - recording the decision. Every gate lives here,
  / and the decision kind follows from the stage that refused. Returns (result; rewritten tree;
  / receipt, or (::) when x did not ask for one). ev evaluates the rewritten tree: eval, or over
  / IPC the handler that was there before serve. x is what the call adds (noextra)
  chkpolicy p;
  no:refusex[p;u;q;;;;x];
  if[not isuser[p;u];no[();`denied;"not a user of this policy: ",-3!u]];
  if[count m:ratecheck[p;u];no[();`denied;m]];
  s:@[{(1b;toparse x)};q;{(0b;x)}];
  if[not s 0;no[();`error;s 1]];
  r:@[tryrewrite[p;u];s 1;{(0b;x)}];
  if[not r 0;no[();$[tree.isfault r 1;`error;`denied];r 1]];
  rw:r 1;
  if[count m:partitioncheck[p;rw];no[rw;`denied;m]];
  rw:settle[p;rw];
  if[count m:partitionlimit[p;rw];no[rw;`denied;m]];
  / precheck: a result that cannot fit is refused before the work, not after it
  if[p[`config;`precheck];
    e:@[sizeof[p;u];rw;{(::)}];
    if[99h=type e;if[`toobig~e`verdict;no[rw;`denied;"too big to run: ",first e`advice]]]];
  v:@[{(1b;x y)}[ev];prepaj rw;{(0b;x)}];
  / a qsp check the walker placed in the tree refused a value the query computed
  if[not v 0;no[rw;$[isqsp v 1;`denied;`error];evalerror v 1]];
  / mingroup: groups too small to hide a hidden value are suppressed, or the query refused
  mg:mingroupapply[p;u;s 1;rw;v 1];
  if[count mg 0;no[rw;`denied;mg 0]];
  v[1]:mg 1;
  if[count m:sizecheck[p`config;v 1];no[rw;`denied;m]];
  rc:(::);
  if[x`wantreceipt;rc:receiptfor[p;u;q;rw;v 1;x];x[`receipt]:rc`id;x[`resulthash]:rc`resulthash];
  record[p;u;q;rw;`allowed;"";x];
  :(v 1;rw;rc);
  };

/ ------------------------------------------------------------------ mingroup
/ With strictcolumns off a where clause may test a column its user may not read. One question at
/ a time - select count sym from trades where account=`A7 - that tells the user about the hidden
/ column. A table's mingroup is the fewest rows each output row of such a query must summarise:
/ a group with fewer is suppressed, as if it had no rows. It is checked against the user's own
/ query, not the rewritten one: the policy's row filter tests hidden columns by design.
/ What it covers: one select over one table, grouped with by or aggregated to a single row. A
/ nested query or a join could recombine suppressed groups, and an ungrouped select returns rows
/ that each summarise one row, so those are refused when they test a hidden column. That is the
/ conservative reading of a question still open - whether a bound on each level of a nested
/ query is enough - and narrowing it is future work

/ the columns of base query x's table, hidden from user u, that x tests in its where or by
hiddentested:{[p;u;x]
  t:x 1;
  h:(pol.columnsof[p;t]) except pol.columnsfor[p;u;t];
  if[0=count h;:`symbol$()];
  b:$[99h=type x 3;value x 3;()];
  :h inter distinct raze tree.namerefs each (tree.getc x 2),b;
  };

/ (refusal or "";result) for user query q0, rewritten to rw, whose result is v
mingroupapply:{[p;u;q0;rw;v]
  bs:tree.basequeries q0;
  if[0=count bs;:("";v)];
  bs:bs where 0<{[p;x] pol.mingroupof[p;x 1]}[p] each bs;
  if[0=count bs;:("";v)];
  h:hiddentested[p;u] each bs;
  bs:bs where 0<count each h;
  h:h where 0<count each h;
  if[0=count bs;:("";v)];
  t:bs[0;1];
  k:pol.mingroupof[p;t];
  what:"tests ",(", " sv string first h)," of ",string[t],", which you cannot read: ";
  if[not (1=count tree.basequeries q0)and q0~first bs;
    :("mingroup: this query ",what,"it must be one select over ",string[t],", not nested or joined";v)];
  b:rw 3;
  if[(b~())or b~1b;:("mingroup: this query ",what,"it must be a select, grouped with by or aggregated to one row";v)];
  / the rows each output row summarises, counted by the same where and by
  n:eval (first rw;rw 1;rw 2;b;(enlist`qspn)!enlist (count;`i));
  if[b~0b;
    if[1<>count v;:("mingroup: this query ",what,"it must aggregate - group with by, or return one row";v)];
    :("";$[k>first n`qspn;0#v;v])];
  ok:key select from n where qspn>=k;
  kc:cols ok;
  r:0!v;
  :("";kc xkey r where (kc#r) in ok);
  };

/ ------------------------------------------------------------------ receipts
/ the receipt for result v of query q, run as user u, rewritten to rw: issued, signed and kept
/ (receipt/init.q). The policy is named by a hash of itself, so a receipt shows which policy
/ decided it; the row filter and partitions are what the rewrite applied to each table read

policyhash:{[p] :raze string md5 `char$-8!p;};

/ result v's hash: SHA-1 of its serialisation, as any q process can compute it again
resulthash:{[v] :@[{raze string -33!-8!x};v;{""}];};

/ each table rw reads -> the row filter user u has on it, as q text
filtertext:{[p;u;rw]
  ts:distinct `symbol$tree.basetables rw;
  :ts!{[p;u;t] c:pol.filterfor[p;u;t]; $[count c;", " sv {[p;x] readable[p;x]}[p] each c;""]}[p;u] each ts;
  };

/ each table rw reads -> the partitions it read, counted as maxpartitions counts them
partitionsread:{[p;rw]
  b:tree.basequeries rw;
  pv:@[value;`.Q.pv;()];
  if[0=count b;:(`symbol$())!`long$()];
  n:$[count pv;partsread[p;pv] each b;(count b)#0];
  g:group `symbol$b[;1];
  :(key g)!sum each n value g;
  };

receiptfor:{[p;u;q;rw;v;x]
  / in process, with no serve to have read them, the keys are read on first use
  if[not null k:p[`config;`receiptkeys];if[null rcpt.signer[];rcpt.loadkeys k]];
  c:x`ctx;
  d:`user`gateway`session`turn`original`fixes`policy`query`rewritten`filter`partitions`rows`columns`resulthash!(
    u;x`gateway;c`session;c`turn;c`original;c`fixes;policyhash p;$[10h=abs type q;q;render q];
    readable[p;rw];filtertext[p;u;rw];partitionsread[p;rw];rows v;$[98h=type v;cols v;99h=type v;cols 0!v;`symbol$()];
    resulthash v);
  r:rcpt.issue d;
  rcpt.keep[p`config;r;v];
  :r;
  };

/ ------------------------------------------------------------------ the api

/ run[p;u;q] -> the result of q, as user u under policy p. Signals a refusal
run:{[p;u;q] :first go[eval;p;u;q];};
/ runx[p;u;q] -> (result; what actually ran, rendered) - for a caller that must show its user
/ what its query was turned into
runx:{[p;u;q] r:go[eval;p;u;q]; :(r 0;readable[p;r 1]);};
/ rewrite[p;u;q] -> the safe parse tree. Signals a refusal. Evaluates nothing
rewrite:{[p;u;q] chkpolicy p; chkuser[p;u]; q:toparse q; :@[walker.rewrite[walker.ctx[p;u;q]];q;{'tree.clean x}];};
/ explain[p;u;q] -> what would run, as text - the thing to paste into a ticket when someone asks
/ why they saw fewer rows than they expected
explain:{[p;u;q] :readable[p;rewrite[p;u;q]];};
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
/ checkterms[p] -> every problem with policy p's terms, as ([]term;problem): a term no user can
/ read all the tables of, or whose example query is refused as such a user. A term describes the
/ data, so its example must be a query the policy would run
checkterms:{[p]
  t:$[`terms in key p;p`terms;pol.emptyterms];
  e:([]term:`symbol$();problem:());
  if[0=count t;:e];
  us:rev.users p;
  acc:rev.access[p;`];
  r:{[p;us;acc;x]
    who:us where {[acc;ts;u] all ts in exec tbl from acc where user=u}[acc;x`tbls] each us;
    if[0=count who;:enlist (x`term;"no user can read all of its tables: "," "sv string x`tbls)];
    if[0=count x`q;:()];
    / a parameterised term runs with its example arguments; with none, it cannot be checked
    q:x`q;
    if[count ps:$[`params in key x;x`params;""];
      if[0=count x`example;:enlist (x`term;"it takes parameters, and has no example to check it with")];
      e:@[{[p;x;ps] (1b;pol.terminst[p;x`term;pol.exampleargs[pol.parseparams ps;x`example]])}[p;x];ps;{(0b;x)}];
      if[not e 0;:enlist (x`term;"its example does not fill its parameters: ",e 1)];
      q:e 1];
    / a term is sound if any user who can read its tables can run its example
    v:validate[p;;q] each who;
    :$[any v[;0];();enlist (x`term;"its query is refused as every user who can read its tables: ",last last v)];
    }[p;us;acc] each t;
  r:raze r;
  :$[count r;flip `term`problem!flip r;e];
  };

/ agentlint[p] -> for each user in the policy's agentgroup, the columns their where clauses could
/ test without being granted them, as ([]user;tbl;hidden). Empty when strictcolumns is on, or no
/ agentgroup is set. With strictcolumns off, where may test any column of a table it reads: one
/ question at a time, an agent can learn a hidden value - select count sym from t where account=`A7
/ - and an agent asks questions without tiring
agentlint:{[p]
  e:([]user:`symbol$();tbl:`symbol$();hidden:());
  g:p[`config;`agentgroup];
  if[null g;:e];
  if[p[`config;`strictcolumns];:e];
  us:rev.users p;
  us:us where {[p;g;u] pol.ingroup[p;g;u]}[p;g] each us;
  if[0=count us;:e];
  / computed first: q-sql resolves a module's names in the caller's namespace
  a:raze {[p;u] t:rev.access[p;u]; :([]user:(count t)#u;tbl:t`tbl;columns:t`columns);}[p] each us;
  h:{[p;t;c] (pol.columnsof[p;t]) except c}[p]'[a`tbl;a`columns];
  r:([]user:a`user;tbl:a`tbl;hidden:h);
  :r where 0<count each r`hidden;
  };

/ fullscans[p;u;q] -> tables q would read every partition of
fullscans:{[p;u;q] :scanned[p;rewrite[p;u;q]];};

/ ------------------------------------------------------------------ the shape of the data
/ what an agent otherwise spends queries finding out, for each table user u may read: the
/ partitions they can see, the first and last of each time column, and the values of each code
/ column - side, src, algo - that has few. All of it as the user: each query is the rewritten one,
/ row filter and embargo in it, evaluated without an audit record, since the user asked nothing.
/ Cached for a minute per user and table: describe is called often, and the data moves slowly

/ a rewritten, settled query, evaluated without a record: describe's own reads. Served, it goes to
/ the evaluator a policed query goes to - the handler there before serve, which is eval when there
/ was none - so a qsp in front of a gateway, holding no data, reads the shape where the data is
quiet:{[p;u;q] t:settle[p;rewrite[p;u;q]]; :$[installed;chain[`.z.pg;t];eval t];};

/ the partitions of table t user u can see: .Q.pv, narrowed by the policy's literal constraints on
/ the partition column pc - an embargo - as run would narrow a query over every one
visibledates:{[p;u;t;pc]
  pv:@[value;`.Q.pv;()];
  if[0=count pv;:pv];
  rw:@[{settle[x;rewrite[x;y;z]]}[p;u];"select from ",string[t]," where ",string[pc]," within ",(-3!first pv)," ",-3!last pv;{()}];
  if[()~rw;:pv];
  c:first tree.getc rw 2;
  :pv where @[{eval (x 0;enlist y;x 2)}[c];pv;{[pv;e] (count pv)#1b}pv];
  };

/ a column's few values: up to this many distinct ones, or none
fewvalues:20;

tableshape:{[p;u;t]
  pc:p[`tabs;t];
  cs:pol.columnsfor[p;u;t];
  ty:(exec col!typ from p[`schema] where tbl=t) cs;
  / a null entry first keeps r a general dictionary: dictionaries as its values would collapse it
  / into a table, and the next, with other keys, would not fit
  r:(enlist`)!enlist(::);
  w:"";
  if[not null pc;
    ds:visibledates[p;u;t;pc];
    r[`dates]:`first`last`count!(first ds;last ds;count ds);
    if[0=count ds;:1_r];
    w:" where ",string[pc],"=",-3!last ds];
  / each read on its own: one that fails - a gateway that is down - costs its column, not the
  / dates already found
  tc:cs where (ty in "pntuvz")and not cs=pc;
  if[count tc;
    r[`time]:tc!{[p;u;t;w;c] @[{first each value flip x};
      @[quiet[p;u];"select a:min ",(string c),", b:max ",(string c)," from ",(string t),w;{()}];{()}]}[p;u;t;w] each tc];
  sc:cs where (ty="s")and not cs=pc;
  if[count sc;
    v:sc!{[p;u;t;w;c] @[quiet[p;u];"exec distinct ",(string c)," from select ",(string c)," from ",(string t),w;{()}]}[p;u;t;w] each sc;
    r[`values]:(where {(count x)within 1,fewvalues} each v)#v];
  :1_r;
  };

shapettl:0D00:01;
shapecache:()!();
shape:{[p;u]
  ts:exec distinct tbl from rev.access[p;u];
  :ts!{[p;u;t]
    k:`$string[u],"|",string t;
    if[k in key shapecache;if[shapettl>.z.p-first shapecache k;:last shapecache k]];
    r:@[tableshape[p;u];t;{()!()}];
    .z.m.shapecache[k]:(.z.p;r);
    :r;
    }[p;u] each ts;
  };

/ ------------------------------------------------------------------ estimate
/ estimate[p;u;q] -> how big query q is, before it runs. maxrows and maxsize refuse a result after
/ its work is done, and a join too big for -T or -w stalls the process for everyone first. So for
/ each table the query reads - each base select - the rows its where clause selects are counted,
/ as the user: the clause is the rewritten one, with the row filter in it, so a count never
/ includes rows the user cannot see (a raw partition count would say how many a filter hides).
/ That reads only the clause's columns. Rows times the bytes of the columns the select returns -
/ schema.csv's measured bytes, or a type's width - is its size; the result's is that of the query
/ it comes from, or a bound. The verdict is checked against the limits, with what to change

/ bytes per row of a type where no measured size is known. A symbol is sent as its text, so 8 is a
/ guess; a list per row (an upper-case type) is a guess at 32
typewidths:"bxhijefcspmdznuvtg"!1 1 2 4 8 4 8 1 8 8 4 4 8 8 4 4 4 16f;

colbytes:{[p;t;c]
  b:first first pol.colinfofor[p;t;enlist c];
  if[not null b;:b];
  ty:first exec typ from p[`schema] where tbl=t,col=c;
  :$[null ty;8f;ty in key typewidths;typewidths ty;32f];
  };

/ bytes per row of one column of a result: a column of table t named as it is, or a computed value
/ as 8
exprbytes:{[p;t;e] :$[-11h<>type e;8f;e in pol.columnsof[p;t];colbytes[p;t;e];8f];};

/ bytes per row of base query x's result: the columns it returns, and its by columns
rowbytes:{[p;u;x]
  t:x 1;
  a:x 4;
  if[(::)~a;a:()];
  e:$[99h=type a;value a;0=count a;pol.columnsfor[p;u;t];enlist a];
  bk:$[99h=type b:x 3;value b;()];
  :sum exprbytes[p;t] each e,bk;
  };

/ the rows base query x's where clause selects
readrows:{[x] :first first value flip eval (tree.selop;x 1;x 2;0b;(enlist`n)!enlist(count;`i));};

/ reducing aggregates: a select with no by whose columns are all aggregates returns 1 row
aggfns:(count;sum;avg;min;max;med;dev;sdev;var;svar;first;last;wavg;wsum;cor;cov;scov;all;any;prd);
isagg:{[e]
  if[0h<>type e;:0b];
  if[0=count e;:0b];
  h:first e;
  if[any h~/:aggfns;:1b];
  if[any h~/:(+;-;*;%;abs;neg;sqrt;log;exp;floor;ceiling;reciprocal;?:);:any isagg each 1_e];
  :0b;
  };
isaggquery:{[x]
  if[not (tree.selop~first x)and(0b~x 3)and 99h=type x 4;:0b];
  if[0=count x 4;:0b];
  :all isagg each value x 4;
  };

/ (rows; exact) of what expression x returns, given each base query's rows and whether it groups:
/ a base query's own (or 1 for an ungrouped aggregate), a select over a select at most its inner
/ one's, a join its left side's (uj both sides'), and 0N where nothing is known
resultrows:{[bs;ns;gs;x]
  if[isaggquery x;:(1;1b)];
  if[not null i:first where bs~\:x;:(ns i;not gs i)];
  if[tree.isjoin x;
    n:.q?first x;
    if[n~`uj;:(sum first each .z.s[bs;ns;gs] each 1_x;0b)];
    l:$[n in `aj`aj0`ej`wj`wj1;x 2;x 1];
    r:.z.s[bs;ns;gs;l];
    :(r 0;(r 1)&n in `aj`aj0`lj`wj`wj1)];
  if[tree.isquery x;if[not -11h=type x 1;:(first .z.s[bs;ns;gs;x 1];0b)]];
  :(0N;0b);
  };

/ the work a read may do before the timeout is a guess: past this many rows, say so
largeread:20000000;

limitsnow:{[p] :`maxrows`maxsize`timeout_s`memory_cap_bytes!(p[`config;`maxrows];p[`config;`maxsize];`long$system"T";.Q.w[]`wmax);};

estimate:{[p;u;q]
  v:validate[p;u;q];
  if[not v 0;:`allowed`reason`reads`result`limits`verdict`advice!(0b;v 1;();()!();limitsnow p;`refused;enlist v 1)];
  :sizeof[p;u;settle[p;rewrite[p;u;q]]];
  };

/ the estimate of rewritten, settled tree rw: what estimate returns for an allowed query, and what
/ precheck consults before run evaluates
sizeof:{[p;u;rw]
  lim:limitsnow p;
  bs:tree.basequeries rw;
  ns:readrows each bs;
  gs:{not 0b~x 3} each bs;
  bpr:rowbytes[p;u] each bs;
  reads:([]table:bs[;1];rows:ns;bytes:`long$ns*bpr;grouped:gs);
  rr:resultrows[bs;ns;gs;rw];
  i:first where bs~\:rw;
  rb:$[null rr 0;0N;not null i;`long$(rr 0)*bpr i;`long$(rr 0)*sum bpr];
  res:`rows`exact`bytes!(rr 0;rr 1;rb);
  adv:();
  hard:0b;
  if[(not null rr 0)&(rr 0)>lim`maxrows;
    if[rr 1;hard:1b];
    adv,:enlist "the result would have ",$[rr 1;"";"up to "],string[rr 0]," rows, more than maxrows ",string[lim`maxrows],
      ": aggregate with by, or take the first rows with select[n] over a select"];
  if[(not null rb)&rb>lim`maxsize;
    if[rr 1;hard:1b];
    adv,:enlist "the result would be about ",string[rb]," bytes, more than maxsize ",string[lim`maxsize],
      ": return fewer columns or rows"];
  if[(0<lim`memory_cap_bytes)&(sum reads`bytes)>lim`memory_cap_bytes;
    hard:1b;
    adv,:enlist "its reads come to about ",string[sum reads`bytes]," bytes, more than the process may use (-w ",
      string[lim`memory_cap_bytes],"): narrow its dates and instruments"];
  / a local: q-sql resolves a module's globals in the caller's namespace
  lr:largeread;
  big:select from reads where rows>lr;
  if[count big;
    adv,:{"it reads ",string[x`rows]," rows of ",string[x`table],", which may run past the timeout: narrow its dates or instruments, or filter it to what the other side of a join needs"} each big];
  / a join whose one side reads far more than the other is usually that side unfiltered: all of a
  / day's quotes against one instrument's trades
  if[(1<count reads)&(1000000<max reads`rows)&(max reads`rows)>100*1|min reads`rows;
    big:first select from reads where rows=max rows;
    small:first select from reads where rows=min rows;
    adv,:enlist "one side reads ",string[big`rows]," rows of ",string[big`table],", ",string[floor big[`rows]%1|small`rows],
      " times the ",string[small`rows]," of ",string[small`table],": filter it to what the other needs - the same instruments and window"];
  vd:$[hard;`toobig;count adv;`large;`fits];
  :`allowed`reason`reads`result`limits`verdict`advice!(1b;"";reads;res;lim;vd;adv);
  };

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
  :admin.start[([run;runx;rewrite;runtests;checkterms;audit;version;apis;serving:{[] installed}]);x];
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
/ the same, returning a dictionary: the result, what ran, and a signed receipt - or, refused, the
/ refusal as data (code, kind, subject, reason, rule) rather than a signal
execasr:`.qsp.execasr;
execforms:(execas;execasx;execasr);
/ (`.qsp.async;id;msg), sent asynchronously: msg is handled as if sent synchronously, and the
/ answer comes back asynchronously as (`.qsp.reply;id;(1b;value)) or (`.qsp.reply;id;(0b;refusal))
asyncmsg:`.qsp.async;
replymsg:`.qsp.reply;
apimsg:`.qsp.api;
limitsmsg:`.qsp.limits;
served:(::);
installed:0b;

/ is message x a gateway, named in policy p, running a query as another user?
/ is x an execas form: (form;query;user), or (form;query;user;ctx) from a gateway?
/ (`.qsp.execas;`sym;`alice) - a query that is one name - is a symbol vector, as q stores a list
/ of symbols
isexecform:{[x]
  if[not (type x) in 0 11h;:0b];
  if[not (count x) in 3 4;:0b];
  :any (first x)~/:execforms;
  };
isgatewaycall:{[p;x] :$[isexecform x;.z.u in p`gateways;0b];};

/ is message x the execas form naming the caller itself? Any login may run as itself, so nothing
/ is granted that a plain query does not already have
isselfcall:{[x] :$[isexecform x;(x 2)~.z.u;0b];};

isasync:{[x] :$[(type x) in 0 11h;$[3=count x;(first x)~asyncmsg;0b];0b];};

/ a gateway's context, checked: a dictionary of nullctx's keys, each of its type. The question
/ and the original query are capped, so a context cannot grow the audit log without bound
ctxmax:4000;
chkctx:{[c]
  tree.chk[99h=type c;"ctx must be a dictionary - keys from ",", " sv string key nullctx];
  tree.chk[11h=type key c;"ctx keys must be symbols"];
  bad:(key c) except key nullctx;
  tree.chk[0=count bad;"unknown ctx key: ",(", " sv string bad)," - one of ",", " sv string key nullctx];
  if[`turn in key c;if[-6h=type c`turn;c[`turn]:`long$c`turn]];
  if[`fixes in key c;if[(0h=type c`fixes)and 0=count c`fixes;c[`fixes]:`symbol$()]];
  if[`fixes in key c;if[-11h=type c`fixes;c[`fixes]:enlist c`fixes]];
  ty:{[c;k] (type c k)=type nullctx k}[c] each key c;
  tree.chk[all ty;"wrong type for ctx key: ",", " sv string (key c) where not ty];
  long:(key c) where {[c;k] $[10h=type c k;ctxmax<count c k;0b]}[c] each key c;
  tree.chk[0=count long;"ctx ",(", " sv string long)," longer than ",string[ctxmax]," characters"];
  :nullctx,c;
  };

/ the refusal in message m, as data: what execasr and an async reply return in place of a result
refusal:{[p;m]
  m:tree.prefix tree.described tree.clean m;
  c:codes.classify m;
  :`reason`rule`code`kind`subject!(m;ruleof[p;m];c`code;c`kind;c`subject);
  };

/ an execas form x, run as user u for gateway gw (` for a self call), evaluating with ev
execrun:{[ev;p;u;x;gw]
  e:noextra;
  e[`gateway]:gw;
  if[4=count x;e[`ctx]:@[chkctx;x 3;{[p;u;x;m] refuse[p;u;x;();`denied;m]}[p;u;x 1]]];
  f:first x;
  if[f~execasr;:runrx[ev;p;u;x 1;e]];
  r:gox[ev;p;u;x 1;e];
  :$[f~execas;r 0;(r 0;readable[p;r 1])];
  };

/ query q as user u, with what the call adds e and a receipt, as a dictionary: on success the
/ result, what ran and the receipt; refused, the refusal as data. Nothing is signalled
runrx:{[ev;p;u;q;e]
  e[`wantreceipt]:1b;
  r:@[{(1b;gox . x)};(ev;p;u;q;e);{(0b;x)}];
  if[r 0;v:r 1;:`status`result`rewritten`receipt!(`ok;v 0;readable[p;v 1];v 2)];
  :refusalreply[p;r 1];
  };

/ runr[p;u;q;ctx] -> query q run in process as user u, with a receipt: what execasr returns. ctx
/ is a context dictionary, or (::) for none
runr:{[p;u;q;c]
  e:noextra;
  e[`gateway]:`;
  if[not (::)~c;e[`ctx]:chkctx c];
  :runrx[eval;p;u;q;e];
  };

/ the receipt with id and its kept values, to the user it ran as or the gateway that asked; and
/ whether a receipt is genuine - signed by a key this process holds, and unchanged
receipt:{[id;caller] :rcpt.fetch[id;caller];};
verify:{[r] :rcpt.verify r;};
newreceiptkey:{[dir] :rcpt.newkey dir;};
reloadkeys:{[p] :rcpt.loadkeys p[`config;`receiptkeys];};

/ ------------------------------------------------------------------ the api
/ qsp.api: api/init.q's endpoints, and the pipeline's own, each taking a format last - `q or `json (see
/ api/init.q). validate gives a dictionary here, ([allowed;reason]), so it reads the same in JSON
apiversion:{[f] :api.encode[f;version];};
/ describe without the rules and the function whitelist - which an agent holding the primer
/ already has - and with a version of each, so it can tell its copy is current
apibrief:{[p;u;f]
  d:api.describe[p;u;`q];
  d:(`rules`functions`calls)_d;
  d[`shape]:shape[p;u];
  d[`rulesversion]:raze string md5 `char$-8!api.rules[p;`q];
  d[`functionsversion]:raze string md5 `char$-8!(asc key p`fns;asc p`calls);
  :api.encode[f;d];
  };
/ user u's own last n decisions, from the audit log: what it asked, what ran, and why it was
/ refused. Its own calls only, so it tells it nothing new
history:{[u;n]
  a:audit[];
  :(neg n)sublist select time,query,rewritten,allowed,decision,reason from a where user=u;
  };
apihistory:{[p;u;n;f] tree.chk[(-7h=type n)or -6h=type n;"history takes how many decisions, as a number"]; :api.encode[f;history[u;`long$n]];};
/ describe, with the shape of the data the user can see (shape, above)
apidescribe:{[p;u;f] d:api.describe[p;u;`q]; d[`shape]:shape[p;u]; :api.encode[f;d];};
/ the rule whose refusal text a message contains (qsp.api.rules), or ` - so a caller goes straight
/ from a refusal to the rule that explains it, and to that rule's good examples
ruleof:{[p;m]
  if[0=count m;:`];
  t:api.rules[p;`q];
  / the longest pattern the message contains is the most specific rule; language and refusals,
  / the catch-alls, lose a tie
  n:{[m;rf] max 0,count each rf where m like/: {"*",x,"*"} each rf}[m] each t`refusal;
  n-:0.5*t[`id] in `language`refusals;
  :$[0<max n;t[`id] n?max n;`];
  };
/ validate's answer with the refusal as data: code, kind and subject (core/codes.q) - `, ` and ""
/ when allowed
apivalidate:{[p;u;q;f]
  v:validate[p;u;q];
  c:$[v 0;`code`kind`subject!(`;`;"");codes.classify v 1];
  :api.encode[f;(`allowed`reason`rule!(v 0;v 1;ruleof[p;v 1])),c];
  };
apiexplain:{[p;u;q;f] :api.encode[f;explain[p;u;q]];};
/ term n's query with arguments a filled in, for user u: the query text, to run like any other. A
/ term the user cannot see - one naming a table it cannot read - is no term to it
termquery:{[p;u;n;a]
  if[10h=type n;n:`$n];
  tree.chk[-11h=type n;"term takes a term's name, then its arguments"];
  t:api.termsfor[p;exec tbl from rev.access[p;u]];
  tree.chk[n in t`term;"no term ",string[n]," that this user can read"];
  :pol.terminst[p;n;a];
  };
/ runterm[p;u;n;args] -> term n run as user u with args
runterm:{[p;u;n;a] :run[p;u;termquery[p;u;n;a]];};

/ is a receipt genuine, and is it one this process still keeps? Any login may ask: a receipt
/ says nothing to anyone who does not already hold it
apiverify:{[r;f] :api.encode[f;`valid`stored!(verify r;$[99h=type r;rcpt.isstored r`id;0b])];};
/ a stored receipt and the values it kept, to the login it ran for or the gateway that asked
apireceipt:{[id;caller;f]
  if[10h=type id;id:"G"$id];
  tree.chk[-2h=type id;"receipt takes a receipt id, a guid"];
  :api.encode[f;receipt[id;caller]];
  };
/ estimate, with a refusal as data as validate gives it
apiestimate:{[p;u;q;f]
  e:estimate[p;u;q];
  if[not e`allowed;e,:`code`kind`subject#codes.classify e`reason];
  :api.encode[f;e];
  };
apis:``version`limits`memstats`users`functions`rules`primer`access`describe`validate`explain`estimate`brief`history`verify`receipt!(::;
  apiversion;api.limits;api.memstats;api.users;api.functions;api.rules;api.primer;api.access;apidescribe;
  apivalidate;apiexplain;apiestimate;apibrief;apihistory;apiverify;apireceipt);

/ ------------------------------------------------------------------ the api over IPC
/ (`.qsp.api;name;...) calls the api by name against the served policy: process facts, and the
/ policy as it applies to one user, for a gateway or a query generator to read before writing q.
/ A gateway names the user - (`.qsp.api;`describe;`alice) - and may make every call. A user's own
/ login may make the calls about itself, with no user: (`.qsp.api;`describe). A format may follow
/ the arguments - (`.qsp.api;`describe;`json), (`.qsp.api;`describe;`alice;`json) - and is `q
/ when it does not. `.qsp.limits alone is (`.qsp.api;`limits), as the original qsp answered it

/ each call: which only a gateway may make, which name a user, and how many arguments follow
apinames:`version`limits`memstats`users`functions`rules`primer`access`describe`validate`explain`estimate`brief`history`verify`receipt`reloadkeys`codes`term;
apigwonly:`limits`memstats`users`reloadkeys;
apiuser:`access`describe`validate`explain`estimate`brief`history`term;
apinargs:apinames!0 0 0 0 0 0 0 0 0 1 1 1 0 1 1 1 0 0 2;
/ and what it does, as [policy;user;arguments;format]
apifns:apinames!(
  {[p;u;a;f] apiversion f};{[p;u;a;f] api.limits[p;f]};{[p;u;a;f] api.memstats f};
  {[p;u;a;f] api.users[p;f]};{[p;u;a;f] api.functions[p;f]};{[p;u;a;f] api.rules[p;f]};
  {[p;u;a;f] api.primer f};
  {[p;u;a;f] api.access[p;u;f]};{[p;u;a;f] apidescribe[p;u;f]};
  {[p;u;a;f] apivalidate[p;u;first a;f]};{[p;u;a;f] apiexplain[p;u;first a;f]};
  {[p;u;a;f] apiestimate[p;u;first a;f]};
  {[p;u;a;f] apibrief[p;u;f]};{[p;u;a;f] apihistory[p;u;first a;f]};
  {[p;u;a;f] apiverify[first a;f]};{[p;u;a;f] apireceipt[first a;.z.u;f]};
  {[p;u;a;f] api.encode[f;reloadkeys p]};{[p;u;a;f] api.encode[f;codes.table[]]};
  {[p;u;a;f] api.encode[f;termquery[p;u;a 0;a 1]]});

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
serverunx:{[h;p;u;q] r:go[chain h;p;u;q]; :(r 0;readable[p;r 1]);};

req:{[h;x]
  / the handler h: run message x as the caller, under the served policy
  if[0=.z.w;:priorof[h] x];
  p:served;
  / .z.pw admits only logins of the policy served when the connection opened. Check again: the
  / policy may have been swapped since, or .z.pw replaced
  if[not islogin[p;.z.u];refuse[p;.z.u;x;();`denied;"not a user of this policy: ",-3!.z.u]];
  if[x~limitsmsg;x:(apimsg;`limits)];
  if[isapicall x;:@[apicall[p];x;{[p;x;e] refuse[p;.z.u;x;();$[isqsp e;`denied;`error];e]}[p;x]]];
  if[isasync x;:asyncreq[h;x]];
  if[isgatewaycall[p;x];
    / execasr answers with data whatever happens, so its caller has one shape to read
    :$[execasr~first x;@[gatewaycall[h;p];x;{[p;x;m] $[99h=type m;m;refusalreply[p;m]]}[p;x]];gatewaycall[h;p;x]]];
  / a user's own login may send the same message naming itself, to get back what ran with the
  / result: an agent bound to one user sees the rewrite without a gateway's power to be anyone.
  / Context is a gateway's to give: a user could otherwise label its queries with any question
  if[isselfcall x;
    if[4=count x;refuse[p;.z.u;x 1;();`denied;"only a gateway login may send ctx with a query"]];
    :execrun[chain h;p;.z.u;x;`]];
  :serverun[h;p;.z.u;x];
  };

gatewaycall:{[h;p;x]
  / a user that is not a single symbol is refused, and logged against the gateway's own login
  if[not isuser[p;x 2];refuse[p;$[-11h=type x 2;x 2;.z.u];x 1;();`denied;"not a user of this policy: ",-3!x 2]];
  / a scoped gateway names only members of its group, and is logged against its own login when
  / it names anyone else
  if[not pol.inscope[p;.z.u;x 2];refuse[p;.z.u;x 1;();`denied;
    "gateway ",string[.z.u]," may not run queries as ",string[x 2]," - it may name only members of ",string p[`gwscope] .z.u]];
  :execrun[chain h;p;x 2;x;.z.u];
  };

/ execasr's reply to a refusal that came before the query was run
refusalreply:{[p;m]
  d:refusal[p;m];
  :(`status`result`rewritten`receipt!($[`runtime~d`kind;`error;`refused];(::);"";(::))),d;
  };

asyncreq:{[h;x]
  / an async request: handle the message it carries as if it had come synchronously, then send the
  / answer back on the same handle. A refusal is an answer, not a signal: the caller is waiting
  / for a reply with its id, and a signal would leave it waiting
  w:.z.w;
  m:x 2;
  r:$[isasync m;(0b;"qsp: an async request cannot carry another");@[{(1b;req[x;y])}[h];m;{(0b;x)}]];
  a:$[r 0;r;(0b;refusal[served;r 1])];
  @[neg w;(replymsg;x 1;a);{[e] }];
  :(::);
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
  / the receipt keys first: a policy naming a key directory that cannot be read is not served
  rcpt.loadkeys p[`config;`receiptkeys];
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
gatewaywrapr:{[q;u] :(execasr;q;u);};

export:([
  / build a policy - each returns a new policy
  policy:pol.new;table:pol.table;partition:pol.partition;refresh:pol.refresh;
  droptable:pol.droptable;grant:pol.grant;revoke:pol.revoke;member:pol.member;
  unmember:pol.unmember;allowfunction:pol.allowfunction;denyfunction:pol.denyfunction;
  allowcall:pol.allowcall;allowjoincall:pol.allowjoincall;denycall:pol.denycall;
  gateway:pol.gateway;configure:pol.configure;colinfo:pol.colinfo;term:pol.term;paramterm:pol.paramterm;mingroup:pol.mingroup;
  / keep one as files
  fromfiles:polfiles.fromfiles;check:polfiles.check;scaffold:polfiles.scaffold;schemadrift:polfiles.schemadrift;
  measure:polfiles.measure;remeasure:polfiles.remeasure;
  / inspect one
  columnsfor:pol.columnsfor;filterfor:pol.filterfor;access:rev.access;diff:rev.diff;api:apis;
  / enforce it
  run;runx;rewrite;explain;validate;estimate;fullscans;checkterms;agentlint;termquery;runterm;
  / a refusal as data: its code, kind and subject, and the published codes
  classify:codes.classify;codes:codes.table;refusal;
  / test it
  tests;checktests;runtests;adminui;
  / serve it
  serve;unserve;active;audit;clearaudit;audittable;auditto;gatewaywrap;gatewaywrapx;gatewaywrapr;
  / receipts: run with one, fetch one, check one, and keep the keys that sign them
  runr;receipt;verify;newreceiptkey;reloadkeys;
  / render a parse tree as q-SQL text, with a whitelist's names (a policy's fns)
  totext:qsql.text;
  / gateways limited to the users of one group
  scopegateway:pol.scopegateway;
  / write filters
  f;ALL:pol.allcols;USER:tree.usermark;NOW:tree.nowmark;
  version]);
