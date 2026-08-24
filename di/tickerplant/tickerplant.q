/ core tick-capture for the modular torq world: receive updates from feeds, write them to a
/ tickerplant log for recovery, and publish them to subscribers, rolling the log at end of day.
/ orchestrates three hard deps - di.pubsub (subscribe/publish), di.eodtime (roll timing), and
/ di.tplog (log check/repair on recovery) - with an injected log and timer. the pubsub / eodtime /
/ tplog module handles are imported in init.q (module-local) and used here.
/ .
/ NB the tickerplant's data tables live at ROOT, not in .z.m. a tickerplant process owns its tables
/ (feeds insert into them, subscribers replay them), and di.pubsub reads them by name via `value`,
/ so they cannot be module-local. this is the one deliberate root-state exception for this process
/ module; all other mutable state is module-local in .z.m.
/ .
/ NB init also publishes subdetails and tablelist at ROOT - see installroot. they are the subscription
/ protocol di.subscriptions speaks, and an IPC caller reaches them through the default .z.pg/.z.ps,
/ so a module-local binding would be invisible. teardown gives them back.
/ .
/ NB subscriber-disconnect cleanup is handled by di.pubsub's own .z.pc (it self-assigns it, chaining
/ onto whatever already owned the event). di.pubsub's init now ALSO takes an optional `handlers key
/ (di.handlers' register dict) to register that hook with the central registry so it is visible via
/ di.handlers.list[`.z.pc], not just chained through it - this module forwards its own OPTIONAL
/ `handlers dep straight through, unvalidated (di.pubsub validates its own shape), the same way it
/ forwards `log to di.eodtime/di.tplog below. omitting `handlers here is still fully supported -
/ di.pubsub.init[(::)] behaves exactly as before

/ ============================================================
/ constants (load-time)
/ ============================================================

/ default batch publish interval (matches TorQ's 1s system timer); di.timer periods are whole seconds
defaultbatchperiod:0D00:00:01;

/ optional config keys forwarded verbatim to di.eodtime.init
eodtimekeys:`rolltimezone`datatimezone`rolltimeoffset;

/ the root names init publishes and teardown gives back - the subscription protocol di.subscriptions
/ calls over IPC. see installroot
rootnames:`subdetails`tablelist;

/ ============================================================
/ internal helpers
/ ============================================================

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root.
  / schemas has no module-level default - its only value comes from init, so this probe cannot be
  / fooled by a load-time constant of the same name
  :@[{.z.m.schemas;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger. there is no default
  / logger, so without this an early call dies with a bare 'type instead of a usable message
  if[not initialised[];
    '"di.tickerplant: ",string[ctx],": init must be called before any other function"];
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.tickerplant: ",string[ctx],": ",msg;
  };

stamp:{[x]
  / prepend a data-timestamp column unless the update already carries one (first value is a timestamp)
  if[-12h=type first first x;:x];
  a:.z.p+eodtime.getdailyadj[];
  :$[0>type first x;a,x;(enlist(count first x)#a),x];
  };

openlog:{[date]
  / open the tp log for `date`, checking/repairing a pre-existing log via di.tplog; 0i if logging off.
  / records the PATH in .z.m.logpath and RETURNS the handle, which the caller stores in .z.m.logfile.
  / the two are deliberately separate names: writelog tests the handle with >0i, and subdetails has to
  / report the path to subscribers, so one name cannot carry both - it used to try, and the path
  / assignment was dead because every caller overwrote it with the handle
  if[0=count .z.m.logdir;.z.m.logpath:`;:0i];
  l:hsym `$ .z.m.logdir,"/",.z.m.logname,string date;
  if[count key l;l:tplog.check l];
  if[not count key l;l set ()];
  .z.m.logpath:l;
  h:hopen l;
  .z.m.loginfo[`openlog;"logging to ",string l];
  :h;
  };

publishbuffer:{[]
  / batch mode: publish each root table's buffered rows to subscribers then clear them; i catches j.
  / the row counts are taken BEFORE pubclear, which publishes and then empties each table.
  / `. is the explicit ROOT namespace - the captured tables live there, not in .z.m
  .z.m.rowcounts:.z.m.rowcounts+.z.m.tabs!count each `. .z.m.tabs;
  pubsub.pubclear[.z.m.tabs];
  .z.m.i:.z.m.j;
  };

