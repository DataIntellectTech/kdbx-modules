/ di.subscriptions - subscribe a process (e.g. di.torq.proc.rdb) to a tickerplant. In one flow it
/ fetches the schema + log details via the TP's subdetails call, defines the tables locally,
/ replays the pre-subscription log EXACTLY once (via di.tplogmgr.replayupto, using the
/ message counts the TP reported at subscription time), then lets live updates flow through the
/ root `upd`. Ported/simplified from TorQ/code/common/subscriptions.q (.sub).
/ ---
/ Two tickerplant protocols are supported, chosen the way TorQ's own .sub.subscribe chooses
/ (subscriptions.q:92-105): read a root `tptype` off the handle, defaulting to `standard when the
/ variable is undefined.
/   `standard  - di.torq.proc.tickerplant and di.torq.proc.chainedtp. Publish `.u.subdetails,
/                returning `tables`schemas`logfile`rowcount`date - ONE log file, one count.
/   `segmented - di.torq.proc.segmentedtp. Publishes a bare `subdetails, returning
/                `schemalist`logfilelist`rowcounts`date`logdir - MANY log files, one
/                (msgcount;logfile) pair each, because it splits the day's log by design.
/ NB `rowcounts` (segmented) counts ROWS and is NOT a replay bound - -11! is message-limited, and
/ the message counts live inside logfilelist. A closed segment reports the 0W sentinel, which
/ di.tplogmgr.replayupto already treats as "replay the whole file", so it needs no special case.
/ ---
/ Scope (critical path): connect+subscribe+replay for a co-located subscriber (it reads the TP
/ log files directly, same filesystem - the classic tick assumption). Not yet:
/ auto-reconnect/resubscribe, filtered-column subscriptions, remote-log streaming.

/ registry schema - the template init seeds the live registry from. Named apart from the live
/ state so each name has one meaning (bare module-local names and .z.m are the same storage).
/ `active` mirrors TorQ's own .sub.SUBSCRIPTIONS column, and carries the same meaning: the handle this
/ subscription was made over has not been seen to close. It is the load-bearing half of the reconnect
/ design this module will grow - in TorQ, .sub.pc only ever WRITES it and three other functions read
/ it (dedupe, retry selection, and GC of dead rows)
registryschema:([]handle:`int$();tabs:();syms:();subtime:`timestamp$();active:`boolean$());

/ module state that exists before init has run
initdone:0b;

/ config values arrive as booleans, symbols (a .q settings file), strings (.toml or a command-line
/ override) or numbers, so coerce at the point of use. Three traps this avoids:
/   - `boolean$ on a string gives one boolean PER CHARACTER, and using that in a conditional throws
/   - a single-character string is a char ATOM, so it never matches a multi-character word
/   - `boolean$ on a symbol throws outright, though a .q settings file is exactly where symbols come from
/ An unrecognised word SIGNALS rather than defaulting to false: a typo in a setting is a configuration
/ error, and silently reading it as "off" is how a safety setting gets disabled unnoticed.
/ NB the `1 and `0 words are LOAD-BEARING - do not trim them in a tidy-up. A command-line override
/ arrives as a STRING, and di.torq.proc.chainedtp's integration suite passes `-replay 1
/ -clearlogonsubscription 1` (test_integration.q:175,238) precisely to exercise that path, as
/ test_integration_ctp.q:4-7 states. Two integration tests depend on "1" coercing to true.
truewords:`true`yes`on`t`y`1;
falsewords:`false`no`off`f`n`0;

tobool:{[x]
  if[-1h=type x;:x];
  if[type[x] in -4 -5 -6 -7 -8 -9h;:0<>x];
  if[not type[x] in -11 -10 10h;
    '"di.subscriptions: cannot read ",(-3!x)," as a boolean"];
  w:`$lower $[-11h=type x;string x;(),x];
  if[w in truewords;:1b];
  if[w in falsewords;:0b];
  '"di.subscriptions: cannot read ",(-3!x)," as a boolean; expected one of ",", " sv string truewords,falsewords
  };

