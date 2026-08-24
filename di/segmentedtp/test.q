/ fixture helpers for di.segmentedtp's k4unit tests. test.csv's own `before` rows build every mock
/ and scenario closure inline (mocklog/mocktimer/mockhandlers, .t.scenA, the custom-mode csv fixtures)
/ since none of them need commas that would break a csv field. this file exists for the one helper
/ genuinely worth sharing rather than repeating inline, matching di.tplog's test.q precedent of
/ keeping fixture plumbing out of the csv proper.

/ wipe and recreate a scratch directory under /tmp - used by test.csv's before rows and available for
/ test_integration.csv's spawned-process scenarios to call the same way
resetscratch:{[dir] system "rm -rf ",dir; system "mkdir -p ",dir;}

/ =============================================================================
/ test_integration.csv helpers - spawn a FRESH q process for a scenario that needs its own genuinely
/ fresh init (a different multilog/batchmode config), which test.csv's single shared process cannot
/ give: a second stp.init call there is a RE-init, not a fresh one - see segmentedtp.md's design notes.
/ =============================================================================

/ write scriptlines (a list of strings) to dir/child.q, run it via a q binary matched to this parent
/ process's own QHOME/QPATH, and return the captured stdout as a list of lines
runchild:{[dir;scriptlines]
  resetscratch[dir];
  sf:dir,"/child.q";
  (hsym `$sf) 0: scriptlines;
  qhome:first system "echo $QHOME";
  qpath:first system "echo $QPATH";
  qbin:qhome,"/bin/q";
  :system "QHOME=",qhome," QPATH=",qpath," ",qbin," ",sf," -q 2>&1";
  };

/ like runchild, but does NOT wipe dir first - for a scenario that chains multiple child processes
/ against the SAME on-disk state (e.g. a process that crashes, followed by a restart into the exact
/ same log directory, simulating real crash-recovery rather than a single isolated fresh init)
runchildkeep:{[dir;scriptlines]
  sf:dir,"/child.q";
  (hsym `$sf) 0: scriptlines;
  qhome:first system "echo $QHOME";
  qpath:first system "echo $QPATH";
  qbin:qhome,"/bin/q";
  :system "QHOME=",qhome," QPATH=",qpath," ",qbin," ",sf," -q 2>&1";
  };

