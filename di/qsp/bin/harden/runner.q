/ harden/runner.q - five verification and attack suites for di.qsp
/ Args: -port1 P1 -port2 P2 -rundir RUN -outdir OUT -modroot REPO -poldir POLDIR -q

o:.Q.opt .z.x;
port1:"J"$first o`port1;
port2:"J"$first o`port2;
RUN:first o`rundir;
OUT:first o`outdir;
REPO:first o`modroot;
POLDIR:first o`poldir;

/ the queries checked against a value, each written once, and their expected results (mkexpected.q).
/ cases.q also defines the dates D and E the other suites use
system"l ",{$[count i:where x="/";(1+last i)#x;"./"]}[string .z.f],"cases.q";
exp_data:-9!read1 hsym`$RUN,"/expected.bin";
sym:get hsym`$RUN,"/hdb/sym";

canary_called:hsym`$RUN,"/canary_called";
canary_created:hsym`$RUN,"/canary_created_file";
canary_keep:hsym`$RUN,"/canary_keep_file";

results:([]id:`long$();suite:`symbol$();user:`symbol$();description:();query:();expected:();actual:();passed:`boolean$();notes:());

fmt:{[x] :$[10h=type x;x;-10h=type x;enlist x;-11h=type x;string x;.Q.s1 x];};

add_result:{[suite;user;title;query;expected;actual;passed;note]
  id:1+count results;
  qstr:fmt query;
  estr:fmt expected;
  astr:fmt actual;
  nstr:fmt note;
  tstr:fmt title;
  `results upsert (id;suite;user;tstr;qstr;estr;astr;`boolean$passed;nstr);
  if[not passed;
    -1"[FAIL] #",string[id]," [",string[suite],"/",string[user],"] ",tstr," | expected: ",estr," | actual: ",astr,$[count nstr;" (",nstr,")";""]];
  };

handles:(`symbol$())!`int$();

open_as:{[tries;port;user]
  target:`$":localhost:",string[port],":",string[user],":x";
  h:0Ni;
  do[tries;
    if[null h;
      h:@[hopen;(target;1000);{0Ni}];
      if[null h;system"sleep 0.05"]]];
  :h;
  };

/ Wait for both servers to finish initializing (they both write canary_keep_file before qsp.serve)
-1"Waiting for servers on ports ",string[port1]," and ",string[port2],"...";
h_wait1:0Ni;
h_wait2:0Ni;
do[100;
  if[null[h_wait1] or null[h_wait2];
    if[null h_wait1;h_wait1:@[hopen;(`$":localhost:",string[port1],":llm1:x";500);{0Ni}]];
    if[null h_wait2;h_wait2:@[hopen;(`$":localhost:",string[port2],":llm1:x";500);{0Ni}]];
    if[null[h_wait1] or null[h_wait2];system"sleep 0.05"]]];
if[not null h_wait1;handles[`llm1]:h_wait1];
if[not null h_wait2;@[hclose;h_wait2;::]];

get_handle:{[u]
  if[u in key handles;
    if[not null handles u;:handles u]];
  h:open_as[20;port1;u];
  handles[u]:h;
  :h;
  };

exec_as:{[u;q]
  h:get_handle u;
  if[null h;:(0b;"connection failed")];
  :@[{(1b;x y)}[h];q;{(0b;x)}];
  };

check_val:{[suite;u;title;q;expected;note]
  r:exec_as[u;q];
  if[not r 0;
    :add_result[suite;u;title;q;"match expected table/val (count=",string[count expected],")";"ERROR: ",fmt r 1;0b;note]];
  ok:(r 1)~expected;
  act:$[ok;"match (count=",string[count r 1],")";"MISMATCH (got count=",string[count r 1],", type=",string[type r 1],"): ",120 sublist .Q.s1 r 1];
  add_result[suite;u;title;q;"match (count=",string[count expected],")";act;ok;note];
  };

expected:{[id;u]
  / case id's expected result for user u
  k:`$string[id],"/",string u;
  if[not k in key exp_data;'"no expected result for ",string[id]," as ",string u];
  :exp_data k;
  };

/ case id (cases.q), run as u
check_case:{[suite;id;u] c:cases id; check_val[suite;u;c`title;c`q;expected[id;u];c`note];};

/ case id, forwarded by the gateway login to run as u
check_gw:{[id;u]
  c:cases id;
  check_val[`logins_transport;`gateway;"gateway execas ",string[u],": ",c`title;(`.qsp.execas;c`q;u);expected[id;u];c`note];
  };

check_refused:{[suite;u;title;q;pattern;note]
  r:exec_as[u;q];
  if[r 0;
    :add_result[suite;u;title;q;"refused (",pattern,")";"ALLOWED: ",120 sublist .Q.s1 r 1;0b;note]];
  msg:fmt r 1;
  ok:msg like pattern;
  add_result[suite;u;title;q;"refused (",pattern,")";"ERR: ",msg;ok;note];
  };

reset_canaries:{[]
  if[not ()~key canary_called;@[hdel;canary_called;::]];
  if[not ()~key canary_created;@[hdel;canary_created;::]];
  if[()~key canary_keep;canary_keep 0: enlist "keep"];
  };

check_attack:{[u;title;q;note]
  reset_canaries[];
  r:exec_as[u;q];
  called:not ()~key canary_called;
  created:not ()~key canary_created;
  deleted:()~key canary_keep;
  s:$[r 0;.Q.s1 r 1;""];
  leaked:$[r 0;any {0<count ss[x;y]}[s] each ("alpha";"beta";"gamma";"secret_id";"Northbridge";"Halden";"`NA`EMEA`APAC");0b];
  side:();
  if[called;side,:enlist"canaryfn executed"];
  if[created;side,:enlist"file created"];
  if[deleted;side,:enlist"keep_file deleted"];
  if[leaked;side,:enlist"secret data leaked"];
  passed:0=count side;
  act:$[r 0;"RETURNED: ",100 sublist s;"REFUSED: ",fmt r 1];
  if[count side;act:("SIDE EFFECT [",("; " sv side),"] "),act];
  reset_canaries[];
  add_result[`attacks;u;title;q;"no side effect / no secret leak";act;passed;note];
  };

/ ==============================================================================
/ SUITE 1: permissions
/ ==============================================================================
-1"== Running suite: permissions ==";

/ Reference data for all users
{[id] check_case[`permissions;id] each cases[id;`users]} each `instruments`venues;

/ --- llm1 (research) ---
check_case[`permissions;`llm1_trades_E;`llm1];
check_case[`permissions;`llm1_trades_D;`llm1];
check_case[`permissions;`llm1_trades_D8;`llm1];
check_case[`permissions;`llm1_trades_jpm;`llm1];
check_case[`permissions;`llm1_vwap_E;`llm1];
check_case[`permissions;`llm1_aapl_by_d;`llm1];
check_case[`permissions;`llm1_quotes_E;`llm1];
check_case[`permissions;`llm1_quotes_D;`llm1];

/ llm1 hidden columns on trades: src, account, trader, notional, orderID
{[c]
  check_refused[`permissions;`llm1;"trades hidden col ",string c;
    "select ",string[c]," from trades where date=",E;"qsp: *";""];
  check_refused[`permissions;`llm1;"trades hidden col in where ",string c;
    "select from trades where date=",E,", not null ",string c;"qsp: *";""];
 } each `src`account`trader`notional`orderID;

/ llm1 hidden columns on quotes: src, bsize, asize
{[c]
  check_refused[`permissions;`llm1;"quotes hidden col ",string c;
    "select ",string[c]," from quotes where date=",E;"qsp: *";""];
 } each `src`bsize`asize;

/ llm1 ungranted tables: orders, depth, accounts, traders, auditlog
{[t]
  check_refused[`permissions;`llm1;"ungranted table ",string t;
    "select from ",string[t],$[t in `orders`depth;" where date=",E;""];"qsp: *";""];
 } each `orders`depth`accounts`traders`auditlog;

/ --- quant1 (quant) ---
check_case[`permissions;`trades_D;`quant1];
check_case[`permissions;`quotes_D;`quant1];
check_case[`permissions;`depth_D;`quant1];
check_case[`permissions;`quant1_spread_D;`quant1];

/ quant1 hidden columns on trades: account, trader, orderID
{[c]
  check_refused[`permissions;`quant1;"trades hidden col ",string c;
    "select ",string[c]," from trades where date=",D;"qsp: *";""];
 } each `account`trader`orderID;

/ quant1 ungranted tables: orders, accounts, traders, auditlog
{[t]
  check_refused[`permissions;`quant1;"ungranted table ",string t;
    "select from ",string[t],$[t=`orders;" where date=",D;""];"qsp: *";""];
 } each `orders`accounts`traders`auditlog;

/ --- sales_na & sales_emea (sales) ---
check_case[`permissions;`accounts;`sales_na];
check_case[`permissions;`accounts;`sales_emea];
check_case[`permissions;`trades_D;`sales_na];
check_case[`permissions;`trades_D;`sales_emea];
check_case[`permissions;`orders_D;`sales_na];
check_case[`permissions;`orders_D;`sales_emea];
check_case[`permissions;`notional_D;`sales_na];
check_case[`permissions;`notional_D;`sales_emea];
check_case[`permissions;`sales_join_D;`sales_na];

/ sales hidden columns on trades: src, trader
{[u]
  {[u;c]
    check_refused[`permissions;u;"trades hidden col ",string c;
      "select ",string[c]," from trades where date=",D;"qsp: *";""];
   }[u] each `src`trader;
  / sales hidden columns on orders: trader, desk, arrivalPx
  {[u;c]
    check_refused[`permissions;u;"orders hidden col ",string c;
      "select ",string[c]," from orders where date=",D;"qsp: *";""];
   }[u] each `trader`desk`arrivalPx;
  / sales ungranted tables: quotes, depth, traders, auditlog
  {[u;t]
    check_refused[`permissions;u;"ungranted table ",string t;
      "select from ",string[t],$[t in `quotes`depth;" where date=",D;""];"qsp: *";""];
   }[u] each `quotes`depth`traders`auditlog;
 } each `sales_na`sales_emea;

/ --- cash_head & etf_head (desk) ---
check_case[`permissions;`traders;`cash_head];
check_case[`permissions;`traders;`etf_head];
check_case[`permissions;`orders_D;`cash_head];
check_case[`permissions;`orders_D;`etf_head];
check_case[`permissions;`cash_orders_etf;`cash_head];
check_case[`permissions;`trades_D;`cash_head];
check_case[`permissions;`trades_D;`etf_head];

/ desk ungranted tables: quotes, depth, accounts, auditlog
{[u]
  {[u;t]
    check_refused[`permissions;u;"ungranted table ",string t;
      "select from ",string[t],$[t in `quotes`depth;" where date=",D;""];"qsp: *";""];
   }[u] each `quotes`depth`accounts`auditlog;
 } each `cash_head`etf_head;

/ --- compliance1 (compliance) ---
check_case[`permissions;`accounts;`compliance1];
check_case[`permissions;`traders;`compliance1];
check_case[`permissions;`trades_D;`compliance1];
check_case[`permissions;`quotes_D;`compliance1];
check_case[`permissions;`orders_D;`compliance1];
check_case[`permissions;`depth_D;`compliance1];
check_case[`permissions;`comp_5d_summary;`compliance1];


/ ==============================================================================
/ SUITE 2: logins_transport
/ ==============================================================================
-1"== Running suite: logins_transport ==";

/ Unknown & group logins refused at connect with 'access
{[badu]
  r:@[{(1b;hopen `$":localhost:",string[port1],":",string[x],":x")};badu;{(0b;x)}];
  if[r 0;@[hclose;r 1;::]];
  ok:(not r 0) and (r 1)~"access";
  add_result[`logins_transport;badu;"connect refused for ",string badu;
    "hopen :",string badu;"'access";$[r 0;"CONNECTED";r 1];ok;""];
 } each `unknown_user`nobody`admin`research`quant`sales`desk`compliance`refdata;

/ Gateway login connects, cannot query tables directly
gw:get_handle`gateway;
add_result[`logins_transport;`gateway;"gateway login connects";
  "hopen :gateway";"valid handle";$[null gw;"0Ni";string gw];not null gw;""];

check_refused[`logins_transport;`gateway;"gateway cannot query tables directly";
  "select from venues";"qsp: *";""];

/ Gateway execas forwarding works for real users
check_gw[`accounts;`sales_na];
check_gw[`accounts;`sales_emea];
check_gw[`llm1_vwap_E;`llm1];

/ Gateway execasx returns (result; rewritten_text)
rx:exec_as[`gateway;(`.qsp.execasx;cases[`accounts;`q];`sales_na)];
rx_ok:(rx 0) and (2=count rx 1) and ((first rx 1)~expected[`accounts;`sales_na]) and (10h=type last rx 1);
add_result[`logins_transport;`gateway;"gateway execasx returns (result;rewritten)";
  "(`.qsp.execasx;\"select from accounts\";`sales_na)";"(table;rewritten string)";
  $[rx_ok;"ok";.Q.s1 rx];rx_ok;""];

/ Gateway execas refused for unknown users and groups
{[badu]
  check_refused[`logins_transport;`gateway;"gateway execas refused for ",string badu;
    (`.qsp.execas;"select from venues";badu);"qsp: not a user of this policy*";""];
  check_refused[`logins_transport;`gateway;"gateway execasx refused for ",string badu;
    (`.qsp.execasx;"select from venues";badu);"qsp: not a user of this policy*";""];
 } each `nobody`research`sales`desk`compliance`refdata`gateway;

/ Gateway execas with non-symbol user (string or symbol vector) refused
check_refused[`logins_transport;`gateway;"gateway execas refused for string user";
  (`.qsp.execas;"select from accounts";"sales_na");"qsp: *";"string user in execas"];
check_refused[`logins_transport;`gateway;"gateway execas refused for symbol-vector user";
  (`.qsp.execas;"select from accounts";`sales_na`sales_emea);"qsp: *";"symbol vector user in execas"];

/ Non-gateway cannot use .qsp.execas or .qsp.execasx
check_refused[`logins_transport;`llm1;"non-gateway cannot use .qsp.execas";
  (`.qsp.execas;"select from accounts";`compliance1);"qsp: *";""];
check_refused[`logins_transport;`llm1;"non-gateway cannot use .qsp.execasx";
  (`.qsp.execasx;"select from accounts";`compliance1);"qsp: *";""];

/ A gateway may ask what the process will bear; nobody else may
lim:exec_as[`gateway;`.qsp.limits];
limkeys:`memory_cap_bytes`physical_memory_bytes`heap_in_use_bytes`timeout_s`maxrows`maxsize_bytes;
limok:$[lim 0;(limkeys~key lim 1)and 100000=lim[1]`maxrows;0b];
add_result[`logins_transport;`gateway;"gateway reads .qsp.limits";"`.qsp.limits";
  "the six limits, maxrows 100000";$[lim 0;.Q.s1 lim 1;"ERROR: ",fmt lim 1];limok;""];
check_refused[`logins_transport;`llm1;"non-gateway cannot read .qsp.limits";`.qsp.limits;"qsp: *";""];

/ The api: (`.qsp.api;name;...). A gateway names the user and may make every call; a user's own
/ login may ask about itself
apiok:{[u;title;m;test;want]
  r:exec_as[u;m];
  ok:$[r 0;test r 1;0b];
  add_result[`logins_transport;u;title;m;want;$[r 0;120 sublist .Q.s1 r 1;"ERROR: ",fmt r 1];ok;""];
  };
apiok[`gateway;"api version";(`.qsp.api;`version);{10h=type x};"the module version"];
apiok[`gateway;"api memstats";(`.qsp.api;`memstats);{all `used`heap`wmax in key x};"q's memory statistics"];
apiok[`gateway;"api users";(`.qsp.api;`users);{(`llm1 in x`users)and `gateway in x`gateways};"users and gateways"];
apiok[`gateway;"api functions";(`.qsp.api;`functions);{`sum in x`functions};"the whitelist"];
apiok[`gateway;"api access for sales_na";(`.qsp.api;`access;`sales_na);{`trades in exec tbl from x};"the user's access rows"];
apiok[`gateway;"api describe for llm1";(`.qsp.api;`describe;`llm1);
  {(`date`sym`time`price`size`side~first exec columns from x[`tabs] where tbl=`trades)and 0<count x`rules};"llm1's view of trades, and the rules"];
apiok[`gateway;"api validate refuses a hidden column";(`.qsp.api;`validate;`llm1;"select account from trades where date=",D);{not x`allowed};"([allowed:0b;reason])"];
apiok[`gateway;"api explain shows the rewrite";(`.qsp.api;`explain;`llm1;"select from trades where date=",D);{0<count ss[x;"AAPL"]};"the row filter in the where clause"];
apiok[`llm1;"api describe about oneself";(`.qsp.api;`describe);{`llm1=x`user};"llm1's own description"];
check_refused[`logins_transport;`llm1;"api describe about another user";(`.qsp.api;`describe;`sales_na);"qsp: api call describe takes 0 arguments*";"a user cannot name a user"];
check_refused[`logins_transport;`llm1;"api memstats is gateway only";(`.qsp.api;`memstats);"qsp: api call memstats is for gateway logins only";""];
check_refused[`logins_transport;`gateway;"api unknown call";(`.qsp.api;`nosuch);"qsp: unknown api call*";""];
check_refused[`logins_transport;`gateway;"api describe for an unknown user";(`.qsp.api;`describe;`nobody);"qsp: not a user of this policy*";""];

/ Async (neg h) is policed and audited
reset_canaries[];
h_llm:get_handle`llm1;
(neg h_llm)"canaryfn 1";
h_llm"1+1"; / sync flush
async_called:not ()~key canary_called;
add_result[`logins_transport;`llm1;"async message is policed (canaryfn blocked)";
  "(neg h)\"canaryfn 1\"";"canary not called";$[async_called;"CALLED";"blocked"];not async_called;""];
reset_canaries[];

(neg h_llm)"select account from trades where date=",E;
h_llm"1+1"; / sync flush
al_async:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"*select account*\""];
async_audited:(al_async 0) and (0<count al_async 1) and (`denied=last (al_async 1)`decision);
add_result[`logins_transport;`llm1;"async denied query is recorded in auditlog";
  "(neg h)\"select account from trades...\"";"recorded as denied";
  $[async_audited;"recorded as denied";.Q.s1 al_async];async_audited;""];

/ HTTP GET, HTTP POST, and WebSocket refused
raw_http:{[port;req]
  h:@[hopen;(`$":localhost:",string port;1000);{0Ni}];
  if[null h;:""];
  r:@[{(neg x) y; raze string read1 x}[h];`char$req;{x}];
  @[hclose;h;::];
  :r;
  };

http_get:raze @[system;"curl -s -m 2 -u llm1:x 'http://localhost:",string[port1],"/?select%20from%20venues' 2>/dev/null";{enlist""}];
add_result[`logins_transport;`llm1;"HTTP GET refused";
  "curl GET http://localhost:port1/?select...";"*HTTP access is not permitted* / HTTP refused";http_get;
  (http_get like "*qsp: HTTP access is not permitted*") or (http_get like "*not allowed for HTTP*");""];

http_post:raze @[system;"curl -s -m 2 -u llm1:x -d 'select from venues' 'http://localhost:",string[port1],"/' 2>/dev/null";{enlist""}];
add_result[`logins_transport;`llm1;"HTTP POST refused";
  "curl POST http://localhost:port1/";"*HTTP access is not permitted* / HTTP refused";http_post;
  (http_post like "*qsp: HTTP access is not permitted*") or (http_post like "*not allowed for HTTP*");""];

/ every other HTTP method: .z.pm is refused too, so nothing a module installed before serve
/ answers them unpoliced
{[m]
  r:raze @[system;"curl -s -i -m 2 -u llm1:x -X ",m," -d 'canaryfn 1' 'http://localhost:",string[port1],"/' 2>/dev/null";{enlist""}];
  ok:not any r like/:("*HTTP/1.1 200*";"*42*");
  add_result[`logins_transport;`llm1;"HTTP ",m," refused";"curl -X ",m;"not 200, nothing evaluated";120 sublist r;ok;""];
  } each ("PUT";"DELETE";"OPTIONS";"PATCH");

ws_resp:raze @[system;"curl -s -i -m 2 -u llm1:x -H 'Upgrade: websocket' -H 'Connection: Upgrade' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' 'http://localhost:",string[port1],"/' 2>/dev/null";{enlist""}];
ws_ok:(ws_resp like "*qsp: *") or (ws_resp like "*400*") or (not ws_resp like "*101 Switching Protocols*");
add_result[`logins_transport;`llm1;"WebSocket upgrade refused";
  "curl WebSocket upgrade";
  "not 101 Switching Protocols / qsp refusal";120 sublist ws_resp;ws_ok;""];


/ ==============================================================================
/ SUITE 3: limits
/ ==============================================================================
-1"== Running suite: limits ==";

/ requirepartition refuses unconstrained partition scans
check_refused[`limits;`quant1;"requirepartition refuses unconstrained trades scan";
  "select from trades";"qsp: full table scan: trades needs a constraint on `date*";""];
check_refused[`limits;`quant1;"requirepartition refuses sym-only trades scan";
  "select from trades where sym=`AAPL";"qsp: full table scan: trades needs a constraint on `date*";""];
check_refused[`limits;`quant1;"requirepartition refuses date=max date scan";
  "select from trades where date=max date";"qsp: full table scan: trades needs a constraint on `date*";""];
check_refused[`limits;`quant1;"requirepartition refuses nested unconstrained scan";
  "select from (select from quotes) where date=",D;"qsp: full table scan: quotes needs a constraint on `date*";""];
check_refused[`limits;`quant1;"requirepartition refuses non-leading date after aggregate";
  "select from quotes where bsize=max bsize, date=",D;"qsp: full table scan*";"non-leading date constraint after aggregate"];
check_refused[`limits;`quant1;"requirepartition refuses date<>literal full scan";
  "select count sym from quotes where date<>1900.01.01";"qsp: full table scan*";"date<>literal full scan"];
check_refused[`limits;`quant1;"requirepartition refuses a one-sided date range";
  "select count sym from quotes where date>1900.01.01";"qsp: full table scan*";"date>literal reads every partition after it"];
check_refused[`limits;`quant1;"requirepartition refuses a date range split over two constraints";
  "select count sym from quotes where date>=2026.10.07, date<=2026.10.08";"qsp: full table scan*";"q prunes by the first constraint only"];
check_val[`limits;`quant1;"requirepartition allows date within";
  "select count sym from quotes where date within 2026.10.07 2026.10.08";([]sym:enlist 8000);""];
check_refused[`limits;`llm1;"requirepartition refuses an embargoed user with no date";
  "select n:count sym by date from trades where sym=`AAPL";"qsp: full table scan*";"the embargo is an upper bound only"];

/ maxrows enforced (maxrows is 100000)
check_refused[`limits;`quant1;"maxrows refuses table > 100000 rows";
  "(select sym,bid from quotes where date=",D,") cross (select sym from trades where date=",D,")";
  "qsp: result exceeds the maximum permitted row count";""];
check_refused[`limits;`quant1;"maxrows refuses vector > 100000 elements";
  "raze 50#enlist exec sym from select sym from quotes where date=",D;
  "qsp: result exceeds the maximum permitted*";"vector result exceeding maxrows"];

/ maxdepth enforced (maxdepth is 24)
deep_ok:(raze 10#enlist"neg "),"1";
check_val[`limits;`quant1;"depth 10 allowed";deep_ok;1;""];
deep_bad:(raze 30#enlist"neg "),"1";
check_refused[`limits;`quant1;"maxdepth refuses depth 30";
  deep_bad;"qsp: expression is nested too deeply";""];

/ -T 1 server on port2 interrupts a long query
h_t1:open_as[40;port2;`quant1];
t1_r:$[null h_t1;(0b;"connect failed");
  @[{(1b;x y)}[h_t1];"count (select sym,bid from quotes where date=",D,") cross (select sym,ask from quotes where date=",D,") cross (select sym from instruments)";{(0b;x)}]];
if[not null h_t1;@[hclose;h_t1;::]];
t1_msg:fmt t1_r 1;
t1_ok:(not t1_r 0) and (t1_msg like "*stop*");
add_result[`limits;`quant1;"-T 1 server interrupts long-running query with stop";
  "heavy cross on port2 (-T 1)";"qsp: stop";$[t1_r 0;"ALLOWED: ",t1_msg;"ERR: ",t1_msg];t1_ok;""];


/ ==============================================================================
/ SUITE 4: audit
/ ==============================================================================
-1"== Running suite: audit ==";

/ Only compliance1 can read auditlog
{[u]
  check_refused[`audit;u;"non-compliance cannot read auditlog (",string[u],")";
    "select from auditlog";"qsp: *";""];
 } each `llm1`quant1`sales_na`sales_emea`cash_head`etf_head;

al0:exec_as[`compliance1;"select from auditlog"];
add_result[`audit;`compliance1;"compliance1 can read auditlog";
  "select from auditlog";"table of audit rows";
  $[al0 0;"table (count=",string[count al0 1],")";"ERROR: ",al0 1];(al0 0) and 98h=type al0 1;""];

/ Check each decision kind:
/ 1. allowed
exec_as[`llm1;"select from venues"];
r_allow:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"select from venues\""];
ok_allow:(r_allow 0) and (0<count r_allow 1) and (`allowed=last (r_allow 1)`decision) and (1b=last (r_allow 1)`allowed);
add_result[`audit;`compliance1;"permitted query logged as `allowed";
  "select from venues (as llm1)";"decision=`allowed, allowed=1b";
  $[ok_allow;"decision=`allowed";.Q.s1 r_allow];ok_allow;""];

/ 2. denied (permission refusal)
exec_as[`llm1;"select account from trades where date=",E];
r_deny:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"select account from trades*\""];
ok_deny:(r_deny 0) and (0<count r_deny 1) and (`denied=last (r_deny 1)`decision) and (0b=last (r_deny 1)`allowed);
add_result[`audit;`compliance1;"permission-denied query logged as `denied";
  "select account from trades (as llm1)";"decision=`denied, allowed=0b";
  $[ok_deny;"decision=`denied";.Q.s1 r_deny];ok_deny;""];

/ 3. error (unparseable syntax)
exec_as[`llm1;"select from venues where ("];
r_syn:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"select from venues where (\""];
ok_syn:(r_syn 0) and (0<count r_syn 1) and (`error=last (r_syn 1)`decision) and (0b=last (r_syn 1)`allowed);
add_result[`audit;`compliance1;"unparseable query logged as `error";
  "select from venues where (";"decision=`error, allowed=0b";
  $[ok_syn;"decision=`error";.Q.s1 r_syn];ok_syn;""];

/ 4. error (scope fault: granted column dropped by inner select)
exec_as[`llm1;"select price from select sym from trades where date=",E];
r_flt:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"select price from select sym*\""];
ok_flt:(r_flt 0) and (0<count r_flt 1) and (`error=last (r_flt 1)`decision) and (0b=last (r_flt 1)`allowed);
add_result[`audit;`compliance1;"scope-fault query logged as `error";
  "select price from select sym from trades...";"decision=`error, allowed=0b";
  $[ok_flt;"decision=`error";.Q.s1 r_flt];ok_flt;""];

/ 5. error (runtime evaluation error on a permitted query)
exec_as[`llm1;"select x:size+`a from trades where date=",E];
r_rt:exec_as[`compliance1;"select from auditlog where user=`llm1, query like \"select x:size+`a*\""];
ok_rt:(r_rt 0) and (0<count r_rt 1) and (`error=last (r_rt 1)`decision) and (0b=last (r_rt 1)`allowed);
add_result[`audit;`compliance1;"runtime-error query logged as `error";
  "select x:size+`a from trades...";"decision=`error, allowed=0b";
  $[ok_rt;"decision=`error";.Q.s1 r_rt];ok_rt;""];


/ ==============================================================================
/ SUITE 5: attacks
/ ==============================================================================
-1"== Running suite: attacks ==";

/ 5.1 Forbidden primitives (direct text & parse tree)
check_attack[`quant1;"forbidden primitive: system";"system \"touch ",RUN,"/canary_created_file\"";"direct system call"];
check_attack[`quant1;"forbidden primitive: value";"value \"canaryfn 1\"";"direct value call"];
check_attack[`quant1;"forbidden primitive: get";"get `secret_table";"direct get call"];
check_attack[`quant1;"forbidden primitive: set";"`secret_table set 0";"direct set call"];
check_attack[`quant1;"forbidden primitive: eval";"eval (canaryfn;1)";"direct eval call"];
check_attack[`quant1;"forbidden primitive: reval";"reval (canaryfn;1)";"direct reval call"];
check_attack[`quant1;"forbidden primitive: parse";"parse \"canaryfn 1\"";"direct parse call"];
check_attack[`quant1;"forbidden primitive: hopen";"hopen `$\":",RUN,"/canary_created_file\"";"direct hopen call"];
check_attack[`quant1;"forbidden primitive: read0";"read0 `$\":",RUN,"/canary_keep_file\"";"direct read0 call"];
check_attack[`quant1;"forbidden primitive: read1";"read1 `$\":",RUN,"/canary_keep_file\"";"direct read1 call"];
check_attack[`quant1;"forbidden primitive: hdel";"hdel `$\":",RUN,"/canary_keep_file\"";"direct hdel call"];
check_attack[`quant1;"forbidden primitive: exit";"exit 1";"direct exit call"];
check_attack[`quant1;"forbidden primitive: insert";"`secret_table insert (4;`delta)";"direct insert call"];
check_attack[`quant1;"forbidden primitive: upsert";"`secret_table upsert (4;`delta)";"direct upsert call"];
check_attack[`quant1;"forbidden primitive: key";"key `.; canaryfn 1";"direct key call"];

/ 5.2 Assignment and amend
check_attack[`quant1;"local assignment";"a:canaryfn 1";"colon assignment"];
check_attack[`quant1;"global assignment";"a::canaryfn 1";"double-colon assignment"];
check_attack[`quant1;"amend @";"@[(1 2 3);0;:;99]; canaryfn 1";"amend @ operator"];
check_attack[`quant1;"amend .";".[(1 2 3);enlist 0;:;99]; canaryfn 1";"amend . operator"];
check_attack[`quant1;"amend global table";"@ [`accounts;`client;:;()]";"accounts amend"];

/ 5.3 Inline lambdas and IPC-injected lambdas
check_attack[`quant1;"inline lambda in query";"select {canaryfn x} each size from trades where date=",D;"inline lambda"];
check_attack[`quant1;"bare inline lambda";"{canaryfn x}[1]";"bare lambda application"];
check_attack[`quant1;"IPC parse-tree lambda";({canaryfn x};1);"lambda value in IPC tree"];
check_attack[`quant1;"IPC one-item lambda list";(+;1;enlist ({canaryfn x};1));"one-item list wrapping lambda call"];
check_attack[`quant1;"IPC one-item list quoting value, applied by each";(each;enlist value;(enlist;"canaryfn 1"));"eval hands back a one-item list's item unevaluated"];
check_refused[`attacks;`sales_na;"functional form: a column clause built by code reads a hidden column";
  "?[trades;();0b;(enlist`x)!enlist(distinct;`trader)]";"qsp: write the query as select*";"the walker checked the code, q ran what it built"];
check_refused[`attacks;`sales_na;"functional form: the same, sent as a tree";
  (?;`trades;();0b;(!;(enlist;enlist`x);(enlist;(enlist;distinct;enlist`trader))));"qsp: write the query as select*";""];
check_refused[`attacks;`sales_na;"functional form: a where clause built by code";
  "?[trades;enlist(=;`date;",D,");0b;()]";"qsp: write the query as select*";""];
check_attack[`quant1;"IPC one-item list quoting a lambda, applied by each";(each;enlist {canaryfn x};(enlist;1));"a quoted function never walked as one"];

/ 5.3b Values q applies (third review): an int is a handle - 0 evaluates text - and a list, dictionary
/ or column holding a function applies it when indexed at depth
check_attack[`quant1;"handle 0 computed in the head";"(0+0i)[\"canaryfn 1\"]";"q applies an int as a handle"];
check_attack[`quant1;"handle 0 handed to each";"0 each enlist \"canaryfn 1\"";"a literal handle in the applied slot"];
check_attack[`quant1;"handle 0 composed";"'[first;0i][\"canaryfn 1\"]";"a handle inside a composition"];
check_attack[`quant1;"a list holding each, indexed at depth";"(each;count)[0;`canaryfn;1 2]";"indexing at depth applies each"];
check_attack[`quant1;"a list holding ?, indexed at depth";"(?;count)[0;`secret_table;();0b;()]";"indexing at depth reads a table"];
check_attack[`quant1;"a column holding each";"exec f[0;`canaryfn;1 2] from select f:(each;count) from trades where date=",D;"a column of functions"];
check_attack[`quant1;"wj with a symbol pair";
  "wj[(-00:01+exec time from select time from trades where date=",D,";00:01+exec time from select time from trades where date=",D,");`sym`time;select sym,time,price from trades where date=",D,";(select sym,time,bid from quotes where date=",D,";`canaryfn`bid)]";
  "wj applies the first symbol of an aggregation pair"];
apiok[`quant1;"wj with a written-out pair still runs";
  "wj[(-00:01+exec time from select time from trades where date=",D,";00:01+exec time from select time from trades where date=",D,");`sym`time;select sym,time,price from trades where date=",D,";(select sym,time,bid from quotes where date=",D,";(max;`bid))]";
  {(98h=type x)and `bid in cols x};"the control for the symbol pair above"];
check_attack[`quant1;"exec as a tree: a symbol-vector call in the exec slot";
  (?;`trades;enlist enlist(=;`date;"D"$D);();enlist `canaryfn`sym);"read as a delete's column list, it was never walked"];
check_refused[`attacks;`sales_na;"select as a tree: an empty symbol list, which q reads as every column";
  (?;`accounts;();0b;`symbol$());"qsp: write the query as select*";"a hand-built tree"];
check_refused[`attacks;`sales_na;"select as a tree: an empty dictionary, read the same way";
  (?;`accounts;();0b;(`symbol$())!());"qsp: write the query as select*";""];
check_refused[`attacks;`llm1;"an exec that is not a table names the global enum domain";
  "exec enlist sym from (exec (distinct `a`b)!1 2 by date:date from select date from trades where date=2026.10.07)";
  "qsp: sym is not in scope here*";"sym would resolve to the HDB's enum domain"];
check_refused[`attacks;`quant1;"a select written as a column scans every partition";
  "select x:(count select from quotes) from venues";"qsp: full table scan*";"requirepartition finds a read inside a select clause"];

/ 5.4 In-place update / delete and table mutation
check_attack[`quant1;"in-place update by symbol";"update price:0f from `trades where date=",D;"in-place update"];
check_attack[`quant1;"in-place delete by symbol";"delete from `accounts";"in-place delete"];
check_attack[`quant1;"direct update on table";"update price:0f from trades where date=",D;"selectonly update check"];
check_attack[`quant1;"direct delete on table";"delete from trades where date=",D;"selectonly delete check"];
check_attack[`quant1;"xasc in-place sort on literal table";"`account xasc `accounts";"literal table name in xasc"];

/ 5.5 select[<n] and select[>n] grade overloads (hopen / hclose)
check_attack[`quant1;"select[<port] hopen overload";"select[<5000] from trades where date=",D;"select[<atom] grade overload"];
check_attack[`quant1;"select[>handle] hclose overload";"select[>3] from trades where date=",D;"select[>atom] grade overload"];

/ 5.6 Virtual column i
check_refused[`attacks;`quant1;"virtual column i in select";
  "select i from trades where date=",D;"qsp: *";"virtual column i in select"];
check_refused[`attacks;`quant1;"virtual column i in where";
  "select from trades where date=",D,", i<10";"qsp: *";"virtual column i in where"];

/ 5.7 File-handle symbols (literal vs runtime-constructed via `$)
check_attack[`quant1;"literal file handle with 0:";"(`:",RUN,"/canary_created_file) 0: enlist \"pwn\"";"literal file handle"];
check_attack[`quant1;"literal file handle with ?";"(`:",RUN,"/canary_created_file)?`a`b";"literal file handle enum extend"];
check_attack[`quant1;"literal file handle with not (hdel)";"not `:",RUN,"/canary_keep_file";"literal file handle in not/hdel"];
check_attack[`quant1;"runtime file handle with not (hdel)";"not `$\":",RUN,"/canary_keep_file\"";"runtime file handle in not/hdel"];
check_attack[`quant1;"runtime file handle with ? (file write)";"(`$\":",RUN,"/canary_created_file\")?`a`b";"runtime file handle with ? writes enum file"];

/ 5.8 Runtime-constructed symbols naming functions, tables, handles
check_attack[`quant1;"runtime symbol in head position calls canaryfn";"(`$\"canaryfn\")[1]";"runtime symbol in application head"];
check_attack[`quant1;"indexed symbol vector in head calls canaryfn";"((`a`canaryfn) 1)[1]";"indexed symbol vector in head"];
check_attack[`quant1;"runtime symbol reads ungranted table column";"(`$\"accounts\")`client";"runtime symbol table column read"];
check_attack[`quant1;"runtime symbol reads unregistered secret_table";"(`$\"secret_table\")`pass";"runtime symbol unregistered table read"];
check_attack[`quant1;"runtime symbol reads policy lookup coverage";"(`$\"coverage\")`region";"runtime symbol internal table read"];

/ 5.9 Whitelisted iterators, fby, and 4-arg functional exec with function symbol in arg position
check_attack[`quant1;"each iterator with function symbol";"(`canaryfn) each 1 2";"function symbol passed to each"];
check_attack[`quant1;"over iterator with function symbol";"(`canaryfn) over 1 2";"function symbol passed to over"];
check_attack[`quant1;"scan iterator with function symbol";"(`canaryfn) scan 1 2";"function symbol passed to scan"];
check_attack[`quant1;"peach iterator with function symbol";"(`canaryfn) peach 1 2";"function symbol passed to peach"];
check_attack[`quant1;"prior iterator with function symbol";"(`canaryfn) prior 1 2";"function symbol passed to prior"];
check_attack[`quant1;"fby with function symbol in aggregation";"select from trades where date=",D,", size=(`canaryfn;size) fby sym";"function symbol in fby"];
check_attack[`quant1;"4-arg functional ? with function symbol";"?[select from venues;();`canaryfn;enlist `src]";"4-arg functional exec calls symbol in 3rd arg"];

/ 5.10 cols and meta on ungranted and unregistered tables
check_refused[`attacks;`quant1;"cols on literal ungranted registered table";
  "cols `accounts";"qsp: *";"literal registered table in cols"];
check_refused[`attacks;`quant1;"cols on runtime-symbol ungranted table";
  "cols `$\"accounts\"";"qsp: *";"runtime symbol in cols"];
check_refused[`attacks;`quant1;"cols on unregistered secret_table";
  "cols `secret_table";"qsp: *";"unregistered table in cols"];
check_refused[`attacks;`quant1;"meta on unregistered secret_table";
  "meta `secret_table";"qsp: *";"unregistered table in meta"];
check_refused[`attacks;`quant1;"cols on internal policy table coverage";
  "cols `coverage";"qsp: *";"internal policy table in cols"];

/ 5.11 Row-filter ordering inference channel for sales_na
check_case[`attacks;`sales_na_mintime_D;`sales_na];


/ ==============================================================================
/ REPORT GENERATION
/ ==============================================================================
-1"== Generating results.csv and report.md ==";

(hsym`$OUT,"/results.csv") 0: csv 0: results;

suites:distinct results`suite;
summary:([]
  suite:suites;
  total:{count select from results where suite=x} each suites;
  passed:{count select from results where suite=x,passed} each suites;
  failed:{count select from results where suite=x,not passed} each suites);

tot_all:count results;
tot_pass:count select from results where passed;
tot_fail:count select from results where not passed;

md:();
md,:enlist "# `di.qsp` Security & Permission Verification Report";
md,:enlist "";
md,:enlist "## Suite Summary";
md,:enlist "";
md,:enlist "| Suite | Total | Passed | Failed |";
md,:enlist "|---|---:|---:|---:|";
md,:{
  "| `",string[x`suite],"` | ",string[x`total]," | ",string[x`passed]," | ",string[x`failed]," |"
 } each summary;
md,:enlist "| **Total** | **",string[tot_all],"** | **",string[tot_pass],"** | **",string[tot_fail],"** |";
md,:enlist "";

fails:select from results where not passed;
md,:enlist "## Detailed Failure Breakdown";
md,:enlist "";
if[0=count fails;
  md,:enlist "_All checks passed._"];
if[0<count fails;
  md,:raze {
    ("| **ID** | `#",string[x`id],"` |";
     "|---|---|";
     "| **Suite** | `",string[x`suite],"` |";
     "| **User** | `",string[x`user],"` |";
     "| **Description** | ",x[`description]," |";
     "| **Query** | `",x[`query],"` |";
     "| **Expected** | `",x[`expected],"` |";
     "| **Actual** | `",x[`actual],"` |";
     "| **Note** | ",x[`notes]," |";
     "")
   } each fails];

md,:enlist "---";
md,:enlist "Total: ",string[tot_all]," checks — ",string[tot_pass]," passed, ",string[tot_fail]," failed.";

(hsym`$OUT,"/report.md") 0: md;

-1"\nTotal: ",string[tot_all]," checks — ",string[tot_pass]," passed, ",string[tot_fail]," failed.";

{[h] if[not null h;@[hclose;h;::]]} each value handles;
/ any failed check fails the campaign, so CI notices
exit `long$0<tot_fail;
