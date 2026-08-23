/ implementation for di.segmentedtp - see segmentedtp.md for the naming-mode / batch-mode reference
/ and the design notes recording every place this diverges from (or corrects) legacy TorQ's
/ code/segmentedtickerplant.q + code/segmentedtickerplant/{stplog,stpmeta,pubsub}.q.
/ chained (sctp) mode is explicitly out of scope - see segmentedtp.md's chained-mode section for the
/ six legacy branch points that collapse to their non-chained path permanently.

/ ============================================================
/ root state - see segmentedtp.md's "root-state exception" section for why these two names must be
/ visible at root rather than module-local: the legacy test harness (and any live subscriber tooling
/ carried forward from it) reaches currlog by bare name over IPC. seeded once, at module load, exactly
/ matching legacy's own timing (stplog.q:1-7) - module load happens once per process regardless of how
/ many times init is called, so this does not need the fresh/re-init guard init's own state does.
/ ============================================================

`.currlog set ([tbl:`symbol$()]logname:`symbol$();handle:`int$());

/ loghandles - a tbl!handle view of currlog. DELIBERATELY NOT a genuine kdb+ view (legacy's
/ `loghandles::exec tbl!handle from currlog` is real view syntax, but that only works because legacy
/ runs directly in the process's own root namespace; the same syntax inside module-rewritten code
/ would register the dependency against this MODULE's private namespace, not root, defeating the
/ point). instead, updatehandles[] explicitly recomputes this after every currlog mutation. no sibling
/ module (di.tickerplant, di.timer, di.handlers, di.eodtime, di.tplog, di.dbwrite, di.pubsub) uses kdb+
/ views anywhere, so this keeps the module consistent with the rest of the project and easier to test.
`.loghandles set (`symbol$())!`int$();

/ ============================================================
/ constants (load-time)
/ ============================================================

/ empty metatable schema - stpmeta.q:6. seq/logname/start/end describe one open-or-closed log; tbls is
/ the list of tables that row covers (one table for tabperiod/tabular, all of them for singular/
/ periodic); msgcount is populated on close; schema/additional are free per-row extension points,
/ mirrored from legacy even though nothing in this build writes to `additional`
metatableschema:([]seq:`int$();logname:`$();start:`timestamp$();end:`timestamp$();tbls:();
  msgcount:`int$();schema:();additional:());

/ optional config keys forwarded verbatim to di.eodtime.init, same as di.tickerplant
eodtimekeys:`rolltimezone`datatimezone`rolltimeoffset;

/ the root names init publishes and teardown gives back. NB no `tptype` here - legacy needed it to
/ disambiguate segmented-vs-standard tickerplant reply semantics, but the modular protocol solved that
/ by FIELD SHAPE instead (di.tickerplant's subdetails already returns logfilelist as a list, precisely
/ because "the protocol also serves a segmented tickerplant" - tickerplant.q:107-120). grepped both
/ local kdbx-modules clones: zero references to tptype anywhere, di.subscriptions included.
rootnames:`subdetails`tablelist;

/ ============================================================
/ internal helpers - init-state guards, error/log plumbing
/ ============================================================

initialised:{[]
  / has init COMPLETED, not just started? probes .z.m.initcomplete - set only as init's own final
  / statement - rather than an early-written field like .z.m.schemas. a genuine bug, found by testing a
  / failed-then-corrected init back to back: every validation check in init (multilogperiod,
  / errorlogname collision, the domain checks below) runs AFTER .z.m.schemas is already written, so a
  / THROWN init still left initialised[] reporting true. a caller who fixes their config and retries
  / then got silently treated as a RE-init - fresh:not initialised[] came back false - skipping every
  / bit of first-time state seeding. the retry itself then threw on undefined .z.m.scheduled, and any
  / upd call after it threw on undefined .z.m.logtabs. confirmed directly against both symptoms before
  / this fix
  :@[{.z.m.initcomplete;1b};::;{[e] :0b}];
  };

custommodeset:{[]
  / has readcustomcsv/setcustommode ever been called? a table in `custom` mode with no assignment at
  / all is a valid, if degenerate, config - "not specified in csv" tables are simply never logged,
  / matching legacy's own documented behaviour (stplog.q:40-41's comment on custom mode)
  :@[{.z.m.custommode;1b};::;{[e] :0b}];
  };

logready:{[]
  / has init wired the log dependency yet? checkcustommode/readcustomcsv are callable BEFORE init (see
  / their own header comment below) and are the only exported functions besides init/upd not
  / requireinit-guarded, so they cannot assume .z.m.log* already exists the way raiseerror's callers can
  :@[{.z.m.logerr;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  if[not initialised[];
    '"di.segmentedtp: ",string[ctx],": init must be called before any other function"];
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.segmentedtp: ",string[ctx],": ",msg;
  };

/ ============================================================
/ naming (five modes) - stplog.q:22-45
/ ============================================================

gentimeformat:{[p]
  / standardised timestamp string for log names - stplog.q:25
  :(raze string "dv"$p) except ".:";
  };

logname:(`$())!();

/ tabperiod - one log per table per period (default). tabular is BYTE-IDENTICAL to this body in
/ legacy (stplog.q:28 vs :37) - the only difference between the two modes is the period length
/ (forced to 1D for tabular in init), not the naming logic, so it is aliased below rather than
/ reimplemented
logname[`tabperiod]:{[dir;tab;p] :` sv (dir;`$raze string (`$.z.m.logprefix;"_";tab),gentimeformat[p])};
logname[`tabular]:logname[`tabperiod];

/ singular - one log, all tables, rolled daily (forced multilogperiod in init)
logname[`singular]:{[dir;tab;p] :` sv (dir;`$raze string .z.m.logprefix,"_",gentimeformat[p])};

/ periodic - one log, all tables, rolled per multilogperiod
logname[`periodic]:{[dir;tab;p] :` sv (dir;`$raze string .z.m.logprefix,"_periodic",gentimeformat[p])};