publishrows:{[t;x]
  / zero-latency mode: publish one stamped update immediately, as a table keyed by t's columns, then
  / mark it published. i:j is what makes i the PUBLISHED-message watermark in this mode - without it
  / i never leaves its seeded 0 and every subscriber is told to replay nothing. TorQ does exactly this
  / in chainedtp.q's tickpub (:96-99), and upd calls writelog FIRST so j is already bumped here
  f:cols t;
  d:$[0>type first x;enlist f!x;flip f!x];
  pubsub.publish[t;d];
  .z.m.rowcounts:@[.z.m.rowcounts;t;+;count d];
  .z.m.i:.z.m.j;
  };

writelog:{[t;x]
  / append the update to the tp log (if enabled) and bump the total message count
  if[.z.m.logfile>0i;.z.m.logfile enlist (`upd;t;x);.z.m.j+:1];
  };

logfilelist:{[]
  / internal - the (messagecount;logfile) pairs subdetails reports. a LIST because the protocol also
  / serves a segmented tickerplant, which writes one log per table; this one writes a single log, so
  / there is at most one entry. EMPTY when logging is disabled - di.subscriptions accepts that
  / (subscriptions.q:307) and replays nothing.
  / the count is .z.m.i, the PUBLISHED watermark, NOT .z.m.j. in batch mode a row that has been logged
  / but not yet flushed is still sitting in the buffer, and pubclear publishes the WHOLE table to every
  / registered handle - including one that registered after the row was buffered. so reporting j would
  / have the subscriber replay those rows from the log AND receive them again at the next tick.
  / TorQ sends the same field for the same reason: chainedtp.q:169 puts .u.i in the reply, and
  / kdb+tick's r.q replays with .u`i
  if[null .z.m.logpath;:()];
  :enlist (.z.m.i;.z.m.logpath);
  };

rollcheck:{[now]
  / trigger end-of-day if we have passed the next scheduled roll timestamp
  if[eodtime.getnextroll[]<now;endofday[]];
  };

tick:{[]
  / timer job: in batch mode flush the buffer to subscribers, then check for an end-of-day roll
  if[.z.m.batch;publishbuffer[]];
  rollcheck .z.p;
  };

rolllog:{[]
  / close the current tp log and open a fresh one for the new date; reset message and row counts, as
  / TorQ's refreshtp does (chainedtp.q:136). openlog updates .z.m.logpath alongside the handle
  if[.z.m.logfile>0i;hclose .z.m.logfile];
  .z.m.i:.z.m.j:0;
  .z.m.rowcounts:.z.m.tabs!(count .z.m.tabs)#0;
  .z.m.logfile:openlog .z.m.d;
  };

createtables:{[schemas;fresh]
  / internal - materialise the captured tables at ROOT, applying `g# to any sym column.
  / a FRESH init owns the tables outright and defines every one of them from its schema, attributes
  / included. a RE-INIT defines only names not already at root - a schema key added since the first
  / call - because re-running `nm set schema` over a live tickerplant would discard every buffered row
  / that had been logged but not yet published, leaving the message counts describing data that had
  / just been thrown away
  nms:$[fresh;key schemas;(key schemas) where not (key schemas) in tables[`.]];
  if[0=count nms;:()];
  {[nm;s] nm set $[`sym in cols s;@[s;`sym;`g#];s]}'[nms;schemas nms];
  };

publishroot:{[nm;f]
  / internal - publish ONE root entry point, warning first when the name already holds something that
  / is neither the function about to be installed nor the one this module installed last time.
  / uninstallroot deliberately refuses to delete a binding that is not ours; installing over one
  / silently is that same asymmetry in reverse, and it is how a co-hosted process loses its own
  / bindings without a word. same shape as di.rdb's publishroot
  if[nm in key `.;
    cur:`. nm;
    if[not any (f;.z.m.rootinstalled nm)~\:cur;
      .z.m.logwarn[`installroot;"root ",(string nm)," was already bound to something di.tickerplant ",
        "did not install - replacing it. teardown will not give the previous binding back"]]];
  @[`.;nm;:;f];
  };

installroot:{[]
  / publish the subscription protocol at ROOT, where an IPC caller reaches it through the default
  / .z.pg/.z.ps. a bare module-level assignment lands in this module's private namespace and would
  / never be found:
  /   subdetails - di.subscriptions sends (`subdetails;tabs;syms) and requires the reply keys
  /   tablelist  - di.subscriptions sends (`tablelist;`) to resolve a ` (all tables) request
  / NB the root `upd` is deliberately NOT published here - di.torq wires the process's feed entry
  / point, which may legitimately be a caller-supplied wrapper around this module's upd
  fs:(subdetails;tablelist);
  publishroot'[rootnames;fs];
  / record what was published, so the NEXT install can tell "someone else took this name" apart from
  / a legitimate re-init. written as ONE dict rather than amended per name
  .z.m.rootinstalled:rootnames!fs;
  };

dropifours:{[nm;f]
  / internal - delete a root name only if it still holds the function we installed there
  if[not nm in key `.;:()];
  if[not f~`. nm;:()];
  ![`.;();0b;enlist nm];
  };