requireinit:{[ctx]
  / init is what wires the logger, so this cannot go through raiseerror - there is nothing to log
  / through yet. Without it a pre-init call fails deep inside on an unset name, reporting a module
  / internal (".m.di.0subscriptions.registry") rather than the actual mistake
  if[not .z.m.initdone;
    '"di.subscriptions: ",string[ctx],": init must be called before any other function"];
  };

checkdep:{[deps;k;fns;hint]
  / one injected dependency: present, a dict, and carrying the functions this module calls. Plain
  / signals - init is what wires the logger, so there is nothing to log through yet. Matches the
  / checkdep in di.torq.proc.segmentedtp and di.torq.proc.chainedtp
  if[not k in key deps;'"di.subscriptions: ",(string k)," dependency is required - ",hint];
  if[99h<>type deps k;'"di.subscriptions: ",(string k)," dependency must be a dict - ",hint];
  if[count missing:fns except key deps k;
    '"di.subscriptions: ",(string k)," dependency is missing ",", " sv string missing];
  };

/ .z.pc, registered through the injected handlers dep. The whole body, exactly as TorQ's .sub.pc:
/ mark the subscription dead, nothing more. It deliberately does NOT resubscribe - there is no
/ reconnect path in this stack yet, and half of one here would be worse than none. What it buys now
/ is that subscribed[] stops answering 1b for a tickerplant that has gone away.
pcfunc:{[w]
  .z.m.registry:update active:0b from .z.m.registry where handle~\:w;
  };

init:{[config;deps]
  / wire the injected deps, read config and reset the subscription registry
  if[99h<>type config;'"di.subscriptions: config must be a dict"];
  checkdep[deps;`log;`info`warn`error;"see di.util.log"];
  checkdep[deps;`handlers;`register`remove;"see di.torq.handlers"];
  .z.m.log:deps`log;
  .z.m.handlers:deps`handlers;
  .z.m.tp:use`di.tplogmgr;          / for replayupto (repair-aware, count-limited -11!)
  .z.m.registry:registryschema;
  / a simple event, so the phase is ` (null) - di.torq.handlers rejects anything else for .z.pc.
  / Re-registering the same name replaces it in place, so a repeat init is safe
  (.z.m.handlers`register)[`.z.pc;`;`subscriptions;0;pcfunc];
  / a log file that cannot be replayed is logged and SKIPPED by default, so a subscriber comes up with
  / the data it can still get. Set failonreplayerror to make it fatal instead: a consumer whose own
  / state must faithfully mirror the tickerplant's - di.torq.proc.chainedtp raises today for exactly
  / this reason - cannot accept silently incomplete history
  .z.m.failonreplayerror:$[`failonreplayerror in key config;tobool config`failonreplayerror;0b];
  .z.m.initdone:1b;                 / LAST - so a part-way failure leaves the module uninitialised
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so a failure is observable in the log and
  / not only as an exception the caller may swallow
  .z.m.log[`error][ctx;msg];
  '"di.subscriptions: ",string[ctx],": ",msg;
  };

/ which tickerplant is on the other end of this handle? sends a function that reads the root
/ `tptype` ON THE TICKERPLANT, defaulting to `standard where the variable is undefined - exactly
/ TorQ's probe. di.torq.proc.tickerplant and di.torq.proc.chainedtp define none; only
/ di.torq.proc.segmentedtp publishes one.
gettptype:{[tph]
  r:@[tph;({@[value;`tptype;`standard]};`);{[e](`probeerr;e)}];
  if[`probeerr~first r;
    raiseerror[`subscribe;"could not read tptype from the tickerplant: ",last r]];
  if[not -11h=type r;
    raiseerror[`subscribe;"tickerplant reported a non-symbol tptype: ",-3!r]];
  r
  };

/ the subscription call itself - the ROOT NAME differs by protocol, so this has to be decided
/ before the call, not after it: a segmented TP has no `.u.subdetails to answer.
callsubdetails:{[tph;tptype;tabs;syms]
  $[tptype=`standard;
    tph(`.u.subdetails;tabs;syms);
    tptype in `chained`segmented;
    tph(`subdetails;tabs;syms);
    raiseerror[`subscribe;"unrecognised tickerplant type: ",string tptype]]
  };

/ tablename!schema dict from whichever protocol answered. segmented returns `schemalist, a list
/ of (table;schema) pairs; standard returns `schemas, already a dict.
getschemas:{[sd]
  $[`schemalist in key sd;
    (sd[`schemalist][;0])!sd[`schemalist][;1];
    sd`schemas]
  };

/ the (msgcount;logfile) pairs to replay, normalised to the segmented shape. A standard TP's
/ single logfile/rowcount becomes a one-element list, so one loop serves both - as TorQ's own
/ standard branch does (it builds enlist(.u`i`L)).
getlogpairs:{[sd]
  if[`logfilelist in key sd; :sd`logfilelist];
  / nothing logged yet, or logging disabled on the TP (tplogdir unset -> rowcount stays 0 and logfile
  / is `): there is no history to replay and that is not an error. A missing log file is only a fault
  / when the TP claims it logged something
  if[0=sd`rowcount; :()];
  lf:sd`logfile;
  if[null lf;
    raiseerror[`replay;"TP reports ",(string sd`rowcount)," logged message(s) but no log file - cannot replay"]];
  enlist(sd`rowcount;lf)
  };

/ filtering replay wrapper installed as root `upd` during log replay: forward only rows
/ for subscribed tables/syms to the real upd. Live data is already TP-filtered; only the
/ log needs filtering to match a narrowed subscription. For a segmented TP this matters even
/ more - each physical file holds the messages of EVERY table written to it, including tables
/ outside this request, so the filter has to span the whole replay.
/ x is the stamped payload: time first, sym second - either one column per field, or one ATOM per
/ field. The atom form is not hypothetical: di.torq.proc.tickerplant's stamp[] deliberately keeps an
/ atom row atomic and LOGS it that way, enlisting only on the publish path. Indexing an atom row's
/ sym gives an atom, and `where` on an atom throws 'type - which runreplay would catch and report as
/ a skipped file, losing the whole log silently. Normalise to columns before filtering.
/ a table payload is also accepted, so the one function covers every shape a consumer can be handed
/ (di.torq.proc.chainedtp's private twin of this did, and that difference is how the two drifted)
ascols:{[d]
  d:$[98h=type d;value flip d;d];
  $[0>type first d;enlist each d;d]
  };

replayfilter:{[origupd;tabs;syms;t;x]
  if[not $[tabs~`;1b;t in tabs]; :()];        / skip tables we didn't subscribe to
  x:ascols x;
  if[not syms~`; x:x@\:where x[1] in syms];   / keep only subscribed syms (col 1)
  if[not count first x; :()];                 / the filter emptied the batch - nothing to forward
  origupd[t;x];
  };

/ protected count-limited replay through root `upd`; returns the count, or (`replayerr;e).
runreplay:{[lf;n] .[{[m;lf;n](m`replayupto)[lf;n]};(.z.m.tp;lf;n);{[e](`replayerr;e)}]};

/ one physical log file. By default a file that fails to replay is logged and SKIPPED, not fatal: the
/ subscriber comes up with a real (possibly partial) dataset and a log entry naming the bad file,
/ rather than refusing to subscribe because one older segment is corrupt. This is TorQ's own
/ policy - .sub.replay wraps each file in its own protected block and continues the loop.
/ failonreplayerror flips it to fail-fast for a consumer that cannot accept partial history.
replayone:{[pair]
  r:runreplay[pair 1;pair 0];
  if[-7h<>type r;
    if[.z.m.failonreplayerror;
      raiseerror[`replay;"replay failed for ",(string pair 1),": ",last r]];
    .z.m.log[`error][`subscriptions;"replay failed for ",(string pair 1),": ",last r];
    :0];
  .z.m.log[`info][`subscriptions;"replayed ",(string r)," message(s) from ",string pair 1];
  r
  };

/ every file in order; returns the total replayed. NB the count guard is load-bearing: `sum ()` is `()`,
/ not 0, so an empty pair list (a segmented TP with nothing logged for the requested tables) would
/ otherwise return a generic list and fail the -7h type check downstream
replayall:{[pairs] $[count pairs;sum replayone each pairs;0]};

/ replay the pre-subscription history, filtered to the subscribed tables/syms. NB module-namespace
/ boundary: a `use`-loaded module cannot create/populate ROOT tables via bare symbols (they land in
/ the module's private namespace) - so table creation uses @[`.;name;:;..] and replay drives the
/ ROOT `upd` (which di.torq.proc.rdb sets to `insert` at root). For the common all/all subscription
/ we don't wrap upd at all; for a narrowed subscription we install a root-level filter wrapper ONCE
/ around the whole loop and restore the original after, success or failure.
doreplay:{[pairs;tabs;syms;alltabs]
  if[(tabs~`) and syms~`; :replayall pairs];
  origupd:$[`upd in key `.;`. `upd;{[t;x]}];
  @[`.;`upd;:;replayfilter[origupd;$[tabs~`;alltabs;(),tabs];syms]];
  n:.[replayall;enlist pairs;{[e](`replayerr;e)}];
  @[`.;`upd;:;origupd];                                / restore, success or failure
  if[-7h<>type n;raiseerror[`replay;"replay failed: ",last n]];
  n
  };

/ the dict subscribe returns. A standard TP's own dict is passed through, so existing consumers
/ (di.torq.proc.rdb, wdb, chainedtp - which asserts the classic key set with `in`, so extra keys are
/ fine) are unaffected. A segmented TP's dict is normalised to carry the same
/ `tables`schemas`rowcount`date those consumers read, plus its own extra keys. No `logfile` key is
/ synthesised: its absence is the honest signal that `logfilelist` is authoritative.
/ ---
/ `rowcount` keeps its protocol-native meaning - the count the TP REPORTED for a standard TP, the
/ replayed total for a segmented one, where no comparable reported total exists (closed segments
/ report the 0W sentinel, so summing them is meaningless).
/ `replayed` is added for BOTH and is always the number of messages that actually made it through
/ root `upd`. Without it a caller cannot distinguish a clean replay from one where every file was
/ skipped: the default policy logs and continues, so a standard TP's dict would still report the
/ TP's claim while nothing at all had landed, and di.torq.proc.rdb would log that claim as fact.
normalisedetails:{[sd;schemas;replayed]
  if[not `logfilelist in key sd; :sd,(enlist`replayed)!enlist replayed];
  `tables`schemas`rowcount`date`logfilelist`logdir`rowcounts`replayed!
    (key schemas;schemas;replayed;sd`date;sd`logfilelist;sd`logdir;sd`rowcounts;replayed)
  };

replay:{[sd;tabs;syms]
  / replay a subscription's log(s) through the root `upd`, filtered to tabs/syms, and return the
  / number of messages that actually landed. Takes the dict `subscribe` returned, so it speaks both
  / protocols - one (msgcount;logfile) pair for a standard TP, several for a segmented one.
  / ---
  / EXPORTED so a consumer that must sequence its own work around the replay can drive it itself:
  / di.torq.proc.chainedtp calls subscribe with replay off, opens its own log for the date subdetails
  / returned, and only then replays - because a replayed message must not reach upd before that log
  / is open, or the history never lands in it and no downstream can replay it in turn. subscribe
  / cannot do that for it, and calling subdetails twice would double-register.
  / `subscribe` uses this same function, so there is ONE replay path rather than two that drift -
  / which is exactly how chainedtp's private copy came to handle payload shapes this one did not.
  requireinit`replay;
  doreplay[getlogpairs sd;tabs;syms;key getschemas sd]
  };

/ subscribe over an already-open tickerplant handle `tph` (di.torq.proc.rdb obtains it via
/ di.torq.servers). tabs/syms: ` for all, else a list. withreplay: 1b to replay the tp log.
/ Returns the subscription-details dict (tables/schemas/rowcount/date, plus logfile for a
/ standard TP or logfilelist/logdir/rowcounts for a segmented one).
/ define the subscribed tables at ROOT from the returned schemas (they carry g# etc.).
/ @[`.;name;:;schema] targets root explicitly - a bare `name set schema` from inside this module
/ would create the table in the module's private namespace instead.
/ reset=1b (we are about to replay) clears the table first, so the replay lands in a clean table and
/ cannot duplicate rows that are already there. reset=0b leaves an EXISTING table alone: a
/ re-subscribe without replay would otherwise silently discard everything the process had
/ accumulated, which is data loss with no way to notice it.
definetables:{[schemas;reset]
  nms:$[reset;key schemas;(key schemas) except tables[`.]];
  {@[`.;x;:;y]}'[nms;schemas nms];
  };

/ registry rows for a handle. `~\:` rather than `=` because a handle need not be comparable with `=`
/ (a test fixture passes a function), and matching never throws
dropregistry:{[tph] .z.m.registry:.z.m.registry where not (.z.m.registry`handle)~\:tph;};

/ NB the boolean is `withreplay`, not `replay` - `replay` is now an exported function of this module,
/ and a parameter of that name would shadow it inside this very function
subscribe:{[tph;tabs;syms;withreplay]
  requireinit`subscribe;
  tptype:gettptype tph;
  sd:callsubdetails[tph;tptype;tabs;syms];
  schemas:getschemas sd;
  definetables[schemas;withreplay];
  n:$[withreplay;replay[sd;tabs;syms];0];
  / one row per handle - re-subscribing over the same handle replaces its row rather than adding a
  / second, matching the idempotent-re-init convention the rest of the framework relies on
  dropregistry tph;
  .z.m.registry:.z.m.registry,
    ([]handle:enlist tph;tabs:enlist key schemas;syms:enlist syms;subtime:enlist .z.p;active:enlist 1b);
  .z.m.log[`info][`subscriptions;
    "subscribed to ",(", " sv string key schemas)," on ",(string tptype)," tickerplant handle ",string tph];
  normalisedetails[sd;schemas;n]
  };

unsubscribe:{[tph]
  / forget a subscription. The tickerplant is NOT told: di.pubsub drops a subscriber on .z.pc, so a
  / closed handle deregisters itself there. What nothing else clears is OUR record, and a stale row
  / makes subscribed[] answer 1b for a tickerplant that has gone away
  requireinit`unsubscribe;
  if[not any (.z.m.registry`handle)~\:tph;
    raiseerror[`unsubscribe;"no subscription recorded on handle ",-3!tph]];
  dropregistry tph;
  .z.m.log[`info][`subscriptions;"unsubscribed handle ",-3!tph];
  };

teardown:{[]
  / forget every subscription and give back the .z.pc registration, matching the remove-what-you-
  / registered convention in di.torq.proc.chainedtp and di.torq.proc.segmentedtp. The module is
  / dormant afterwards - disconnects stop being tracked until init runs again, which re-registers.
  / Safe to call repeatedly
  requireinit`teardown;
  n:count .z.m.registry;
  .z.m.registry:registryschema;
  (.z.m.handlers`remove)[`.z.pc;`;`subscriptions];
  .z.m.log[`info][`subscriptions;"cleared ",(string n)," subscription record(s)"];
  };

/ is any subscription LIVE? A dropped handle is marked inactive by the .z.pc handler, so this no
/ longer answers 1b for a tickerplant that has gone away. What it still cannot tell you is whether a
/ live-looking subscription is actually receiving data - only that its handle has not closed.
subscribed:{[] requireinit`subscribed; 0<count select from .z.m.registry where active};

/ the active-subscriptions registry (introspection)
getsubscriptions:{[] requireinit`getsubscriptions; .z.m.registry};

getapimeta:{[]
  / callable api for di.torq to register with di.api. init/getapimeta/version are plumbing di.torq
  / calls by convention and are deliberately omitted. one (name;public;descrip;params;return) row
  / per line - flip cols!flip rows.
  :flip `name`public`descrip`params`return!flip(
    (`subscribe;       1b; "subscribe over an open tickerplant handle and replay its log exactly once";
       "[int: tickerplant handle; symbol(list): tables (` for all); symbol(list): syms (` for all); boolean: replay]";
       "dict: tables, schemas, rowcount, date and the log details for the tickerplant's protocol");
    (`replay;          1b; "replay a subscription's log(s) through root upd, for a consumer driving its own sequencing";
       "[dict: the subscription details subscribe returned; symbol(list): tables (` for all); symbol(list): syms (` for all)]";
       "long: messages replayed");
    (`unsubscribe;     1b; "forget the subscription recorded against a tickerplant handle";
       "[int: tickerplant handle]";                                "null");
    (`teardown;        1b; "forget every recorded subscription";
       "[]";                                                       "null");
    (`subscribed;      1b; "is any subscription currently recorded?";
       "[]";                                                       "boolean: 1b if the registry is non-empty");
    (`getsubscriptions;1b; "the active-subscriptions registry";
       "[]";                                                       "table: handle, tabs, syms and subtime"));
  };