/ custom - dispatches per-table through .z.m.custommode into one of the four modes above
logname[`custom]:{[dir;tab;p] :logname[.z.m.custommode tab][dir;tab;p]};

/ error - errorlogname is a config value playing the role of a table name here, matching legacy
logname[`error]:{[dir;ename;p] :` sv (dir;`$raze string (`$.z.m.logprefix;"_";ename),gentimeformat[p])};

effectivemode:{[tab]
  / a table's actual naming/batch mode - its custom-csv assignment under `custom, else the top-level
  / multilog mode for everyone
  :$[.z.m.multilog~`custom;.z.m.custommode[tab];.z.m.multilog];
  };

/ ============================================================
/ log open/close/roll
/ ============================================================

createdld:{[date]
  / create the day-log directory stplogs/<logprefix>_<date>/ under kdbtplog - stplog.q:16-20
  if[0=count .z.m.kdbtplog;raiseerror[`createdld;"kdbtplog is not set"]];
  dir:hsym `$.z.m.kdbtplog,"/stplogs/",.z.m.logprefix,"_",string date;
  system "mkdir -p ",1_string dir;
  .z.m.dldir:dir;
  };

updatehandles:{[]
  / explicit recompute of the tbl!handle view - see the root-state header note above
  `.loghandles set exec tbl!handle from `.currlog;
  };

openlog:{[tab;p]
  / open (or reuse) the log for tab at period p, under tab's effective naming mode - stplog.q:137-145.
  / an EXISTING file is run through di.tplog.check first, repairing a corrupt one - a genuine
  / improvement over legacy's blind hopen (see deps.q / segmentedtp.md). check's repair writes a
  / NEW file at <name>.good (leaving the original corrupt file on disk, untouched) when repair is
  / needed; the RETURNED path, not the requested one, becomes the live log, and currlog is written
  / with whatever is actually on disk
  / createlogs off - .z.m.dldir was never set (createdld only runs inside init's own createlogs gate),
  / so referencing it here would throw an undefined-variable error on the FIRST upd, for every message,
  / real bug found and fixed during smoke testing. every caller must treat 0Ni as "no log, don't write"
  if[not .z.m.createlogs;:0Ni];
  lname:logname[effectivemode tab][.z.m.dldir;tab;p];
  / match on logname ALONE, not tbl=tab,logname=lname: singular/periodic modes have MULTIPLE tables
  / sharing one logical file, and each table's own openlog call must find and reuse whatever handle
  / an EARLIER table already opened for the SAME path. checking only this table's own currlog row
  / missed that entirely - two independent hopen calls against the same file produced two independent
  / OS handles, and the resulting file was corrupt (unreadable by di.tplog.replay - confirmed directly)
  h0:exec first handle from `.currlog where logname=lname, not null handle;
  if[not null h0;`.currlog upsert (tab;lname;h0); updatehandles[]; :h0];
  notexists:not type key lname;
  if[not notexists;
    checked:tplog[`check] lname;
    if[not checked~lname;
      .z.m.logwarn[`openlog;"log ",(string lname)," was corrupt - repaired to ",string checked]];
    lname:checked];
  if[notexists;.[lname;();:;()]];
  h:hopen lname;
  .z.m.loginfo[`openlog;"opened logfile ",string lname];
  `.currlog upsert (tab;lname;h);
  updatehandles[];
  :h;
  };

openlogerr:{[]
  / error log for failed updates in error mode - stplog.q:148-153. rolled daily only, same as legacy
  / createlogs off - same guard as openlog, and for the same reason: badmsg calls this unconditionally
  / (not gated by createlogs), so without this a bad message with logging off would throw a SECOND,
  / unrelated error from inside errmode's own recovery path, potentially escaping errmode entirely
  / since a throw inside an error handler is not caught by the protected apply it is handling
  if[not .z.m.createlogs;:(::)];
  lname:logname[`error][.z.m.dldir;.z.m.errorlogname;.z.p+eodtime[`getdailyadj][]];
  if[not type key lname;.[lname;();:;()]];
  h:hopen lname;
  .z.m.loginfo[`openlogerr;"opened error logfile ",string lname];
  `.currlog upsert (.z.m.errorlogname;lname;h);
  updatehandles[];
  };

badmsg:{[e;t;x]
  / log a failed message and its error to the error log - stplog.q:156-159
  .z.m.logwarn[`upd;"bad message for ",(string t),", error: ",e];
  if[null `.loghandles .z.m.errorlogname;openlogerr[]];
  / createlogs off - openlogerr above is now a no-op, so loghandles still has no entry for
  / errorlogname. only attempt the write if a real handle actually exists
  if[not null `.loghandles .z.m.errorlogname;
    (`.loghandles .z.m.errorlogname) enlist (`upderr;t;x)];
  };

