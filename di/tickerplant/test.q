/ fixture helpers for di.tickerplant's k4unit tests.
/ tickerplant orchestrates the real di.pubsub / di.eodtime / di.tplog / di.timer modules with an
/ injected log, so these tests wire the real modules (tplog resolved via QPATH) and drive a full
/ init -> upd -> roll cycle. the data tables live at ROOT (the tickerplant owns them and di.pubsub
/ reads them by name), and replay runs the ROOT upd, so a schema + recorder upd live here at root.
/ tp (di.tickerplant), timer (di.timer) and ntp (di.tplog) are bound by test.csv's before rows.

base:"/tmp/di_tickerplant_k4unit";
trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());
upd:{[t;x] t insert x};

/ capturing logger shared by tickerplant and its dep modules, so any module's output is assertable
logcap:([]lvl:`symbol$();ctx:`symbol$();msg:());
caplog:{`info`warn`error!(
  {[c;m]`logcap insert(`info;c;m);};
  {[c;m]`logcap insert(`warn;c;m);};
  {[c;m]`logcap insert(`error;c;m);})};

freshdir:{[sub] dd:base,"/",sub; system"rm -rf ",dd; system"mkdir -p ",dd; dd};

/ deps for init - real timer, capturing log, one trade table, logging into dd, batch flag as given
mkdeps:{[dd;batch] `log`timer`schemas`logdir`logname`batch!(caplog[];timer;enlist[`trade]!enlist trade;dd;"tp";batch)};

/ fresh init into a clean per-test dir; clears the root table and the log capture first
freshinit:{[sub;batch]
  dd:freshdir sub;
  `trade set 0#trade;
  `logcap set 0#logcap;
  tp.init mkdeps[dd;batch];
  dd};

/ a feed update: sym, price, size - no time, so the tickerplant stamps it
row:{[s] (s;1.0;100)};

setupfixture:{system"rm -rf ",base; system"mkdir -p ",base;};
teardownfixture:{system"rm -rf ",base;};

/ deps builders for the init validation fail rows
depsnolog:{(enlist`x)!enlist 1};
depsonlylog:{enlist[`log]!enlist caplog[]};
depsnoschemas:{`log`timer!(caplog[];timer)};
depsbadtimer:{`log`timer`schemas!(caplog[];(enlist`x)!enlist 1;enlist[`trade]!enlist trade)};

/ =============================================================================
/ tests (each returns 1b on success)
/ =============================================================================

/ init materialises the tables at root (g# on sym), schedules the timer job, zeroes the counts
testinit:{[]
  freshinit["init";1b];
  c:tp[`getcounts][];
  (`g=attr exec sym from trade) and (enlist[`trade]~tp[`gettables][]) and (0=c`i) and (0=c`j)
    and (-14h=type c`d) and `tickerplant in exec id from timer.getalljobs[]};

/ batch mode: upd stamps, buffers into the root table, and logs (bumping j; i unchanged)
testupdbatch:{[]
  freshinit["updb";1b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  c:tp[`getcounts][];
  (2=count trade) and (`AAPL`MSFT~exec sym from trade) and (not any null exec time from trade)
    and (2=c`j) and 0=c`i};

/ an empty update is a no-op: no throw, nothing buffered, nothing logged
testemptyupd:{[]
  freshinit["empty";1b];
  tp[`upd][`trade;()];
  c:tp[`getcounts][];
  (0=count trade) and 0=c`j};

/ zero-latency mode: upd publishes immediately, does NOT buffer into the root table, still logs
testzerolatency:{[]
  freshinit["zl";0b];
  tp[`upd][`trade;row`AAPL];
  c:tp[`getcounts][];
  (0=count trade) and 1=c`j};

/ re-init is safe: it closes the previous log handle instead of leaking the descriptor, and logging
/ keeps working. fd count (linux /proc, as the suite is already unix-coupled) must not grow.
testreinitnoleak:{[]
  fddir:"/proc/",(string .z.i),"/fd";
  freshinit["reinit";1b];
  b:"J"$first system"ls ",fddir," | wc -l";
  freshinit["reinit";1b]; freshinit["reinit";1b]; freshinit["reinit";1b];
  a:"J"$first system"ls ",fddir," | wc -l";
  tp[`upd][`trade;row`AAPL];
  (a=b) and 1=tp[`getcounts][]`j};

/ the tp log tickerplant writes replays through di.tplog - the two modules agree on the log format
testlogroundtrip:{[]
  dd:freshinit["rt";1b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  lf:hsym`$dd,"/tp",string first tp[`getcounts][]`d;
  `trade set 0#trade; `rcv set 0;
  `upd set {[t;x] `rcv set rcv+1; t insert x;};
  n:ntp[`replay] lf;
  `upd set {[t;x] t insert x;};
  (2=n) and (2=rcv) and 2=count trade};

/ endofday flushes the buffer, rolls to the next day's log, and resets the counts
testendofday:{[]
  dd:freshinit["eod";1b];
  tp[`upd][`trade;row`AAPL];
  oldd:first tp[`getcounts][]`d;
  tp[`endofday][];
  c:tp[`getcounts][];
  ((oldd+1)=c`d) and (0=c`i) and (0=c`j) and (0=count trade)
    and not ()~key hsym`$dd,"/tp",string oldd+1};

/ rolling into a pre-existing CORRUPT log makes openlog repair it via di.tplog.check
testcheckrepaironroll:{[]
  dd:freshinit["rep";1b];
  oldd:first tp[`getcounts][]`d;
  nl:hsym`$dd,"/tp",string oldd+1;
  h:hopen nl;
  h enlist (`upd;`trade;(enlist 2026.08.13D10:00;enlist`AAPL;enlist 1.0;enlist 100));
  h enlist (`upd;`trade;(enlist 2026.08.13D10:01;enlist`IBM;enlist 2.0;enlist 200));
  hclose h;
  nl set (-8)_read1 nl;
  `logcap set 0#logcap;
  tp[`endofday][];
  (not ()~key hsym`$dd,"/tp",(string oldd+1),".good") and `warn in exec lvl from logcap where ctx=`check};