/ memorybatch: insert-only in upd, nothing written or published until the timer flush OR the .z.exit
/ handler on a clean shutdown (segmentedtp.md's memorybatch risk section). the child process never
/ calls teardown or fires the timer - it inits, inserts two rows, and exits cleanly (exit 0), so the
/ ONLY way the data reaches disk is the registered .z.exit handler actually firing on real process
/ exit. real di.handlers is used (not a mock) specifically because a mock is never wired to the
/ genuine .z.exit event - only di.handlers' own .z.exit assignment is
memorybatchscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`batchmode`multilog!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`memorybatch;`singular);";
    "stp.init[deps];";
    "stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];";
    "stp.upd[`trade;(enlist`MSFT;enlist 200.25;enlist 5)];";
    "exit 0;");
  runchild[dir;lines];
  / the log file is the only witness that matters - find it and replay it through di.tplog directly,
  / same as a real subscriber would, rather than trusting anything the (now-dead) child process said
  logfiles:key hsym `$dir,"/stplogs";
  daydir:first logfiles;
  files:key hsym `$dir,"/stplogs/",string daydir;
  logfile:first files where files like "stp_2*";
  / bracket notation, not dot - a use inside a function binds a function-local name, and the dotted
  / accessor throws (same gotcha documented in segmentedtp/init.q's own header comment)
  tplog:use`di.tplog;
  tplog[`init][enlist[`log]!enlist `info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()})];
  / a root-level table, not a function-local var: q lambdas do not close over an enclosing function's
  / locals, so a nested {[t;x] localvar,:...} inside upd would silently accumulate into a variable the
  / replay callback can never actually see. `.mbreplayed set (matching .t.jobs/.t.regs's own pattern
  / in test.csv) is a genuine global both this function and the upd override can reach
  `.mbreplayed set ([]t:`symbol$();x:());
  upd::{[t;x] `.mbreplayed insert (t;enlist x);};
  tplog[`replay] hsym `$dir,"/stplogs/",string[daydir],"/",string logfile;
  :count `.mbreplayed;
  };

/ custom mode mixing tabular (excluded from periodic rolling) with periodic (included) - the real,
/ on-disk counterpart to test.csv's in-process rolltabs negative control. after a real period roll,
/ the tabular-assigned table's log file must be untouched while the periodic-assigned one is not
custommodescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "stp.setcustommode[([]tabname:`trade`quote;mode:`tabular`periodic)];";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog`multilogperiod!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`custom;0D00:00:01);";
    "stp.init[deps];";
    "tradebefore:exec first logname from `.currlog where tbl=`trade;";
    "quotebefore:exec first logname from `.currlog where tbl=`quote;";
    "priv:`$\".m.di.0segmentedtp\";";
    / periodrollover alone does not advance currperiod - only endofperiod does, then calls
    / periodrollover itself. calling periodrollover directly would reuse the SAME currperiod value,
    / producing the SAME filename regardless of rolltabs - not a real test of the roll at all
    "cp:priv`currperiod; np:cp+priv`multilogperiod;";
    "priv[`endofperiod][cp;np;`p`proctype`tables!(np;`segmentedtp;`trade`quote);1b];";
    "tradeafter:exec first logname from `.currlog where tbl=`trade;";
    "quoteafter:exec first logname from `.currlog where tbl=`quote;";
    "-1 \"RESULT tradeunchanged=\",(string tradebefore~tradeafter),\" quotechanged=\",string not quotebefore~quoteafter;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT tradeunchanged=*";
  / token-split rather than hardcoded character offsets - "RESULT" "tradeunchanged=1b" "quotechanged=0b"
  toks:" " vs line;
  :`tradeunchanged`quotechanged!("1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2);
  };

/ regression test for a real bug found while pinning the phantom-table guard above: checkcustommode
/ and readcustomcsv are documented (segmentedtp.q's own header comment on checkcustommode) as callable
/ BEFORE init - "the natural call order is load custom assignment, then init" - but both called
/ .z.m.logerr/.z.m.loginfo directly, which init is the ONLY thing that ever sets. in a genuinely
/ pre-init process (not test.csv's shared process, where init already ran earlier) EVERY call threw a
/ confusing internal error (indexing an unset .z.m.logerr/.loginfo) instead of the intended clear
/ message - even a perfectly VALID readcustomcsv call failed, since it logs unconditionally on
/ success. fixed by a logready[] probe (same shape as initialised[]/custommodeset[] above) guarding
/ every log call in both functions, with each error message's own local var assigned unconditionally
/ so the guard does not also swallow the message the trailing signal depends on
preinitvalidationscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    / no handlers/timer wiring and no stp.init call at all - genuinely pre-init, matching the
    / documented natural call order exactly
    "r1:.[stp.setcustommode;enlist ([]tabname:enlist`trade;mode:enlist`notarealmode);{x}];";
    "(hsym`$\"",dir,"/custom.csv\") 0: (\"tabname,mode\";\"trade,tabular\");";
    "r2:.[stp.readcustomcsv;enlist \"",dir,"/custom.csv\";{x}];";
    "r1ok:(10h=type r1) and 0<count r1 ss \"unrecognised mode(s): notarealmode\";";
    "r2ok:r2~(::);";
    "-1 \"RESULT r1ok=\",(string r1ok),\" r2ok=\",string r2ok;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT r1ok=*";
  toks:" " vs line;
  :`r1ok`r2ok!("1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2);
  };

/ regression test pinning the custom-mode phantom-table validation guard (segmentedtp.q's init,
/ badtabs check): a custom-mode config that assigns a table not present in schemas must be rejected
/ at init - previously verified by hand during adversarial testing but never pinned with a permanent
/ test. asserts init throws, the message names both the guard reason and the offending table, and -
/ per the guard's own design comment - that no stplogs directory was even created, proving the check
/ runs before createdld/openlog so no orphan log file is ever opened for the unknown table
phantomtablescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "stp.setcustommode[([]tabname:enlist`bogus;mode:enlist`tabular)];";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`custom);";
    "r:.[stp.init;enlist deps;{x}];";
    "threw:not r~(::);";
    "msgtext:$[threw;r;\"\"];";
    / key on a MISSING path returns () rather than throwing on this build, so a protected apply on
    / the subdirectory itself would always report "exists" - check the (already-real) parent dir's
    / own listing for the child name instead
    "direxists:`stplogs in key hsym`$\"",dir,"\";";
    "-1 \"RESULT threw=\",(string threw),\" direxists=\",(string direxists),\" msgtext=\",msgtext;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT threw=*";
  toks:" " vs line;
  threw:"1"=first last "=" vs toks 1;
  direxists:"1"=first last "=" vs toks 2;
  hasmsg:(0<count line ss "not in schemas") and 0<count line ss "bogus";
  :`threw`direxists`hasmsg!(threw;direxists;hasmsg);
  };

/ regression test for a real bug found during smoke testing: singular/periodic modes have MULTIPLE
/ tables sharing one logical log file, but openlog's reuse check used to be keyed on (tbl;logname),
/ so a second table resolving to the SAME logname as an already-open first table got its own
/ INDEPENDENT hopen call to that same path - two separate OS handles writing to one file, which
/ produced a file di.tplog could not replay at all ('rank, confirmed directly against the raw file
/ before the fix). the fix reuses ANY currlog row with a matching logname, not just this table's own.
/ this scenario writes real alternating trade/quote traffic through periodic mode, closes, and proves
/ the file replays cleanly with the full row count - not just that init/upd didn't throw
periodichandlescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`periodic);";
    "stp.init[deps];";
    "htrade:exec first handle from `.currlog where tbl=`trade;";
    "hquote:exec first handle from `.currlog where tbl=`quote;";
    "-1 \"RESULT samehandle=\",string htrade~hquote;";
    "do[5;stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];stp.upd[`quote;(enlist`AAPL;enlist 100.0;enlist 101.0)]];";
    "exit 0;");
  out:runchild[dir;lines];
  sameline:first out where out like "RESULT samehandle=*";
  samehandle:"1"=first last "=" vs sameline;
  daydir:first key hsym `$dir,"/stplogs";
  files:key hsym `$dir,"/stplogs/",string daydir;
  logfile:first files where files like "stp_periodic*";
  tplog:use`di.tplog;
  tplog[`init][enlist[`log]!enlist `info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()})];
  / :: not : throughout this block - t insert x (a by-name insert) always targets ROOT regardless of
  / any same-named local, and di.tplog.replay's -11! looks up upd at ROOT too. a bare : here would
  / leave root without trade/quote to insert into and upd undefined at the name -11! actually calls
  `trade set ([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());
  `quote set ([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());
  upd::{[t;x] t insert x;};
  n:@[tplog[`replay];hsym `$dir,"/stplogs/",string[daydir],"/",string logfile;{[e] -1;`THREW}];
  :`samehandle`replaycount`tradecount`quotecount!(samehandle;n;count trade;count quote);
  };

