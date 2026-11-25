/ the example's admin UI:   q di/qsp/examples/equities/demo.q [-db DIR] [-policy DIR] [-port 8080] [-public]
/ builds the example database if it is not there, loads it and the policy (setup.q, as hdb.q
/ does), then opens qsp.adminui on it and prints the address. That is all: the page is qsp's own
/ (admin/ in the module), and any process with data loaded can do the same with
/   qsp.adminui`local
/ an admin tool, not a policed process: anyone who reaches the page can query as any user and see
/ the rows the policy hides, so it answers this machine only unless started with -public. Run it
/ in the foreground: q exits when its console's input ends

/ this directory, absolute - loading the database moves the working directory into it
/ (q demo.q and q ./demo.q give no directory, or ./ - neither is written into the paths shown)
here:{[f] d:$[count i:where f="/";(1+last i)#f;""]; if["/"<>first d;d:system["cd"],"/",d];
  while[d like "*/./*";d:ssr[d;"/./";"/"]]; :d;} string .z.f;
system"l ",here,"setup.q";
\c 40 300
/ floats to 12 significant digits in the page's JSON, which .j.j writes as string does
\P 12

/ ------------------------------------------------------------------ -check: answer each call, then exit
/ every call the page makes, through the same handler the page reaches, checked for an answer of
/ the right shape - for CI, which has no browser. Exits 1 if one fails

if[`check in key o;
  qsp.adminui ([access:`local;port:0;dir:pdir]);
  post:{[c;a] r:.j.k last "\r\n\r\n" vs .z.pp enlist "api ",.j.j `call`args!(c;a); :r;};
  ok:{[name;b] -1 $[b;"  ok    ";"  FAIL  "],name; :b;};
  D:last string .Q.pv;
  r:();
  ov:post[`overview;()!()];
  r,:ok["overview";ov[`ok]and all `users`grants`tables`files`sources in key ov`data];
  x:post[`run;`user`query!("sales_na";"select notional:sum notional by account from trades where date=",D)];
  r,:ok["run: a row filter is added";x[`ok]and(x[`data;`ok])and 0<count x[`data;`injected]];
  x:post[`run;`user`query!("llm1";"select account from trades where date=",D)];
  r,:ok["run: a hidden column is refused";x[`ok]and(not x[`data;`ok])and x[`data;`error] like "qsp: unknown or not-permitted column*"];
  x:post[`lens;`user`table!("sales_na";"trades")];
  r,:ok["lens: a filtered user sees some rows";x[`ok]and(0<count x[`data;`visiblerows])and(count x[`data;`visiblerows])<count x[`data;`sample]];
  x:post[`lens;`user`table!("sales_na";"accounts")];
  r,:ok["lens: a string column of a splayed table is strings";x[`ok]and 10h=type first x[`data;`sample;;1]];
  x:post[`run;`user`query!("compliance1";"select from accounts")];
  r,:ok["run: ...and so in a result";x[`ok]and 10h=type first x[`data;`result;`rows;;1]];
  x:post[`compare;(enlist`query)!enlist "select from venues"];
  r,:ok["compare: every user";x[`ok]and(count x`data)=7];
  x:post[`whatif;(enlist`files)!enlist (enlist`$"grants.csv")!enlist "entity,tbl,columns,filter\nresearch,trades,date nosuch,\n"];
  r,:ok["whatif: a bad edit names its line";x[`ok]and(not x[`data;`ok])and 2=first x[`data;`problems;`line]];
  x:post[`test;(enlist`i)!enlist 0];
  r,:ok["test: the first of tests.csv passes, with its run";x[`ok]and(x[`data;`pass])and x[`data;`ok]];
  x:post[`whatif;(enlist`files)!enlist (enlist`$"members.csv")!enlist "user,entity\nllm1,research\nresearch,refdata\n"];
  r,:ok["whatif: the tests run against the edit";x[`ok]and(x[`data;`ok])and 0<count x[`data;`tests]];
  x:post[`run;`user`query!("sales_na";"asc exec distinct account from select account from trades where date=",D)];
  r,:ok["run: a short result comes with its q literal";x[`ok]and x[`data;`lit]~"`A1`A3`A5`A7"];
  x:post[`audit;()!()];
  r,:ok["audit";x`ok];
  x:post[`nosuch;()!()];
  r,:ok["an unknown call is refused";not x`ok];
  pg:.z.ph enlist "views/map.js";
  r,:ok["the page's files are served";pg like "HTTP/1.1 200 OK*"];
  r,:ok["and nothing else";(.z.ph enlist "../init.q") like "HTTP/1.1 404*"];
  -1 $[all r;"every call answered";string[sum not r]," call(s) failed"];
  exit `long$not all r];

/ ------------------------------------------------------------------ open it

qsp.adminui ([access:$[`public in key o;`public;`local];port:$[`port in key o;"J"$first o`port;0N];dir:pdir]);
