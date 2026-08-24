/ fixture helpers for di.tickerplant's k4unit tests.
/ tickerplant orchestrates the real di.pubsub / di.eodtime / di.tplog / di.timer modules with an
/ injected log, so these tests wire the real modules (tplog resolved via QPATH) and drive a full
/ init -> upd -> roll cycle. the data tables live at ROOT (the tickerplant owns them and di.pubsub
/ reads them by name), and replay runs the ROOT upd, so a schema + recorder upd live here at root.
/ tp (di.tickerplant), timer (di.timer), ntp (di.tplog), eod (di.eodtime) and ps (di.pubsub) are
/ bound by test.csv's before rows.

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

/ force the module back to a pre-init state, so the NEXT init is a fresh one.
/ init deliberately seeds runtime state (date, counts, open log) only on the first call - see
/ tickerplant.md - so a suite that wants a genuinely clean tickerplant per test has to clear the name
/ initialised[] probes. done here rather than by exporting a reset verb: a state-wiping function that
/ exists only for tests does not belong in the public api. also drops the self-subscription a
/ subdetails test leaves behind on handle 0, so a later flush does not publish into it
resetmodule:{[]
  if[`schemas in key `.m.di.0tickerplant;
    tp[`teardown][];
    @[{if[.m.di.0tickerplant.logfile>0i;hclose .m.di.0tickerplant.logfile]};::;{[e] :(::)}];
    ![`.m.di.0tickerplant;();0b;`schemas`scheduled]];
  @[ps`closesub;0i;{[e] :(::)}];
  };

/ fresh init into a clean per-test dir; clears the root table and the log capture first
freshinit:{[sub;batch]
  resetmodule[];
  dd:freshdir sub;
  `trade set 0#trade;
  `logcap set 0#logcap;
  tp.init mkdeps[dd;batch];
  dd};

/ drive one batch flush without the roll check tick[] also does - the timer is never started here
flushbuffer:{[] .m.di.0tickerplant.publishbuffer[]};

/ a feed update: sym, price, size - no time, so the tickerplant stamps it
row:{[s] (s;1.0;100)};

setupfixture:{system"rm -rf ",base; system"mkdir -p ",base;};
teardownfixture:{resetmodule[]; system"rm -rf ",base;};

/ deps builders for the init validation fail rows
depsnolog:{(enlist`x)!enlist 1};
depsonlylog:{enlist[`log]!enlist caplog[]};
depsnoschemas:{`log`timer!(caplog[];timer)};
depsbadtimer:{`log`timer`schemas!(caplog[];(enlist`x)!enlist 1;enlist[`trade]!enlist trade)};
depsnodeletejobs:{`log`timer`schemas!(caplog[];`deletejobs _ timer;enlist[`trade]!enlist trade)};

/ =============================================================================
/ tests (each returns 1b on success)
/ =============================================================================

/ init materialises the tables at root (g# on sym), publishes the subscription protocol at root,
/ schedules the timer job and zeroes the counts
testinit:{[]
  freshinit["init";1b];
  c:tp[`getcounts][];
  (`g=attr exec sym from trade) and (enlist[`trade]~tp[`gettables][]) and (0=c`i) and (0=c`j)
    and (-14h=type c`d) and (`tickerplant in exec id from timer.getalljobs[])
    and all `subdetails`tablelist in key `.};

/ batch mode: upd stamps, buffers into the root table and logs (bumping j). i is the PUBLISHED
/ watermark and must NOT move while the rows are still buffered - it catches up at the flush
/ init's OPTIONAL `handlers dep is forwarded verbatim to di.pubsub.init - see the design note in
/ tickerplant.md. a fresh init WITH a handlers dep must make di.pubsub's own .z.pc hook visible in
/ di.handlers' own registry (di.handlers.list[`.z.pc] naming `pubsub), which omitting the key (every
/ other test here) never triggers
testhandlersforwarded:{[]
  resetmodule[];
  dd:freshdir"handlers";
  `trade set 0#trade;
  handlers.init[enlist[`log]!enlist caplog[]];
  tp.init mkdeps[dd;1b],enlist[`handlers]!enlist handlers;
  0<count select from handlers.list[`.z.pc] where name=`pubsub};

testupdbatch:{[]
  freshinit["updb";1b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  c:tp[`getcounts][];
  n:count trade;
  s:exec sym from trade;
  stamped:not any null exec time from trade;
  flushbuffer[];
  a:tp[`getcounts][];
  (2=n) and (`AAPL`MSFT~s) and stamped and (2=c`j) and (0=c`i) and (2=a`i) and 2=a`j};

/ an empty update is a no-op: no throw, nothing buffered, nothing logged
testemptyupd:{[]
  freshinit["empty";1b];
  tp[`upd][`trade;()];
  c:tp[`getcounts][];
  (0=count trade) and 0=c`j};

/ an empty update still triggers an overdue roll (the roll check runs before the empty-data skip)
testemptyupdtriggersroll:{[]
  freshinit["emptyroll";1b];
  oldd:first tp[`getcounts][]`d;
  eod.setnextroll .z.p-0D01:00:00;
  tp[`upd][`trade;()];
  (oldd+1)=first tp[`getcounts][]`d};

/ zero-latency mode: upd publishes immediately, does NOT buffer into the root table, still logs - and
/ i tracks j, because every logged message has already gone out. without that a zero-latency
/ tickerplant tells every subscriber to replay nothing
testzerolatency:{[]
  freshinit["zl";0b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  c:tp[`getcounts][];
  (0=count trade) and (2=c`j) and 2=c`i};

