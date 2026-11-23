/ a policed HDB to try qsp on:   q di/qsp/examples/equities/hdb.q [-db DIR] [-p 5100]
/ builds the example database with mkhdb.q if DIR does not exist (default: qsp-example-db in
/ $TMPDIR or /tmp - never inside the module, which is copied as a unit), loads it, loads the
/ policy kept as files in policy/ and the q it names (policy/defs.q), and walks through what each
/ role can and cannot do. Every step says what should happen, and the script exits 1 if one does
/ not - so it is also a test. See README.md
/ With -p it then serves the policy: connect as any user in policy/members.csv and send plain
/ q, or log in as gateway and send (`.qsp.execas;query;user). Without -p it exits.
/ This console is not policed; try qsp.run[p;`llm1;"..."] and qsp.explain[p;`llm1;"..."] here

/ this directory, absolute - loading the database moves the working directory into it
/ (q hdb.q and q ./hdb.q give no directory, or ./ - neither is written into the paths shown)
here:{[f] d:$[count i:where f="/";(1+last i)#f;""]; if["/"<>first d;d:system["cd"],"/",d];
  while[d like "*/./*";d:ssr[d;"/./";"/"]]; :d;} string .z.f;
system"l ",here,"setup.q";
\c 40 200

/ who can read what, user by user: each table, its rows, and its columns
-1"\n== who can read what (qsp.access[p;`] has it as a table)";
showaccess:{[a]
  {[a;u]
    r:select from a where user=u;
    -1"\n",string[u]," (",(", "sv string distinct raze r`via),")";
    {-1"  ",(12$string x`tbl),"rows:    ",x[`rows],"\n",(14#" "),"columns: "," "sv string x`columns} each r;
    }[a] each distinct a`user;
  };
showaccess qsp.access[p;`];

/ ------------------------------------------------------------------ the walkthrough
/ policy/tests.csv says what this policy must mean, a query at a time: qsp.tests reads it, and
/ qsp.runtests judges each - the same verdict bin/policy.q -test gives CI and the admin UI shows.
/ Here each is also run with qsp.run, to show what came back and fill the audit log

D:"2026.10.09";   / the last day
E:"2026.10.07";   / the last day research can see: its grant holds back two days
failed:();
T:qsp.tests pdir;
R:qsp.runtests[p;T];
show1:{[was;r]
  if[not r[`user]~was;-1"\n== ",string[r`user]," (",(", "sv string exec distinct entity from p[`members] where user=r`user),")"];
  -1"\n",string[r`user],"> ",r`query;
  if[count r`note;-1"  ",r`note];
  v:@[{(1b;qsp.run[p;x;y])}[r`user];r`query;{(0b;x)}];
  $[v 0;[show 8 sublist v 1;if[8<count v 1;-1"  ... ",string[count v 1]," rows"]];-1"  refused: ",v 1];
  if[not r`pass;-1"  ** expected ",string[r`expect],$[count r`value;" ",r`value;""],", got ",r`got;failed,:enlist r`query];
  :r`user;
  };
show1/[`;R];
-1"\n",string[sum R`pass]," of ",string[count R]," tests in policy/tests.csv passed";

-1"\n== the rules an LLM agent is given (qsp.api.rules[p;`json]), checked: every query a rule gives";
-1"   as good runs, and every one it gives as bad is refused with the refusal it names";
/ the rules' examples are over trades and quotes, which quant1 reads in full
rulecheck:{[r]
  {[id;q] e:@[{qsp.run[p;`quant1;x];""};q;{x}];
    if[count e;-1"  ** rule ",string[id],": ",q," was refused: ",e;failed,:enlist q]}[r`id] each r`good;
  if[0=count r`refusal;:()];
  {[id;rf;q] e:@[{qsp.run[p;`quant1;x];""};q;{x}];
    ok:$[count e;any e like/: {"*",x,"*"} each rf;0b];
    if[not ok;-1"  ** rule ",string[id],": ",q,$[count e;" was refused for another reason: ",e;" ran"];failed,:enlist q]}[r`id;r`refusal] each r`bad;
  };
rulecheck each qsp.api.rules[p;`q];
-1"  ",string[count qsp.api.rules[p;`q]]," rules, every example as it says";
-1"  for llm1, describe as JSON starts: ",80#qsp.api.describe[p;`llm1;`json];

-1"\n== the primer an LLM agent is given (qsp.api.primer`q), checked: every q example in it runs";
/ each example is one line between ```q and ``` (indented in a list or not), over trades, quotes
/ and orders, which compliance1 reads in full
pl:trim "\n" vs qsp.api.primer`q;
pi:where pl like "```q";
if[not all pl[pi+2] like "```";-1"  ** a primer example spans more than one line";failed,:enlist"primer layout"];
{[q] e:@[{qsp.run[p;`compliance1;x];""};q;{x}];
  if[count e;-1"  ** primer: ",q," was refused: ",e;failed,:enlist q]} each pl pi+1;
-1"  ",string[count pi]," examples, each run as compliance1";

-1"\n== what actually runs (qsp.explain): sales_na's query, with the row filter and the columns pinned\n";
-1 qsp.explain[p;`sales_na;"select notional:sum notional by account from trades where date=",D];

-1"\n",$[count failed;string[count failed]," step(s) did not go as expected:\n  ","\n  " sv failed;
  "every step went as expected"];

/ ------------------------------------------------------------------ serve, or exit

if[0=system"p";exit `long$0<count failed];
qsp.serve p;
-1"\nqsp serving ",db," on port ",string[system"p"],". From another q:";
-1"  h:hopen `:localhost:",string[system"p"],":llm1:x      / any user in policy/members.csv";
-1"  h\"select vwap:size wavg price by sym from trades where date=",E,"\"";
-1"  g:hopen `:localhost:",string[system"p"],":gateway:x   / a gateway runs queries as a named user";
-1"  g(`.qsp.execas;\"select from accounts\";`sales_emea)";
-1"Only the policy's users and the gateway login can connect: an unknown name, or a group's name";
-1"(sales, compliance), is refused with 'access. Passwords are not checked here - a real process";
-1"adds -U passwordfile, or its own .z.pw defined before qsp.serve.";
if[not any .z.X in ("-u";"-U");-1"  WARNING: no password file (-u/-U): anyone who knows a user's name can log in as them"];
-1"Restart with -T 10 -w 1000 to bound a query's time and memory.";
