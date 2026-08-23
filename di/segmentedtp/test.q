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
    "-1 \"RESULT rowcount=\",(string rowcount),\" distinctlognames=\",(string distinctlognames),",
      "\" nullendcount=\",(string nullendcount),\" seqok=\",string seqok;";
    "exit 0;");
  out:runchild[dir;lines];
  line:first out where out like "RESULT rowcount=*";
  toks:" " vs line;
  :`rowcount`distinctlognames`nullendcount`seqok!("J"$last "=" vs toks 1;"J"$last "=" vs toks 2;
    "J"$last "=" vs toks 3;"1"=first last "=" vs toks 4);
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
