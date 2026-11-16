/ harden/cases.q - the queries whose results harden.sh checks, each written once. Loaded by
/ mkexpected.q, which works each result out from a hand-written model of the policy, and by
/ runner.q, which sends each query to the policed server and compares
/   id     the case, as runner.q names it
/   users  who runs it: the expected result is worked out for each
/   title  for the report
/   q      the query, exactly as sent
/   note   for the report

/ the last day, inside the research embargo, and a day outside it
D:"2026.10.09";
E:"2026.10.07";

cases:([id:`symbol$()] users:();title:();q:();note:());
case:{[id;u;t;q;n] `cases upsert ([id:enlist id] users:enlist (),u;title:enlist t;q:enlist q;note:enlist n);};

/ reference data: every role but compliance through refdata, and compliance directly
case[`instruments;`llm1`quant1`sales_na`sales_emea`cash_head`etf_head`compliance1;"read instruments";"select from instruments";""];
case[`venues;`llm1`quant1`sales_na`sales_emea`cash_head`etf_head`compliance1;"read venues";"select from venues";""];

/ research (llm1)
case[`llm1_trades_E;`llm1;"trades on allowed date E";"select from trades where date=",E;""];
case[`llm1_trades_D;`llm1;"trades on embargoed date D returns empty";"select from trades where date=",D;""];
case[`llm1_trades_D8;`llm1;"trades on embargo boundary 2026.10.08 returns empty";"select from trades where date=2026.10.08";""];
case[`llm1_trades_jpm;`llm1;"trades for non-tech sym JPM returns empty";"select from trades where date=",E,", sym=`JPM";""];
case[`llm1_vwap_E;`llm1;"vwap by sym on date E";"select vwap:size wavg price by sym from trades where date=",E;""];
case[`llm1_aapl_by_d;`llm1;"count by date for AAPL over the week: the embargo holds back the last two days";
  "select n:count sym by date from trades where date within 2026.10.05 2026.10.09, sym=`AAPL";""];
case[`llm1_quotes_E;`llm1;"quotes on allowed date E";"select from quotes where date=",E;""];
case[`llm1_quotes_D;`llm1;"quotes on embargoed date D returns empty";"select from quotes where date=",D;""];

/ quant (quant1)
case[`quant1_spread_D;`quant1;"spread by sym on date D";"select spread:avg ask-bid, n:count sym by sym from quotes where date=",D;""];

/ sales (sales_na, sales_emea)
case[`notional_D;`sales_na`sales_emea;"notional by account on date D";"select notional:sum notional by account from trades where date=",D;""];
case[`sales_join_D;`sales_na;"join trades and accounts on date D";
  "select notional:sum notional by clientType from ej[`account;select from trades where date=",D,";select account,clientType from accounts]";""];

/ desk heads (cash_head, etf_head)
case[`cash_orders_etf;`cash_head;"orders for ETF desk as cash_head returns empty";"select from orders where date=",D,", desk=`ETF";""];

/ the same query for several roles, each seeing their own share
case[`trades_D;`quant1`sales_na`sales_emea`cash_head`etf_head`compliance1;"trades on date D";"select from trades where date=",D;""];
case[`quotes_D;`quant1`compliance1;"quotes on date D";"select from quotes where date=",D;""];
case[`depth_D;`quant1`compliance1;"depth on date D";"select from depth where date=",D;""];
case[`orders_D;`sales_na`sales_emea`cash_head`etf_head`compliance1;"orders on date D";"select from orders where date=",D;""];
case[`accounts;`sales_na`sales_emea`compliance1;"accounts";"select from accounts";""];
case[`traders;`cash_head`etf_head`compliance1;"traders";"select from traders";""];

/ compliance (compliance1)
case[`comp_5d_summary;`compliance1;"5-day trade summary";
  "select trades:count sym, notional:sum notional by date from trades where date within 2026.10.05 2026.10.09";""];

/ attacks: the row filter must run before a constraint that reads other rows. Filter first, the
/ earliest NA trade of the day is in JPM; over every account, including hidden EMEA ones, it is BAC
case[`sales_na_mintime_D;`sales_na;"row-filter ordering: compound constraint cannot leak hidden min time";
  "select from trades where date=",D,", sym=(sym where time=min time)[0]";"compound head in where clause ordering"];