closelog:{[tab]
  / close tab's open handle, if any - stplog.q:161-166
  h:exec first handle from `.currlog where tbl=tab;
  if[null h;.z.m.loginfo[`closelog;"no open handle for ",string tab];:()];
  .z.m.loginfo[`closelog;"closing logfile ",string exec first logname from `.currlog where tbl=tab];
  @[hclose;h;{[e] .z.m.logerr[`closelog;"handle already closed: ",e]}];
  / by-name update: modifies `.currlog IN PLACE and returns its NAME, not the updated table - do NOT
  / wrap this in `.currlog set(...), that would overwrite the table with the bare symbol it returns
  update handle:0Ni from `.currlog where tbl=tab;
  updatehandles[];
  };

rolltabs:{[]
  / literal port of stplog.q:254's rolltabs branch - the set of tables that PARTICIPATE in periodic
  / rolling. NOT a per-table period-length computation: under any non-custom top-level mode every
  / table participates unconditionally (even singular/tabular - their period was already forced to 1D
  / globally in init, so periodic rolling and day rolling happen to coincide, but the participation
  / set itself is not filtered). only `custom` mode filters, and only by each table's OWN assigned
  / mode. see segmentedtp.md's "naming and rolling design" note - an earlier draft of this design
  / computed a per-table period length instead, which would have given a custom-assigned tabular table
  / its own independent daily cycle decoupled from the process's real day-roll. legacy does not do
  / that, and this must not either
  :$[.z.m.multilog~`custom;
    .z.m.logtabs except .z.m.logtabs where .z.m.custommode[.z.m.logtabs] in `tabular`singular;
    .z.m.logtabs];
  };

rolllog:{[tabs;p]
  / roll a set of tables to a new logging period - stplog.q:169-178
  updmeta[.z.m.multilog][`close;tabs;p];
  closelog each tabs;
  .z.m.i:@[.z.m.i;tabs;:;(count tabs)#0];
  .z.m.j:@[.z.m.j;tabs;:;(count tabs)#0];
  openlog[;.z.m.currperiod] each tabs;
  updmeta[.z.m.multilog][`open;tabs;.z.m.currperiod];
  setmeta[];
  };

/ ============================================================
/ root install/uninstall - same shape as di.tickerplant.q:154-195
/ ============================================================

publishroot:{[nm;f]
  / internal - publish ONE root entry point, warning first when the name already holds something that
  / is neither the function about to be installed nor the one this module installed last time
  if[nm in key `.;
    cur:`. nm;
    if[not any (f;.z.m.rootinstalled nm)~\:cur;
      .z.m.logwarn[`installroot;"root ",(string nm)," was already bound to something di.segmentedtp ",
        "did not install - replacing it. teardown will not give the previous binding back"]]];
  @[`.;nm;:;f];
  };

installroot:{[]
  / publish the subscription protocol at ROOT, where an IPC caller reaches it through the default
  / .z.pg/.z.ps. NB the root `upd` is deliberately NOT published here - di.torq wires the process's
  / feed entry point, which may legitimately be a caller-supplied wrapper around this module's upd,
  / matching di.tickerplant's explicit precedent
  fs:(subdetails;tablelist);
  publishroot'[rootnames;fs];
  .z.m.rootinstalled:rootnames!fs;
  };

dropifours:{[nm;f]
  / internal - delete a root name only if it still holds the function we installed there
  if[not nm in key `.;:()];
  if[not f~`. nm;:()];
  ![`.;();0b;enlist nm];
  };

uninstallroot:{[]
  / give back exactly what installroot published
  dropifours'[rootnames;(subdetails;tablelist)];
  };

/ ============================================================
/ batch mode dispatch - upd/zts internal function groups, stplog.q:47-100. named updfn/ztsfn (not
/ upd/zts) to avoid colliding with the exported upd function and the timer's tick job
/ ============================================================

stamp:{[x;now]
  / prepend a timestamp column unless the update already carries one. SIMPLIFIED from legacy's
  / per-table-overridable updtab dict - no config or test anywhere in the repo overrides updtab, and
  / di.tickerplant's own stamp[x] is the established sibling pattern for exactly this. a deliberate
  / simplification, documented in segmentedtp.md, not a faithful port of an unused customisation hook
  if[-12h=type first first x;:x];
  :$[0>type first x;now,x;(enlist(count first x)#now),x];
  };

topublishtable:{[t;xs]
  / shape a raw column-data update into the table di.pubsub.publish expects - mirrors
  / di.tickerplant's publishrows
  f:cols .z.m.schemas[t];
  :$[0>type first xs;enlist f!xs;flip f!xs];
  };

updfn:(`$())!();

/ memorybatch - insert only, no write, no publish. flushed by ztsfn`memorybatch on the timer or the
/ .z.exit handler. highest throughput, real data-loss exposure on a non-clean exit - see
/ segmentedtp.md's memorybatch risk section
updfn[`memorybatch]:{[t;x;now]
  t insert stamp[x;now];
  };

/ defaultbatch - write to the log immediately, publish is batched on the timer. createlogs off -
/ openlog returns 0Ni (no log to write to); j only advances for messages actually written, matching
/ its documented meaning
updfn[`defaultbatch]:{[t;x;now]
  xs:stamp[x;now];
  t insert xs;
  h:openlog[t;.z.m.currperiod];
  if[not null h;tplog[`write][h;(`upd;t;xs)]; .z.m.j:@[.z.m.j;t;+;1]];
  };

/ immediate - write and publish in the same call, no batching. createlogs off - publish still
/ happens; only the write (and j) are skipped, matching defaultbatch's guard above
updfn[`immediate]:{[t;x;now]
  xs:stamp[x;now];
  h:openlog[t;.z.m.currperiod];
  if[not null h;tplog[`write][h;(`upd;t;xs)]; .z.m.j:@[.z.m.j;t;+;1]];
  d:topublishtable[t;xs];
  pubsub[`publish][t;d];
  .z.m.i:@[.z.m.i;t;+;1];
  .z.m.rowcounts:@[.z.m.rowcounts;t;+;count d];
  };

ztsfn:(`$())!();

ztsfn[`memorybatch]:{[]
  / createlogs off - the buffer still publishes on this flush (memorybatch's whole point is
  / deferring the write, not the publish); only the write itself and j are skipped
  {[t]
    if[count value t;
      h:openlog[t;.z.m.currperiod];
      if[not null h;tplog[`write][h;(`upd;t;value flip value t)]; .z.m.j:@[.z.m.j;t;+;1]];
      .z.m.i:@[.z.m.i;t;+;1];
      .z.m.rowcounts:@[.z.m.rowcounts;t;+;count value t];
      pubsub[`pubclear][t]];
  } each .z.m.tabs;
  };

ztsfn[`defaultbatch]:{[]
  {[t] if[count value t;.z.m.rowcounts:@[.z.m.rowcounts;t;+;count value t]]} each .z.m.tabs;
  pubsub[`pubclear][.z.m.tabs];
  .z.m.i:.z.m.j;
  };

ztsfn[`immediate]:{[]};

/ ============================================================
/ metadata table (stpmeta.q equivalent)
/ ============================================================

getmeta:{[action;tabs;p]
  / add or update the one metatable row this group of tables shares - a single table for
  / tabperiod/tabular, or the whole set for singular/periodic. stpmeta.q:35-43
  / NB tabs here is always the FLAT group list this one row covers (e.g. enlist`trade for a
  / one-table group, or `trade`quote for a multi-table group) - callers must not pre-wrap it further
  $[action=`open;
    [
      / a stale, never-closed row for this exact tabs group can only exist here if loadmetatable just
      / restored one - any process that exits without a real close (a crash, or simply never reaching
      / one before restart) leaves its currently-open row's end permanently null in the persisted
      / stpmeta. reconciled by LOGNAME, not just tbls - confirmed directly, both restarting into the
      / SAME period (logname unchanged - this restart is RESUMING that file, not opening a new one)
      / and simulating a moved-on period (logname different - a genuinely orphaned segment).
      / appending unconditionally on top of either, as this used to, produces duplicate/orphaned rows
      / getlogs`day` then reports for the same (or a stale) physical file more than once - confirmed
      / to compound across repeated restarts before any real close ever happens
      ln:first exec logname from `.currlog where tbl in tabs;
      stale:select from .z.m.metatable where tbls~\:tabs, null end;
      resuming:any stale[`logname]=ln;
      if[resuming;
        .z.m.logwarn[`getmeta;"resuming logfile ",(string ln)," for ",(", " sv string tabs),
          " after an unclean prior shutdown - reusing its existing open metatable row rather than ",
          "opening a duplicate"]];
      orphaned:stale where not stale[`logname]=ln;
      if[count orphaned;
        / msgcount stays null (unknown), not guessed - a real count means replaying the file, which
        / has side effects on live root tables this reconciliation must not trigger
        .z.m.logwarn[`getmeta;"closing ",(string count orphaned)," orphaned metatable row(s) for ",
          (", " sv string tabs)," left open by an unclean prior shutdown - logname(s): ",
          ", " sv string orphaned`logname];
        .z.m.metatable:update end:p from .z.m.metatable
          where tbls~\:tabs, null end, not logname=ln];
      if[not resuming;
        .z.m.metatable,:enlist `seq`logname`start`end`tbls`msgcount`schema`additional!
          (.z.m.seq;ln;p;0Np;tabs;0Ni;.z.m.schemas tabs;()!())]
      ];
    .z.m.metatable:update end:p,msgcount:`int$sum .z.m.j tabs from .z.m.metatable
      where tbls~\:tabs, null end];
  };

updmeta:(`$())!();
updmeta[`tabperiod]:{[action;tabs;p] getmeta[action;;p] each enlist each tabs};
updmeta[`tabular]:updmeta[`tabperiod];
updmeta[`singular]:{[action;tabs;p] getmeta[action;tabs;p]};
updmeta[`periodic]:updmeta[`singular];
updmeta[`custom]:{[action;tabs;p]
  / splits by ROW-STRUCTURE style, not by period-vs-day: tabperiod/tabular are per-table rows,
  / singular/periodic are one row spanning the whole group - stpmeta.q's own updmeta[`custom]
  pertable:tabs where .z.m.custommode[tabs] in `tabperiod`tabular;
  grouped:tabs where .z.m.custommode[tabs] in `singular`periodic;
  if[count pertable;updmeta[`tabperiod][action;pertable;p]];
  if[count grouped;updmeta[`singular][action;grouped;p]];
  };

loadmetatable:{[]
  / read the persisted metatable back on a day roll, and pick up the log sequence number where it
  / left off - stplog.q:266-269
  f:hsym `$string[.z.m.dldir],"/stpmeta";
  .z.m.metatable:@[get;f;0#metatableschema];
  .z.m.seq:1+0|max -1,exec seq from .z.m.metatable;
  };

setmeta:{[]
  / persist the metatable to <dldir>/stpmeta - stpmeta.q's own setmeta. called after every metatable
  / change (a period roll, the initial open, a clean exit) so loadmetatable's restart-recovery is
  / actually meaningful: without this, the on-disk metadata table - the feature this whole module is
  / named for - would exist only in memory and be silently discarded at every day roll.
  / createlogs off - .z.m.dldir was never set, and there is nothing meaningful to persist anyway
  / (every metatable row's own logname is null, since openlog never actually opened anything)
  if[not .z.m.createlogs;:(::)];
  (hsym `$string[.z.m.dldir],"/stpmeta") set .z.m.metatable;
  };

/ ============================================================
/ custom-mode csv - mirrors di.dbwrite's readcsv/setconfig/checkconfig structure (distinct names:
/ different csv schema - tabname,mode here vs tabname,att,column,sort there). NOT requireinit-guarded:
/ the natural call order is "load custom assignment, then init" (custom-mode init needs .z.m.custommode
/ already resolved to compute logtabs), matching how multilog:`custom itself is config, not runtime state
/ ============================================================

checkcustommode:{[t]
  / callable before init (see the header comment above), so every log call here is guarded by
  / logready[] - unlike raiseerror's callers, this cannot assume .z.m.logerr already exists. err is
  / assigned UNCONDITIONALLY before the guarded log call, not inside it - otherwise the trailing bare
  / 'err would signal a never-assigned name whenever logready[] is false
  if[98h<>type t;
    err:"di.segmentedtp: custom mode config must be a table with columns `tabname`mode";
    if[logready[];.z.m.logerr[`checkcustommode;err]];
    'err];
  c:cols t;
  badcols:c where not c in `tabname`mode;
  if[count badcols;
    err:"di.segmentedtp: unrecognised config column(s): ",", " sv string badcols;
    if[logready[];.z.m.logerr[`checkcustommode;err]];
    'err];
  missingcols:(`tabname`mode) where not (`tabname`mode) in c;
  if[count missingcols;
    err:"di.segmentedtp: missing required config column(s): ",", " sv string missingcols;
    if[logready[];.z.m.logerr[`checkcustommode;err]];
    'err];
  if[any null t`tabname;
    err:"di.segmentedtp: tabname must not be null";
    if[logready[];.z.m.logerr[`checkcustommode;err]];
    'err];
  badmodes:m where not (m:distinct t`mode) in `tabperiod`singular`periodic`tabular;
  if[count badmodes;
    err:"di.segmentedtp: unrecognised mode(s): ",", " sv string badmodes;
    if[logready[];.z.m.logerr[`checkcustommode;err]];
    'err];
  };

readcustomcsv:{[file]
  / callable before init (see checkcustommode's header comment above) - guarded by logready[] for the
  / same reason: unlike raiseerror's callers, this cannot assume .z.m.log* already exists
  if[10h=type file;file:hsym `$file];
  if[-11h=type file;if[not ":"=first string file;file:hsym file]];
  if[not -11h=type file;
    err:"di.segmentedtp: file must be a symbol or string path, got type ",string type file;
    if[logready[];.z.m.logerr[`readcustomcsv;err]];
    'err];
  / 0: with an explicit type spec does NOT auto-skip a header row - drop it explicitly via read0/1_
  t:@[{flip `tabname`mode!("SS";",")0: 1_ read0 x};file;{[f;e] '"di.segmentedtp: readcustomcsv: failed to read ",(string f),": ",e}[file;]];
  checkcustommode t;
  if[logready[];.z.m.loginfo[`readcustomcsv;"read ",(string count t)," custom mode row(s) from ",string file]];
  .z.m.custommode:exec tabname!mode from t;
  :(::);
  };

setcustommode:{[t]
  checkcustommode t;
  .z.m.custommode:exec tabname!mode from t;
  :(::);
  };

/ ============================================================
/ period/day rolling
/ ============================================================

createtables:{[schemas;fresh]
  / materialise the captured tables at ROOT, applying `g# to any sym column - same rule as
  / di.tickerplant.q:142-152: a fresh init defines every schema key, a re-init only names not already
  / at root, so a live re-init cannot discard buffered-but-unpublished rows
  nms:$[fresh;key schemas;(key schemas) where not (key schemas) in tables[`.]];
  if[0=count nms;:()];
  {[nm;s] nm set $[`sym in cols s;@[s;`sym;`g#];s]}'[nms;schemas nms];
  };

enddata:{[]
  / configurable-in-legacy dict of process data for eod/eop messages - simplified here to the two
  / fields this module can actually populate without a .proc namespace (legacy also carries
  / proctype/procname from .proc, which has no equivalent in the modular world)
  :`proctype`tables!(`segmentedtp;.z.m.tabs);
  };

getnextendutc:{[]
  / next timestamp checkends should react to - the earlier of the next day-roll and the next period
  / end - stplog.q:238
  .z.m.nextendutc:-1+eodtime[`getnextroll][] & .z.m.nextperiod-eodtime[`getdailyadj][];
  };

periodrollover:{[data]
  / common eop log-rolling logic - stplog.q:210-213
  .z.m.seq+:1;
  rolllog[rolltabs[];data`p];
  };

endofperiod:{[currentpd;nextpd;data;dorolllogs]
  / the STP's OWN end-of-period handling - mirrors stplog.q's stpeoperiod (196-207). legacy's plain
  / endofperiod (185-192) is the chained/sctp delegate variant and is out of scope
  .z.m.loginfo[`endofperiod;"flushing remaining data to subscribers and clearing tables"];
  pubsub[`pubclear][.z.m.tabs];
  pubsub[`callendofperiod][currentpd;nextpd;data];
  .z.m.currperiod:nextpd;
  .z.m.nextperiod:.z.m.multilogperiod+.z.m.currperiod;
  if[(data`p)>.z.m.nextperiod;
    .z.m.timer[`disable][];
    raiseerror[`endofperiod;"next period is in the past"]];
  getnextendutc[];
  if[dorolllogs;periodrollover[data]];
  .z.m.loginfo[`endofperiod;"end of period complete, current period ",string .z.m.currperiod];
  };

dayrollover:{[data]
  / advance the trading day directly - mirrors di.tickerplant's endofday, NOT legacy's literal
  / call-init-again (stplog.q:233). tickerplant's own fresh/re-init guard exists to protect a LIVE
  / re-init (di.torq re-wiring, a config reload) from rewinding runtime state; it does not double as
  / the day-roll mechanism, since tickerplant's endofday performs the day-roll reset itself. this does
  / the same, generalised for STP's multi-log/per-table state, rather than recursing into init and
  / fighting its own fresh guard
  if[(data`p)>eodtime[`getroll][data`p];
    .z.m.timer[`disable][];
    raiseerror[`dayrollover;"next roll is in the past"]];
  eodtime[`setd] eodtime[`getd][]+1;
  updmeta[.z.m.multilog][`close;.z.m.logtabs;(data`p)+eodtime[`getdailyadj][]];
  / persist the OLD day's final metatable to the OLD .z.m.dldir before wiping/switching - createdld
  / below reassigns .z.m.dldir to the new day, so this has to happen first or the close entries above
  / are lost for good instead of landing in the day's own stpmeta file
  setmeta[];
  .z.m.metatable:0#metatableschema;
  closelog each .z.m.logtabs;
  / data`p, not .z.p - dayrollover is driven by checkends' EVENT time (the x/x1 timestamp that
  / triggered the roll), which may not be bit-identical to "now" by the time this line executes.
  / using .z.p here would let the new day's first log file get named from a DIFFERENT timestamp than
  / the one that actually triggered the roll - the same class of naming inconsistency already fixed
  / once for init-vs-upd (see the openlog[;.z.m.currperiod] note below), just for the day-roll path
  eodtime[`setnextroll] eodtime[`getroll][data`p];
  eodtime[`setdailyadj] eodtime[`getdailyadjustment][];
  getnextendutc[];
  .z.m.i:.z.m.j:.z.m.logtabs!(count .z.m.logtabs)#0;
  .z.m.rowcounts:.z.m.logtabs!(count .z.m.logtabs)#0;
  .z.m.seq:1;
  .z.m.currperiod:.z.m.multilogperiod xbar (data`p)+eodtime[`getdailyadj][];
  .z.m.nextperiod:.z.m.multilogperiod+.z.m.currperiod;
  if[.z.m.createlogs;
    createdld[eodtime[`getd][]];
    / use currperiod, not the exact wall-clock time, so the naming timestamp openlog computes here
    / matches exactly what a later upd/tick call recomputes for the SAME open period (both call
    / openlog[tab;.z.m.currperiod] - see openlog's reuse check). using wall time here (legacy's own
    / literal behaviour at stplog.q:263) would make the very first upd after a day-roll compute a
    / DIFFERENT logname than what was just opened and spuriously open a second file for that table
    openlog[;.z.m.currperiod] each .z.m.logtabs;
    if[.z.m.errmode;openlogerr[]];
    loadmetatable[];
    updmeta[.z.m.multilog][`open;.z.m.logtabs;.z.m.currperiod];
    setmeta[]];
  .z.m.loginfo[`dayrollover;"end of day complete, new date ",string eodtime[`getd][]];
  };

endofday:{[date;data]
  / common eod logic for the STP's own (non-chained) path - stplog.q:216-222
  .z.m.loginfo[`endofday;"flushing remaining data to subscribers and clearing tables"];
  pubsub[`pubclear][.z.m.tabs];
  pubsub[`callendofday][date];
  dayrollover[data];
  };

checkends:{[x]
  / triggers endofperiod/endofday when the current time has passed the next scheduled boundary -
  / stplog.q:240-247. called from both upd and the timer job's tick, matching pubsub.q's def wrappers
  if[.z.m.nextendutc>x;:()];
  x1:x+eodtime[`getdailyadj][];
  if[.z.m.nextperiod<x1;
    endofperiod[.z.m.currperiod;.z.m.nextperiod;enddata[],enlist[`p]!enlist x1;
      not eodtime[`getnextroll][]<x]];
  if[eodtime[`getnextroll][]<x;
    if[eodtime[`getd][]<("d"$x)-1;
      .z.m.timer[`disable][];
      raiseerror[`checkends;"more than one day elapsed since the last check"]];
    endofday[eodtime[`getd][];enddata[],enlist[`p]!enlist x]];
  };

tick:{[]
  / timer job: flush per batch mode, then check for period/day rolls - mirrors pubsub.q's zts.def
  ztsfn[.z.m.batchmode][];
  checkends[.z.p];
  };

/ ============================================================
/ replay - internal only, feeds subdetails' logfilelist. NOT exported: a subscriber replays log
/ FILES directly via di.tplog, it never calls back into this module to do so
/ ============================================================

getlogs:(`$())!();

/ current period only - live counts and lognames straight from currlog/j
getlogs[`period]:{[t]
  :distinct flip (.z.m.j;exec tbl!logname from `.currlog where tbl in t)@\:t;
  };

/ the whole day - every closed log this trading day (msgcount 0Wj = replay-all sentinel, since a
/ closed file is never appended to again) plus the live count for the currently-open period
getlogs[`day]:{[t]
  lnames:select seq,tbls,logname,msgcount:0Wj from .z.m.metatable where any each tbls in\:t;
  lnames:update msgcount:`long$sum each .z.m.j[tbls] from lnames where seq=.z.m.seq;
  :flip value exec `long$msgcount,logname from lnames;
  };

replaylog:{[t]
  :getlogs[.z.m.replayperiod][t];
  };

/ ============================================================
/ .z.exit handler - registered via the injected handlers dependency
/ ============================================================

exithandler:{[x]
  / mirrors stplog.q:283-299's CORRECTED scope (see segmentedtp.md): general close+meta-update on ANY
  / clean exit, for every batch mode, with the memorybatch flush as a first sub-step - not "flush
  / memorybatch, full stop" as an earlier draft of the design framed it. a non-zero exit code skips
  / this ENTIRELY, same as legacy - not just a hard kill; any unclean exit loses whatever memorybatch
  / had buffered. see segmentedtp.md's memorybatch risk section
  if[not x~0i;.z.m.logerr[`exithandler;"unclean exit, code ",string x];:()];
  .z.m.loginfo[`exithandler;"exiting process"];
  if[.z.m.batchmode=`memorybatch;
    .z.m.loginfo[`exithandler;"batchmode is memorybatch - flushing buffered data to disk"];
    ztsfn[`memorybatch][]];
  updmeta[.z.m.multilog][`close;.z.m.logtabs;.z.p];
  setmeta[];
  closelog each .z.m.logtabs;
  .z.m.loginfo[`exithandler;"log files closed"];
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / wire the injected log/timer/handlers, initialise the dep modules, materialise the tables at root,
  / open today's logs, publish the subscription protocol at root, schedule the tick timer job and
  / register the exit handler. deps: a dict with `log (required), `timer (required), `handlers
  / (required), `schemas (required, tablename!schema) and `kdbtplog (required, no default), plus the
  / optional config keys in segmentedtp.md's configuration table.
  / dependencies and config are re-applied on EVERY init; RUNTIME state - counts, the open logs, the
  / current period/date - is seeded only on the FIRST, same rule as di.tickerplant
  if[99h<>type deps;
    '"di.segmentedtp: deps must be a dict with `log, `timer, `handlers and `schemas keys"];
  if[not `log in key deps;
    '"di.segmentedtp: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.segmentedtp: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.segmentedtp: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[not `timer in key deps;
    '"di.segmentedtp: timer dependency is required; pass di.timer's exports keyed on `timer"];
  if[99h<>type deps`timer;
    '"di.segmentedtp: timer value must be a dict exposing addjob"];
  if[not `addjob in key deps`timer;
    '"di.segmentedtp: timer dict must expose addjob"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.segmentedtp: timer addjob must expose the custom variant"];
  if[not `deletejobs in key deps`timer;
    '"di.segmentedtp: timer dict must expose deletejobs - teardown needs it"];
  if[not (type deps[`timer]`deletejobs) within 100 112h;
    '"di.segmentedtp: timer deletejobs must be a function [ids]"];
  if[not `disable in key deps`timer;
    '"di.segmentedtp: timer dict must expose disable - the roll-safety guards need it"];
  if[not `handlers in key deps;
    '"di.segmentedtp: handlers dependency is required; pass di.handlers's exports keyed on `handlers"];
  if[99h<>type deps`handlers;
    '"di.segmentedtp: handlers value must be a dict exposing register/remove"];
  if[not `register in key deps`handlers;
    '"di.segmentedtp: handlers dict must expose register"];
  if[not `remove in key deps`handlers;
    '"di.segmentedtp: handlers dict must expose remove - teardown needs it"];
  if[not `schemas in key deps;
    '"di.segmentedtp: schemas is required; pass a tablename!schema dict keyed on `schemas"];
  if[99h<>type deps`schemas;
    '"di.segmentedtp: schemas must be a dict of tablename!schema"];
  if[not `kdbtplog in key deps;
    '"di.segmentedtp: kdbtplog is required - base log directory, no default"];

  / is this the FIRST init in this process? read it BEFORE any write
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  .z.m.schemas:deps`schemas;
  .z.m.tabs:key deps`schemas;

  / optional config with defaults - one explicit write per key
  .z.m.multilog:$[`multilog in key deps;deps`multilog;`tabperiod];
  / an unrecognised value here would otherwise surface as a bare 'rank deep inside openlog (the naming
  / dispatch dict indexed with a missing key returns generic null, applied as a 3-arg function) -
  / caught here, loudly, the same way multilogperiod/errorlogname are below
  if[not .z.m.multilog in `tabperiod`singular`periodic`tabular`custom;
    raiseerror[`init;"unrecognised multilog mode: ",string .z.m.multilog]];
  .z.m.multilogperiod:$[`multilogperiod in key deps;deps`multilogperiod;0D01];
  / a zero or negative period makes currperiod (multilogperiod xbar p) evaluate to a NULL timestamp,
  / and gentimeformat of a null timestamp is the EMPTY string - every table's log for every period
  / would silently collide onto the exact same filename within a day, intermingling unrelated periods'
  / data in one file rather than erroring. caught here, loudly, instead of discovered as data corruption
  if[.z.m.multilogperiod<=0D;
    raiseerror[`init;"multilogperiod must be positive, got ",string .z.m.multilogperiod]];
  / mirrors segmentedtickerplant.q:19 exactly - a ONE-TIME global override, applied only when the
  / TOP-LEVEL multilog mode is itself singular or tabular. never fires for `custom - see rolltabs[]
  if[.z.m.multilog in `singular`tabular;.z.m.multilogperiod:1D];
  .z.m.errmode:$[`errmode in key deps;deps`errmode;1b];
  .z.m.batchmode:$[`batchmode in key deps;deps`batchmode;`defaultbatch];
  / an unrecognised value would silently pass init and only surface on the FIRST upd, as a bare 'rank
  / from updfn indexed with a missing key - caught by errmode (if on) and misfiled forever as "bad
  / message ... error: rank", a config mistake permanently mistaken for a data-quality one. confirmed
  / directly: without this check, that is exactly what happens
  if[not .z.m.batchmode in `defaultbatch`memorybatch`immediate;
    raiseerror[`init;"unrecognised batchmode: ",string .z.m.batchmode]];
  .z.m.replayperiod:$[`replayperiod in key deps;deps`replayperiod;`day];
  / worse than the two checks above: an unrecognised value here throws NOTHING anywhere. getlogs
  / indexed with a missing key returns generic null, and applying that as a function to subdetails'
  / table list is the IDENTITY - logfilelist silently comes back as the raw table-name list instead of
  / (msgcount;logfile) pairs, corrupting the subscription protocol for any di.subscriptions consumer
  / with no error at all. confirmed directly against a real subdetails call before adding this check
  if[not .z.m.replayperiod in `day`period;
    raiseerror[`init;"unrecognised replayperiod: ",string .z.m.replayperiod]];
  .z.m.errorlogname:$[`errorlogname in key deps;deps`errorlogname;`segmentederrorlogfile];
  / currlog is keyed by a single tbl symbol, and openlogerr upserts under errorlogname as if it were
  / a table name (matching legacy exactly - see the header comment above). if errorlogname ever
  / equals a REAL captured table's name, the two currlog rows collide and silently stomp each other's
  / handle, corrupting tracking for both the error log and the colliding table. caught here, at
  / config time, rather than left to manifest as a mysteriously wrong handle deep in openlog
  if[.z.m.errorlogname in key deps`schemas;
    raiseerror[`init;"errorlogname (",(string .z.m.errorlogname),") collides with a captured table ",
      "name - currlog keys by table name and cannot distinguish the two"]];
  .z.m.createlogs:$[`createlogs in key deps;deps`createlogs;1b];
  .z.m.tickinterval:$[`tickinterval in key deps;deps`tickinterval;1000];
  .z.m.kdbtplog:deps`kdbtplog;
  / logprefix is a necessary addition beyond the original design: legacy's naming functions use
  / .proc.procname as the filename prefix, which has no equivalent outside the TorQ framework. mirrors
  / di.tickerplant's own `logname` config key exactly (default "tp" there); named logprefix here to
  / avoid colliding with this module's internal `logname` naming-dispatch dict
  .z.m.logprefix:$[`logprefix in key deps;deps`logprefix;"stp"];

  createtables[deps`schemas;fresh];
  eodtime[`init][(enlist[`log]!enlist deps`log),(key[deps] inter eodtimekeys)#deps];
  tplog[`init][enlist[`log]!enlist deps`log];
  pubsub[`setsubtables][.z.m.tabs];
  pubsub[`init][];

  / RUNTIME state is seeded only on a FRESH init - see di.tickerplant.q:260-274 for the precedent
  if[fresh;
    / readcustomcsv/setcustommode are callable before init (schemas may not exist yet when they run),
    / so they cannot cross-check table names against schemas themselves - this is the first point
    / both are known together. an unrecognised table here would otherwise silently get its own
    / orphan log file opened (openlog only needs a name, not a real schema/root table) that never
    / receives data, since upd's own `t in .z.m.tabs` guard would reject any update for it forever
    if[.z.m.multilog~`custom;
      if[custommodeset[];
        badtabs:key[.z.m.custommode] where not key[.z.m.custommode] in key deps`schemas;
        if[count badtabs;
          raiseerror[`init;"custom mode config references table(s) not in schemas: ",
            ", " sv string badtabs]]]];
    .z.m.logtabs:$[.z.m.multilog~`custom;$[custommodeset[];key .z.m.custommode;`$()];.z.m.tabs];
    .z.m.i:.z.m.j:.z.m.logtabs!(count .z.m.logtabs)#0;
    .z.m.rowcounts:.z.m.logtabs!(count .z.m.logtabs)#0;
    .z.m.seq:1;
    .z.m.metatable:0#metatableschema;
    .z.m.currperiod:.z.m.multilogperiod xbar .z.p+eodtime[`getdailyadj][];
    .z.m.nextperiod:.z.m.multilogperiod+.z.m.currperiod;
    getnextendutc[];
    .z.m.rootinstalled:(`$())!();
    .z.m.scheduled:0b;
    .z.m.handlerregistered:0b;
    if[.z.m.createlogs;
      createdld[eodtime[`getd][]];
      / currperiod, not exact wall-clock time - see dayrollover's identical note. keeps the naming
      / timestamp init computes here consistent with what upd/tick recompute for the same open period
      openlog[;.z.m.currperiod] each .z.m.logtabs;
      if[.z.m.errmode;openlogerr[]];
      loadmetatable[];
      updmeta[.z.m.multilog][`open;.z.m.logtabs;.z.m.currperiod];
      setmeta[]]];

  installroot[];
  if[not .z.m.scheduled;
    .z.m.timer[`addjob][`custom][`segmentedtp;tick;();`int$.z.m.tickinterval;1h;()!()];
    .z.m.scheduled:1b];
  if[not .z.m.handlerregistered;
    .z.m.handlers[`register][`.z.exit;`;`segmentedtp;0;exithandler];
    .z.m.handlerregistered:1b];
  .z.m.loginfo[`init;"di.segmentedtp initialised (multilog=",(string .z.m.multilog),
    ", batchmode=",string[.z.m.batchmode],")"];
  / marks init as genuinely COMPLETE - see initialised[]'s own header comment. must stay the last
  / statement in this function: initialised[]/fresh depend on this line having actually been reached
  .z.m.initcomplete:1b;
  };

teardown:{[]
  / release everything init installed process-wide: the root subscription protocol, the timer job and
  / the exit handler. module state, currlog and the captured tables are deliberately left intact
  requireinit[`teardown];
  uninstallroot[];
  @[.z.m.timer[`deletejobs];enlist`segmentedtp;{[e] :(::)}];
  .z.m.scheduled:0b;
  .[.z.m.handlers[`remove];(`.z.exit;`;`segmentedtp);{[e] :(::)}];
  .z.m.handlerregistered:0b;
  .z.m.loginfo[`teardown;"di.segmentedtp root entry points, timer job and exit handler removed"];
  };

upd:{[t;x]
  / feed entry point - stamp/write/publish per the current batch mode, then check for a period/day
  / roll. NB the ONLY callable export without a requireinit guard, deliberately - matches
  / di.tickerplant's upd exactly and for the same reason (a permanent per-message tax to catch a
  / wiring mistake that can only happen at startup)
  if[not -11h=type t;raiseerror[`upd;"table must be a symbol"]];
  if[not t in .z.m.tabs;raiseerror[`upd;"unknown table ",string t]];
  / a wiring/config problem, not a data-quality one - treated the same as "unknown table" above
  / (unconditional, not errmode-gated): without this check, an unassigned table under custom mode
  / falls through to openlog, which indexes the naming dispatch dict with a null mode and throws a
  / confusing internal 'rank deep in the call stack - and with errmode off, that throw is NOT caught,
  / crashing the process outright for what is really just a config gap, not bad data
  if[(.z.m.multilog=`custom) and not t in .z.m.logtabs;
    raiseerror[`upd;"table ",(string t)," has no custom logging mode assigned - not logged"]];
  now:.z.p+eodtime[`getdailyadj][];
  $[.z.m.errmode;
    .[updfn[.z.m.batchmode];(t;x;now);{[t;x;e] badmsg[e;t;x]}[t;x;]];
    updfn[.z.m.batchmode][t;x;now]];
  checkends[.z.p];
  };

tablelist:{[x]
  / the tables offered for subscription - UNARY on purpose, matching di.tickerplant/legacy - see
  / tickerplant.md's note on why a niladic form silently degrades under di.subscriptions
  requireinit[`tablelist];
  :pubsub[`getsubtables][];
  };

subdetails:{[tabs;instruments]
  / subscribe and return the schemas, log details and counts di.subscriptions needs. logfilelist comes
  / from replaylog (per-table getlogs dispatch on replayperiod), not directly from currlog - the day
  / replay path needs closed-log history from the metatable, not just what's currently open
  requireinit[`subdetails];
  r:pubsub[`subscribe][tabs;instruments];
  if[-11h=type r;raiseerror[`subdetails;"no requested table is published: ",string r]];
  partial:-11h=type first r;
  if[partial;.z.m.logwarn[`subdetails;string first r]];
  pairs:flip $[partial;last r;r];
  nms:pairs[;0];
  :`schemalist`logfilelist`rowcounts`date!
    (pairs;replaylog[nms];nms!0^.z.m.rowcounts nms;eodtime[`getd][]);
  };

getcounts:{[]
  / published (i) and logged (j) per-table message counts, and the trading date. i and j genuinely
  / diverge under defaultbatch - the log write happens immediately in upd, but the published count
  / lags until the next timer tick's pubclear. same asymmetry di.tickerplant's i/j capture, per-table
  / here since a segmented tickerplant is structurally multi-log where a plain tickerplant is single-log
  requireinit[`getcounts];
  :`i`j`d!(.z.m.i;.z.m.j;eodtime[`getd][]);
  };

getapimeta:{[]
  / callable api for di.torq to register with di.api (init/getapimeta/version are plumbing, omitted -
  / matches di.tickerplant's real precedent, not the narrower illustrative skill-template exclusion)
  :flip `name`public`descrip`params`return!flip(
    (`upd;          1b; "feed entry point - stamp, log (per batch mode) and publish (or buffer) an update";
       "[symbol: table; list: column data]";                              "null");
    (`teardown;     1b; "remove the root subscription protocol, timer job and exit handler installed by init";
       "[]";                                                              "null");
    (`tablelist;    1b; "the tables offered for subscription, so a ` (all tables) request can be resolved";
       "[ignored - unary because di.subscriptions sends (`tablelist;`)]"; "symbol list: table names");
    (`subdetails;   1b; "subscribe and return the schemas, log details and counts di.subscriptions needs";
       "[symbol(list): tables (` for all); symbol(list)|dict: syms (` for all)]";
       "dict: schemalist, logfilelist, rowcounts and date");
    (`readcustomcsv;1b; "load per-table custom logging mode assignment from a csv file";
       "[symbol|string: file path]";                                     "null");
    (`setcustommode;1b; "set per-table custom logging mode assignment from an in-memory table";
       "[table: tabname!mode rows]";                                     "null");
    (`getcounts;    1b; "published (i) and logged (j) per-table message counts, and the trading date";
       "[]";                                                             "dict: i, j and d"));
  };
