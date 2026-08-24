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
/ subdetails at root - rather than invented here. verified against a live TorQ v1.0 segmented
/ tickerplant (singular multilog, replayperiod day) as well as the integration tests, which drive a
/ separate process built to the same protocol
requireddetailkeys:`schemalist`logfilelist`rowcounts`date;

/ what subscribe accepts as a tickerplant handle: an int handle, or a function standing in for one
validhandletypes:-7 -6 100 104h;

/ the tickerplant-side function subscribe calls, unless config overrides it
defaultsubdetailsfunc:`subdetails;

/ the tickerplant-side function that resolves ` (all tables) to a concrete list, unless config
/ overrides it. both shipped producers define it at root as {.stpps.t} - chainedtp.q and
/ segmentedtickerplant.q - and legacy calls it before subdetails for exactly this reason
defaulttablelistfunc:`tablelist;

/ the tickerplant-side function that RELEASES this connection's subscriptions, if the tickerplant
/ offers one. defaults to ` - none - because shipped TorQ does not: pubsub.q's closesub is reachable
/ only from the tickerplant's own .z.pc, and suball/subfiltered each clear only their OWN registry
/ (pubsub.q:34,41), so going from an all-syms to a filtered subscription on one connection leaves the
/ all-syms entry behind and the wider feed keeps arriving. wire this at init and unsubscribe becomes
/ a real release; leave it unset and unsubscribe stays local bookkeeping and says so
defaultunsubscribefunc:`;

/ whether a successful subscribe hands the tables it defined at root to the LOCAL di.pubsub, so this
/ process can serve them downstream. off by default: a plain rdb or wdb subscriber consumes a feed and
/ must not silently start publishing one. set it and this module fills the chained/segmented
/ tickerplant role TorQ splits across chainedtp.q and sctp.q - see handoffpublisher
defaultrepublish:0b;

/ appended to every error raised AFTER the subdetails call. asking a tickerplant for the schemas IS
/ .u.sub (pubsub.q defines .ps.subscribe:.u.sub), so the call registers this handle for live delivery
/ as a side effect, and the subdetails protocol has no unsubscribe verb to undo it - tickerplant-side
/ release is driven by .z.pc, which only the caller closing the handle can trigger. every other guard
/ now runs BEFORE that call, so preflight is the only place this can still happen; say so where it
/ happens rather than leaving the caller to infer it
/ kept short deliberately: q truncates a signalled error at 254 characters (measured), and these are
/ appended to messages that already carry a log path, so a verbose note would push the remedy off the
/ end of what the caller actually sees. the log always has the full text - raiseerror logs first
registerednote:" - close the handle before retrying, it is already registered with the tickerplant";

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
  / an EMPTY symbol vector is rejected rather than quietly treated as a filter. as tabs it would
  / otherwise surface as "tickerplant returned no schema", blaming the tickerplant for the caller's
  / own input; as syms it would SUCCEED SILENTLY - narrowed path, zero rows replayed, a defined but
  / empty table and no warning at any level. every other rejection here goes through raiseerror and
  / every mismatch gets a warn, so a silent no-op would be the module contradicting its own standard.
  / NB 11h is the VECTOR case - the ` all-sentinel is -11h and has count 1, so it is unaffected
  if[(11h=type x) and 0=count x;
    raiseerror[ctx;nm," is an empty symbol vector - pass ` for all, or name at least one"]];
  };

