/ harden/mkexpected.q - ground-truth expected results for harden.sh, computed straight from
/ the HDB and the policy spec. Never loads di.qsp. Args: -db HDB -out expected.bin

o:.Q.opt .z.x;
db:first o`db;
out:first o`out;
system"l ",db;

/ Hand-written expectations straight from README.md and policy/*.csv:
/ Clock is fixed at 2026.10.10D00:00; qsp.aged[date;2D] means date < 2026.10.08
tech:`AAPL`MSFT`NVDA`META;
embargo_cutoff:2026.10.08;
D:2026.10.09;
E:2026.10.07;

na_accts:exec account from accounts where region=`NA;
emea_accts:exec account from accounts where region in `EMEA`APAC;
cash_traders:exec trader from traders where desk=`CASH;
etf_traders:exec trader from traders where desk=`ETF;

exp_data:([
  / Reference data (granted via refdata group to all roles except compliance, and directly to compliance)
  instruments_all: select sym,name,sector,ccy,listing from instruments;
  venues_all:      select src,mic,name,country,ccy from venues;

  / Research (llm1): trades & quotes for AAPL MSFT NVDA META, date < 2026.10.08, restricted columns
  llm1_trades_E:   select date,sym,time,price,size,side from trades where date=E, sym in tech;
  llm1_trades_D:   select date,sym,time,price,size,side from trades where date=D, sym in tech, date<embargo_cutoff;
  llm1_trades_D8:  select date,sym,time,price,size,side from trades where date=2026.10.08, sym in tech, date<embargo_cutoff;
  llm1_trades_jpm: select date,sym,time,price,size,side from trades where date=E, sym in tech, sym=`JPM;
  llm1_vwap_E:     select vwap:size wavg price by sym from trades where date=E, sym in tech;
  llm1_aapl_by_d:  select n:count sym by date from trades where date<embargo_cutoff, sym in tech, sym=`AAPL;
  llm1_quotes_E:   select date,sym,time,bid,ask from quotes where date=E, sym in tech;
  llm1_quotes_D:   select date,sym,time,bid,ask from quotes where date=D, sym in tech, date<embargo_cutoff;

  / Quant (quant1): trades (8 cols, no account/trader/orderID), quotes (*), depth (*)
  quant1_trades_D: select date,sym,time,src,price,size,side,notional from trades where date=D;
  quant1_quotes_D: select date,sym,time,src,bid,ask,bsize,asize from quotes where date=D;
  quant1_depth_D:  select from depth where date=D;
  quant1_spread_D: select spread:avg ask-bid, n:count sym by sym from quotes where date=D;

  / Sales (sales_na, sales_emea): accounts (*), trades (9 cols, no src/trader), orders (12 cols, no trader/desk/arrivalPx)
  sales_na_accounts:   select account,client,clientType,region from accounts where account in na_accts;
  sales_emea_accounts: select account,client,clientType,region from accounts where account in emea_accts;
  sales_na_trades_D:   select date,sym,time,price,size,side,account,notional,orderID from trades where date=D, account in na_accts;
  sales_emea_trades_D: select date,sym,time,price,size,side,account,notional,orderID from trades where date=D, account in emea_accts;
  sales_na_orders_D:   select date,sym,orderID,side,qty,limitPx,account,time,state,algo,filledQty,avgPx from orders where date=D, account in na_accts;
  sales_emea_orders_D: select date,sym,orderID,side,qty,limitPx,account,time,state,algo,filledQty,avgPx from orders where date=D, account in emea_accts;
  sales_na_notional_D: select notional:sum notional by account from trades where date=D, account in na_accts;
  sales_emea_notional_D: select notional:sum notional by account from trades where date=D, account in emea_accts;
  sales_na_join_D:     select notional:sum notional by clientType from ej[`account;select date,sym,time,price,size,side,account,notional,orderID from trades where date=D, account in na_accts;select account,clientType from accounts where account in na_accts];
  / For inference side-channel test on sales_na (first trade of day in NA is JPM; globally across hidden EMEA accounts it is BAC):
  sales_na_mintime_D:  select date,sym,time,price,size,side,account,notional,orderID from (select from trades where date=D, account in na_accts) where sym=(sym where time=min time)[0];

  / Desk heads (cash_head, etf_head): orders (*, by desk), trades (*, by desk traders), traders (*, by desk)
  cash_traders_tbl: select trader,desk from traders where desk=`CASH;
  etf_traders_tbl:  select trader,desk from traders where desk=`ETF;
  cash_orders_D:    select date,sym,orderID,side,qty,limitPx,account,trader,desk,time,state,arrivalPx,algo,filledQty,avgPx from orders where date=D, desk=`CASH;
  etf_orders_D:     select date,sym,orderID,side,qty,limitPx,account,trader,desk,time,state,arrivalPx,algo,filledQty,avgPx from orders where date=D, desk=`ETF;
  cash_orders_etf:  select date,sym,orderID,side,qty,limitPx,account,trader,desk,time,state,arrivalPx,algo,filledQty,avgPx from orders where date=D, desk=`CASH, desk=`ETF;
  cash_trades_D:    select date,sym,time,src,price,size,side,account,trader,notional,orderID from trades where date=D, trader in cash_traders;
  etf_trades_D:     select date,sym,time,src,price,size,side,account,trader,notional,orderID from trades where date=D, trader in etf_traders;

  / Compliance (compliance1): everything (*)
  comp_accounts: select account,client,clientType,region from accounts;
  comp_traders:  select trader,desk from traders;
  comp_trades_D: select from trades where date=D;
  comp_quotes_D: select from quotes where date=D;
  comp_orders_D: select from orders where date=D;
  comp_depth_D:  select from depth where date=D;
  comp_5d_summary: select trades:count sym, notional:sum notional by date from trades where date within 2026.10.05 2026.10.09
  ]);

/ Serialise with -8! (IPC wire format) so expected tables have identical wire representation to IPC results
(hsym`$out) 1: -8!exp_data;
exit 0;