/ regression test for a real bug found during a holistic re-read of the whole file: EVERY validation
/ guard in init (multilogperiod, errorlogname collision, the multilog/batchmode/replayperiod domain
/ checks) runs AFTER .z.m.schemas is already written, so a THROWN init still left initialised[]
/ reporting true. a caller who fixes their config and retries then got silently treated as a RE-init -
/ fresh:not initialised[] came back false - skipping every bit of first-time state seeding (logtabs,
/ currperiod, the initial log open, .z.m.scheduled/.z.m.handlerregistered). the "corrected" retry
/ itself then threw on undefined .z.m.scheduled, and upd afterward threw on undefined .z.m.logtabs.
/ confirmed directly, both before and after the fix (a dedicated .z.m.initcomplete flag, set only as
/ init's own final statement, replacing .z.m.schemas as initialised[]'s probe). needs a genuinely
/ fresh process - test.csv's shared process already has a successful init from scenario A, so
/ initialised[] is already (correctly) true there before this bug could ever be observed
freshinitpoisonscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "badbase:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:00);";
    "r1:.[stp.init;enlist badbase;{x}];";
    "r1threw:10h=type r1;";
    "goodbase:`log`timer`handlers`schemas`kdbtplog!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\");";
    "r2:.[stp.init;enlist goodbase;{x}];";
    "r2ok:r2~(::);";
    "r3:.[stp.upd;(`trade;(enlist`AAPL;enlist 100.5;enlist 10));{x}];";
    "r3ok:r3~(::);";
    "-1 \"RESULT r1threw=\",(string r1threw),\" r2ok=\",(string r2ok),\" r3ok=\",string r3ok;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT r1threw=*";
  toks:" " vs line;
  :`r1threw`r2ok`r3ok!("1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2;"1"=first last "=" vs toks 3);
  };

/ regression test for a real bug found during a holistic re-read, in getmeta's `open` action: a
/ process that dies before ever closing its currently-open period (a crash, or any exit that skips
/ the .z.exit handler) leaves that row permanently null-end in the persisted stpmeta. the ORIGINAL
/ getmeta[`open] always APPENDED a fresh row on top, with no check for one already there - confirmed
/ directly, by chaining three restarts against the same log directory without ever letting one close
/ cleanly: the metatable ended up with FIVE rows all pointing at the exact same physical logfile, and
/ subdetails' logfilelist (via getlogs`day`) reported that one file five times over - a subscriber
/ replaying "the day" would replay the same data five times. fixed by reconciling against any existing
/ null-end row for the same tables BEFORE appending: same logname (the common case - a restart within
/ the same period window) means RESUME it, not duplicate it; this scenario proves that half directly,
/ with a real crash (exit 1, skipping .z.exit entirely) followed by a real restart into the same dir
crashresumescenario:{[dir]
  resetscratch[dir];
  alines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`singular);";
    "stp.init[deps];";
    "stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];";
    / exit 1, not 0 - a non-zero code skips the .z.exit handler entirely (segmentedtp.md's own
    / documented guard), simulating a real crash: the metatable's open row for `trade is never closed
    "exit 1;");
  / q's system throws 'os on a nonzero exit code - expected and wanted here (that's the simulated
  / crash), so trap it; the external process has already run to completion by the time system
  / decides whether to throw, so process A's on-disk state is unaffected either way. `.`, not `@` -
  / runchildkeep is dyadic, and @ on a dyadic function silently returns an unevaluated projection
  / instead of calling it - confirmed directly, and the exact reason process A never actually ran
  / the first time this scenario was written, silently invalidating the whole test
  .[runchildkeep;(dir;alines);{[e]}];
  blines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "`.captured set ([]ctx:`symbol$();msg:());";
    "caplog:`info`warn`error!({[c;m]:()};{[c;m] `.captured insert (c;m);};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist caplog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(caplog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`singular);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "rows:select from priv[`metatable] where tbls~\\:enlist`trade;";
    "resumed:0<count .captured where .captured[`msg] like \"*resuming logfile*\";";
    "-1 \"RESULT rowcount=\",(string count rows),\" resumed=\",string resumed;";
    "exit 0;");
  out:runchildkeep[dir;blines];
  line:first out where out like "RESULT rowcount=*";
  toks:" " vs line;
  :`rowcount`resumed!("J"$last "=" vs toks 1;"1"=first last "=" vs toks 2);
  };