/ a re-init refreshes config but must NOT rewind runtime state: the date, the message counts a
/ subscriber replays against, the buffered rows, or the open log handle. it must not leak a
/ descriptor either, which it cannot now that it no longer reopens the log
testreinitpreservesstate:{[]
  fddir:"/proc/",(string .z.i),"/fd";
  dd:freshinit["reinit";1b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  c0:tp[`getcounts][];
  lp0:.m.di.0tickerplant.logpath;
  b:"J"$first system"ls ",fddir," | wc -l";
  tp.init mkdeps[dd;1b]; tp.init mkdeps[dd;1b]; tp.init mkdeps[dd;1b];
  a:"J"$first system"ls ",fddir," | wc -l";
  c1:tp[`getcounts][];
  tp[`upd][`trade;row`IBM];
  (c0~c1) and (a=b) and (lp0~.m.di.0tickerplant.logpath) and (3=count trade)
    and 3=tp[`getcounts][]`j};

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

/ =============================================================================
/ the subscription protocol di.subscriptions speaks
/ =============================================================================

/ subdetails carries all four required keys, in the shapes di.subscriptions' guards check:
/ schemalist as (tablename;schema) pairs, logfilelist as (integer count;symbol file) pairs,
/ rowcounts as a dict keyed by table, date as a date
testsubdetails:{[]
  freshinit["subd";1b];
  tp[`upd][`trade;row`AAPL];
  flushbuffer[];
  d:tp[`subdetails][`;`];
  sl:d`schemalist;
  lfl:d`logfilelist;
  (all `schemalist`logfilelist`rowcounts`date in key d)
    and (1=count sl) and (`trade~first first sl) and (.Q.qt last first sl)
    and (1=count lfl) and ((type first first lfl) in -7 -6h) and (-11h=type last first lfl)
    and (99h=type d`rowcounts) and (1=(d`rowcounts)`trade) and (-14h=type d`date)};

