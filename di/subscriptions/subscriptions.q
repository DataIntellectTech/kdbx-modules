/ subscribe a process (rdb, wdb, chained tp) to a tickerplant: fetch the schemas and log details in
/ one bundled call, define the subscribed tables at ROOT, replay the pre-subscription tp log exactly
/ once, then let live updates flow through the root upd. ported from TorQ's code/common/subscriptions.q
/ (.sub) - see subscriptions.md for scope, omissions and the design rationale.
/ the version lives in the VERSION file and is read by init.q

/ constants (load-time)

/ registry template - the live copy is .z.m.subscriptions, populated by subscribe. handle is a
/ GENERAL column: production always stores an int handle, but the unit tests drive a function
/ standing in for a handle (h(msg) applies to either), and an int column could not hold one.
/ active is MAINTAINED (set 0b by the .z.pc observer), not derived - see islive
subscriptionsschema:([]handle:();tabs:();syms:();subtime:`timestamp$();active:`boolean$());

/ the keys a tickerplant's subdetails response must carry. these names and shapes are taken from the
/ real, shipped TorQ protocol - code/processes/chainedtp.q and segmentedtickerplant.q both define
/ subdetails at root - rather than invented here. NB the module has not yet been run against a live
/ TorQ tickerplant; the integration tests drive a process built to the same protocol
requireddetailkeys:`schemalist`logfilelist`rowcounts`date;

/ what subscribe accepts as a tickerplant handle: an int handle, or a function standing in for one
validhandletypes:-7 -6 100 104h;

/ the tickerplant-side function subscribe calls, unless config overrides it
defaultsubdetailsfunc:`subdetails;

/ internal helpers

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root
  :@[{.z.m.subscriptions;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger. there is no default
  / logger, so without this an early call dies with a bare 'type instead of a usable message
  if[not initialised[];
    '"di.subscriptions: ",string[ctx],": init must be called before any other function"];
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a
  / throw. init's own dependency validation is the one exception - the logger is not wired yet
  .z.m.logerr[ctx;msg];
  '"di.subscriptions: ",string[ctx],": ",msg;
  };

requirehandle:{[ctx;tph]
  / the caller owns the connection - di.rdb gets one from di.servers.gethandlebytype and passes it in
  if[not type[tph] in validhandletypes;
    raiseerror[ctx;"tph must be an open tickerplant handle or a function, got type ",.Q.s1 type tph]];
  };

requiretabspec:{[ctx;nm;x]
  / a table/sym selector is either ` (all) or one or more symbols
  if[not 11h=abs type x;
    raiseerror[ctx;nm," must be ` (all) or a symbol vector, got type ",.Q.s1 type x]];
  };

normspec:{[x]
  / normalise a table/sym selector to a LIST, leaving the ` all-sentinel alone. a bare symbol atom is
  / a natural way to name one table (subscribe[h;`trade;..]) and legacy accepted it - subscriptions.q
  / enlists both selectors the same way. without this an atom reaches `inter` and throws a bare 'type
  / that bypasses raiseerror and never reaches the log
  :$[x~`;x;(),x];
  };

requireflag:{[ctx;nm;x]
  / a boolean switch
  if[not -1h=type x;
    raiseerror[ctx;nm," must be a boolean, got type ",.Q.s1 type x]];
  };

islive:{[stored;h]
  / is this registry row's subscription still live? TWO complementary signals, because neither alone
  / is sufficient (both measured):
  /   stored - set 0b by the .z.pc observer the instant the tickerplant drops. exact, and immune to
  /            handle-number recycling, which a .z.W probe alone is NOT: kdb+ hands back the lowest
  /            free descriptor, so a reused number would otherwise revive a stale row and make the
  /            duplicate guard refuse a legitimate re-subscribe after a reconnect
  /   .z.W   - catches a handle the CALLER closed itself, which does not fire .z.pc at all
  / a non-int handle (the function the unit tests pass) cannot be probed, so only stored applies
  if[not stored; :0b];
  :$[type[h] in -7 -6h; h in key .z.W; 1b];
  };

markdead:{[wh]
  / the .z.pc observer - every subscription on a dropped connection is dead. registered by init via
  / the injected handlers dependency; di.handlers calls it, and this lambda's compile-time rewrite
  / means it still updates THIS module's state when it does.
  / NB handle is a general column, so match-each (~\:) rather than =, which would throw on a
  / function element
  .z.m.subscriptions:update active:0b from .z.m.subscriptions where handle~\:wh;
  };

activesubscriptions:{[]
  / internal - the registry with the effective live flag folded into active.
  / NB islive is hoisted into a LOCAL first: a q-sql select/update/where clause inside module code
  / cannot resolve a module-level name (it throws 'islive) - only function-locals and column names
  / resolve there. the from-target is fine, it is only the clauses that are affected
  / the boolean cast keeps the column type stable: on an EMPTY registry each' yields a general empty
  / list, which would report active as type 0h rather than the boolean the api metadata promises
  f:islive;
  :update active:`boolean$f'[active;handle] from .z.m.subscriptions;
  };