/ regression test for the OTHER half of the same getmeta[`open] fix: a stale null-end row with a
/ DIFFERENT logname than the one currently in use - a genuinely orphaned segment left by a process
/ that crashed, then was restarted only after enough real time passed to cross a period boundary.
/ reproducing that with a real elapsed-time gap would need an actual wait through a period boundary,
/ so this drives getmeta directly (white-box, the same technique daytimestampscenario/custommodescenario
/ already use for checkends/endofperiod) - seeding one fake stale row with a logname that does NOT
/ match currlog's real, currently-open one, then re-invoking getmeta[`open] and asserting it is
/ force-closed (msgcount left null - honestly unknown, not guessed, since a real count would mean
/ replaying the file and triggering upd side effects this reconciliation must not cause) while the
/ REAL open row for the same tables is left untouched, still open, not itself force-closed or duplicated
orphanedmetascenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "`.captured set ([]ctx:`symbol$();msg:());";
    "caplog:`info`warn`error!({[c;m]:()};{[c;m] `.captured insert (c;m);};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist caplog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(caplog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`singular);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "mt0:priv`metatable;";
    "fakerow:`seq`logname`start`end`tbls`msgcount`schema`additional!(999i;`fakestalelog;.z.p;0Np;enlist`trade;0Ni;()!();()!());";
    ".m.di.0segmentedtp.metatable:mt0,fakerow;";
    "priv[`getmeta][`open;enlist`trade;priv`currperiod];";
    "mt1:priv`metatable;";
    "fakeend:exec first end from mt1 where logname=`fakestalelog;";
    "fakemsgcount:exec first msgcount from mt1 where logname=`fakestalelog;";
    "realstillopen:0<count select from mt1 where tbls~\\:enlist`trade, not logname=`fakestalelog, null end;";
    "closedwarned:0<count .captured where .captured[`msg] like \"*orphaned metatable row*\";";
    "-1 \"RESULT fakeclosed=\",(string not null fakeend),\" fakemsgnull=\",(string null fakemsgcount),\" realstillopen=\",(string realstillopen),\" closedwarned=\",string closedwarned;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT fakeclosed=*";
  toks:" " vs line;
  :`fakeclosed`fakemsgnull`realstillopen`closedwarned!("1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2;"1"=first last "=" vs toks 3;"1"=first last "=" vs toks 4);
  };

/ regression test for a real bug found during smoke testing: dayrollover computed the new day's
/ currperiod (and next-roll target) from .z.p (real wall-clock "now") rather than the EVENT time
/ (data`p, the timestamp checkends actually detected the roll at). under any latency between the
/ two - simulated here via checkends' own x argument, which is exactly how a real elapsed-time gap
/ would show up - the new log file's naming timestamp landed in the CORRECT new-day directory but
/ carried the WRONG (stale, old-day) timestamp in its filename. fixed by using data`p throughout.
daytimestampscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "eodtime:use`di.eodtime;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`singular);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    / singular forces multilogperiod to 1D, so a 1-day jump crosses exactly one period boundary too,
    / avoiding the unrelated "next period is in the past" safety guard
    "future:.z.p+1D;";
    "priv[`checkends][future];";
    "newdate:string eodtime[`getd][];";
    "logname:exec first logname from `.currlog where tbl=`trade;";
    "-1 \"RESULT newdate=\",newdate,\" logname=\",string logname;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT newdate=*";
  toks:" " vs line;
  newdate:last "=" vs toks 1;
  logname:last "=" vs toks 2;
  / the new day's date (no dashes/dots, matching gentimeformat's own stripping) must appear in the
  / logfile's own name - proving the naming timestamp actually matches the day it landed in
  compact:ssr[;".";""] newdate;
  :0<count logname ss compact;
  };

/ immediate mode - write and publish together, no batching lag. this is the genuinely clean version
/ of the check test.csv's own immediate-mode scenario cannot make: in test.csv's shared process,
/ scenario A's earlier subdetails call registers the in-process caller as a subscriber under a bogus
/ (non-IPC) handle, and di.pubsub correctly throws trying to notify it on any later publish - caught
/ by errmode, but it means i never advances there for reasons that have nothing to do with immediate
/ mode itself. a fresh child process here never calls subdetails, so publish has zero subscribers and
/ behaves the way a real immediate-mode write does
immediatemodescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`batchmode!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";`immediate);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "j0:priv[`j]`trade; i0:priv[`i]`trade;";
    "stp.upd[`trade;(enlist`XYZ;enlist 50.0;enlist 1)];";
    "j1:priv[`j]`trade; i1:priv[`i]`trade;";
    "-1 \"RESULT jdelta=\",(string j1-j0),\" ideltaeqjdelta=\",string (i1-i0)=(j1-j0);";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT jdelta=*";
  toks:" " vs line;
  :`jdelta`ideltaeqjdelta!("J"$last "=" vs toks 1;"1"=first last "=" vs toks 2);
  };