/ the message count is the PUBLISHED watermark i, not the logged total j: rows logged but not yet
/ flushed are still in the buffer and go out to a NEW subscriber at the next flush, so reporting j
/ would have it replay them from the log AND receive them again
testsubdetailscountispublished:{[]
  freshinit["subdi";1b];
  tp[`upd][`trade;row`AAPL];
  tp[`upd][`trade;row`MSFT];
  flushbuffer[];
  tp[`upd][`trade;row`IBM];
  c:tp[`getcounts][];
  n:first first tp[`subdetails][`;`]`logfilelist;
  (2=c`i) and (3=c`j) and 2=n};

/ with logging disabled there is no log to replay, so logfilelist is EMPTY rather than naming a file
testsubdetailsnolog:{[]
  resetmodule[];
  `trade set 0#trade;
  `logcap set 0#logcap;
  tp.init[`log`timer`schemas`logdir!(caplog[];timer;enlist[`trade]!enlist trade;"")];
  d:tp[`subdetails][`;`];
  (()~d`logfilelist) and 0=tp[`getcounts][]`j};

/ subdetails for a table this tickerplant does not publish fails with a message that NAMES the table
/ and logs it. a bare `fail` row would pass on any throw at all, including an unrelated one
testsubdetailsunknown:{[]
  freshinit["subdunk";1b];
  e:string @[{tp[`subdetails][x;`];`NOTHROW};`nope;{[e] `$e}];
  (0<count e ss "no requested table is published") and (0<count e ss "nope")
    and `error in exec lvl from logcap where ctx=`subdetails};

/ tablelist must accept the ONE argument di.subscriptions sends - (`tablelist;`). a niladic form
/ throws 'rank, which di.subscriptions catches and silently downgrades to asking for `
testtablelist:{[]
  freshinit["tl";1b];
  (enlist[`trade]~tp[`tablelist][`]) and enlist[`trade]~tp[`tablelist][`trade]};

/ both protocol names live at ROOT, where the default .z.pg reaches them for an IPC caller, and are
/ callable in the message shape an IPC caller sends. teardown gives them back and drops the timer job
testrootandteardown:{[]
  freshinit["root";1b];
  installed:all `subdetails`tablelist in key `.;
  callable:enlist[`trade]~value (`tablelist;`);
  tp[`teardown][];
  installed and callable and (not any `subdetails`tablelist in key `.)
    and not `tickerplant in exec id from timer.getalljobs[]};

/ a re-init after teardown re-publishes the protocol and re-schedules the job - the flag is what
/ makes that work, since a re-init is not fresh and di.timer throws on a duplicate job id
testreinitafterteardown:{[]
  dd:freshinit["rat";1b];
  tp[`teardown][];
  tp.init mkdeps[dd;1b];
  (all `subdetails`tablelist in key `.) and `tickerplant in exec id from timer.getalljobs[]};

/ every callable export except upd reports the module's own "init must be called" message rather than
/ a bare unresolved-name error. upd is the documented exception - it is the per-message hot path and
/ carries no guard, so this pins WHICH functions are guarded rather than asserting they all are.
/ NB the calls are wrapped in NILADIC lambdas: tp[`subscribe][`;`] written bare would be evaluated
/ while the list is built, throwing there instead of inside the protected apply
testrequireinit:{[]
  resetmodule[];
  / return the ERROR STRING, or "NOTHROW" - never `string` of the result. a successful call can
  / return a symbol vector or (::), and stringifying either yields a LIST of strings, which then
  / throws 'type inside ss rather than failing the assertion (measured)
  msg:{[f] :@[{[g] g[]; "NOTHROW"};f;{[e] e}]};
  calls:({[] tp[`teardown][]};{[] tp[`subscribe][`;`]};{[] tp[`subdetails][`;`]};
    {[] tp[`tablelist][`]};{[] tp[`endofday][]};{[] tp[`getcounts][]};{[] tp[`gettables][]});
  saidinit:all {[m] 0<count m ss "init must be called before any other function"} each msg each calls;
  / upd is deliberately unguarded, so it does NOT report the init guard. NB resetmodule clears only
  / the names initialised[] probes, so .z.m.tabs survives and upd may simply return rather than
  / throw - either outcome is correct here, and only the absence of the guard message is asserted
  unguarded:0=count (msg {[] tp[`upd][`trade;()]}) ss "init must be called";
  / leave the module INITIALISED again: the upd validation rows that follow are `fail` rows, and an
  / uninitialised module makes them throw on an unset .z.m.logerr - passing for the wrong reason
  freshinit["reqinit";1b];
  saidinit and unguarded};