/ init

init:{[deps]
  / wire the injected dependencies (log and handlers - both REQUIRED, never defaulted) and this
  / module's config. ONE dict carrying dependency and config keys side by side - the call shape
  / di.torq wires every module with.
  / e.g. sub.init[`log`handlers!(logging.logdict`log;handlerdep)]
  / NB build deps as ONE multi-key dict. joining logdict to a single-key dict - i.e.
  / logdict,enlist[`handlers]!enlist handlerdep - throws 'mismatch: both value sides are tables
  / init has ONE process-global side effect: a .z.pc observer registered through di.handlers, which
  / marks a dropped connection's subscriptions dead. teardown removes it. the registration is
  / idempotent - di.handlers replaces a duplicate [event;name] in place - so a second init is safe
  if[99h<>type deps;
    '"di.subscriptions: deps must be a dict with `log and `handlers keys - see di.log, di.handlers"];
  if[not all `log`handlers in key deps;
    '"di.subscriptions: log and handlers dependencies are required; pass `log (`info`warn`error) and ",
      "`handlers (`register`remove) - see di.log, di.handlers; got: ",(", " sv string key deps)];
  if[99h<>type deps`log;
    '"di.subscriptions: log value must be a dict; pass `info`warn`error functions - see di.log"];
  if[not all `info`warn`error in key deps`log;
    '"di.subscriptions: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`handlers;
    '"di.subscriptions: handlers value must be a dict; pass `register`remove functions - see di.handlers"];
  / only register/remove are required - this module calls no others
  if[not all `register`remove in key deps`handlers;
    '"di.subscriptions: handlers dict must have `register`remove keys; got: ",(", " sv string key deps`handlers)];
  / resolve and validate config BEFORE any state is mutated: a rejected re-init must not leave the
  / module half-configured with a wired logger and an invalid tickerplant entry point
  sdf:$[`subdetailsfunc in key deps;deps`subdetailsfunc;defaultsubdetailsfunc];
  if[not -11h=type sdf;
    '"di.subscriptions: subdetailsfunc must be a symbol naming the tickerplant-side function"];
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.register:(deps`handlers)`register;
  .z.m.removehandler:(deps`handlers)`remove;
  .z.m.subdetailsfunc:sdf;
  if[fresh;.z.m.subscriptions:subscriptionsschema];
  / .z.pc is a SIMPLE (observer) event in di.handlers - side-effect only, fan-out - so the phase is
  / ` (null) and this coexists with every other .z.pc registrant in the priority-ordered chain
  .z.m.register[`.z.pc;`;`subscriptions;0j;markdead];
  .z.m.loginfo[`init;"di.subscriptions initialised - tickerplant entry point ",string .z.m.subdetailsfunc];
  };

teardown:{[]
  / release the .z.pc registration init installed, leaving no process-global residue. paired with
  / init's one side effect - a module whose init registers nothing needs no teardown, this one does
  requireinit[`teardown];
  .z.m.removehandler[`.z.pc;`;`subscriptions];
  .z.m.loginfo[`teardown;"di.subscriptions .z.pc registration removed"];
  };

/ subscription

fetchdetails:{[tph;tabs;syms]
  / one bundled round trip to the tickerplant. legacy issued a separate tablelist call first to learn
  / what was available; the bundled response makes that round trip unnecessary
  r:@[{[h;m] (1b;h m)}[tph];(.z.m.subdetailsfunc;tabs;syms);{[e] (0b;e)}];
  if[not first r;
    raiseerror[`subscribe;"tickerplant ",(string .z.m.subdetailsfunc)," call failed: ",last r]];
  d:last r;
  if[99h<>type d;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," must return a dictionary, got type ",.Q.s1 type d]];
  if[not all requireddetailkeys in key d;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," response must carry ",(", " sv string requireddetailkeys),
      "; got: ",(", " sv string key d)]];
  / validate the schemalist SHAPE here rather than letting a malformed entry surface later as a bare
  / 'rank out of the table-creation amend, which would bypass raiseerror and never reach the log.
  / an empty entry is legitimate - legacy filters those out - so only non-empty ones are checked
  sl:d`schemalist;
  if[0>type sl;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," schemalist must be a list of (tablename;schema) pairs"]];
  entries:sl where not 0=count each sl;
  if[not all 2=count each entries;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," schemalist entries must be (tablename;schema) pairs"]];
  if[not all -11h=type each entries[;0];
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," schemalist entries must name their table with a symbol"]];
  :d;
  };

guardduplicate:{[wanted]
  / refuse to re-subscribe a table that already has a LIVE subscription: a second subscribe would
  / redefine the table (discarding its rows) and replay the log into it again. this is deliberately
  / NOT a port of legacy's reducesubs - no instrument-level dedup, no partial-overlap splitting, just
  / enough to fail loud instead of failing open. re-subscribing after the tickerplant has gone is
  / legitimate and stays allowed, which is why the check is on LIVE rows rather than history.
  / NB this runs AFTER the tickerplant has been asked what it offers, so `wanted` is the resolved
  / table list. checking before that could only compare the raw request, which for ` (all tables) is
  / unresolvable - it would have to refuse ANY all-tables subscribe while ANY subscription was live,
  / even to a completely disjoint set of tables
  live:select from activesubscriptions[] where active;
  if[0=count live; :(::)];
  held:distinct (),raze live`tabs;
  clash:(),wanted inter held;
  if[0<count clash;
    raiseerror[`subscribe;"already subscribed to ",(", " sv string clash)]];
  };

warnmissing:{[tabs;offered]
  / a requested table the tickerplant did not return is a real anomaly worth surfacing. legacy logged
  / it from reducesubs after a separate tablelist round trip; the bundled response gives it for free
  if[tabs~`; :(::)];
  missing:(),tabs except offered;
  if[0=count missing; :(::)];
  .z.m.logwarn[`subscribe;"tickerplant did not return ",(", " sv string missing),
    " - not subscribed to ",$[1=count missing;"it";"them"]];
  };

warnextra:{[tabs;offered]
  / the converse: a tickerplant that volunteers tables nobody asked for. we ignore them rather than
  / defining and replaying them, so say so instead of silently dropping them
  if[tabs~`; :(::)];
  extra:(),offered except tabs;
  if[0=count extra; :(::)];
  .z.m.logwarn[`subscribe;"tickerplant returned unrequested table(s) ",(", " sv string extra)," - ignoring"];
  };

createtables:{[schemapairs]
  / define each subscribed table at ROOT from the tickerplant's schema (which carries its attributes,
  / e.g. g# on sym). legacy's own idiom. NB the ROOT target is explicit and deliberate: a source-level
  / bare identifier in module code is rewritten to .z.m at load, so it would never reach root
  .z.m.loginfo[`createtables;"setting the schema definition for ",", " sv string schemapairs[;0]];
  (@[`.;;:;].) each schemapairs;
  };

/ replay

goodcount:{[lf]
  / the number of readable messages in a log, via the NON-EXECUTING -11!(-2;..) streaming count. a
  / clean log returns a single count; a corrupt one returns (goodmessages;validbytes).
  / doing this BEFORE any replay is load-bearing, not defensive padding: -11!(n;log) with n past the
  / corruption point replays every good message and THEN throws, leaving tables half populated
  / (measured: a 4-message log truncated to 3 good, replayed with n=4, ran upd 3 times then threw 'badtail)
  r:@[{(1b;-11!(-2;x))};lf;{[e] (0b;e)}];
  if[not first r;
    raiseerror[`replay;"cannot read log ",(string lf),": ",last r]];
  i:last r;
  :$[1<count i;first i;i];
  };

tryreplay:{[nmsg;lf]
  / -11!(n;logfile) under protected apply, returning (1b;count) or (0b;error). n is the message count
  / the tickerplant had logged when we subscribed, so messages that arrive after that - which also
  / come down the live feed - are not replayed as well
  :@[{(1b;-11!(x 0;x 1))};(nmsg;lf);{[e] (0b;e)}];
  };

replayall:{[nmsg;lf]
  / all tables and all syms: every logged message is wanted, so the root upd handles them directly and
  / no filter wrapper is installed
  r:tryreplay[nmsg;lf];
  if[not first r;
    raiseerror[`replay;"replay of ",(string lf)," failed: ",last r]];
  :last r;
  };

requirerootupd:{[]
  / a replay drives the ROOT upd. without one every replayed message is silently discarded - and the
  / narrowed path below would additionally leave its no-op stand-in bound at root, so the live feed
  / would vanish into it too. fail before anything is defined rather than report a phantom success
  if[not `upd in key `.;
    raiseerror[`replay;"replay was requested but no upd is defined at root - define one before subscribing"]];
  };

replaynarrowed:{[nmsg;lf;subtabs;syms]
  / a narrowed subscription: the log holds every table and sym, so install a filtering wrapper as the
  / ROOT upd for the duration of the replay and restore the original afterwards - on the failure path
  / too. live data is already filtered by the tickerplant; only the log needs this.
  / requirerootupd has already established that upd exists, so there is no stand-in branch here
  origupd:`. `upd;
  @[`.;`upd;:;replayfilter[origupd;subtabs;syms]];
  r:tryreplay[nmsg;lf];
  @[`.;`upd;:;origupd];
  if[not first r;
    raiseerror[`replay;"replay of ",(string lf)," failed: ",last r]];
  :last r;
  };

payloadtable:{[t;x]
  / normalise a logged payload to a table so it can be filtered by COLUMN NAME. legacy assumed the
  / classic list-of-columns payload; a tickerplant that logs a table (98h) or a dict row is equally
  / valid, and filtering by column POSITION would silently mishandle both
  if[98h=type x; :x];
  if[99h=type x; :flip x];
  c:cols get t;
  :$[0>type first x; flip c!enlist each x; flip c!x];
  };

replayfilter:{[origupd;subtabs;syms;t;x]
  / installed as the root upd for the duration of a narrowed replay: forward only the tables and syms
  / this subscription asked for, to the real upd
  if[not t in subtabs; :(::)];
  if[syms~`; :origupd[t;x]];
  d:payloadtable[t;x];
  if[not `sym in cols d; :origupd[t;x]];
  origupd[t;select from d where sym in syms];
  };

logentries:{[details]
  / internal - the non-empty (messagecount;logfile) pairs the tickerplant reported. logfilelist is a
  / LIST because a segmented tickerplant writes one log per table
  lfl:details`logfilelist;
  :lfl where not 0=count each lfl;
  };

preflightone:{[entry]
  / internal - confirm one log really holds the messages the tickerplant claims, WITHOUT replaying
  nmsg:first entry;
  lf:last entry;
  if[null lf;
    raiseerror[`replay;"tickerplant reported a message count but no log file"]];
  if[0>=nmsg; :(::)];
  good:goodcount lf;
  if[good<nmsg;
    raiseerror[`replay;"log ",(string lf)," holds only ",(string good)," readable message(s) but the tickerplant reported ",
      (string nmsg)," - refusing to replay a partial history"]];
  };

preflightlogs:{[details]
  / verify EVERY log before anything is created or replayed, so a short log fails with the process
  / untouched - no half-defined schemas and no half-populated tables. this runs the whole check up
  / front rather than per-log inside the replay loop, because the first log could otherwise replay
  / successfully before the second one is found wanting
  preflightone each logentries details;
  };

replayone:{[entry;wanted;syms;alltabs]
  / replay one (messagecount;logfile) pair. the log has already been preflighted by preflightlogs,
  / so it is not rescanned here - -11!(-2;..) is a full file scan and once is enough
  nmsg:first entry;
  lf:last entry;
  if[0>=nmsg;
    .z.m.loginfo[`replay;"nothing to replay from ",string lf];
    :(::)];
  n:$[alltabs and syms~`;replayall[nmsg;lf];replaynarrowed[nmsg;lf;wanted;syms]];
  .z.m.loginfo[`replay;"replayed ",(string n)," message(s) from ",string lf];
  };

replaylogs:{[details;wanted;syms;alltabs]
  / replay every pre-subscription log the tickerplant reported
  lfl:logentries details;
  if[0=count lfl;
    .z.m.loginfo[`replay;"tickerplant reported no log file to replay"];
    :(::)];
  replayone[;wanted;syms;alltabs] each lfl;
  };

/ return shape

tplogdate:{[details]
  / the date in the tp log file name, as legacy derives it, falling back to the date the tickerplant
  / reported when the name does not carry one
  / reuse logentries rather than repeating its filter, so the two cannot drift apart
  lfl:logentries details;
  if[0=count lfl; :details`date];
  :(details`date)^@[{"D"$-10 sublist string last first x};lfl;{[e] :0Nd}];
  };

buildreturn:{[details;subtabs]
  / the shape legacy's callers actually consume: rdb.q reads subtables and tplogdate, wdb.q reads
  / tplogdate for fixpartition, chainedtp.q reads date and rowcounts (its .u.d and .u.icounts)
  r:`subtables`tplogdate`rowcounts`date!(subtabs;tplogdate details;details`rowcounts;details`date);
  :$[`logdir in key details;r,enlist[`logdir]!enlist details`logdir;r];
  };

/ public api

subscribe:{[tph;tabs;syms;setschema;replay]
  / subscribe over an ALREADY-OPEN tickerplant handle - this module never opens a connection; the
  / caller resolves one (di.servers.gethandlebytype) and passes it in.
  / tabs/syms: ` for all, or one or more symbols (a bare atom is normalised to a list).
  / setschema: define the returned schemas at root.
  / replay: replay the pre-subscription tp log - requires a root-level upd.
  / returns `subtables`tplogdate`rowcounts`date, plus `logdir when the tickerplant supplied one
  requireinit[`subscribe];
  requirehandle[`subscribe;tph];
  requiretabspec[`subscribe;"tabs";tabs];
  requiretabspec[`subscribe;"syms";syms];
  requireflag[`subscribe;"setschema";setschema];
  requireflag[`subscribe;"replay";replay];
  / normalise a bare symbol atom to a list before anything indexes or intersects it
  tabs:normspec tabs;
  syms:normspec syms;
  details:fetchdetails[tph;tabs;syms];
  schemapairs:(details`schemalist) where not 0=count each details`schemalist;
  offered:(),schemapairs[;0];
  / what we actually subscribe to is what we ASKED FOR intersected with what the tickerplant offered
  / - not simply everything it returned. driving the replay filter off the offered set instead would
  / replay tables that were never requested
  wanted:$[tabs~`;offered;(),tabs inter offered];
  if[0=count wanted;
    raiseerror[`subscribe;"tickerplant returned no schema for the requested table(s) - nothing to subscribe to"]];
  guardduplicate[wanted];
  warnmissing[tabs;offered];
  warnextra[tabs;offered];
  schemapairs:schemapairs where schemapairs[;0] in wanted;
  / preflight EVERY log before defining a single table, so a short log leaves the process untouched
  if[replay;
    requirerootupd[];
    preflightlogs[details]];
  if[setschema;createtables[schemapairs]];
  if[replay;replaylogs[details;wanted;syms;tabs~`]];
  / catenate+reassign, NOT (`name insert row): a symbol-mediated insert resolves the LITERAL name at
  / root and would miss the compile-time module-local rewrite a source-level .z.m.subscriptions gets
  .z.m.subscriptions:.z.m.subscriptions,
    ([]handle:enlist tph;tabs:enlist wanted;syms:enlist syms;subtime:enlist .z.p;active:enlist 1b);
  .z.m.loginfo[`subscribe;"subscribed to ",(", " sv string wanted)," on tickerplant handle ",.Q.s1 tph];
  :buildreturn[details;wanted];
  };

subscribed:{[]
  / is any subscription currently live? the connectivity check legacy's .rdb.notpconnected[] needs
  requireinit[`subscribed];
  :any (),exec active from activesubscriptions[];
  };

getsubscriptions:{[]
  / the subscription registry. active combines the flag the .z.pc observer maintains with a .z.W
  / check for a handle the caller closed itself - see islive
  requireinit[`getsubscriptions];
  :activesubscriptions[];
  };

/ api metadata

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are omitted
  / as framework plumbing. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;          1b; "module version string";
       "[]";                                                                     "string: version");
    (`teardown;         1b; "release the .z.pc registration installed by init";
       "[]";                                                                     "null");
    (`subscribe;        1b; "subscribe over an open tickerplant handle, optionally defining schemas and replaying the log";
       "[int|function: tickerplant handle; symbol(list): tables (` for all); symbol(list): syms (` for all); boolean: setschema; boolean: replay]";
       "dict: subtables, tplogdate, rowcounts, date (and logdir if supplied)");
    (`subscribed;       1b; "is any subscription currently live?";
       "[]";                                                                     "boolean: at least one live subscription");
    (`getsubscriptions; 1b; "the subscription registry, with a live/active flag per subscription";
       "[]";                                                                     "table: handle, tabs, syms, subtime, active"));
  };