allsyms:{[syms]
  / does this sym selector mean "everything" as far as the REPLAY is concerned? ` obviously does, and
  / so does a filter dict: legacy's replayupd takes the same view (`if[(syms~`)or 99=type syms`) -
  / the dict is a tickerplant-side filter expressed as parse clauses, which the log replay cannot
  / evaluate, so it is passed to the tickerplant for the LIVE feed and the replay is left unfiltered
  :(syms~`) or 99h=type syms;
  };

requiresymspec:{[ctx;x]
  / a sym selector is ` (all), one or more symbols, or a filter DICT keyed by table. the dict form is
  / TorQ's own: rdb.q loads it from a csv (.sub.filterparams) and passes it straight through as the
  / instruments argument, and .u.sub dispatches on its type (pubsub.q: 11h -> selfiltered,
  / 99h -> addfiltered). rejecting it here would narrow a shipped API
  if[99h=type x; :(::)];
  requiretabspec[ctx;"syms";x];
  };

normspec:{[x]
  / normalise a table/sym selector to a LIST, leaving the ` all-sentinel alone. a bare symbol atom is
  / a natural way to name one table (subscribe[h;`trade;..]) and legacy accepted it - subscriptions.q
  / enlists both selectors the same way. without this an atom reaches `inter` and throws a bare 'type
  / that bypasses raiseerror and never reaches the log
  :$[x~`;x;99h=type x;x;(),x];
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
  / NB di.servers is NOT injected - it is a HARD dependency imported with `use` in init.q, per the
  / modularisation plan's tier table (di.subscriptions -> di.servers, di.pubsub). see deps.q
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
  tlf:$[`tablelistfunc in key deps;deps`tablelistfunc;defaulttablelistfunc];
  if[not -11h=type tlf;
    '"di.subscriptions: tablelistfunc must be a symbol naming the tickerplant-side function"];
  / ` (the default) means the tickerplant offers no release verb, so unsubscribe stays local-only
  usf:$[`unsubscribefunc in key deps;deps`unsubscribefunc;defaultunsubscribefunc];
  if[not -11h=type usf;
    '"di.subscriptions: unsubscribefunc must be a symbol naming the tickerplant-side function, or ` for none"];
  / off by default: only a chained or segmented tickerplant republishes what it subscribed to
  rpb:$[`republish in key deps;deps`republish;defaultrepublish];
  if[not -1h=type rpb;
    '"di.subscriptions: republish must be a boolean"];
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.register:(deps`handlers)`register;
  .z.m.removehandler:(deps`handlers)`remove;
  .z.m.subdetailsfunc:sdf;
  .z.m.tablelistfunc:tlf;
  .z.m.unsubscribefunc:usf;
  .z.m.republish:rpb;
  if[fresh;.z.m.subscriptions:subscriptionsschema];
  / cleared BEFORE the registration is attempted and set only once it has succeeded, so a register
  / that throws leaves the flag false rather than unset or stale. that matters twice: .z.m.subscriptions
  / is already assigned by this point, so initialised[] reports true even for an init that did not
  / finish, and requireobserver would otherwise read an unset name and die with a bare 'observing that
  / never reaches the log; and a FAILED re-init would otherwise leave a stale true behind
  .z.m.observing:0b;
  / .z.pc is a SIMPLE (observer) event in di.handlers - side-effect only, fan-out - so the phase is
  / ` (null) and this coexists with every other .z.pc registrant in the priority-ordered chain
  .z.m.register[`.z.pc;`;`subscriptions;0j;markdead];
  .z.m.observing:1b;
  .z.m.loginfo[`init;"di.subscriptions initialised - tickerplant entry point ",string .z.m.subdetailsfunc];
  };

teardown:{[]
  / release the .z.pc registration init installed, leaving no process-global residue. paired with
  / init's one side effect - a module whose init registers nothing needs no teardown, this one does.
  / the registry is deliberately LEFT INTACT so a shutdown path can still inspect or release what was
  / held; only the ability to take NEW subscriptions is withdrawn, by clearing the observing flag
  requireinit[`teardown];
  .z.m.removehandler[`.z.pc;`;`subscriptions];
  .z.m.observing:0b;
  .z.m.loginfo[`teardown;"di.subscriptions .z.pc registration removed"];
  };

requireobserver:{[ctx]
  / a new subscription is only trackable while the .z.pc observer is installed. after teardown it is
  / not, and the registry would then report a dead tickerplant as live for as long as .z.W held the
  / handle number - and indefinitely once kdb+ reissued that number to another connection. that is
  / precisely the failure the handlers dependency exists to prevent (see deps.q), so taking a new
  / subscription in that state is refused rather than silently degraded to the .z.W-only mode this
  / module documents as insufficient. reading and releasing stay available, for shutdown paths
  / read explicitly, not as a bare name. a bare read does resolve to .z.m, but every other state
  / access in this module is explicit, and the bare form is the one thing qlint flags as an
  / undeclared global - a warning a reader has to dismiss by hand every time
  if[not .z.m.observing;
    raiseerror[ctx;"the .z.pc observer is not installed - teardown removed it, or init did not ",
      "complete - so a new subscription could not be tracked. call init again before subscribing"]];
  };

/ subscription

fetchdetails:{[tph;tabs;syms]
  / the bundled round trip: schemas, log details and counts in one call.
  / NB this does NOT replace legacy's separate tablelist call - subscribe still makes that one first,
  / and must (see publishedtabs and narrowtabs). an earlier revision of this module dropped it on the
  / assumption that the bundled response made it redundant; it does not, because subdetails is
  / .ps.subscribe each-left and fails outright on a name the tickerplant does not publish.
  / calling this REGISTERS the handle for live delivery as a side effect - see registerednote
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
  / the SCHEMA half must actually be a table. without this a tickerplant that sends a dict or an atom
  / gets it planted at root under the caller's table name by createtables' @[`.;name;:;schema] - which
  / succeeds for any value - and subscribe then reports success over a root name that is not a table.
  / .Q.qt, not 98h=type: a KEYED table is 99h and must still be accepted, while a column-less ([]) is
  / also 99h and must not be (its cols are empty, so replaying into it is meaningless)
  / NB a STRING here is not a garbled schema, it is the tickerplant declining the table: TorQ's
  / .u.sub returns (name;"Table ... not in list of stp pub/sub tables") for one it does not publish,
  / so name that cause rather than leaving the caller to decode a bare shape complaint
  if[not all .Q.qt each entries[;1];
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," schemalist entries must give a table as the ",
      "schema - a string in that position is the tickerplant refusing to publish the table"]];
  / a duplicate table name would be carried straight through to subtables, which di.rdb and di.wdb
  / iterate over, and into the registry's tabs column. reject rather than silently dedupe - every
  / other malformed response here fails loud, and deduping would hide the tickerplant's own bug
  / NB `where` over the dict `count each group nms` yields the duplicated NAMES directly - indexing
  / nms by it instead would index by symbol and throw a bare 'type that bypasses the log
  nms:entries[;0];
  if[(count distinct nms)<>count nms;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," schemalist names a table more than once: ",
      ", " sv string where 1<count each group nms]];
  / the same shape discipline for the other half of the response. two shapes stay legitimate and are
  / covered by tests: an EMPTY logfilelist (a tickerplant with nothing logged yet) and a NULL log
  / symbol (preflightone rejects that with its own, more specific message)
  lfl:d`logfilelist;
  if[0>type lfl;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," logfilelist must be a list of (messagecount;logfile) pairs"]];
  lfe:lfl where not 0=count each lfl;
  if[not all 2=count each lfe;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," logfilelist entries must be (messagecount;logfile) pairs"]];
  if[not all (type each lfe[;0]) in -7 -6h;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," logfilelist entries must give the message count as an integer"]];
  if[not all -11h=type each lfe[;1];
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," logfilelist entries must name the log file with a symbol"]];
  / a NEGATIVE count is a malformed response, not "nothing to replay" - a shape check cannot catch it
  / because -1 is a perfectly good integer. rejected HERE rather than in preflightone so it is caught
  / even when replay is 0b; preflight only ever runs on the replay path
  / NB not `neg` - that is a q reserved word and a bare assignment to it throws 'assign at PARSE
  / time, taking the whole module down at load
  badcount:lfe where 0>lfe[;0];
  if[0<count badcount;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," reported a negative message count (",
      (", " sv .Q.s1 each badcount[;0]),") - a count must be zero or more"]];
  / an EXACT duplicate entry - the same file with the same count, twice - cannot come from any
  / shipped tickerplant: the segmented producer applies `distinct` to these pairs itself
  / (stplog.q getlogs[`period]), and the chained and standard producers each emit at most one entry.
  / it would replay that file twice, so reject it. NB the same file with DIFFERENT counts is a
  / legitimate shared-log tickerplant and is collapsed by collapsesharedlogs, NOT rejected here
  dupe:where 1<count each group lfe;
  if[0<count dupe;
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," logfilelist repeats an identical ",
      "(messagecount;logfile) entry: ",", " sv .Q.s1 each dupe]];
  / rowcounts is handed straight back to the caller, and a subscriber seeds real bookkeeping from it
  / (TorQ's sctp.q builds .u.icounts/.u.jcounts off this field), so a wrong shape would fail far from
  / its cause. TWO shapes are legitimate: a dictionary keyed by table, and an EMPTY GENERAL LIST - a
  / chained tickerplant leaves icounts unset unless its own subscribesyms is `, and (`a`b`c)!()
  / broadcasts () to every value (chainedtp.q; TorQ's own consumer guards for it at sctp.q).
  / anything else - an atom, a table - comes from no real producer
  rc:d`rowcounts;
  if[not $[99h=type rc;1b;(0h=type rc) and 0=count rc];
    raiseerror[`subscribe;(string .z.m.subdetailsfunc)," rowcounts must be a dictionary keyed by ",
      "table, or an empty list; got type ",.Q.s1 type rc]];
  :d;
  };

publishedtabs:{[tph;needed]
  / the tickerplant's published table list via a tablelist round trip, or ` when it cannot answer.
  / this call is PURE - tablelist is {.stpps.t} on both shipped producers and registers nothing,
  / unlike subdetails - so it is safe to make before any guard runs.
  / it does two jobs, and legacy does both from the same round trip (subscriptions.q:108-110):
  /   1. resolves the ` all-tables sentinel. a SEGMENTED tickerplant cannot accept `: its subdetails
  /      hands tabs to .stplg.replaylog, whose `where tbl in t` matches nothing for an atom and then
  /      ranks on the each-left (measured - getlogs[`period][`] throws 'rank). a CHAINED tickerplant
  /      DOES accept it (chainedtp.q does subtabs,() then first), which is why the sentinel is a
  /      usable fallback rather than a failure
  /   2. narrows an EXPLICIT request to what the tickerplant actually publishes - see narrowtabs
  / needed says which of the two the caller depends on, so a tickerplant with no tablelist is only
  / reported at warn when the ` sentinel genuinely had to be resolved. on the explicit path the
  / round trip is a safety net, so failing to get one is an info, not a warning
  say:$[needed;.z.m.logwarn;.z.m.loginfo];
  r:@[{[h;m] (1b;h m)}[tph];(.z.m.tablelistfunc;`);{[e] (0b;e)}];
  if[not first r;
    say[`subscribe;"tickerplant ",(string .z.m.tablelistfunc)," call failed (",(last r),
      ") - asking for ` instead, which a segmented tickerplant cannot answer"];
    :`];
  offered:last r;
  if[not 11h=abs type offered;
    say[`subscribe;"tickerplant ",(string .z.m.tablelistfunc)," answered with something other than ",
      "a symbol list (type ",(.Q.s1 type offered),") - asking for ` instead"];
    :`];
  offered:(),offered;
  if[0=count offered;
    say[`subscribe;"tickerplant ",(string .z.m.tablelistfunc)," published no tables - ",
      "asking for ` instead"];
    :`];
  :offered;
  };

narrowtabs:{[tabs;published]
  / drop from an explicit request any table the tickerplant does not publish, exactly as legacy does
  / (subscriptions.q:41-43, "tables ... are not available to be subscribed to, they will be ignored").
  / this is NOT tidiness. subdetails is .ps.subscribe each-left over tabs, and every shipped producer
  / fails on a name it does not publish: standard SIGNALS 'x (u.q sub), while segmented and chained
  / answer the pair (name;"Table ... not in list of stp pub/sub tables") which the schema guard then
  / rejects. either way ONE bad name sinks the WHOLE call - and because the each-left runs left to
  / right, every valid table ahead of it has already been registered by suball before the failure.
  / a typo or a table retired at the tickerplant would otherwise take down the entire subscription
  / and leave a partial one live at the tickerplant with nothing on this side recording it
  dropped:(),tabs except published;
  if[0=count dropped; :tabs];
  .z.m.logwarn[`subscribe;"tickerplant does not publish ",(", " sv string dropped)," - dropping ",
    $[1=count dropped;"it";"them"]," from the request, because asking for a table a tickerplant ",
    "does not publish fails the whole subdetails call"];
  keep:(),tabs inter published;
  if[0=count keep;
    raiseerror[`subscribe;"tickerplant publishes none of the requested table(s): ",
      ", " sv string (),tabs]];
  :keep;
  };

guardduplicate:{[wanted]
  / refuse to re-subscribe a table that already has a LIVE subscription: a second subscribe would
  / redefine the table (discarding its rows) and replay the log into it again. this is deliberately
  / NOT a port of legacy's reducesubs - no instrument-level dedup, no partial-overlap splitting, just
  / enough to fail loud instead of failing open. re-subscribing after the tickerplant has gone is
  / legitimate and stays allowed, which is why the check is on LIVE rows rather than history.
  / this runs BEFORE the tickerplant is asked for its schemas, against the requested (tablelist-
  / resolved) list rather than the offered one, because asking REGISTERS the handle - see subscribe.
  / that also makes the rule consistent: re-subscribing to a table already held is a caller mistake
  / whatever the tickerplant happens to offer this round, and checking the offered set instead let the
  / same mistake pass with only a warnmissing whenever the tickerplant had also stopped offering it.
  / subscribe still calls this again on the offered set, for the one case ` cannot be resolved up front
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

logstatus:{[lf]
  / the readable state of a log as (goodmessages;corrupt), via the NON-EXECUTING -11!(-2;..)
  / streaming count. a clean log returns a single count; a corrupt one returns
  / (goodmessages;validbytes) - that PAIR is the only signal kdb+ gives that the tail is unreadable,
  / so it is carried out of here rather than collapsed away. callers that compare against a finite
  / claimed count only need the count (corruption BEYOND the messages actually wanted is tolerated
  / and deliberate); the caller that replays the WHOLE log needs the flag too.
  / doing this BEFORE any replay is load-bearing, not defensive padding: -11!(n;log) with n past the
  / corruption point replays every good message and THEN throws, leaving tables half populated
  / (measured: a 4-message log truncated to 3 good, replayed with n=4, ran upd 3 times then threw 'badtail)
  r:@[{(1b;-11!(-2;x))};lf;{[e] (0b;e)}];
  if[not first r;
    raiseerror[`replay;"cannot read log ",(string lf),": ",(last r),registerednote]];
  i:last r;
  :$[1<count i;(first i;1b);(i;0b)];
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

requiretablesexist:{[wanted]
  / with setschema 0b the caller keeps its own schemas, so nothing here defines the target tables -
  / and a replay would then drive upd into tables that may not exist. that fails differently on each
  / path and NEITHER failure reaches raiseerror or the log: the all-syms path dies inside the
  / caller's own upd, the narrowed path throws from `cols get t` in payloadtable. check it up front.
  / tables[`.] is specifically the ROOT table list - it excludes a non-table root name that happens
  / to collide, which a bare `in key `.` would not (both measured from module context)
  missing:(),wanted where not wanted in tables[`.];
  if[0<count missing;
    raiseerror[`subscribe;"setschema is 0b but no table is defined at root for ",(", " sv string missing),
      " - define them first, or subscribe with setschema 1b"]];
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
  if[allsyms syms; :origupd[t;x]];
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

collapsesharedlogs:{[entries]
  / a segmented tickerplant in singular or periodic multilog mode writes EVERY table to ONE log
  / (stplog.q's logname.singular ignores the table argument), and getlogs returns one
  / (messagecount;logname) pair PER TABLE - so the same physical file legitimately arrives more than
  / once with different counts. replaying it once per entry re-applies the head of the file:
  / measured, (4;LF) then (2;LF) over a 6-message shared log applies messages 0 and 1 TWICE and never
  / reaches 4 and 5.
  / collapse to ONE replay per file and mark it 0W, handing the resolution to preflightone. the
  / per-table counts cannot be turned into a single file offset, so the only answer that cannot
  / silently DROP a subscribed message is to replay the whole file and let the table filter discard
  / the rest. a silently missed row is invisible and permanent; a duplicated row is visible and
  / diagnosable, and this module rejects rather than silently narrows everywhere else.
  / NB a file that appears ONCE keeps its own count - only a shared one is marked
  if[0=count entries; :entries];
  fs:entries[;1];
  if[(count distinct fs)=count fs; :entries];
  g:group fs;
  .z.m.logwarn[`replay;"tickerplant reported ",(", " sv string where 1<count each g)," more than ",
    "once - a shared-log (singular or periodic multilog) tickerplant. replaying each in full; ",
    "messages logged between the subdetails call and the replay may arrive again on the live feed"];
  :{[e;lf;ix] :$[1=count ix;e ix 0;(0W;lf)]}[entries]'[key g;value g];
  };

preflightone:{[entry]
  / internal - confirm one log really holds the messages the tickerplant claims, WITHOUT replaying,
  / and return (messagecount;logfile;wholefile) with the count RESOLVED. the third field is the one
  / thing the pair could not carry: whether the count came from the tickerplant or from reading the
  / file to its end. that distinction decides which replay path is safe - see replayone
  nmsg:first entry;
  lf:last entry;
  if[null lf;
    raiseerror[`replay;"tickerplant reported a message count but no log file",registerednote]];
  / 0=, not 0>= - fetchdetails has already rejected a negative count as a malformed response, so a
  / negative can no longer reach here and must not be quietly folded into "nothing to replay"
  if[0=nmsg; :(nmsg;lf;0b)];
  st:logstatus lf;
  good:first st;
  / 0W is the "everything readable" sentinel, NOT a claim about the count, and it arrives two ways:
  / a segmented tickerplant sends it for every CLOSED log under replayperiod `day (stplog.q's
  / getlogs[`day] sets msgcount:0Wj), and collapsesharedlogs sets it for a log several tables share.
  / either way the answer is the same - replay the file to its full preflighted total.
  / resolve it HERE rather than forwarding 0W to -11!: measured, -11!(0W;corruptlog) replays the good
  / prefix and only THEN throws 'badtail, which is precisely the half-populated state this preflight
  / exists to prevent. only long infinity is a sentinel; a merely large finite count is still an
  / over-claim and still fails below.
  / a CORRUPT log is refused on this path even though its readable prefix could be replayed: the
  / whole log was asked for, so replaying part of it would hand the subscriber a silently incomplete
  / history. on the finite path below, damage beyond the messages actually wanted is still tolerated
  if[0W=nmsg;
    if[last st;
      raiseerror[`replay;"log ",(string lf)," is truncated after ",(string good)," readable ",
        "message(s) and the tickerplant asked for the whole log - refusing to replay an ",
        "incomplete history",registerednote]];
    :(good;lf;1b)];
  if[good<nmsg;
    raiseerror[`replay;"log ",(string lf)," holds only ",(string good)," readable message(s) but the tickerplant reported ",
      (string nmsg)," - refusing to replay a partial history",registerednote]];
  :(nmsg;lf;0b);
  };

preflightlogs:{[details]
  / verify EVERY log before anything is created or replayed, so a short log fails with the process
  / untouched - no half-defined schemas and no half-populated tables. this runs the whole check up
  / front rather than per-log inside the replay loop, because the first log could otherwise replay
  / successfully before the second one is found wanting.
  / returns the RESOLVED entries - shared logs already collapsed, any 0W already turned into a real
  / count, each carrying whether that count means "the whole file" - so the replay neither rescans a
  / file that has just been scanned here nor has to re-derive which files were read to their end
  :preflightone each collapsesharedlogs logentries details;
  };

replayone:{[entry;wanted;syms;alltabs]
  / replay one preflighted (messagecount;logfile;wholefile) entry. the log has already been scanned by
  / preflightlogs, so it is not rescanned here - -11!(-2;..) is a full file scan and once is enough
  nmsg:first entry;
  lf:entry 1;
  wholefile:entry 2;
  if[0>=nmsg;
    .z.m.loginfo[`replay;"nothing to replay from ",string lf];
    :(::)];
  / the unfiltered fast path is only safe when the log cannot hold anything outside the subscription.
  / for a per-table log that is guaranteed: the tickerplant returned the file BECAUSE it belongs to a
  / table it offered us. for a WHOLE-FILE entry it is not, and the difference is structural rather
  / than hypothetical - a segmented tickerplant opens logs for tables[`.] except `currlog (stplog.q
  / init, logtabs) but publishes only tables[] except `currlog`heartbeat`logmsg`svrstoload
  / (segmentedtickerplant.q, .stpps.init), and .stpps.upd applies NO membership check before logging.
  / so in singular/periodic multilog mode the one shared file can legitimately carry tables the
  / tickerplant declined to offer a schema for, and replaying it raw would drive the caller's upd with
  / a table it never subscribed to - throwing part way through, or silently creating a wrongly shaped
  / table at root. narrow those to `wanted`; the sym filter still passes through untouched when syms
  / is `, so this costs the whole-file path a table-membership test per message and nothing else
  raw:alltabs and (allsyms syms) and not wholefile;
  n:$[raw;replayall[nmsg;lf];replaynarrowed[nmsg;lf;wanted;syms]];
  .z.m.loginfo[`replay;"replayed ",(string n)," message(s) from ",string lf];
  };

replaylogs:{[entries;wanted;syms;alltabs]
  / replay every pre-subscription log the tickerplant reported. entries are the PREFLIGHTED triples
  / from preflightlogs - shared logs already collapsed to one replay each, any 0W already resolved
  if[0=count entries;
    .z.m.loginfo[`replay;"tickerplant reported no log file to replay"];
    :(::)];
  replayone[;wanted;syms;alltabs] each entries;
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
  / the shape legacy's callers actually consume, read off the shipped consumers rather than assumed.
  / rdb.q takes subtables and tplogdate (rdb.q:171) and wdb.q takes tplogdate for fixpartition
  / (wdb.q:546) - but a chained tickerplant reads `d` and `icounts`, NOT `date` and `rowcounts`
  / (chainedtp.q:81-84, sctp.q:22-25), and it reads them through `if[key in r]` guards. a missing key
  / there does not fail: it silently never seeds .u.d or .u.icounts/.u.jcounts, and every downstream
  / subscriber of that process then gets wrong counts. so both names are emitted.
  / rowcounts and date stay canonical - they are the tickerplant's OWN key names, carried through from
  / the subdetails reply unchanged, whereas subtables and tplogdate are names legacy invented and so
  / keep legacy's spelling. icounts and d are the compatibility surface for code ported from TorQ.
  / legacy's `i` is deliberately NOT emitted: no shipped consumer reads it, and legacy gives it two
  / different meanings by tickerplant type - the whole logfilelist for segmented, the message count
  / for standard and chained - which this module has no tptype to disambiguate between
  r:`subtables`tplogdate`rowcounts`date!(subtabs;tplogdate details;details`rowcounts;details`date);
  r:r,`icounts`d!(details`rowcounts;details`date);
  :$[`logdir in key details;r,enlist[`logdir]!enlist details`logdir;r];
  };

/ public api

handoffpublisher:{[]
  / hand the tables this process has subscribed to over to the LOCAL di.pubsub, so it can serve them
  / downstream. this is the chained/segmented tickerplant role: TorQ's chainedtp.q (:71-82) and
  / sctp.q (:15-25) subscribe upstream and republish the same tables, serving their own table list
  / straight out of the pubsub registry (chainedtp.q:7, tablelist:{.stpps.t}).
  / OFF by default - a plain rdb or wdb subscriber must not silently become a publisher.
  / passes the union across the WHOLE registry, not just the tables from this subscribe call:
  / di.pubsub's setsubtables REPLACES its table list (pubsub.q:119), so sending only the latest
  / call's tables would drop everything subscribed before it
  / read EXPLICITLY - a bare read would resolve to .z.m.republish just the same, but every other
  / state access in this module is explicit and the bare form is the one thing qlint flags
  if[not .z.m.republish;:()];
  / ADDITIVE - unions with what the publisher already serves rather than recomputing purely from the
  / registry. two reasons, both measured:
  /   - unsubscribe DELETES its registry rows, so a registry-only union would drop those tables at the
  /     next unrelated subscribe. downstream subscribers would silently stop receiving a table, at a
  /     moment unconnected to the unsubscribe that caused it
  /   - setsubtables with an EMPTY list does not mean "publish nothing": di.pubsub then falls back to
  /     every table at root (pubsub.q:125), so shrinking toward empty is actively dangerous
  / the set therefore only grows within a process. a table that is unsubscribed stays advertised and
  / simply stops receiving data - a visible, inert condition rather than a silent disappearance
  tabs:distinct (),raze exec tabs from .z.m.subscriptions;
  tabs:distinct tabs,pubsub.getsubtables[];
  / di.pubsub.init reads each table from ROOT (extractschema:{0#value table}, pubsub.q:84), so a name
  / that was never defined - a subscribe with setschema:0b against a table this process does not hold -
  / would throw there. drop those rather than hand over a name the publisher cannot resolve
  tabs:tabs where tabs in tables[];
  if[0=count tabs;:()];
  / WARN, not raiseerror: unlike every other raiseerror site in this module, a failure here does not
  / mean the subscribe failed. it already fully succeeded - schemas defined, replay done, registry row
  / committed - before this runs at all (see the call site, last statement of subscribe).
  / registerednote's remedy, "close the handle before retrying", describes a DIFFERENT failure - a
  / subdetails call that registered live delivery before subscribe could be validated - and would be
  / actively wrong advice here: the connection is healthy, and a retry would immediately hit
  / guardduplicate against the row this very call committed.
  / this matches how unsubscribe handles the identical shape (local state already committed, an
  / optional notification step then fails): warn and return, because what mattered locally already
  / happened. republish is opt-in and secondary by design, so it must not take down a successful
  / subscribe
  r:@[{[t] pubsub.setsubtables t; pubsub.init[]; (1b;t)};tabs;{[e] (0b;e)}];
  $[first r;
    .z.m.loginfo[`handoffpublisher;"registered ",(", " sv string tabs)," with the local ",
      "publisher for republishing"];
    .z.m.logwarn[`handoffpublisher;"failed to register subscribed tables with the local ",
      "publisher: ",(last r)," - the subscribe itself succeeded; this process is not serving ",
      "them downstream until this is retried or di.pubsub is checked"]];
  };

subscribe:{[tph;tabs;syms;setschema;replay]
  / subscribe over an ALREADY-OPEN tickerplant handle - this module never opens a connection; the
  / caller resolves one (di.servers.gethandlebytype) and passes it in.
  / tabs/syms: ` for all, or one or more symbols (a bare atom is normalised to a list).
  / setschema: define the returned schemas at root.
  / replay: replay the pre-subscription tp log - requires a root-level upd.
  / returns `subtables`tplogdate`rowcounts`date, plus `logdir when the tickerplant supplied one
  requireinit[`subscribe];
  requireobserver[`subscribe];
  requirehandle[`subscribe;tph];
  requiretabspec[`subscribe;"tabs";tabs];
  requiresymspec[`subscribe;syms];
  requireflag[`subscribe;"setschema";setschema];
  requireflag[`subscribe;"replay";replay];
  / capture the all-tables INTENT before resolving it. a segmented tickerplant cannot be sent the `
  / sentinel (see publishedtabs), but the replay path and the mismatch warnings still need to know the
  / caller asked for everything rather than for a specific list - otherwise resolving ` would quietly
  / switch an all-tables subscribe onto the narrowed replay path and warn about every table the
  / tickerplant chose not to return
  alltabs:tabs~`;
  / normalise a bare symbol atom to a list before anything indexes or intersects it
  tabs:normspec tabs;
  syms:normspec syms;
  / ONE tablelist round trip serves both jobs, and it registers nothing, so it runs before everything
  published:publishedtabs[tph;alltabs];
  / what the caller effectively asked for, with ` resolved. the guards below compare against THIS and
  / not against the narrowed list: re-subscribing a table you already hold, or claiming with
  / setschema 0b that a table exists when it does not, are caller mistakes whatever the tickerplant
  / happens to publish this round - narrowing first would let exactly those mistakes back through
  requested:$[alltabs;published;tabs];
  if[alltabs and not published~`;
    .z.m.loginfo[`subscribe;"resolved ` to ",(", " sv string requested)," via ",string .z.m.tablelistfunc]];
  / EVERY guard that does not need the tickerplant's reply runs here, before fetchdetails, because
  / fetchdetails REGISTERS this handle for live delivery as a side effect (see registerednote) and
  / nothing can undo that. legacy orders it the same way - reducesubs runs against a tablelist round
  / trip before subfunc (TorQ subscriptions.q:108-110) - so this restores the original ordering rather
  / than inventing one. ` cannot always be resolved (a tickerplant offering no table list), and these
  / need a concrete list, so that one case is skipped here and caught by the copies below
  if[replay;requirerootupd[]];
  if[not requested~`;guardduplicate[requested]];
  / what we actually SEND. an explicit request is narrowed to what the tickerplant publishes, because
  / one unpublished name fails the whole subdetails call - see narrowtabs
  sendtabs:$[alltabs or published~`;requested;narrowtabs[tabs;published]];
  / the tables-exist check runs early only for an EXPLICIT request. on the all-tables path
  / `requested` is the TABLELIST list, which may advertise more than schemalist actually returns, and
  / this guard asserts that EVERY name exists at root - so a superset there would refuse a perfectly
  / valid subscribe. the duplicate guard above is unaffected by the same superset, because it only
  / bites where the list INTERSECTS a table already held, and that is a caller mistake either way.
  / the all-tables case is covered by the post-reply copy against `wanted`, once the reply has said
  / what is really on offer.
  / it checks SENDTABS, not the caller's raw list: narrowtabs has already dropped anything the
  / tickerplant does not publish, with a warn rather than a failure, and those tables were never going
  / to be part of the subscription - so requiring them at root would throw for a table the caller
  / never needed to hold. this runs AFTER narrowtabs but still BEFORE fetchdetails, which is what
  / matters: the tablelist round trip behind `published` is pure and registers nothing, whereas
  / fetchdetails registers this handle for live delivery as a side effect
  / sendtabs is the closest approximation to `wanted` obtainable before the reply, not an equal one -
  / it can still be a superset when schemalist omits a table the tablelist advertised, which is the
  / gap the post-reply copy below continues to cover
  if[replay;
    if[not alltabs;
      if[not setschema;requiretablesexist[sendtabs]]]];
  details:fetchdetails[tph;sendtabs;syms];
  schemapairs:(details`schemalist) where not 0=count each details`schemalist;
  offered:(),schemapairs[;0];
  / what we actually subscribe to is what we ASKED FOR intersected with what the tickerplant offered
  / - not simply everything it returned. driving the replay filter off the offered set instead would
  / replay tables that were never requested
  wanted:$[alltabs;offered;(),sendtabs inter offered];
  if[0=count wanted;
    raiseerror[`subscribe;"tickerplant returned no schema for the requested table(s) - nothing to subscribe to"]];
  / redundant whenever the early copy above ran, and the ONLY check when it did not (an all-tables
  / subscribe to a tickerplant with no usable table list). left in rather than made conditional: it is
  / a cheap select, and a guard that silently does not run on some paths is worse than one that runs twice
  guardduplicate[wanted];
  / an all-tables subscribe has nothing to compare - whatever the tickerplant offers IS the request -
  / so the mismatch warnings are driven by the caller's intent, not by the resolved list.
  / these compare against what we SENT, not what the caller asked for: a table narrowtabs already
  / dropped has been reported once with the real reason, and reporting it again here as "the
  / tickerplant did not return it" would describe the same fact worse
  if[not alltabs;
    warnmissing[sendtabs;offered];
    warnextra[sendtabs;offered]];
  schemapairs:schemapairs where schemapairs[;0] in wanted;
  / preflight EVERY log before defining a single table, so a short log leaves the process untouched.
  / preflightlogs is the one guard that CANNOT move above fetchdetails - the log file names only exist
  / in the reply, and their integrity can only be established by reading them - so it is the single
  / remaining place a throw can leave the tickerplant publishing into a failed subscribe
  if[replay;
    if[not setschema;requiretablesexist[wanted]];
    entries:preflightlogs[details]];
  if[setschema;createtables[schemapairs]];
  if[replay;replaylogs[entries;wanted;syms;alltabs]];
  / catenate+reassign, NOT (`name insert row): a symbol-mediated insert resolves the LITERAL name at
  / root and would miss the compile-time module-local rewrite a source-level .z.m.subscriptions gets
  .z.m.subscriptions:.z.m.subscriptions,
    ([]handle:enlist tph;tabs:enlist wanted;syms:enlist syms;subtime:enlist .z.p;active:enlist 1b);
  .z.m.loginfo[`subscribe;"subscribed to ",(", " sv string wanted)," on tickerplant handle ",.Q.s1 tph];
  handoffpublisher[];
  :buildreturn[details;wanted];
  };

unsubscribe:{[tph]
  / release the subscriptions held on this handle, and return the tables released.
  / call this BEFORE hclose. it exists because of the one liveness signal kdb+ cannot give us: a
  / handle the CALLER closes fires no .z.pc, and kdb+ then reissues the freed descriptor to the next
  / connection - so a stale row would go on reporting live, and the duplicate guard would refuse a
  / legitimate re-subscribe to a table nobody holds any more. the .z.pc observer covers tickerplant
  / death; this covers a deliberate local close, which nothing else can observe
  / the caller owns the connection, so this NEVER closes the handle. it also never messages the
  / tickerplant: the subdetails protocol has no unsubscribe verb, and inventing one would break the
  / property that this module speaks TorQ's real protocol rather than a private dialect
  / a deliberate release DELETES its rows rather than flagging them dead: the caller already knows it
  / closed the handle, so the row carries no information it does not have. a .z.pc drop is the
  / opposite case and KEEPS its row (see markdead) - an unexpected disconnect is worth seeing after
  / the fact. that asymmetry is deliberate; see subscriptions.md for what it does and does not bound
  / idempotent by design - a release path must be safe to call twice, and a subscription the
  / tickerplant already dropped is dead before we get here, so neither case is an error
  requireinit[`unsubscribe];
  requirehandle[`unsubscribe;tph];
  / select on the STORED active flag, NOT the effective one activesubscriptions computes. a caller
  / that closed the handle before calling us leaves a row that is stored-active but effectively dead
  / (.z.W has already lost the handle) - and that is exactly the row whose revival on a reissued
  / descriptor this function exists to prevent, so it must still be found and removed here.
  / tph is a function LOCAL, so it resolves inside the where clause - a module-level name would not
  / (see activesubscriptions). match-each, not =, because handle is a general column
  held:select from .z.m.subscriptions where active, handle~\:tph;
  if[0=count held;
    .z.m.logwarn[`unsubscribe;"no live subscription on handle ",(.Q.s1 tph)," - nothing to release"];
    :`$()];
  .z.m.subscriptions:delete from .z.m.subscriptions where active, handle~\:tph;
  released:distinct (),raze held`tabs;
  / release at the TICKERPLANT too when it offers a verb for it. without this the tickerplant keeps
  / publishing everything this connection ever asked for, so re-subscribing more narrowly on the same
  / handle still delivers the wider feed - measured against a live segmented tickerplant.
  / a release failure is not fatal: the local rows are already gone and the caller's next step is to
  / close the handle, which releases it anyway. it is reported so it cannot pass unnoticed
  $[.z.m.unsubscribefunc~`;
    .z.m.logwarn[`unsubscribe;"released locally only - no unsubscribefunc configured, so the ",
      "tickerplant keeps publishing on this handle until the connection closes"];
    [r:@[{[h;m] (1b;h m)}[tph];(.z.m.unsubscribefunc;released);{[e] (0b;e)}];
     $[first r;
       .z.m.loginfo[`unsubscribe;"tickerplant released ",(", " sv string released)," via ",
         string .z.m.unsubscribefunc];
       .z.m.logwarn[`unsubscribe;"tickerplant ",(string .z.m.unsubscribefunc)," call failed (",
         (last r),") - close the handle to release it"]]]];
  .z.m.loginfo[`unsubscribe;"released ",(", " sv string released)," on tickerplant handle ",.Q.s1 tph];
  :released;
  };

resubscribe:{[tph]
  / re-establish every subscription that has since dropped, over a NEW handle to the same tickerplant.
  / this is legacy's retrysubscription (subscriptions.q:155) ported to this module's shape. legacy
  / drove it from .servers.connectcustom, which would make di.servers a hard dependency and would
  / mean this module resolving connections - the one thing it deliberately does not do. so the split
  / is: the module keeps the knowledge of WHAT was subscribed, the caller supplies the new handle,
  / and di.rdb/di.servers decide WHEN to call it.
  / setschema 0b and replay 0b exactly as legacy does: the tables are already defined and their
  / history was replayed on the first subscribe, so a reconnect wants the live feed back and nothing
  / else. replaying again would double-apply everything since the original subscription.
  / best-effort per subscription and never fatal - a reconnect path that aborts on the first failure
  / leaves the rest of the process unsubscribed with no way to retry
  requireinit[`resubscribe];
  requireobserver[`resubscribe];
  requirehandle[`resubscribe;tph];
  / idx: ALIAS the virtual index column - a bare `i` in the select list lands as a column named `x`.
  / it carries each dead row's position in .z.m.subscriptions, so the cleanup below can rewrite
  / exactly the rows this call attempted. activesubscriptions is an update over the registry, so it
  / preserves row order and count and the index maps 1:1
  dead:select idx:i,tabs,syms from activesubscriptions[] where not active;
  if[0=count dead;
    .z.m.loginfo[`resubscribe;"no dropped subscription to re-establish"];
    :`$()];
  / ask this tickerplant what it publishes, ONCE, and skip dead subscriptions it cannot serve.
  / a process may hold subscriptions to several tickerplants; without this, reconnecting one of them
  / retries the others' tables against it and warns about each, every call - and a caller drives this
  / from a timer. the round trip is pure (see publishedtabs) and replaces one failed subscribe per row.
  / when the tickerplant offers no table list there is nothing to filter on, so everything is attempted
  published:publishedtabs[tph;0b];
  if[not published~`;
    g:{[p;t] :any ((),t) in p}[published];
    dead:dead where g'[dead`tabs]];
  if[0=count dead;
    .z.m.loginfo[`resubscribe;"no dropped subscription this tickerplant can serve"];
    :`$()];
  / report what subscribe ACTUALLY established, not what this row asked for. narrowtabs drops a table
  / the tickerplant no longer publishes with a warn rather than a failure, so a multi-table row can
  / succeed having re-established only some of its tables - and taking the request as the outcome
  / would then mark the dropped one done and delete it below, losing every trace of it with nothing
  / left to retry it. subtables is the narrowed list subscribe actually registered (see buildreturn)
  done:raze {[tph;t;s]
    r:@[{[tph;t;s] res:subscribe[tph;t;s;0b;0b]; (1b;res`subtables)}[tph;t];s;{[e] (0b;e)}];
    if[not first r;
      .z.m.logwarn[`resubscribe;"could not re-establish ",(", " sv string (),t),": ",last r];
      :`$()];
    :(),r 1}[tph]'[dead`tabs;dead`syms];
  done:distinct (),done;
  if[0<count done;
    / retire the tables we have just replaced from the dead rows that carried them. the registry
    / otherwise KEEPS a dropped subscription on purpose, so a post-mortem can see it - but a table
    / that is live again on a new handle is superseded history, not evidence, and leaving it makes
    / every later resubscribe retry it and warn. measured before this: a second call emitted three
    / warnings and grew with the number of historically-dead rows, on the one path a caller drives
    / from a timer.
    / rows are NARROWED rather than deleted whole, and a row is dropped only once nothing is left in
    / it. deleting whole would discard the tables that did NOT come back, and keeping whole would
    / retry them alongside the ones that did - which now hold a live subscription, so guardduplicate
    / would reject the retry and warn about it on every call, forever
    / only the rows this call ATTEMPTED are touched (dead`idx), so a same-named table belonging to a
    / different tickerplant's dead row is left alone - narrower than matching on table name alone
    / strip and ix are LOCALS - a module-level name does not resolve inside a q-sql clause, only
    / function-locals and column names do (see activesubscriptions)
    strip:{[d;t] :(),((),t) except d}[done];
    ix:dead`idx;
    .z.m.subscriptions:update tabs:strip'[tabs] from .z.m.subscriptions where i in ix;
    .z.m.subscriptions:delete from .z.m.subscriptions where i in ix, 0=count each tabs;
    .z.m.loginfo[`resubscribe;"re-established ",(", " sv string done)," on handle ",.Q.s1 tph]];
  :done;
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

getsubscriptionhandles:{[proctype;procname]
  / resolve tickerplant handles by proctype and/or procname, projected to the (procname;proctype;w)
  / triple a caller needs before it can subscribe. ported from TorQ .sub.getsubscriptionhandles
  / (code/common/subscriptions.q:11) - registered public API there (apidetails.q:67), called by
  / rdb.q:163, wdb.q:540, chainedtp.q:71 and sctp.q:15.
  / the two lookup arguments are NOT interchangeable and this is the whole of the function's logic:
  / ` matches EVERY row, () matches NONE and additionally switches the combine from intersection to
  / union. that is what makes both real call shapes work off one function - rdb/wdb pass [types;()]
  / and want the proctype matches, chainedtp/sctp pass [`;name] and want the single named process.
  / TWO deliberate differences from legacy, both forced by di.servers' contract:
  /   - legacy took a third `attributes` argument and filtered on .servers.SERVERS's attributes
  /     column. di.servers' SERVERS carries no such column, so the parameter is DROPPED rather than
  /     accepted and ignored - a filter that silently does nothing returns handles the caller
  /     believes were filtered, which surfaces far from its cause
  /   - legacy passed autoopen:1b to retry dead connections on demand. di.servers returns live rows
  /     only (where not null w) and runs its own retry job, so reconnection is its concern now
  / di.servers is reached directly as a hard dependency (init.q's `use`), not through an injected
  / dict - the plan's tier table makes it a hard edge, and a module import needs no wiring
  requireinit[`getsubscriptionhandles];
  if[not all (type each (proctype;procname)) in -11 11 0h;
    raiseerror[`getsubscriptionhandles;"proctype and procname must each be a symbol, a symbol list or ()"]];
  if[any {(0h=type x) and 0<count x} each (proctype;procname);
    raiseerror[`getsubscriptionhandles;"a general-list argument must be empty: use () to match nothing, ` to match everything"]];
  / hoisted OUT of the where clause below: q-sql resolves procname to the COLUMN, so comparing
  / against the parameter of the same name inside the select would silently compare the column
  / with itself and match every row
  pn:(),procname;
  / di.servers refuses every accessor until its own init has run. that is deliberate on its side - a
  / pre-init getservers used to return an empty table, indistinguishable from "nothing is connected" -
  / but the raw signal names only di.servers and bypasses THIS module's log, so it is caught and
  / re-raised through raiseerror: the caller learns which of the two modules is unwired, and the
  / failure is observable in the log like every other domain error here. an empty result is NOT an
  / acceptable fallback - "I cannot tell you" is not the same answer as "no handles"
  srvs:@[{[] :servers.getservers[`]};::;
    {[e] raiseerror[`getsubscriptionhandles;"could not read the di.servers server list (",e,
      ") - di.servers must be initialised before subscription handles can be resolved"]}];
  bytype:$[0h=type proctype;0#srvs;servers.getservers[proctype]];
  byname:$[0h=type procname;0#srvs;$[`~procname;srvs;select from srvs where procname in pn]];
  / project BEFORE combining - inter requires identical column sets, and legacy projects first too
  bytype:select procname,proctype,w from bytype;
  byname:select procname,proctype,w from byname;
  :$[0h in type each (proctype;procname);distinct bytype,byname;bytype inter byname];
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
       "dict: subtables, tplogdate, rowcounts, date, icounts and d (legacy aliases of the two before them), plus logdir if supplied");
    (`resubscribe;      1b; "re-establish subscriptions that have dropped, over a new handle to the same tickerplant";
       "[int|function: new tickerplant handle]";                                  "symbol list: tables re-established");
    (`unsubscribe;      1b; "release the subscriptions held on a tickerplant handle, before the caller closes it";
       "[int|function: tickerplant handle]";                                      "symbol list: tables released");
    (`subscribed;       1b; "is any subscription currently live?";
       "[]";                                                                     "boolean: at least one live subscription");
    (`getsubscriptions; 1b; "the subscription registry, with a live/active flag per subscription";
       "[]";                                                                     "table: handle, tabs, syms, subtime, active");
    (`getsubscriptionhandles; 1b; "resolve live tickerplant handles by proctype and/or procname (` matches all, () matches none)";
       "[symbol(list): proctype (` for all, () for none); symbol(list): procname (` for all, () for none)]";
       "table: procname, proctype, w"));
  };
