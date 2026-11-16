/ harden/mkexpected.q - ground-truth results for harden.sh, from a model of the policy written by
/ hand from README.md and policy/*.csv. Never loads di.qsp, and never reads the policy files.
/ Args: -db HDB -out expected.bin
/ The model is what qsp promises: each user sees a view of each table - the granted columns, in
/ the table's own order, of the rows the user's filter admits - and a query runs over those views
/ exactly as written. So each case's query (cases.q) is evaluated unchanged with every table name
/ bound to the user's view of it. A table the user is not granted is bound to nothing, so a case
/ that reads one fails here rather than producing an expected result

o:.Q.opt .z.x;
db:first o`db;
out:first o`out;
system"l ",{$[count i:where x="/";(1+last i)#x;"./"]}[string .z.f],"cases.q";
system"l ",db;

/ every table, read into memory once: the views are built from these, and the table names are
/ then rebound per user
tabs:`trades`quotes`orders`depth`accounts`traders`instruments`venues;
raw:tabs!{select from x} each tabs;

/ ------------------------------------------------------------------ the policy, by hand

/ research: the four tech names, nothing from the two days before the clock (fixed at
/ 2026.10.10D00:00, so qsp.aged[date;2D] keeps date<2026.10.08)
tech:`AAPL`MSFT`NVDA`META;
embargo:2026.10.08;
/ sales: the accounts in the regions each salesperson covers
na_accts:exec account from raw[`accounts] where region=`NA;
emea_accts:exec account from raw[`accounts] where region in `EMEA`APAC;

refdata:`instruments`venues!(raw`instruments;raw`venues);

salesview:{[accts]
  :refdata,`trades`orders`accounts!(
    select date,sym,time,price,size,side,account,notional,orderID from raw[`trades] where account in accts;
    select date,sym,orderID,side,qty,limitPx,account,time,state,algo,filledQty,avgPx from raw[`orders] where account in accts;
    select from raw[`accounts] where account in accts);
  };

deskview:{[d]
  ts:exec trader from raw[`traders] where desk=d;
  :refdata,`orders`trades`traders!(
    select from raw[`orders] where desk=d;
    select from raw[`trades] where trader in ts;
    select from raw[`traders] where desk=d);
  };

access:([
  llm1:refdata,`trades`quotes!(
    select date,sym,time,price,size,side from raw[`trades] where sym in tech, date<embargo;
    select date,sym,time,bid,ask from raw[`quotes] where sym in tech, date<embargo);
  quant1:refdata,`trades`quotes`depth!(
    select date,sym,time,src,price,size,side,notional from raw`trades;
    raw`quotes;
    raw`depth);
  sales_na:salesview na_accts;
  sales_emea:salesview emea_accts;
  cash_head:deskview`CASH;
  etf_head:deskview`ETF;
  compliance1:raw]);

/ ------------------------------------------------------------------ the expected results

bind:{[u]
  / bind every table name to user u's view of it, or to nothing
  v:access u;
  {[v;t] t set $[t in key v;v t;::]}[v] each tabs;
  };

result:{[id;u]
  bind u;
  :@[value;cases[id;`q];{[id;u;e] 'string[id]," as ",string[u],": ",e}[id;u]];
  };

/ `id/user -> the result, for every user of every case
pairs:raze {[id] id,/:cases[id;`users]} each exec id from key cases;
exp_data:(`$"/" sv' string pairs)!result ./: pairs;

/ Serialise with -8! (IPC wire format) so expected tables have identical wire representation to IPC results
(hsym`$out) 1: -8!exp_data;
exit 0;