/ stress test - N period rolls back to back, no delay between them, driven the CORRECT way (through
/ endofperiod, which advances currperiod, then calls periodrollover itself - periodrollover ALONE does
/ not advance currperiod, matching custommodescenario's own header note above). proves the naming/
/ metatable machinery this session already fixed (getmeta's restart-recovery reconciliation, openlog's
/ shared-handle reuse) holds up under RAPID succession too, not just one roll at a time: every period
/ gets its own distinct logname, exactly one row stays open, and seq increments monotonically with no
/ gaps or duplicates
rapidperiodrollscenario:{[dir]
  n:20;
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:01);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "do[",(string n),";",
      "stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];",
      "cp:priv`currperiod;np:cp+priv`multilogperiod;",
      "priv[`endofperiod][cp;np;`p`proctype`tables!(np;`segmentedtp;enlist`trade);1b]];";
    "mt:select from priv[`metatable] where tbls~\\:enlist`trade;";
    "rowcount:count mt;";
    "distinctlognames:count distinct exec logname from mt;";
    "nullendcount:count select from mt where null end;";
    / = not ~ - seq is int, til is long; ~ is strict on type as well as value and would never match
    "seqok:all (asc exec seq from mt)=1+til count mt;";
    / i/j must NOT be reset by a period roll (only dayrollover resets them - see rolllog's own header
    / comment). each of the n iterations writes exactly one message before its own roll, so with the
    / fix j accumulates to n; the old bug reset it to 0 inside every single one of these rolls, so j
    / would end at 0 regardless of n - a clean, deterministic differentiator, no timing dependency
    "jfinal:priv[`j]`trade;";
    "-1 \"RESULT rowcount=\",(string rowcount),\" distinctlognames=\",(string distinctlognames),",
      "\" nullendcount=\",(string nullendcount),\" seqok=\",(string seqok),\" jfinal=\",string jfinal;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT rowcount=*";
  toks:" " vs line;
  :`rowcount`distinctlognames`nullendcount`seqok`jfinal!("J"$last "=" vs toks 1;"J"$last "=" vs toks 2;
    "J"$last "=" vs toks 3;"1"=first last "=" vs toks 4;"J"$last "=" vs toks 5);
  };

/ regression test for a real bug found during review: the three roll-safety guards (endofperiod,
/ dayrollover, checkends) used to call di.timer's PROCESS-WIDE disable, which gates main[] for every
/ job of every module sharing that timer instance - not just this module's own tick job. a
/ segmentedtp-specific clock-skew trip would silently halt every other module's timer-driven work in
/ the same process. proves the fix's actual blast-radius claim: a real, unrelated timer job registered
/ through the SAME real di.timer instance must survive the guard trip untouched, while segmentedtp's
/ own job is correctly disabled. white-box asserts against di.timer's own private state
/ (.m.di.0timer.enabled/.jobs), the same technique di.timer's own test.csv and di.heartbeat's real-
/ timer integration test already use - this is the only reliable way to observe the process-wide flag,
/ which di.timer does not expose through any export. endofperiod is called directly (not via checkends
/ + a wall-clock jump) with an event timestamp set deliberately far beyond nextperiod+multilogperiod,
/ so the guard trips deterministically regardless of real time
rollguardscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:01);";
    "stp.init[deps];";
    / di.timer's own `enabled` flag defaults to 0b at module load and is only ever set 1b inside
    / di.timer.init - segmentedtp never calls it (segmentedtp only reaches timer through the injected
    / addjob/deletejobs/disablejobs functions, never timer's own init), so it must be called here
    / directly or `enabled` would read 0b regardless of whether the fix or the old bug is in effect,
    / making the globalenabled assertion below meaningless
    "timer[`init][(::)];";
    "timer[`addjob][`custom][`unrelatedjob;{[]::};();`int$60000;1h;()!()];";
    "priv:`$\".m.di.0segmentedtp\";";
    "cp:priv`currperiod; np:cp+priv`multilogperiod;";
    "r:.[priv[`endofperiod];(cp;np;`p`proctype`tables!(np+1D;`segmentedtp;enlist`trade);1b);{x}];";
    "threw:not r~(::);";
    "globalenabled:.m.di.0timer.enabled;";
    "segmentedtpstatus:.m.di.0timer.jobs[`segmentedtp][`status];";
    "unrelatedstatus:.m.di.0timer.jobs[`unrelatedjob][`status];";
    "-1 \"RESULT threw=\",(string threw),\" globalenabled=\",(string globalenabled),",
      "\" segmentedtpstatus=\",(string segmentedtpstatus),\" unrelatedstatus=\",string unrelatedstatus;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT threw=*";
  toks:" " vs line;
  :`threw`globalenabled`segmentedtpstatus`unrelatedstatus!(
    "1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2;
    "1"=first last "=" vs toks 3;"1"=first last "=" vs toks 4);
  };

