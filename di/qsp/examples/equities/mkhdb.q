/ build a small example HDB to try qsp on:   q di/qsp/examples/equities/mkhdb.q -db /path/to/db [-days 5]
/ four date-partitioned tables (trades, quotes, orders, depth, parted by sym) and four splayed
/ reference tables (accounts, instruments, traders, venues), the shape of a typical equities
/ execution database. Every trade fills an order, so orders, trades and accounts join. The data
/ is the same on every run: the dates are fixed and the generator is seeded.
/ hdb.q builds one with this if it has to. Refuses to write over a directory that exists

/ the builder's helpers live in .mk, not at the root: a process that loads this file would
/ otherwise carry globals called px, fill, base and tick, and qsp refuses a column alias that
/ shadows a global function (select px:price*size ... then reads px), which an agent trips over
\d .mk

/ ------------------------------------------------------------------ reference data

mkaccounts:{[]
  :([]account:`A1`A2`A3`A4`A5`A6`A7`A8;
    client:("Northbridge Capital";"Halden Pension Fund";"Arbor Asset Management";"Kestrel Partners";
      "Meridian Insurance";"Quayside Wealth";"Torrent Quant";"Larch Sovereign Fund");
    clientType:`hedgeFund`pension`assetManager`hedgeFund`insurer`wealth`quant`sovereign;
    region:`NA`EMEA`NA`EMEA`NA`EMEA`NA`APAC);
  };

mkinstruments:{[]
  :([]sym:`AAPL`MSFT`NVDA`META`JPM`GS`BAC`KO`PG`XOM`VOD`LLOY;
    name:("Apple Inc";"Microsoft Corp";"NVIDIA Corp";"Meta Platforms Inc";"JPMorgan Chase & Co";
      "Goldman Sachs Group";"Bank of America Corp";"Coca-Cola Co";"Procter & Gamble Co";
      "Exxon Mobil Corp";"Vodafone Group plc";"Lloyds Banking Group plc");
    sector:`Technology`Technology`Technology`Communication`Financials`Financials`Financials,
      `Staples`Staples`Energy`Communication`Financials;
    ccy:`USD`USD`USD`USD`USD`USD`USD`USD`USD`USD`GBP`GBP;
    listing:`O`O`O`O`N`N`N`N`N`N`L`L);
  };

mktraders:{[] :([]trader:`$"T",/:-2#'"0",/:string 1+til 12;desk:12#`CASH`PROG`ETF`DERIV);};

mkvenues:{[]
  :([]src:`N`O`L;mic:`XNYS`XNAS`XLON;
    name:("New York Stock Exchange";"Nasdaq";"London Stock Exchange");country:`US`US`UK;ccy:`USD`USD`GBP);
  };

/ a starting price per instrument
base:`AAPL`MSFT`NVDA`META`JPM`GS`BAC`KO`PG`XOM`VOD`LLOY!
  228 415 135 580 245 590 44 63 168 112 0.71 0.56;

/ ------------------------------------------------------------------ one day

/ the tick: a cent, or a hundredth of a penny below 10
tick:{[p] :?[p<10;0.0001;0.01];};
/ prices near p, on the tick
px:{[p] t:tick p; :t*floor 0.5+(p*1+0.002*-1+2*count[p]?1f)%t;};

mkorders:{[d;n]
  s:n?key base;
  tr:mktraders[];
  t:n?tr`trader;
  r:([]sym:s;orderID:`$"O_",/:string[d],/:"_",/:string til n;side:n?`buy`sell;qty:`int$100*1+n?100;
    limitPx:px base s;account:n?mkaccounts[][`account];trader:t;desk:(tr`desk)tr[`trader]?t;
    time:asc d+09:30+n?06:30:00.000000000;state:`;arrivalPx:px base s;algo:n?`POV`VWAP`TWAP`IS`DMA;
    filledQty:0i;avgPx:0n);
  :`time xasc r;
  };

mktrades:{[d;o;n]
  / n fills of orders o, each after its order arrived, on the instrument's listing venue mostly
  i:n?count o;
  f:o i;
  lst:mkinstruments[][`listing];
  src:{[l;x] $[l=`L;`L;x]}'[lst (mkinstruments[][`sym])?f`sym;n?`N`O];
  p:px base f`sym;
  sz:`int$100*1+n?20;
  :`time xasc ([]sym:f`sym;time:f[`time]+n?00:30:00.000000000;src:src;price:p;size:sz;side:f`side;
    account:f`account;trader:f`trader;notional:p*sz;orderID:f`orderID);
  };

/ orders as filled by trades t: quantity filled, average price, and a state
fill:{[o;t]
  x:select fq:`int$sum size,ap:size wavg price by orderID from t;
  o:o lj x;
  o:update filledQty:0i^fq,avgPx:ap from o;
  o:update qty:qty|filledQty from o;
  o:update state:?[filledQty=qty;`filled;?[filledQty>0;`partial;`cancelled]] from o;
  :delete fq,ap from o;
  };

mkquotes:{[d;n]
  s:n?key base;
  m:px base s;
  w:tick m;
  :`time xasc ([]sym:s;time:d+09:30+n?06:30:00.000000000;src:n?`N`O;bid:m;ask:m+w;
    bsize:`int$100*1+n?50;asize:`int$100*1+n?50);
  };

mkdepth:{[d;n]
  s:n?key base;
  m:px base s;
  w:tick m;
  r:([]sym:s;time:d+09:30+n?06:30:00.000000000);
  lv:{[m;w;n;l]
    b:`$("bid";"bsize";"ask";"asize"),\:string l;
    :flip b!(m-w*l;`int$100*l+n?50;m+w*l;`int$100*l+n?50);
    }[m;w;n] each 1+til 5;
  c:raze {`$x,/:string 1+til 5} each ("bid";"bsize";"ask";"asize");
  o:raze {`$("bid";"bsize"),\:string x} each 1+til 5;
  o:o,raze {`$("ask";"asize"),\:string x} each 1+til 5;
  :`time xasc r,'o#(,'/)lv;
  };

/ ------------------------------------------------------------------ the database

/ the weekdays ending on the Friday of 2026.10.09
dates:{[n] :reverse n#d where 1<(d:2026.10.09-til 7*n) mod 7;};

mkhdb:{[db;days]
  / write the database into directory db: days weekdays of data, and the reference tables
  if[not ()~key h:hsym`$db;'"mkhdb: ",db," exists - delete it first, or name another directory"];
  system"S 20261009";
  {[h;d]
    o:mkorders[d;300];
    t:mktrades[d;o;1500];
    `orders set fill[o;t];
    `trades set t;
    `quotes set mkquotes[d;4000];
    `depth set mkdepth[d;1000];
    {[h;d;t] .Q.dpft[h;d;`sym;t]}[h;d] each `trades`quotes`orders`depth;
    }[h] each dates days;
  {[h;n;t] (` sv h,n,`) set .Q.en[h] t}[h]'[`accounts`instruments`traders`venues;
    (mkaccounts[];mkinstruments[];mktraders[];mkvenues[])];
  delete trades,quotes,orders,depth from `.;
  :h;
  };

\d .
mkhdb:.mk.mkhdb;

/ run as a script: build, and exit
if[(string .z.f) like "*mkhdb.q";
  o:.Q.opt .z.x;
  if[not `db in key o;-2"usage: q mkhdb.q -db /path/to/db [-days 5]";exit 1];
  r:@[mkhdb[first o`db];$[`days in key o;"J"$first o`days;5];{-2 x;exit 1}];
  -1"wrote ",1_string r;
  exit 0];
