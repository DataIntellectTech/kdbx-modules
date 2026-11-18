/ fixtures and helpers for di.qsp's tests - loaded by test.csv and by test/server.q
/ expects qsp:use`di.qsp to have run; defines globals only, and touches no files

/ the module directory, absolute, as loading a partitioned database changes directory
.t.mod:{[m] $["/"=first m;m;system["cd"],"/",m],"/"} .Q.m.mp`di.qsp;
.t.cwd:system"cd";
qt:use`di.qsp.core.tree;
qp:use`di.qsp.policy;
qf:use`di.qsp.policy.files;
qa:use`di.qsp.api;

/ ------------------------------------------------------------------ fixtures
/ the same data and policy are policed in process and, by test/server.q, over IPC

trade:([]date:2010.01.01 2010.01.01 2010.01.02 2010.01.02 2010.01.03;
  sym:`aaa`bbb`aaa`ccc`bbb;account:`A1`A2`A1`A3`A2;size:10 20 30 40 50;
  price:1 2 3 4 5f;trader:`tom`dick`tom`harry`dick;pnl:100 200 300 400 500f);
quote:([]sym:`aaa`bbb`ccc;bid:1 2 3f;ask:1.5 2.5 3.5);
secret:([]k:1 2 3;v:`x`y`z);
leak:`none;
/ a global a query must never get to run
leakfn:{leak::`leaked;x};
entitlements:([]user:`alice`alice`bob;sym:`aaa`bbb`ccc);
allowedsyms:{[u] exec sym from entitlements where user=u};

P:qsp.policy[];
P:qsp.table[P;`trade;::];
P:qsp.table[P;`quote;::];
/ llm: two accounts, and no trader or pnl
P:qsp.grant[P;`llm;`trade;`date`sym`account`size`price;enlist qsp.f.isin[`account;`A1`A2]];
P:qsp.grant[P;`llm;`quote;qsp.ALL;()];
/ analyst: everything
P:qsp.grant[P;`analyst;`trade;qsp.ALL;()];
/ desk: symbols looked up per user, per query, baked into the query
P:qsp.grant[P;`desk;`trade;`date`sym`size;{[u] enlist qsp.f.isin[`sym;allowedsyms u]}];
/ call: the same lookup left in the tree, keyed on the user
P:qsp.grant[P;`call;`trade;`date`sym`size;enlist (in;`sym;(`allowedsyms;qsp.USER))];
P:qsp.member[P;`llmu;`llm];
P:qsp.member[P;`junior;`llm];
P:qsp.member[P;`ana;`analyst];
P:qsp.member[P;`alice;`desk];
P:qsp.member[P;`bob;`desk];
P:qsp.member[P;`carol;`call];
P:qsp.gateway[P;`gateway];

A12:select from trade where account in `A1`A2;
LLMC:`date`sym`account`size`price;

/ ------------------------------------------------------------------ assertions
/ each returns 1b on success, and prints what it saw otherwise

.t.eq:{[a;b]
  / a matches b
  if[not r:a~b;-1"  got: ",.Q.s1 a;-1"  exp: ",.Q.s1 b];
  :r;
  };

.t.err:{[f;m]
  / evaluating f signals, with a message matching pattern m
  r:@[{(0b;value x)};f;{(1b;x)}];
  if[not r 0;-1"  ran and returned: ",.Q.s1 r 1;:0b];
  if[not r[1] like m;-1"  wrong refusal: ",r 1;:0b];
  :1b;
  };

/ a qsp refusal
.t.deny:{[p;u;q] :.t.err[(qsp.run;p;u;q);"qsp: *"];};

.t.allow:{[p;u;q;e]
  / q runs as u under p, and returns e
  r:@[{(1b;qsp.run . x)};(p;u;q);{(0b;x)}];
  if[not r 0;-1"  refused: ",r 1;:0b];
  :.t.eq[r 1;e];
  };

/ ------------------------------------------------------------------ databases

.t.mkpart:{[dir;gacct;d]
  / one date partition of ticks under dir; gacct also indexes account
  t:([]sym:`aaa`aaa`bbb`ccc;time:d+0D09:00 0D10:00 0D11:00 0D12:00;account:`A1`A2`A1`A3;size:1 2 3 4);
  t:update `p#sym from .Q.en[hsym`$dir] t;
  if[gacct;t:update `g#account from t];
  .Q.dd[hsym`$dir,"/",string d;`ticks`] set t;
  };

.t.mkhdb:{[dir;gacct]
  / a two-day partitioned database under dir, loaded
  .t.mkpart[dir;gacct] each 2020.01.01 2020.01.02;
  system"l ",dir;
  };

/ ------------------------------------------------------------------ ipc

.t.try:{[u]
  / one attempt to log in to the test server as u; null if it is not up yet
  h:@[hopen;(`$":localhost:",string[.t.port],":",string[u],":x";1000);{0Ni}];
  if[null h;system"sleep 0.1"];
  :h;
  };

/ keep trying until it answers
.t.retry:{[u;h] :$[null h;.t.try u;h];};

/ a handle to the test server as u, waiting up to 10 seconds for it to start
.t.open:{[u] :.t.retry[u]/[100;0Ni];};

/ ------------------------------------------------------------------ policy files

.t.pol:{[n;fs]
  / write a policy directory n, fresh, from name!contents; contents are lines, or bytes as they are
  d:.t.tmp,"/",n;
  system"rm -rf ",d;
  system"mkdir -p ",d;
  .t.polfile[d]'[key fs;value fs];
  :d;
  };

.t.polfile:{[d;f;c]
  / one file of a policy directory; a name without an extension gets .csv
  s:string f;
  p:hsym`$d,"/",s,$["."in s;"";".csv"];
  $[4h=type c;p 1: c;p 0: (),/:c];
  };

.t.problems:{[fs] :qsp.check .t.pol["p";fs];};
/ the tests in a directory n holding only a tests.csv of lines ls (its header is added)
.t.suitedir:{[n;ls]
  d:"/tmp/qspsuite",string[.z.i],"/",n;
  system"rm -rf ",d;
  system"mkdir -p ",d;
  (hsym`$d,"/tests.csv") 0: (enlist "user,query,expect,value,note"),ls;
  :d;
  };
.t.suite:{[n;ls] :qsp.tests .t.suitedir[n;ls];};
/ a call to the admin UI's JSON API, through its own handler: (ok; data or error), from JSON
.t.post:{[c;a] :.j.k last "\r\n\r\n" vs .z.pp enlist "api ",.j.j `call`args!(c;a);};
/ evaluating f signals, and the message contains each of strings ps
.t.errhas:{[f;ps]
  r:@[{(0b;value x)};f;{(1b;x)}];
  if[not r 0;-1"  ran and returned: ",.Q.s1 r 1;:0b];
  if[not all b:{0<count ss[x;y]}[r 1] each ps;-1"  message: ",r 1;-1"  lacks: ",.Q.s1 ps where not b;:0b];
  :1b;
  };
.t.load:{[fs] :qsp.fromfiles .t.pol["p";fs];};
/ lines -> the bytes of a file with Windows line endings
.t.crlf:{"x"$raze x,\:"\r\n"};
.t.with:{[fs;f;c] :fs,(enlist f)!enlist c;};

.t.report:{[e;x]
  / the problems e are exactly x: a list of (file;line;error pattern)
  if[not 0h=type first x;x:enlist x];
  ok:$[count[e]<>count x;0b;
    (e[`file]~`$x[;0])and(e[`line]~`long$x[;1])and all e[`error] like' x[;2]];
  if[not ok;-1"  got:";show e;-1"  expected:";show x];
  :ok;
  };

.t.clean:{[e] :.t.report[e;()];};

/ the smallest good policy
B:`tables`grants!(("tbl,partition";"trade,");("entity,tbl,columns,filter";"llm,trade,date sym,"));

/ the fixture policy P, as files
FD:`tables`grants`members`gateways!(
  ("tbl,partition";"trade,";"quote,");
  ("entity,tbl,columns,filter";
   "# the generator's group";
   "llm,trade,date sym account size price,account in `A1`A2";
   "llm,quote,*,";
   "";
   "analyst,trade,*,";
   "desk,trade,date sym size,fn:deskfilter";
   "call,trade,date sym size,sym in allowedsyms qsp.USER");
  ("user,entity";"llmu,llm";"junior,llm";"ana,analyst";"alice,desk";"bob,desk";"carol,call");
  ("login";"gateway"));

/ text as a quoted csv cell, as a spreadsheet writes one
.t.cell:{"\"",ssr[x;"\"";"\"\""],"\""};
/ a one-row grants file with filter text f, loaded: its row filter
.t.filter:{[f] :first exec rows from .t.load[.t.with[B;`grants;("entity,tbl,columns,filter";"llm,trade,*,",.t.cell f)]]`grants;};
/ ...or the problems with it
.t.badfilter:{[f] :.t.problems .t.with[B;`grants;("entity,tbl,columns,filter";"llm,trade,*,",.t.cell f)];};

.t.roundtrip:{[cell]
  / the filter access shows for cell loads back as the same filter
  f:.t.filter cell;
  p:qsp.member[.t.load .t.with[B;`grants;("entity,tbl,columns,filter";"llm,trade,*,",.t.cell cell)];`u;`llm];
  :f~.t.filter first exec rows from qsp.access[p;`u];
  };

/ ------------------------------------------------------------------ bin/policy.q

/ any line of ls holding every one of ws literally (like signals nyi on three or more *)
.t.has:{[ls;ws] :any .t.hasall[ws] each ls;};
.t.hasall:{[ws;l] :all {1<count y vs x}[l] each ws;};

.t.tool:{[args]
  / run bin/policy.q with args: (exit code; output)
  o:.t.tmp,"/tool.out";
  / in a subshell: q's system returns nothing for a bare child q
  c:first system"(q ",.t.mod,"bin/policy.q ",args," -q </dev/null >",o," 2>&1); echo $?";
  :("J"$c;read0 hsym`$o);
  };
