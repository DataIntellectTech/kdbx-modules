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
here:{[f] :$[count i:where f="/";(1+last i)#f;"./"];} string .z.f;
if["/"<>first here;here:system["cd"],"/",here];
.Q.m.SP:(enlist here,"../../../../"),.Q.m.SP;
qsp:use`di.qsp;
system"l ",here,"mkhdb.q";
\c 40 200

/ ------------------------------------------------------------------ the database

o:.Q.opt .z.x;
db:$[`db in key o;first o`db;$[count t:getenv`TMPDIR;t;"/tmp"],"/qsp-example-db"];
if["/"<>first db;db:system["cd"],"/",db];
if[()~key hsym`$db;-1"building the example database in ",db;mkhdb[db;5]];
system"l ",db;

/ ------------------------------------------------------------------ what the policy names
/ the lookups its filters call and its clock. They live with the policy, so a change to them is
/ reviewed with the grants that call them, and CI loads the same file to check the policy

system"l ",here,"policy/defs.q";

/ qsp's decision log, under the name the policy grants to compliance
qsp.auditto`auditlog;

/ ------------------------------------------------------------------ the policy

p:qsp.fromfiles here,"policy";

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

/ run query q as user u, show what came back, and check it is what the step expects:
/ `rows - a non-empty result, `empty - an empty one, `refused - a qsp refusal
step:{[u;e;q;why]
  -1"\n",string[u],"> ",q;
  -1"  ",why;
  r:@[{(1b;qsp.run[p;x;y])}[u];q;{(0b;x)}];
  got:$[not r 0;$[r[1] like "qsp: *";`refused;`error];0=count r 1;`empty;`rows];
  $[r 0;[show 8 sublist r 1;if[8<count r 1;-1"  ... ",string[count r 1]," rows"]];-1"  refused: ",r 1];
  if[not got~e;-1"  ** expected ",string[e],", got ",string got;failed,:enlist q];
  };
failed:();

D:"2026.10.09";   / the last day
E:"2026.10.07";   / the last day research can see


-1"\n== research: an external analyst, or an LLM. Prints and quotes for four names, two days late";
step[`llm1;`rows;"select vwap:size wavg price by sym from trades where date=",E;
  "every name is asked for; only the four granted come back"];
step[`llm1;`empty;"select vwap:size wavg price by sym from trades where date=",D;
  "the last two days are embargoed (qsp.aged[date;2D]): the same query finds nothing"];
step[`llm1;`rows;"select from venues";"reference data, which every role gets through the refdata group"];
step[`llm1;`empty;"select from quotes where date=",E,", sym=`JPM";
  "a name outside the row filter is not an error - there is just nothing there"];
step[`llm1;`refused;"select sum size by account from trades where date=",E;
  "account is not granted, so it does not exist for this user"];
step[`llm1;`rows;"select n:count sym by date from trades where sym=`AAPL";
  "no date in the query, but the embargo is a date constraint, so only the days before it are read"];
step[`llm1;`refused;"select from accounts";"no grant on accounts at all"];
step[`llm1;`refused;"select from trades where date=",E,", 0<count system\"ls\"";
  "system is never allowed, whatever the policy says"];

-1"\n== quant: all the market data, with no client or trader";
step[`quant1;`refused;"select from trades where sym=`AAPL";
  "no date: that would read every partition, and requirepartition refuses it"];
step[`quant1;`refused;"select n:count i by sym from quotes where date=",D;
  "i, the row index, would show where hidden rows are; it is off unless the policy sets rowindex"];
step[`quant1;`rows;"select spread:avg ask-bid, n:count sym by sym from quotes where date=",D;
  "count a column instead - and every name is here"];
step[`quant1;`rows;"select time,bid1,bid2,bid3,ask1,ask2,ask3 from depth where date=",D,", sym=`VOD";
  "the depth of book, which no one but quant and compliance sees"];
step[`quant1;`refused;"select notional:sum notional by account from trades where date=",D;
  "the prints, but not whose they are"];

-1"\n== sales: their region's clients, looked up per user on every query";
step[`sales_na;`rows;"select notional:sum notional by account from trades where date=",D;
  "the same query as quant's - and here it works, for the North American accounts only"];
step[`sales_emea;`rows;"select notional:sum notional by account from trades where date=",D;
  "the same text again, as the EMEA salesperson (who also covers APAC)"];
step[`sales_na;`rows;"select from accounts";"the clients behind those accounts, and no others"];
step[`sales_na;`rows;"select notional:sum notional by clientType from ",
  "ej[`account;select from trades where date=",D,";select account,clientType from accounts]";
  "a join: both sides are filtered before they meet"];
step[`sales_na;`refused;"select n:count sym by trader from trades where date=",D;
  "who executed it stays with the desk"];

-1"\n== desk heads: their own desk's orders, and its traders' fills";
step[`cash_head;`rows;"select orders:count orderID, filled:sum filledQty by trader from orders where date=",D;
  "the CASH desk's traders"];
step[`etf_head;`rows;"select orders:count orderID, filled:sum filledQty by trader from orders where date=",D;
  "the same text, as the ETF desk head"];
step[`cash_head;`empty;"select from orders where date=",D,", desk=`ETF";
  "asking for another desk's orders finds none"];
step[`cash_head;`refused;"select from accounts";"an account is a code here; who the client is stays with sales"];

-1"\n== compliance: everything, and qsp's own log";
step[`compliance1;`rows;"select trades:count sym, notional:sum notional by date from trades where date within 2026.10.05 2026.10.09";
  "every row of every partition"];
step[`compliance1;`rows;"select user,query,reason from auditlog where decision<>`allowed";
  "every refusal above, with who asked and why it was refused"];
step[`llm1;`refused;"select from auditlog";"and no one else reads it"];

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
