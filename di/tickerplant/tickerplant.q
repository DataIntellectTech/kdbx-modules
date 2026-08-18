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
/ NB subscriber-disconnect cleanup is handled by di.pubsub's own .z.pc (it self-assigns it). this
/ module therefore takes no di.handlers dependency. FLAG: di.pubsub should migrate to di.handlers so
/ .z.pc is not assigned outside the central registry - out of scope here, tracked separately.

/ ============================================================
/ constants (load-time)
/ ============================================================

/ default batch publish interval (matches TorQ's 1s system timer); di.timer periods are whole seconds
defaultbatchperiod:0D00:00:01;

/ optional config keys forwarded verbatim to di.eodtime.init
eodtimekeys:`rolltimezone`datatimezone`rolltimeoffset;

/ ============================================================
/ internal helpers
/ ============================================================

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
  / open the tp log for `date`, checking/repairing a pre-existing log via di.tplog; 0i if logging off
  if[0=count .z.m.logdir;:0i];
  l:hsym `$ .z.m.logdir,"/",.z.m.logname,string date;
  if[count key l;l:tplog.check l];
  if[not count key l;l set ()];
  .z.m.logfile:l;
  h:hopen l;
  .z.m.loginfo[`openlog;"logging to ",string l];
  :h;
  };

publishbuffer:{[]
  / batch mode: publish each root table's buffered rows to subscribers then clear them; i catches j
  pubsub.pubclear[.z.m.tabs];
  .z.m.i:.z.m.j;
  };

publishrows:{[t;x]
  / zero-latency mode: publish one stamped update immediately, as a table keyed by t's columns
  f:cols t;
  pubsub.publish[t;$[0>type first x;enlist f!x;flip f!x]];
  };

writelog:{[t;x]
  / append the update to the tp log (if enabled) and bump the total message count
  if[.z.m.logfile>0i;.z.m.logfile enlist (`upd;t;x);.z.m.j+:1];
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
  / close the current tp log and open a fresh one for the new date; reset log message counts
  if[.z.m.logfile>0i;hclose .z.m.logfile];
  .z.m.i:.z.m.j:0;
  .z.m.logfile:openlog .z.m.d;
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / wire the injected log + timer, initialise the dep modules, materialise the tables at root, open
  / the tp log and schedule the batch/roll timer job.
  / deps: a dict with `log (required), `timer (required), `schemas (required, tablename!schema) and
  /   optional `batch (1b), `batchperiod (timespan), `logdir (string, "" disables logging),
  /   `logname (string), `subtables (symbol list), plus di.eodtime keys (rolltimezone/datatimezone/
  /   rolltimeoffset) forwarded verbatim.
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
  if[not `schemas in key deps;
    '"di.tickerplant: schemas is required; pass a tablename!schema dict keyed on `schemas"];
  if[99h<>type deps`schemas;
    '"di.tickerplant: schemas must be a dict of tablename!schema"];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.timer:deps`timer;
  / optional config with defaults
  .z.m.batch:$[`batch in key deps;deps`batch;1b];
  .z.m.batchperiod:$[`batchperiod in key deps;deps`batchperiod;defaultbatchperiod];
  .z.m.logdir:$[`logdir in key deps;deps`logdir;""];
  .z.m.logname:$[`logname in key deps;deps`logname;"tp"];
  / materialise the schemas as root tables (see the header note on root state), applying `g# to sym
  .z.m.schemas:deps`schemas;
  .z.m.tabs:key deps`schemas;
  {[nm;s] nm set $[`sym in cols s;@[s;`sym;`g#];s]}'[.z.m.tabs;value deps`schemas];
  / initialise the dependency modules: eodtime (log + tz passthrough), tplog (log), pubsub (over the
  / subscribable tables). tplog now takes an injected log and must be init'd before check is called.
  eodtime.init[(enlist[`log]!enlist deps`log),(key[deps] inter eodtimekeys)#deps];
  tplog.init[enlist[`log]!enlist deps`log];
  pubsub.setsubtables[$[`subtables in key deps;deps`subtables;.z.m.tabs]];
  pubsub.init[];
  / date, counts, and the tp log for today
  .z.m.d:eodtime.getd[];
  .z.m.i:.z.m.j:0;
  .z.m.logfile:openlog .z.m.d;
  / schedule the timer job that flushes the buffer (batch) and checks the roll; mode 1 = fixed period.
  / guarded so a re-init does not re-add (di.timer.addjob throws on a duplicate id); tick reads
  / .z.m.batch live, so the one job serves both modes across re-inits
  if[not `scheduled in key .z.m;
    .z.m.timer[`addjob][`custom][`tickerplant;tick;();`int$.z.m.batchperiod%0D00:00:01;1h;()!()];
    .z.m.scheduled:1b];
  .z.m.loginfo[`init;"di.tickerplant initialised (",$[.z.m.batch;"batch";"zero-latency"]," mode)"];
  };

upd:{[t;x]
  / feed entry point: stamp the update, then buffer+log (batch) or publish+log (zero-latency).
  / t is the table name, x the column data. wired to root `upd` by di.torq so feeds can call it.
  if[not -11h=type t;raiseerror[`upd;"table must be a symbol"]];
  if[not t in .z.m.tabs;raiseerror[`upd;"unknown table ",string t]];
  rollcheck .z.p;
  x:stamp x;
  if[.z.m.batch;t insert x;writelog[t;x]];
  if[not .z.m.batch;publishrows[t;x];writelog[t;x]];
  };

subscribe:{[tabs;filters]
  / register a subscriber (delegates to di.pubsub); called by downstream processes over IPC
  :pubsub.subscribe[tabs;filters];
  };

endofday:{[]
  / flush any buffer, notify subscribers, roll the tp log, advance eodtime state and reset counts
  if[.z.m.batch;publishbuffer[]];
  pubsub.callendofday[.z.m.d];
  .z.m.d+:1;
  rolllog[];
  eodtime.setnextroll eodtime.getroll[.z.p];
  eodtime.setdailyadj eodtime.getdailyadjustment[];
  .z.m.loginfo[`endofday;"rolled to ",string .z.m.d];
  };

getcounts:{[]
  / current message counts and trading date - i (in the log), j (log plus buffered), d (date)
  :`i`j`d!(.z.m.i;.z.m.j;.z.m.d);
  };

gettables:{[]
  / the tables this tickerplant captures
  :.z.m.tabs;
  };

getapimeta:{[]
  / callable api for di.torq to register with di.api (init/getapimeta/version are plumbing, omitted)
  :flip `name`public`descrip`params`return!flip(
    (`upd;1b;"feed entry point - stamp, log and publish (or buffer) an update";"[symbol table; list data]";"null");
    (`subscribe;1b;"register a subscriber for tables/syms (delegates to di.pubsub)";"[symbol|list tables; filters]";"subscription result");
    (`endofday;1b;"flush, notify subscribers, roll the log and advance eod state";"[]";"null");
    (`getcounts;1b;"current log/buffer message counts and trading date";"[]";"dict `i`j`d");
    (`gettables;1b;"the tables this tickerplant captures";"[]";"symbol list of table names"));
  };