/ regression test for a real bug found during review: openlog's handle-reuse check queried .currlog by
/ the PRE-repair logname, but di.tplog.repair returns a NEW <name>.good path and opens/closes its own
/ handle internally, never returning one to the caller. under singular/periodic mode - where multiple
/ tables share one logical log file - a second table's openlog call recomputed the same original
/ (still-corrupt) name, missed the first table's already-repaired-and-open handle, and opened an
/ independent second handle onto what should be one shared file. reproduced end to end: real init
/ writes real traffic under periodic mode, the resulting on-disk file is corrupted with the exact
/ byte-smash technique di.tplog's own test.q corrupt helper uses (proven to trigger its corruption
/ detection), then a fresh restart into the same directory drives BOTH tables' openlog through the
/ repair path during init's own fresh-open block
sharedhandlerepairscenario:{[dir]
  lines1:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`periodic);";
    "stp.init[deps];";
    "do[3;stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];stp.upd[`quote;(enlist`AAPL;enlist 100.0;enlist 101.0)]];";
    "stp.teardown[];";
    "exit 0;");
  runchild[dir;lines1];
  / corrupt the shared log file on disk, in THIS process - same byte-smash technique as di.tplog's own
  / test.q corrupt helper (smash k bytes starting at the file's midpoint)
  daydir:first key hsym `$dir,"/stplogs";
  files:key hsym `$dir,"/stplogs/",string daydir;
  logfile:first files where files like "stp_periodic*";
  fn:hsym `$dir,"/stplogs/",string[daydir],"/",string logfile;
  b:read1 fn;
  p:count[b] div 2;
  k:12;
  fn set @[b;p+til k&count[b]-p;:;k#0xff];
  / restart into the SAME directory - both tables' openlog calls hit the same corrupt file during
  / init's fresh-open block
  lines2:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`periodic);";
    "stp.init[deps];";
    "htrade:exec first handle from `.currlog where tbl=`trade;";
    "hquote:exec first handle from `.currlog where tbl=`quote;";
    "-1 \"RESULT samehandle=\",string htrade~hquote;";
    "do[2;stp.upd[`trade;(enlist`MSFT;enlist 50.0;enlist 1)];stp.upd[`quote;(enlist`MSFT;enlist 49.5;enlist 50.5)]];";
    "exit 0;");
  out:runchildkeep[dir;lines2];
  sameline:first out where out like "RESULT samehandle=*";
  samehandle:"1"=first last "=" vs sameline;
  / the original corrupt file is left untouched on disk by design (di.tplog.repair never rewrites in
  / place) - the .good file is the live, repaired log to check
  files2:key hsym `$dir,"/stplogs/",string daydir;
  goodfile:first files2 where files2 like "*.good";
  tplog:use`di.tplog;
  tplog[`init][enlist[`log]!enlist `info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()})];
  `trade set ([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());
  `quote set ([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());
  upd::{[t;x] t insert x;};
  n:@[tplog[`replay];hsym `$dir,"/stplogs/",string[daydir],"/",string goodfile;{[e] -1;`THREW}];
  :`samehandle`replayok`replaycount!(samehandle;not n~`THREW;n);
  };

/ stress test - N day rolls back to back, no delay between them, with TWO tables sharing one OS
/ handle (periodic mode) so the shared-handle logic (also fixed and pinned earlier this session in
/ periodichandlescenario) is exercised under rapid day-roll succession too, not just steady-state.
/ multilogperiod is set to 1D explicitly (periodic mode does not force this the way singular/tabular
/ do) so each checkends call advances by exactly ONE period AND one day together - jumping further
/ (e.g. real wall-clock .z.p+1D from a short, non-daily period) skips intermediate period boundaries
/ and correctly trips endofperiod's own "next period is in the past" safety guard, confirmed directly
/ while designing this test. each day's own directory gets its own single-row stpmeta, wiped and
/ restarted fresh every day-roll by design (segmentedtp.md's directory-per-day layout) - so the
/ in-memory metatable reflects only the CURRENT day, and the real cross-restart assertion is that
/ every one of the N+1 day directories exists with correct, non-duplicated content
rapiddayrollscenario:{[dir]
  n:10;
  lines:(
    "stp:use`di.segmentedtp;";
    "eodtime:use`di.eodtime;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog`multilogperiod!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`periodic;1D);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "startdate:eodtime[`getd][];";
    "do[",(string n),";",
      "stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];",
      "stp.upd[`quote;(enlist`AAPL;enlist 100.0;enlist 101.0)];",
      "priv[`checkends][eodtime[`getnextroll][]+1]];";
    "htrade:exec first handle from `.currlog where tbl=`trade;";
    "hquote:exec first handle from `.currlog where tbl=`quote;";
    "samehandle:htrade~hquote;";
    "daydirs:key hsym`$\"",dir,"/stplogs\";";
    "-1 \"RESULT daydircount=\",(string count daydirs),\" samehandle=\",(string samehandle),",
      "\" startdate=\",(string startdate),\" enddate=\",string eodtime[`getd][];";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT daydircount=*";
  toks:" " vs line;
  daydircount:"J"$last "=" vs toks 1;
  samehandle:"1"=first last "=" vs toks 2;
  startdate:"D"$last "=" vs toks 3;
  enddate:"D"$last "=" vs toks 4;
  / every intervening day must exist as its own directory - no day skipped, none duplicated
  alldayspresent:daydircount=1+enddate-startdate;
  :`daydircount`samehandle`alldayspresent!(daydircount;samehandle;alldayspresent);
  };

/ replayperiod:`period` coverage - never directly exercised before (only `day`, the default). proves
/ subdetails' logfilelist under `period` mode reports ONLY the current period's live count/logname,
/ correctly excluding closed history - the opposite of `day` mode's multi-entry, whole-day picture
/ (already covered by test.csv's own subdetails checks). one period roll creates exactly the closed-
/ vs-open contrast needed: two entries under `day` mode for the same state, but exactly one under
/ `period` mode
periodmodescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod`replayperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:01;`period);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];";
    "cp:priv`currperiod;np:cp+priv`multilogperiod;";
    "priv[`endofperiod][cp;np;`p`proctype`tables!(np;`segmentedtp;enlist`trade);1b];";
    "stp.upd[`trade;(enlist`MSFT;enlist 200.0;enlist 5)];";
    "stp.upd[`trade;(enlist`GOOG;enlist 300.0;enlist 3)];";
    "sd:stp.subdetails[`trade;`];";
    "lf:sd`logfilelist;";
    "daycount:count priv[`getlogs][`day][enlist`trade];";
    "-1 \"RESULT periodcount=\",(string count lf),\" msgcount=\",(string first first lf),",
      "\" jtrade=\",(string priv[`j]`trade),\" daycount=\",string daycount;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT periodcount=*";
  toks:" " vs line;
  :`periodcount`msgcounteqj`daycount!("J"$last "=" vs toks 1;
    ("J"$last "=" vs toks 2)=("J"$last "=" vs toks 3);"J"$last "=" vs toks 4);
  };

/ regression test for a real bug found during review: dayrollover's unconditional openlogerr[] call
/ (when errmode/createlogs are on, the defaults) never closed the PREVIOUS day's error-log handle
/ first - closelog each .z.m.logtabs only covers the captured tables, and errorlogname is guaranteed
/ (by init's own collision guard) to never be one of them, so the error log's old os handle was
/ silently overwritten in .currlog and never closed. a real file-descriptor leak, one per day, for the
/ lifetime of a long-running process - confirmed directly, before the fix, via /proc/self/fd: 5 real
/ day-rolls leaked exactly 5 fds. drives dayrollover directly (white-box, matching daytimestampscenario
/ and rapiddayrollscenario's own technique) rather than via checkends/real wall-clock jumps, so the fd
/ count is measured around EXACTLY n roll calls with nothing else able to open/close fds in between
errorlogleakscenario:{[dir]
  n:5;
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D01);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "fdbefore:count key hsym`$\"/proc/self/fd\";";
    "onedayroll:{[i] priv[`dayrollover][`p`proctype`tables!(.z.p;`segmentedtp;enlist`trade)]};";
    "onedayroll each til ",(string n),";";
    "fdafter:count key hsym`$\"/proc/self/fd\";";
    "-1 \"RESULT fdbefore=\",(string fdbefore),",
      "\" fdafter=\",(string fdafter),\" delta=\",string fdafter-fdbefore;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT fdbefore=*";
  toks:" " vs line;
  :`fdbefore`fdafter`delta!("J"$last "=" vs toks 1;"J"$last "=" vs toks 2;"J"$last "=" vs toks 3);
  };

/ regression test for a real bug found during review: a tripped roll-safety guard disabled
/ segmentedtp's own timer job (disablejobs) but nothing ever re-enabled it, even after the module's
/ OWN roll state self-healed on a later natural attempt (upd's inline checkends call already recovers
/ the roll state, confirmed directly - seq/currperiod advance normally again). left as-is, defaultbatch's
/ publish path - which runs ONLY via the timer's tick -> ztsfn -> pubclear, never inline in upd - stayed
/ silently dead forever: confirmed directly before this fix, j (logged) kept climbing while i
/ (published) stayed frozen, with no error anywhere pointing at why. this scenario drives the exact
/ same repro used to find the bug: trip the guard with a deliberate large jump (rollguardscenario's
/ technique), let REAL wall-clock time cross the now near-term period boundary, then a single normal
/ upd - which drives a natural, successful roll via the inline checkends call - must resume the
/ disabled job, not just recover the module's own internal roll state
guardrecoveryscenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:01);";
    "stp.init[deps];";
    "timer[`init][(::)];";
    "priv:`$\".m.di.0segmentedtp\";";
    "cp:priv`currperiod; np:cp+priv`multilogperiod;";
    "rtrip:.[priv[`endofperiod];(cp;np;`p`proctype`tables!(np+1D;`segmentedtp;enlist`trade);1b);{[e]`THREW}];";
    "threw:`THREW~rtrip;";
    "statusaftertrip:first exec status from timer[`getalljobs][] where id=`segmentedtp;";
    "system \"sleep 2\";";
    "rupd:.[stp.upd;(`trade;(enlist`MSFT;enlist 200.0;enlist 5));{[e]`THREW}];";
    "updok:not `THREW~rupd;";
    "statusafterrecovery:first exec status from timer[`getalljobs][] where id=`segmentedtp;";
    "-1 \"RESULT threw=\",(string threw),\" statusaftertrip=\",(string statusaftertrip),",
      "\" updok=\",(string updok),\" statusafterrecovery=\",string statusafterrecovery;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT threw=*";
  toks:" " vs line;
  :`threw`statusaftertrip`updok`statusafterrecovery!(
    "1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2;
    "1"=first last "=" vs toks 3;"1"=first last "=" vs toks 4);
  };

/ combined-failure regression: corruption and a guard-trip/recovery happening close together, not just
/ each in isolation. corrupts the CURRENTLY OPEN periodic-mode shared file (worse than
/ sharedhandlerepairscenario, which only corrupts between restarts), then immediately trips the "next
/ period is in the past" guard, then lets real wall-clock time cross the boundary for a natural
/ recovery. proves: the guard trip and recovery behave identically whether or not a corrupt file is
/ sitting in .currlog: no throw escapes the recovery, the shared handle stays intact, the timer job
/ re-enables, logging genuinely resumes (j advances) - and, distinctly, that the OLD corrupted file is
/ simply superseded by a fresh periodic-mode filename (per-second naming) rather than ever being
/ reopened or "repaired" in place - confirmed by comparing the old and new lognames directly.
/ NB a first draft of this scenario chased a phantom bug that turned out to be in the test script
/ itself (di.tplog.replay called against a glob that legitimately matched nothing, producing a
/ directory path rather than a file) - not in segmentedtp. this version does not attempt file-level
/ replay verification at all, since rapidperiodrollscenario/periodichandlescenario/
/ sharedhandlerepairscenario already cover replay correctness in isolation; this scenario is purely
/ about the two failure modes not corrupting each other's handling when they overlap
combinedfailurescenario:{[dir]
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilog`multilogperiod!(mocklog;timer;handlers;`trade`quote!(trade;quote);\"",dir,"\";`periodic;0D00:00:01);";
    "stp.init[deps];";
    "timer[`init][(::)];";
    "priv:`$\".m.di.0segmentedtp\";";
    "do[3;stp.upd[`trade;(enlist`AAPL;enlist 100.5;enlist 10)];stp.upd[`quote;(enlist`AAPL;enlist 100.0;enlist 101.0)]];";
    "jbefore:priv[`j]`trade;";
    "oldfile:exec first logname from `.currlog where tbl=`trade;";
    "b:read1 oldfile; p:count[b] div 2;";
    "oldfile set @[b;p+til 12&count[b]-p;:;12#0xff];";
    "cp:priv`currperiod; np:cp+priv`multilogperiod;";
    "r1:.[priv[`endofperiod];(cp;np;`p`proctype`tables!(np+1D;`segmentedtp;`trade`quote);1b);{[e]`THREW}];";
    "threw:`THREW~r1;";
    "statusaftertrip:first exec status from timer[`getalljobs][] where id=`segmentedtp;";
    "system \"sleep 2\";";
    "r2:.[stp.upd;(`trade;(enlist`MSFT;enlist 200.0;enlist 5));{[e]`THREW}];";
    "r3:.[stp.upd;(`quote;(enlist`MSFT;enlist 199.5;enlist 200.5));{[e]`THREW}];";
    "r2ok:not `THREW~r2; r3ok:not `THREW~r3;";
    "statusafter:first exec status from timer[`getalljobs][] where id=`segmentedtp;";
    "htrade:exec first handle from `.currlog where tbl=`trade;";
    "hquote:exec first handle from `.currlog where tbl=`quote;";
    "samehandle:htrade~hquote;";
    "newfile:exec first logname from `.currlog where tbl=`trade;";
    "oldfileuntouched:oldfile<>newfile;";
    "jadvanced:(priv[`j]`trade)>jbefore;";
    "-1 \"RESULT threw=\",(string threw),\" statusaftertrip=\",(string statusaftertrip),",
      "\" r2ok=\",(string r2ok),\" r3ok=\",(string r3ok),\" statusafter=\",(string statusafter),",
      "\" samehandle=\",(string samehandle),\" oldfileuntouched=\",(string oldfileuntouched),",
      "\" jadvanced=\",string jadvanced;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT threw=*";
  toks:" " vs line;
  :`threw`statusaftertrip`r2ok`r3ok`statusafter`samehandle`oldfileuntouched`jadvanced!(
    "1"=first last "=" vs toks 1;"1"=first last "=" vs toks 2;"1"=first last "=" vs toks 3;
    "1"=first last "=" vs toks 4;"1"=first last "=" vs toks 5;"1"=first last "=" vs toks 6;
    "1"=first last "=" vs toks 7;"1"=first last "=" vs toks 8);
  };

/ load-volume regression: every other integration scenario runs single-digit message counts. proves
/ correctness and resource stability under real per-roll VOLUME, not just roll-count - 30 period rolls
/ of 50 messages each (1500 total), driven directly through endofperiod (white-box, deterministic, no
/ real wall-clock dependency, matching rapidperiodrollscenario's own technique). asserts j reaches the
/ exact expected total, the metatable has exactly one row per roll plus the still-open one, and -
/ critically - /proc/self/fd shows zero growth across the whole run, so a per-message or per-roll
/ leak under real sustained volume would be caught here even though no single roll would surface it
loadvolumescenario:{[dir]
  nrolls:30; permsg:50;
  lines:(
    "stp:use`di.segmentedtp;";
    "handlers:use`di.handlers;";
    "timer:use`di.timer;";
    "mocklog:`info`warn`error!({[c;m]:()};{[c;m]:()};{[c;m]:()});";
    "handlers.init[enlist[`log]!enlist mocklog];";
    "trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`long$());";
    "deps:`log`timer`handlers`schemas`kdbtplog`multilogperiod!(mocklog;timer;handlers;enlist[`trade]!enlist trade;\"",dir,"\";0D00:00:01);";
    "stp.init[deps];";
    "priv:`$\".m.di.0segmentedtp\";";
    "fdbefore:count key hsym`$\"/proc/self/fd\";";
    "syms:",(string permsg),"?`3; prices:",(string permsg),"?1000f; sizes:1+",(string permsg),"?100;";
    "oneroll:{[i] do[",(string permsg),";stp.upd[`trade;(enlist first 1?syms;enlist first 1?prices;enlist first 1?sizes)]];",
      "cp:priv`currperiod;np:cp+priv`multilogperiod;",
      "priv[`endofperiod][cp;np;`p`proctype`tables!(np;`segmentedtp;enlist`trade);1b]};";
    "oneroll each til ",(string nrolls),";";
    "fdafter:count key hsym`$\"/proc/self/fd\";";
    "mt:select from priv[`metatable] where tbls~\\:enlist`trade;";
    "-1 \"RESULT jfinal=\",(string priv[`j]`trade),\" fdbefore=\",(string fdbefore),",
      "\" fdafter=\",(string fdafter),\" rowcount=\",(string count mt),",
      "\" nullendcount=\",string count select from mt where null end;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT jfinal=*";
  toks:" " vs line;
  :`jfinal`fddelta`rowcount`nullendcount`expected!(
    "J"$last "=" vs toks 1;("J"$last "=" vs toks 3)-"J"$last "=" vs toks 2;
    "J"$last "=" vs toks 4;"J"$last "=" vs toks 5;nrolls*permsg);
  };