uninstallroot:{[]
  / internal - give back exactly what installroot published. only the names still bound to THIS
  / module's functions are removed: a later module that has taken over one of these root names owns it
  / now, and silently deleting its binding would be a worse outcome than leaving ours behind
  dropifours'[rootnames;(subdetails;tablelist)];
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / wire the injected log + timer, initialise the dep modules, materialise the tables at root, open
  / the tp log, publish the subscription protocol at root and schedule the batch/roll timer job.
  / deps: a dict with `log (required), `timer (required), `schemas (required, tablename!schema) and
  /   optional `batch (1b), `batchperiod (timespan), `logdir (string, "" disables logging),
  /   `logname (string), `subtables (symbol list), `handlers (di.handlers' register dict, forwarded
  /   verbatim to di.pubsub.init - see the header note), plus di.eodtime keys (rolltimezone/
  /   datatimezone/rolltimeoffset) forwarded verbatim.
  / dependencies and config are re-applied on EVERY init; RUNTIME state - the date, the message and
  / row counts, and the open log - is seeded only on the FIRST. see the fresh block below
  if[99h<>type deps;
    '"di.tickerplant: deps must be a dict with `log, `timer and `schemas keys"];
  if[not `log in key deps;
    '"di.tickerplant: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.tickerplant: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.tickerplant: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[not `timer in key deps;
    '"di.tickerplant: timer dependency is required; pass di.timer's exports keyed on `timer"];
  if[99h<>type deps`timer;
    '"di.tickerplant: timer value must be a dict exposing addjob"];
  if[not `addjob in key deps`timer;
    '"di.tickerplant: timer dict must expose addjob"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.tickerplant: timer addjob must expose the custom variant"];
  / deletejobs is required because teardown deletes the job init schedules. a dict-valued dep returns
  / a null-shaped value for an absent key rather than erroring, so a missing deletejobs would fail
  / silently inside teardown's protected apply - same reasoning as di.rdb's timer validation
  if[not `deletejobs in key deps`timer;
    '"di.tickerplant: timer dict must expose deletejobs - teardown needs it"];
  if[not (type deps[`timer]`deletejobs) within 100 112h;
    '"di.tickerplant: timer deletejobs must be a function [ids]"];
  if[not `schemas in key deps;
    '"di.tickerplant: schemas is required; pass a tablename!schema dict keyed on `schemas"];
  if[99h<>type deps`schemas;
    '"di.tickerplant: schemas must be a dict of tablename!schema"];
  / is this the FIRST init in this process? read it BEFORE any write, because initialised[] probes
  / schemas and this must reflect the state on entry
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.timer:deps`timer;
  / optional config with defaults - one explicit write per key, so a reader can see at a glance which
  / keys reach module state
  .z.m.batch:$[`batch in key deps;deps`batch;1b];
  .z.m.batchperiod:$[`batchperiod in key deps;deps`batchperiod;defaultbatchperiod];
  .z.m.logdir:$[`logdir in key deps;deps`logdir;""];
  .z.m.logname:$[`logname in key deps;deps`logname;"tp"];
  .z.m.schemas:deps`schemas;
  .z.m.tabs:key deps`schemas;
  / materialise the schemas as root tables (see the header note on root state), applying `g# to sym
  createtables[deps`schemas;fresh];
  / initialise the dependency modules: eodtime (log + tz passthrough), tplog (log), pubsub (over the
  / subscribable tables). tplog now takes an injected log and must be init'd before check is called
  eodtime.init[(enlist[`log]!enlist deps`log),(key[deps] inter eodtimekeys)#deps];
  tplog.init[enlist[`log]!enlist deps`log];
  pubsub.setsubtables[$[`subtables in key deps;deps`subtables;.z.m.tabs]];
  / `handlers is OPTIONAL and forwarded as-is - di.pubsub.init validates its own shape if given, and
  / treats the generic-null argument below exactly like the old niladic pubsub.init[] call
  pubsub.init[$[`handlers in key deps;enlist[`handlers]!enlist deps`handlers;(::)]];
  / RUNTIME state is seeded only on a FRESH init. a re-init - di.torq re-applying config, a config
  / reload, a second wiring - must not rewind a live tickerplant's date, zero the message counts a
  / subscriber replays against, or reopen (and so leak) the log it is already writing to. di.rdb and
  / di.subscriptions set the same precedent; the dependency and config writes above are refreshed
  / unconditionally. consequence, documented in tickerplant.md: a logdir/logname change applies at the
  / next roll rather than immediately
  if[fresh;
    .z.m.d:eodtime.getd[];
    .z.m.i:.z.m.j:0;
    .z.m.rowcounts:.z.m.tabs!(count .z.m.tabs)#0;
    / what installroot last published at root, keyed by name. seeded here rather than at module load
    / because publishroot reads it on the FIRST install, before installroot has written it
    .z.m.rootinstalled:(`$())!();
    .z.m.scheduled:0b;
    .z.m.logfile:openlog .z.m.d];
  installroot[];
  / schedule the timer job that flushes the buffer (batch) and checks the roll; mode 1 = fixed period.
  / guarded on the flag rather than on `fresh` so a teardown-then-init pair re-schedules it - di.timer
  / throws on a duplicate id, and teardown has deleted it. tick reads .z.m.batch live, so the one job
  / serves both modes across re-inits
  if[not .z.m.scheduled;
    .z.m.timer[`addjob][`custom][`tickerplant;tick;();`int$.z.m.batchperiod%0D00:00:01;1h;()!()];
    .z.m.scheduled:1b];
  .z.m.loginfo[`init;"di.tickerplant initialised (",$[.z.m.batch;"batch";"zero-latency"]," mode)"];
  };

teardown:{[]
  / release everything init installed process-wide: the root subscription protocol and the timer job.
  / paired with init's side effects, the way di.rdb's teardown is paired with its root entry points.
  / module state and the CAPTURED TABLES are deliberately left intact - a shutdown path may still need
  / to inspect or save what is buffered; only the process-global bindings are withdrawn
  requireinit[`teardown];
  uninstallroot[];
  / deleting a job that was never scheduled is a no-op in di.timer (a delete-where over the jobs
  / table), so the id does not have to exist. protected only because a timer whose deletejobs throws
  / must not take down a shutdown path - init has already established that it is a function
  @[.z.m.timer[`deletejobs];enlist`tickerplant;{[e] :(::)}];
  .z.m.scheduled:0b;
  .z.m.loginfo[`teardown;"di.tickerplant root entry points and timer job removed"];
  };

upd:{[t;x]
  / feed entry point: stamp the update, then buffer+log (batch) or log+publish (zero-latency).
  / t is the table name, x the column data. wired to root `upd` by di.torq so feeds can call it.
  / NB the ONLY callable export without a requireinit guard, deliberately: this runs once per feed
  / message, and initialised[] is a protected apply costing ~0.7us a call (measured) - a permanent
  / per-message tax to catch a wiring mistake that can only happen at startup and shows up instantly
  / when it does. calling it before init throws a bare '.m.di.0tickerplant.tabs instead of this
  / module's own message; that is the accepted trade. di.rdb's updfn is unguarded for the same reason
  if[not -11h=type t;raiseerror[`upd;"table must be a symbol"]];
  if[not t in .z.m.tabs;raiseerror[`upd;"unknown table ",string t]];
  rollcheck .z.p;
  / empty update carries no data - nothing to stamp/log, but the roll check above still runs
  if[not count x;:()];
  x:stamp x;
  if[.z.m.batch;t insert x;writelog[t;x]];
  / log BEFORE publishing, so publishrows can copy the bumped j into i, and so a message that fails to
  / publish is at least recoverable from the log. TorQ orders it the same way - chainedtp.q:159-161
  if[not .z.m.batch;writelog[t;x];publishrows[t;x]];
  };

subscribe:{[tabs;filters]
  / register a subscriber (delegates to di.pubsub); the kdb+tick .u.sub entry point, for a caller that
  / wants the raw (tables;schemas) reply rather than the subdetails protocol
  requireinit[`subscribe];
  :pubsub.subscribe[tabs;filters];
  };

subdetails:{[tabs;instruments]
  / TorQ's subdetails protocol, published at ROOT by init. di.subscriptions sends
  / (`subdetails;tabs;syms) and requires `schemalist`logfilelist`rowcounts`date
  / (subscriptions.q:20,266,272); asking for the schemas IS the subscription, so this registers the
  / calling handle for live delivery as a side effect.
  / di.pubsub.subscribe returns THREE shapes (pubsub.q:126-137): (tables;schemas) when every requested
  / table exists, (errmsg;(tables;schemas)) when only some do, and a bare errmsg SYMBOL when none do.
  / flip turns the pair into the (tablename;schema) rows schemalist wants
  requireinit[`subdetails];
  r:pubsub.subscribe[tabs;instruments];
  / nothing matched: di.pubsub registered NOTHING (pubsub.q:28,44), so failing here leaves no half
  / subscription behind. raiseerror rather than passing the symbol back - di.subscriptions wraps this
  / call in a protected apply and reports the message verbatim, whereas a bare symbol reaches it as
  / the far less useful "subdetails must return a dictionary, got type -11h"
  if[-11h=type r;raiseerror[`subdetails;"no requested table is published: ",string r]];
  / a PARTIAL match still succeeds: the tables that did match are already registered, so signalling
  / would tell the caller it failed while leaving it subscribed. say so at warn instead
  partial:-11h=type first r;
  if[partial;.z.m.logwarn[`subdetails;string first r]];
  pairs:flip $[partial;last r;r];
  nms:pairs[;0];
  :`schemalist`logfilelist`rowcounts`date!
    (pairs;logfilelist[];nms!0^.z.m.rowcounts nms;.z.m.d);
  };

tablelist:{[x]
  / the tables offered for subscription, so di.subscriptions can resolve a ` (all tables) request
  / (subscriptions.q:31,365). published at ROOT by init.
  / UNARY on purpose - di.subscriptions sends (`tablelist;`), so a niladic {[] ...} would throw 'rank,
  / which it CATCHES and downgrades to asking for ` (subscriptions.q:366-369): a silent degradation
  / that a segmented tickerplant cannot answer. TorQ's own tablelist:{.stpps.t} is unary for the same
  / reason. the argument is accepted and ignored, exactly as legacy does
  requireinit[`tablelist];
  :pubsub.getsubtables[];
  };

endofday:{[]
  / flush any buffer, notify subscribers, roll the tp log, advance eodtime state and reset counts
  requireinit[`endofday];
  if[.z.m.batch;publishbuffer[]];
  pubsub.callendofday[.z.m.d];
  .z.m.d+:1;
  rolllog[];
  eodtime.setnextroll eodtime.getroll[.z.p];
  eodtime.setdailyadj eodtime.getdailyadjustment[];
  .z.m.loginfo[`endofday;"rolled to ",string .z.m.d];
  };

getcounts:{[]
  / message counts and trading date - i (published to subscribers), j (written to the log), d (date).
  / i is the watermark subdetails reports for replay; in batch mode it lags j by whatever is still
  / buffered, and in zero-latency mode the two move together
  requireinit[`getcounts];
  :`i`j`d!(.z.m.i;.z.m.j;.z.m.d);
  };

gettables:{[]
  / the tables this tickerplant captures
  requireinit[`gettables];
  :.z.m.tabs;
  };

getapimeta:{[]
  / callable api for di.torq to register with di.api (init/getapimeta/version are plumbing, omitted)
  :flip `name`public`descrip`params`return!flip(
    (`upd;        1b; "feed entry point - stamp, log and publish (or buffer) an update";
       "[symbol: table; list: column data]";                    "null");
    (`subscribe;  1b; "register a subscriber for tables/syms - the kdb+tick .u.sub entry point";
       "[symbol(list): tables (` for all); filters]";           "list: (tables;schemas), or an error symbol");
    (`subdetails; 1b; "subscribe and return the schemas, log details and counts di.subscriptions needs";
       "[symbol(list): tables (` for all); symbol(list)|dict: syms (` for all)]";
       "dict: schemalist, logfilelist, rowcounts and date");
    (`tablelist;  1b; "the tables offered for subscription, so a ` (all tables) request can be resolved";
       "[ignored - unary because di.subscriptions sends (`tablelist;`)]"; "symbol list: table names");
    (`endofday;   1b; "flush, notify subscribers, roll the log and advance eod state";
       "[]";                                                    "null");
    (`teardown;   1b; "remove the root subscription protocol and the timer job installed by init";
       "[]";                                                    "null");
    (`getcounts;  1b; "published (i) and logged (j) message counts, and the trading date";
       "[]";                                                    "dict: i, j and d");
    (`gettables;  1b; "the tables this tickerplant captures";
       "[]";                                                    "symbol list: table names"));
  };
