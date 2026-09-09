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
  / is this registry row's subscription still live? TWO complementary signals: stored, set 0b by the
  / .z.pc observer the instant the tickerplant drops - exact, and immune to handle-number recycling,
  / which a bare .z.W probe is not; and .z.W, which catches a handle the CALLER closed itself.
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
  / islive is hoisted to a LOCAL first - a q-sql clause cannot resolve a module-level name directly.
  / the boolean cast keeps the column type stable on an EMPTY registry, where each' would otherwise
  / yield a general empty list instead of the boolean api metadata promises
  f:islive;
  :update active:`boolean$f'[active;handle] from .z.m.subscriptions;
  };

/ init

init:{[deps]
  / wire the injected dependencies (log and handlers, both REQUIRED) and this module's config - ONE
  / dict carrying dependency and config keys side by side, the shape di.torq wires every module with.
  / di.servers is NOT injected - it's a hard `use` dependency (see deps.q).
  / one process-global side effect: a .z.pc observer via di.handlers, marking a dropped connection's
  / subscriptions dead; teardown removes it. idempotent - a second init is safe
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
  / a subscription is only trackable while the .z.pc observer is installed - refused after teardown
  / rather than silently degrading to the .z.W-only liveness check, which cannot detect a dropped
  / tickerplant (see deps.q). reading and releasing stay available for shutdown paths
  if[not .z.m.observing;
    raiseerror[ctx;"the .z.pc observer is not installed - call init again before subscribing"]];
  };

/ subscription

fetchdetails:{[tph;tabs;syms]
  / the bundled round trip: schemas, log details and counts in one call. does NOT replace legacy's
  / separate tablelist call - subscribe still makes that first (see publishedtabs, narrowtabs),
  / because subdetails fails outright each-left on a name the tickerplant does not publish.
  / registers the handle for live delivery as a side effect - see registerednote
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
  / the tickerplant's published table list via a PURE tablelist round trip (registers nothing, unlike
  / subdetails), or ` when it cannot answer. does two jobs: resolves the ` all-tables sentinel (a
  / SEGMENTED tickerplant cannot accept ` directly - see subscriptions.md), and narrows an explicit
  / request to what's actually published (see narrowtabs).
  / needed says which job the caller depends on: only warn when ` genuinely had to be resolved,
  / info when the round trip was just a safety net on the explicit path
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
  / drop from an explicit request any table the tickerplant does not publish, matching legacy. this
  / is NOT tidiness - one bad name fails the WHOLE subdetails call, and because it runs each-left,
  / every valid table ahead of it is already registered by suball - leaving a partial subscription
  / live at the tickerplant with nothing on this side recording it. see subscriptions.md for the
  / per-producer failure shapes
  dropped:(),tabs except published;
  if[0=count dropped; :tabs];
  .z.m.logwarn[`subscribe;"tickerplant does not publish ",(", " sv string dropped)," - dropping ",
    $[1=count dropped;"it";"them"]," from the request"];
  keep:(),tabs inter published;
  if[0=count keep;
    raiseerror[`subscribe;"tickerplant publishes none of the requested table(s): ",
      ", " sv string (),tabs]];
  :keep;
  };

guardduplicate:{[wanted]
  / refuse to re-subscribe a table with a LIVE subscription - a second subscribe would redefine and
  / replay into it again. checked against LIVE rows, not history, so re-subscribing after the
  / tickerplant has gone stays allowed.
  / runs BEFORE the tickerplant is asked (asking REGISTERS the handle - see subscribe), against the
  / requested list; subscribe calls this again on the offered set when ` couldn't be resolved up front
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
  / the readable state of a log as (goodmessages;corrupt), via the non-executing -11!(-2;..) streaming
  / count. a clean log returns a single count; a corrupt one returns (goodmessages;validbytes) - the
  / only signal kdb+ gives that the tail is unreadable, so it's carried out rather than collapsed away.
  / doing this BEFORE any replay is load-bearing: -11! with a count past the corruption point replays
  / every good message and only THEN throws, leaving tables half populated
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
  / with setschema 0b the caller keeps its own schemas - nothing here defines the tables, and an
  / undefined one would otherwise fail far from here (inside the caller's own upd, or from
  / payloadtable), bypassing raiseerror and the log entirely. checked up front instead.
  / tables[`.] is the ROOT table list specifically - excludes a non-table name that happens to collide
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
  / a segmented tickerplant in singular/periodic multilog mode writes every table to ONE log, and
  / getlogs returns one (messagecount;logname) pair PER TABLE - so the same file can legitimately
  / arrive more than once with different counts. replaying each pair separately re-applies the head
  / of the file instead of reaching its end.
  / collapse to ONE replay per shared file, marked 0W for preflightone to resolve - the per-table
  / counts cannot be turned into a single offset, and a duplicated row is visible and diagnosable
  / where a silently dropped one is not. a file appearing once keeps its own count
  if[0=count entries; :entries];
  fs:entries[;1];
  if[(count distinct fs)=count fs; :entries];
  g:group fs;
  .z.m.logwarn[`replay;"tickerplant reported ",(", " sv string where 1<count each g),
    " more than once - shared-log tickerplant, replaying each in full"];
  .z.m.logwarn[`replay;"messages logged since the subdetails call may arrive again on ",
    "the live feed"];
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
  / untouched - checked up front, not per-log inside the replay loop, since an earlier log could
  / otherwise succeed before a later one is found wanting.
  / returns the RESOLVED entries - shared logs collapsed, any 0W resolved to a real count - so replay
  / neither rescans a file nor re-derives which were read to their end
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
  / the shape legacy's callers actually consume: rdb/wdb read subtables/tplogdate, but a chained
  / tickerplant reads `d`/`icounts` through if[key in r] guards - a missing key there fails silently,
  / seeding nothing rather than throwing. both names are emitted so neither path breaks quietly.
  / rowcounts/date are canonical (the tickerplant's own names); icounts/d are legacy's compat surface.
  / legacy's `i` is deliberately NOT emitted - it means different things by tickerplant type, and this
  / module has no tptype to disambiguate
  r:`subtables`tplogdate`rowcounts`date!(subtabs;tplogdate details;details`rowcounts;details`date);
  r:r,`icounts`d!(details`rowcounts;details`date);
  :$[`logdir in key details;r,enlist[`logdir]!enlist details`logdir;r];
  };

/ public api

handoffpublisher:{[]
  / hand tables this process has subscribed to over to the LOCAL di.pubsub, so it can serve them
  / downstream - the chained/segmented tickerplant role. OFF by default: a plain rdb/wdb subscriber
  / must not silently become a publisher
  if[not .z.m.republish;:()];
  / ADDITIVE, not a pure registry recompute: unsubscribe deletes its rows, so a registry-only union
  / would drop those tables at the next unrelated subscribe; and an EMPTY setsubtables list means
  / "publish everything at root" to di.pubsub, not "publish nothing". the set only grows - an
  / unsubscribed table stays advertised but stops receiving data, visibly rather than silently
  tabs:distinct (),raze exec tabs from .z.m.subscriptions;
  tabs:distinct tabs,pubsub.getsubtables[];
  / di.pubsub reads each table from ROOT, so a name never defined there (setschema:0b) would throw -
  / drop those rather than hand over a name the publisher cannot resolve
  tabs:tabs where tabs in tables[];
  if[0=count tabs;:()];
  / WARN, not raiseerror: the subscribe has already fully succeeded by this point, so a failure here
  / doesn't mean it failed - retrying would just hit guardduplicate against the row it committed
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
  / release the subscriptions held on this handle, and return the tables released - call BEFORE
  / hclose. covers the one liveness gap .z.pc cannot: a handle the CALLER closes fires no .z.pc, and
  / kdb+ reissues the freed descriptor, so a stale row would otherwise refuse a legitimate re-subscribe.
  / never closes the handle or messages the tickerplant - no unsubscribe verb exists in the protocol.
  / DELETES its rows (a .z.pc drop instead KEEPS them - see markdead) - idempotent, safe to call twice
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
  / re-establish every dropped subscription over a NEW handle to the same tickerplant - legacy's
  / retrysubscription ported to this module's shape. the module keeps knowledge of what was
  / subscribed; the caller supplies the new handle and decides when to call this, so di.servers
  / stays out of this module's hard dependencies.
  / setschema/replay stay 0b - tables are already defined and history already replayed, so a
  / reconnect wants only the live feed back. best-effort per subscription, never fatal
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
  / report what subscribe ACTUALLY established, not the request - a row can partially succeed, and
  / treating the request as the outcome would delete the still-dropped tables with nothing left to
  / retry them (subtables is the narrowed list subscribe registered - see buildreturn)
  done:raze {[tph;t;s]
    r:@[{[tph;t;s] res:subscribe[tph;t;s;0b;0b]; (1b;res`subtables)}[tph;t];s;{[e] (0b;e)}];
    if[not first r;
      .z.m.logwarn[`resubscribe;"could not re-establish ",(", " sv string (),t),": ",last r];
      :`$()];
    :(),r 1}[tph]'[dead`tabs;dead`syms];
  done:distinct (),done;
  if[0<count done;
    / retire the tables just re-established from the dead rows that held them - live-again tables
    / are superseded history, not evidence, and leaving them would make every later resubscribe
    / retry and warn about them forever.
    / rows are NARROWED, not deleted whole: deleting whole would discard tables that did NOT come
    / back, keeping whole would retry the ones that DID and hit guardduplicate. only rows this call
    / attempted (dead`idx) are touched, so an unrelated tickerplant's dead row is left alone
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
  / resolve tickerplant handles by proctype and/or procname, projected to (procname;proctype;w) -
  / ported from TorQ .sub.getsubscriptionhandles (see subscriptions.md for callers).
  / the two arguments are NOT interchangeable: ` matches EVERY row, () matches NONE and switches the
  / combine from intersection to union - rdb/wdb pass [types;()], chainedtp/sctp pass [`;name].
  / two deliberate differences from legacy's contract: the `attributes` filter is DROPPED (di.servers
  / carries no such column), and autoopen is gone (di.servers retries dead connections itself).
  / di.servers is a hard `use` dependency here, not injected - see deps.q
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
