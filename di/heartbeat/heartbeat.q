/ heartbeat module for kdb-x
/ every process can publish a periodic heartbeat over pub/sub so that downstream monitors can detect
/ when a process has stopped beating - i.e. it is stalled or blocked - even when the underlying
/ connection is still valid
/ the module handles both publishing heartbeats and, on the monitoring side, storing received
/ heartbeats and raising warnings / errors when they stop
/ config and dependencies arrive in a single dictionary passed to init: config keys are optional and
/ fall back to the defaults below; log/timer/pubsub are required (servers too when subenabled)
/ and init errors immediately if a required dependency is missing
/ module-local state convention: constants are bare top-level names, mutable state lives in .z.m, and
/ injected dependencies are read through .z.m at every call site

/ ============================================================
/ constants
/ ============================================================

/ table used to publish heartbeats - sym holds the publishing process type
schema:(
  [] time:`timestamp$();
  sym:`symbol$();
  procname:`symbol$();
  counter:`long$();
  pid:`int$();
  host:`symbol$();
  port:`int$()
  );

/ keyed store of the latest received heartbeat per process, with warning / error state
storeschema:update warning:0b,error:0b from `sym`procname xkey schema;

/ keyed count of consecutive sweeps a discovered peer has gone without producing a heartbeat
unseenschema:2!([]sym:`symbol$();procname:`symbol$();sweeps:`long$());

/ the table name published over pub/sub, and the root name di.pubsub discovers it under
tablename:`heartbeat;

/ the dependency keys of the single init dict - everything else in that dict is config.
/ NB handlers stays in this list only to absorb di.torq's uniform wiring: nothing in this module uses
/ it any more (the .z.pc subscription cache it existed for was removed). do not "clean it up" -
/ dropping it makes resolveconfig warn about handlers on every publisher-only boot, which is the
/ common case since subenabled defaults off
depkeys:`log`timer`pubsub`servers`handlers;

/ config defaults. proctype and procname are deliberately absent - they are self-identity and are
/ required, not defaulted, matching di.servers. legacy captured pid/host/port once at load time and
/ so do we, so a runtime port change is not picked up
configdefaults:(
  `enabled`subenabled`debug`publishroot`publishinterval`checkinterval`subscribeinterval,
  `warningtolerance`errortolerance`subscribewarnsweeps`maxage,
  `pid`host`port`connections`onwarning`onerror
  )!(
  1b;0b;1b;1b;0D00:00:30;0D00:00:10;0D00:01:00;
  2f;3f;3;0D24:00:00;
  .z.i;.z.h;`int$system"p";`ALL;{[procs]};{[procs]}
  );

/ timer job ids this module owns - deleted before re-registering so init is safe to call again
jobids:`hbpublish`hbcheck`hbsubscribe;

/ ============================================================
/ module state
/ ============================================================

/ current-time function - heartbeat owns its clock, separate from di.timer's; override via setcp
cp:{.z.p};

/ ============================================================
/ internal helpers
/ ============================================================

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root
  :@[{.z.m.enabled;1b};::;0b];
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a
  / throw. init's own dependency validation signals with a plain ' - the logger is not wired yet
  .z.m.logerr[ctx;msg];
  '"di.heartbeat: ",string[ctx],": ",msg;
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger and the config
  if[not initialised[];
    '"di.heartbeat: ",string[ctx],": init must be called before any other function"];
  };

tosecs:{[span]
  / di.timer mode-2 periods are in whole seconds; legacy expressed these intervals as timespans
  :`int$span%0D00:00:01;
  };

warningperiod:{[processtype]
  / grace period before a process is flagged warning - takes the process type so a deployment can
  / vary it per type, as legacy documented
  :`timespan$warningtolerance*publishinterval;
  };

errorperiod:{[processtype]
  / grace period before a process is flagged error
  :`timespan$errortolerance*publishinterval;
  };

resolveconnections:{[]
  / `ALL is the shipped default and means every connected process type. legacy converts the sentinel
  / to a null symbol, which .servers.getservers treats as match-all
  :$[`ALL in (),connections;`;connections];
  };

arity:{[f]
  / parameter count of a lambda - value f returns (bytecode;params;...) so index 1 is the param list
  :count value[f]1;
  };

safecall:{[ctx;nm;f;arg]
  / run an injected function in isolation and log any failure instead of letting it propagate.
  / both call sites here are reached from a di.timer job, and di.timer disables a job that throws
  / (addjob.opts sets disableonfail:1b), so an unprotected failure would PERMANENTLY stop heartbeating
  / or heartbeat checking - the very thing this module exists to provide. one broken callback, or one
  / transient publish failure, must not take the mechanism down with it. this is the same reasoning
  / di.handlers applies to its post phase: a watcher must not be able to change the outcome
  @[f;arg;{[ctx;nm;e] .z.m.logerr[ctx;(string nm)," failed: ",e]}[ctx;nm]];
  };

validhandles:{[handles]
  / drop nulls (a dead server row) and handle 0. a "remote" call on handle 0 evaluates LOCALLY, so
  / subscribing it registers this process as a subscriber to its own heartbeats and then publishes
  / to handle 0. legacy guarded exactly this by seeding its subscribedhandles with 0 0Ni
  / (heartbeat.q:21)
  / a negative handle is an ASYNC handle in q, and this guard is LOAD-BEARING rather than defensive
  / now that subscribeone sends with (neg h): neg of an already-negative handle is POSITIVE, so a
  / negative handle slipping through here would silently become the blocking synchronous call the
  / async switch exists to remove
  h:(),handles;
  :h where not (null h) or 0i>=h;
  };

/ ============================================================
/ init - dependency validation and config
/ ============================================================

validatedeps:{[deps]
  / log, timer and pubsub are always required; servers only when this process monitors others.
  / nested if guards rather than and - and evaluates both sides eagerly, so key would be
  / reached on a non-dict. no dependency is ever silently defaulted
  if[99h<>type deps;
    '"di.heartbeat: deps must be a dict of injectables + config - see di.log, di.timer, di.pubsub"];
  if[not all `log`timer`pubsub in key deps;
    '"di.heartbeat: log, timer and pubsub dependencies are required (see di.log, di.timer, di.pubsub); got: ",
      (", " sv string key deps)];
  if[99h<>type deps`log;
    '"di.heartbeat: log value must be a dict; pass `info`warn`error functions - see di.log"];
  if[not all `info`warn`error in key deps`log;
    '"di.heartbeat: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.heartbeat: timer value must be a dict (see di.timer)"];
  if[not all `addjob`deletejobs in key deps`timer;
    '"di.heartbeat: timer dict must expose `addjob and `deletejobs (see di.timer)"];
  if[99h<>type deps[`timer]`addjob;
    '"di.heartbeat: timer`addjob must be a variant dict (see di.timer addjob.custom/default/simple)"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.heartbeat: timer`addjob must expose the `custom variant [id;func;params;period;mode;opts]"];
  if[99h<>type deps`pubsub;
    '"di.heartbeat: pubsub value must be a dict (see di.pubsub)"];
  if[not all `publish`subscribe in key deps`pubsub;
    '"di.heartbeat: pubsub dict must expose `publish and `subscribe (see di.pubsub)"];
  if[not all `proctype`procname in key deps;
    '"di.heartbeat: proctype and procname (self-identity) are required in deps - they are published ",
      "as the heartbeat's sym and procname and have no sensible default"];
  if[not all -11h=type each deps`proctype`procname;
    '"di.heartbeat: proctype and procname must be symbols"];
  if[any null deps`proctype`procname;
    '"di.heartbeat: proctype and procname must not be null - they identify this process in every ",
      "published heartbeat and key the monitor's store, so null ones collide every publisher ",
      "into a single row"];
  };

validatemonitordeps:{[deps]
  / servers is required only when subenabled - a publisher-only process does not need it. split out
  / so the conditional in init stays a single statement, per the style guide.
  / NB no handlers requirement: this module registered a .z.pc observer solely to prune a cache of
  / subscribed handles, and that cache is gone. a handlers dict passed anyway is silently accepted
  / (see depkeys) so di.torq's uniform wiring keeps working unchanged
  if[99h<>type deps`servers;
    '"di.heartbeat: subenabled is set, so a servers dependency is required (see di.servers)"];
  if[not `getservers in key deps`servers;
    '"di.heartbeat: servers dict must expose `getservers (see di.servers)"];
  };

resolveconfig:{[deps]
  / merge the config half of the single init dict over the defaults, warning about anything
  / unrecognised rather than dropping it silently. depkeys are dependencies, not config
  config:(key[deps] except depkeys,`proctype`procname)#deps;
  if[count unknown:(key config) except key configdefaults;
    .z.m.logwarn[`init;"ignoring unrecognised config key(s): ",", " sv string unknown]];
  :configdefaults,(key[configdefaults] inter key config)#config;
  };

validateconfig:{[cfg]
  / catch config that would leave the module quietly doing nothing rather than failing loudly
  if[not all -1h=type each cfg`enabled`subenabled`debug`publishroot;
    raiseerror[`init;"enabled, subenabled, debug and publishroot must be booleans"]];
  if[not all -16h=type each cfg`publishinterval`checkinterval`subscribeinterval;
    raiseerror[`init;"publishinterval, checkinterval and subscribeinterval must be timespans"]];
  / di.timer schedules in whole SECONDS and tosecs rounds, so anything under half a second becomes a
  / period of 0 - a job that then runs on every timer cycle. reject the whole sub-second range rather
  / than silently accept a schedule that cannot be represented
  if[any 0D00:00:01>cfg`publishinterval`checkinterval`subscribeinterval;
    raiseerror[`init;"publishinterval, checkinterval and subscribeinterval must be at least one ",
      "second - di.timer schedules in whole seconds, so a shorter interval cannot be represented"]];
  / the never-beaten warning counts sweeps, so a non-positive threshold would either fire on a peer
  / that has had no chance to answer yet, or (at 0) never match the post-increment count at all
  if[not -7h=type cfg`subscribewarnsweeps;
    raiseerror[`init;"subscribewarnsweeps must be a long"]];
  if[1>cfg`subscribewarnsweeps;
    raiseerror[`init;"subscribewarnsweeps must be at least 1 - it counts consecutive sweeps a ",
      "discovered peer has gone without heartbeating, and the count starts at 1"]];
  if[not all -9h=type each cfg`warningtolerance`errortolerance;
    raiseerror[`init;"warningtolerance and errortolerance must be floats"]];
  / a zero or negative tolerance makes the grace period zero or negative, so now>time+period is true
  / the instant a process is seen and every process sits permanently in error. also catches 0n
  if[any 0>=cfg`warningtolerance`errortolerance;
    raiseerror[`init;"warningtolerance and errortolerance must be positive - a non-positive ",
      "tolerance flags every process immediately and permanently"]];
  if[cfg[`errortolerance]<=cfg`warningtolerance;
    raiseerror[`init;"errortolerance must exceed warningtolerance, else a process reaches error ",
      "before warning and the warning transition never fires"]];
  if[not all 100h=type each cfg`onwarning`onerror;
    raiseerror[`init;"onwarning and onerror must be unary functions taking the affected rows"]];
  / arity is checked, not just type: applying a two-argument callback to one argument yields a
  / PROJECTION rather than throwing, so a wrong-arity callback is silently never called and never
  / logged - the same silent-projection shape as a two-argument init
  if[not all 1=arity each cfg`onwarning`onerror;
    raiseerror[`init;"onwarning and onerror must take exactly one argument (the affected rows); a ",
      "callback of any other arity is silently never called, it just yields a projection"]];
  if[-16h<>type cfg`maxage;
    raiseerror[`init;"maxage must be a timespan (0Wn to keep every process forever)"]];
  / an evicted row must always have had its error transition first, otherwise a process could vanish
  / from the store without anyone ever being told it had stopped
  if[not cfg[`maxage]>`timespan$cfg[`errortolerance]*cfg`publishinterval;
    raiseerror[`init;"maxage must exceed the error period (errortolerance*publishinterval), so a ",
      "process always reaches its error transition before it can be evicted"]];
  / not an error - an explicit empty list is a legal way to say "monitor nothing" - but it is the
  / same shape as legacy's in-file connections:() default, where the whole monitor path silently did
  / nothing. say so rather than let it look configured
  if[cfg[`subenabled] and 0=count (),cfg`connections;
    .z.m.logwarn[`init;"subenabled is set but connections is empty - this process will monitor ",
      "nothing. use `ALL, or list the process types to watch"]];
  };

validateroot:{[cfg]
  / check the root name is available BEFORE init writes any state. claiming it is the only step that
  / can fail on something outside this module, and letting installroot throw part-way through init
  / would leave the module marked initialised, with config written and deps wired, but with no
  / timers and no root table - so publishheartbeat would happily run and publish into a
  / topic di.pubsub cannot serve. exactly the silent failure this module exists to avoid
  if[not cfg`publishroot;:()];
  if[not tablename in tables[];:()];
  / rootowned is unset until the first init has run, so read it defensively
  if[@[{rootowned};::;0b];:()];
  raiseerror[`init;"a table named ",(string tablename)," already exists at root and was not ",
    "created by this module - refusing to use it. if it is left over from an earlier load of ",
    "di.heartbeat, remove it (the publish table is always an empty schema holder, so nothing is ",
    "lost); if it belongs to another module, rename one of them or run with publishroot:0b"];
  };

/ ============================================================
/ root namespace - the publish schema and the remote-subscribe entry point
/ ============================================================

ensureroottable:{[]
  / put the publish schema at root, but NEVER take over a table this module did not create - not even
  / a column-identical one. matching columns are not evidence that a table means the same thing:
  / "identifier plus timestamp plus a few status fields" is a common shape, and adopting on that basis
  / would silently co-mingle this module's liveness rows with whatever the real owner stores there.
  / this is a reachable collision rather than a defensive hypothetical - di.subscriptions installs
  / subscribed schemas at root, so a monitor watching a tickerplant that carries `heartbeat has one.
  / there is deliberately no adoption path: the publish table is only ever an empty schema holder
  / (rows go out over pub/sub, never into it), so a stale one from an earlier load costs nothing to
  / remove, and "the columns matched" is far too weak a signal to hand over a name on
  if[not tablename in tables[];
    set[tablename;schema];
    .z.m.rootowned:1b;
    :()];
  / already there and we created it on an earlier init - keep ownership and leave the table alone
  if[rootowned;:()];
  raiseerror[`installroot;"a table named ",(string tablename)," already exists at root and was not ",
    "created by this module - refusing to use it. if it is left over from an earlier load of ",
    "di.heartbeat, remove it (the publish table is always an empty schema holder, so nothing is ",
    "lost); if it belongs to another module, rename one of them or run with publishroot:0b"];
  };

installroot:{[]
  / di.pubsub discovers publishable tables by scanning ROOT tables[] when its own init runs, and
  / resolves each name with value, so the schema must exist at root under the published name or
  / publish is a silent no-op. legacy does exactly this at heartbeat.q:112
  ensureroottable[];
  / the remote-subscribe entry point. a monitor cannot subscribe itself by calling di.pubsub.subscribe
  / locally - that function reads the CALLER's .z.w - so it makes a synchronous IPC call to this name
  / instead. during that inbound call .z.w is the monitor's connection back to us, so the subscription
  / lands against the right handle. this is the mechanism legacy uses at heartbeat.q:92
  / NB a root table `heartbeat and a root namespace .heartbeat do not collide - verified both orders
  set[`.heartbeat.subscribe;{[] .z.m.pubsubsubscribe[tablename;`]}];
  .z.m.rootinstalled:1b;
  .z.m.loginfo[`installroot;"published root names ",(string tablename)," and .heartbeat.subscribe"];
  };

droprootnames:{[]
  / publishroot is off - remove anything an earlier init published. leaving the names behind would let
  / di.pubsub keep serving the topic and let a remote monitor subscribe SUCCESSFULLY and then receive
  / nothing for the life of the process, while believing it is watching us. a monitor that is silently
  / watching a dead topic is worse than one that fails to subscribe at all
  if[not rootinstalled;:()];
  uninstallroot[];
  .z.m.loginfo[`init;"publishroot is 0b - root names published by an earlier init have been removed"];
  };

uninstallroot:{[]
  / remove the live names installroot created. the root table goes only if WE created it - an adopted
  / one belongs to another part of the process. the empty .heartbeat namespace slot itself remains,
  / since q has no way to remove one
  if[rootowned;![`.;();0b;enlist tablename]];
  ![`.heartbeat;();0b;enlist `subscribe];
  / release the claim, so a later init re-evaluates whoever owns the name by then
  .z.m.rootowned:0b;
  .z.m.rootinstalled:0b;
  };

/ ============================================================
/ wiring - timers
/ ============================================================

registertimers:{[]
  / mode 2 = period after the previous ACTUAL start. a heartbeat asserts "alive now", so missed beats
  / must not be replayed as a catch-up storm, which mode 1 would do. periods are in whole seconds.
  / di.timer's addjob throws on a duplicate id, so clear ours first and init stays safe to re-run
  .z.m.timerdeletejobs jobids;
  if[enabled;
    .z.m.timeraddjob[`custom][`hbpublish;publishheartbeat;();tosecs publishinterval;2;()!()];
    .z.m.timeraddjob[`custom][`hbcheck;checkheartbeat;();tosecs checkinterval;2;()!()]];
  if[subenabled;
    .z.m.timeraddjob[`custom][`hbsubscribe;hbsubscriptions;();tosecs subscribeinterval;2;()!()]];
  };

/ ============================================================
/ monitor side - subscribing to other processes' heartbeats
/ ============================================================

subscribeone:{[h]
  / ask the REMOTE publisher to subscribe us. calling di.pubsub.subscribe locally cannot work - it
  / reads the caller's own .z.w and so can only ever subscribe the caller.
  / sent ASYNC: .z.w still resolves to the monitor's connection during an async inbound call, so the
  / handshake is unaffected, and an async send to a hung peer returns in microseconds where the sync
  / call blocked for the FULL duration of the hang. that mattered because this runs inside a di.timer
  / job on a single thread - a peer that is merely slow (a gc pause, a heavy query) stalled
  / publishheartbeat and checkheartbeat with it, so the monitor went quiet to ITS monitors.
  / a LOCAL failure (a dead or null handle) still throws here and is still logged; a REMOTE failure is
  / invisible to an async send, which is what trackunseen exists to catch
  / the error handler's first parameter is named hdl, not h: the projection [h] supplies the outer
  / handle either way, but reusing the name would shadow it and a later refactor could silently bind
  / the wrong value (raised on PR #109 and worth keeping fixed)
  @[{[h] (neg h)(`.heartbeat.subscribe;::)};h;
    {[hdl;e] .z.m.logerr[`subscribeone;"failed to send heartbeat subscribe on handle ",
      (string hdl),": ",e]}[h]];
  };

trackunseen:{[rows]
  / an async subscribe cannot report a REMOTE failure (a root-name collision on the publisher, a
  / di.pubsub that has not initialised there, a refused call), so watch for the consequence instead:
  / a peer we have subscribed to that never produces a beat. a null counter means an addprocs seed
  / rather than an observation - the same discriminator evictstale uses. warned once, at exactly the
  / threshold sweep, so a permanently broken peer does not log forever.
  / NB the count is rebuilt from the CURRENT discovered set each sweep, so a peer that drops out of
  / di.servers' view and comes back starts again from 1. that is deliberate: a connectivity blip is
  / not the continuously-stuck subscribe this warning exists to catch, and only an uninterrupted run
  / of pending sweeps should trip it
  if[not all `proctype`procname in cols rows;:()];
  / the threshold is hoisted into a LOCAL first: a qsql where clause inside module code cannot resolve
  / a module-level name and throws 'subscribewarnsweeps. same reason checkheartbeat hoists wp and ep
  n:subscribewarnsweeps;
  live:select sym:proctype,procname from rows;
  observed:select sym,procname from 0!hb where not null counter;
  pending:select sym,procname from live where not ([]sym;procname) in observed;
  carried:select from 0!unseen where ([]sym;procname) in pending;
  fresh:select sym,procname,sweeps:0 from pending where not ([]sym;procname) in `sym`procname#carried;
  .z.m.unseen:2!update sweeps:sweeps+1 from carried,fresh;
  due:select from 0!unseen where sweeps=n;
  / NB "no heartbeat", not "never heartbeated" - a peer whose row was evicted by maxage re-enters this
  / set, and it HAS beaten before, just not recently. the alert is still correct; the wording must be
  if[count due;
    .z.m.logwarn[`hbsubscriptions;"subscribed to ",(string count due)," peer(s) with no heartbeat in ",
      (string n)," sweeps - the remote subscribe may have failed (an async subscribe cannot report a ",
      "remote error): ",", " sv string exec procname from due]];
  };

resetdiscovery:{[]
  / internal - forget what this monitoring session learned about peer discovery. all three vars move
  / together because they are ONE mechanism, and resetting only everdiscovered would be worse than
  / resetting none: a carried-over emptysweeps already past a new, lower threshold never equals it
  / again, so the discovered-nothing warning would silently never fire for the new configuration -
  / and a carried-over emptywarned would let the next recovery close out an outage from the old one.
  / NB the heartbeat store, its counter and unseen are deliberately NOT reset here: the store persists
  / across re-init by design, and unseen is rebuilt from the current discovered set on every sweep, so
  / it self-heals where these three do not
  .z.m.everdiscovered:0b;
  .z.m.emptysweeps:0;
  .z.m.emptywarned:0b;
  };

emptysweepmsg:{[]
  / internal - the two ways of discovering nothing have completely different diagnoses, so the message
  / says which one this is. a monitor that has NEVER seen a peer is usually still coming up: di.servers
  / connects on its own retry cycle, which in a staggered rollout can easily outlast a few sweeps. one
  / that HAD peers and now has none has lost them - not a startup condition at all, and it reads very
  / differently to whoever is on call
  if[everdiscovered;
    :"every previously-discovered peer has gone - ",(string subscribewarnsweeps)," consecutive ",
      "sweeps found none. the peers may be down, or di.servers may have dropped their connections"];
  :"no peer discovered yet, after ",(string subscribewarnsweeps)," consecutive sweeps - on a cold ",
    "start the peers may simply still be coming up, in which case this resolves itself and a ",
    "recovery line follows. otherwise check that connections names process types di.servers is ",
    "actually connected to (see heartbeat.md)";
  };

warnemptysweeps:{[]
  / internal - count consecutive sweeps that discovered no usable peer at all, and warn ONCE at the
  / threshold. deliberately cause-AGNOSTIC: it watches the consequence, not any single cause, so it
  / stays correct whatever the reason - a connections list naming a process type di.servers never
  / connects to, a servers dependency returning nothing, or peers that are simply all down. that also
  / means it needs no maintenance as those causes come and go - it survived the di.servers getservers
  / fix unchanged. reuses subscribewarnsweeps: it is the same "consecutive sweeps" unit as the
  / never-beaten warning
  .z.m.emptysweeps:emptysweeps+1;
  if[emptysweeps<>subscribewarnsweeps;:()];
  / record that a warning was actually EMITTED, rather than leaving the recovery line to re-derive it
  / from the counter. a re-init may change subscribewarnsweeps, and comparing a carried-over count
  / against a new threshold claimed a recovery for an outage that had never been reported
  .z.m.emptywarned:1b;
  .z.m.logwarn[`hbsubscriptions;emptysweepmsg[]];
  };

notediscovery:{[n]
  / internal - peers are visible again. if we had already warned, close the loop with an info line:
  / a cold start that merely took longer than the threshold would otherwise leave a lone warning in
  / the log with nothing to say it resolved, which is the failure mode of every "it warned once and
  / then went quiet" alert. the recovery line is what makes the warning safe to act on
  / gated on whether a warning was emitted, NOT on the sweep count against the current threshold -
  / so a recovery line can never appear for an outage nobody was told about.
  / NB "connection(s)": n is the count of distinct usable HANDLES, which is what was actually
  / subscribed. it is not necessarily the number of server rows, since handles are deduped
  / logged at WARN, not info, even though recovery is good news: the discovered-nothing warning fires
  / exactly ONCE, so if its resolution went to a lower level then anyone whose pipeline filters to
  / warn and above would see the alert and never the close-out - which is the dangling-alert problem
  / this line exists to remove. matching the alert's level is what makes a once-only warning safe
  if[emptywarned;
    .z.m.logwarn[`hbsubscriptions;"peer discovery recovered - now watching ",(string n),
      " connection(s)"];
    .z.m.emptywarned:0b];
  .z.m.everdiscovered:1b;
  .z.m.emptysweeps:0;
  };

getheartbeats:{[proctypes]
  / di.servers.getservers returns a TABLE of server rows - the handles are its w column, and a
  / disconnected row carries a null handle.
  / ONE CALL PER PROCTYPE, deliberately, even though di.servers.getservers now accepts a list: a bare
  / symbol is the one shape EVERY version of that contract takes, so this works against a di.servers
  / that predates the null/list support as well as one that has it. an older build throws on a list,
  / and di.timer's disableonfail would then end monitor discovery for the process lifetime - a
  / permanent failure to buy an optimisation worth one call per proctype per sweep
  pts:(),proctypes;
  / an empty connections list is a LEGAL "monitor nothing" configuration - init warns about it rather
  / than rejecting it - so it must be a clean no-op here. without this guard `each` over no proctypes
  / razes to a general empty list, which exec cannot read: it threw 'type on every sweep. clear the
  / never-beaten counters too, since nothing is being monitored to be pending about.
  / NB returning here also bypasses warnemptysweeps, deliberately: discovering nothing is exactly what
  / was asked for, and it was already warned about once at init - repeating it every sweep is noise
  if[0=count pts;
    .z.m.unseen:unseenschema;
    :()];
  rows:raze {[pt] .z.m.serversgetservers pt} each pts;
  / distinct across the per-proctype results: a well-behaved servers impl puts each row under exactly
  / one proctype, but a repeated entry in connections would otherwise send the same peer two subscribes
  handles:distinct validhandles exec w from rows;
  / no tracked handle set: di.pubsub dedupes subscribers by .z.w, so a repeat subscribe is a no-op on
  / the publisher and an async send costs nothing worth caching around. tracking handles here was
  / actively harmful - a handle number is not an identity, kdb+ reissues the lowest free descriptor,
  / and hclose does not fire .z.pc, so a stale entry made the monitor skip a live peer forever
  if[count handles;
    notediscovery count handles;
    .z.m.loginfo[`getheartbeats;"subscribing to heartbeat handle(s) ",", " sv string handles];
    subscribeone each handles];
  / a monitor configured to watch something that nonetheless discovers NOTHING is the exact
  / looks-configured-but-silent failure this module exists to eliminate - say so rather than sit quiet
  if[0=count handles;warnemptysweeps[]];
  / only peers we ACTUALLY attempted are candidates for the never-beaten warning. a row carrying a
  / null handle (a disconnected server) or handle 0 was deliberately skipped, so warning that it never
  / heartbeated would be a false alarm about a peer we never asked
  trackunseen[select from rows where w in handles];
  };

hbsubscriptions:{[]
  / timer job - pick up any newly connected publisher of a configured process type. isolated for the
  / same reason the publish call and the callbacks are: di.timer's addjob.opts defaults
  / disableonfail:1b, so an unprotected throw does not skip one sweep, it ends monitor discovery for
  / the lifetime of the process
  safecall[`hbsubscriptions;`sweep;getheartbeats;resolveconnections[]];
  };

/ ============================================================
/ warning / error transitions
/ ============================================================

logwarnproc:{[r]
  .z.m.logwarn[`checkheartbeat;"process ",(string r`procname)," (type ",(string r`sym),
    ") has not heartbeated since ",string r`time];
  };

logerrproc:{[r]
  .z.m.logerr[`checkheartbeat;"process ",(string r`procname)," (type ",(string r`sym),
    ") has not heartbeated since ",string r`time];
  };

evictstale:{[now]
  / forget processes that have been silent for longer than maxage, so a monitor does not grow without
  / bound. the store is keyed on sym+procname, so anything that churns identities - containers with
  / generated names, a process restarting under a new procname - adds a row per incarnation that
  / would otherwise live for the life of the monitor.
  / eviction is by AGE, never by row count: a dead process has an old timestamp by definition, so
  / evicting "the oldest N" would discard exactly the rows worth keeping.
  / a row that has never heartbeated (null counter) came from addprocs and is operator intent, not an
  / observation - forgetting one would silently stop reporting a process you declared you expected.
  / those are removed only by removeprocs. maxage is validated to exceed the error period, so an
  / evicted row has always fired its error transition first
  if[0Wn=maxage;:()];
  flat:0!hb;
  / only an ALREADY-ERRORED row may be evicted. validating maxage > the error period is not enough on
  / its own: it only guarantees the transition would have fired had a check run in between, and a
  / monitor that was paused, restarted, or handed a beat carrying an old timestamp gets its first
  / check when the row is already past maxage - which evicted it without anyone ever being told the
  / process had stopped. gating on error makes "forgotten only after being reported" structurally
  / true instead of dependent on check cadence. the row simply survives one extra check cycle
  keep:(null flat`counter) or (not flat`error) or not now>flat[`time]+maxage;
  if[all keep;:()];
  .z.m.loginfo[`checkheartbeat;"evicting ",(string sum not keep)," process(es) silent for longer ",
    "than maxage: ",", " sv string flat[`procname] where not keep];
  .z.m.hb:2!flat where keep;
  };

warn:{[procs]
  / move processes into warning state, log the transition and fire the warning callback. state is
  / updated BEFORE the callback runs, so an isolated callback failure cannot leave the store wrong
  if[debug;logwarnproc each 0!procs];
  .z.m.hb:hb upsert select sym,procname,warning:1b from procs;
  safecall[`checkheartbeat;`onwarning;onwarning;procs];
  };

err:{[procs]
  / move processes into error state, log the transition and fire the error callback.
  / NB warning is deliberately NOT cleared here, so an escalated process carries warning:1b AND
  / error:1b. both flags are literally true - it is past both thresholds - and this matches legacy
  / (heartbeat.q:71,77 set each flag independently and never clear). only a fresh heartbeat clears
  / them, in storeheartbeat. queried on PR #109; keeping legacy semantics, and a consumer rendering
  / both columns should treat error as taking precedence
  if[debug;logerrproc each 0!procs];
  .z.m.hb:hb upsert select sym,procname,error:1b from procs;
  safecall[`checkheartbeat;`onerror;onerror;procs];
  };

/ ============================================================
/ public api
/ ============================================================

publishheartbeat:{[]
  / publish one heartbeat row and bump the counter - timer job
  requireinit[`publishheartbeat];
  if[not enabled;:()];
  row:enlist `time`sym`procname`counter`pid`host`port!
    (cp[];proctype;procname;hbcounter;pid;host;port);
  / publishroot 0b means do NOT publish at all - not "publish privately". without the root schema
  / table di.pubsub can never serve this topic (its init scans root tables[] and resolves each name
  / with value), so publishing would build and discard a row on every tick, forever. retain it
  / locally instead, where getownhb can still read it and nothing touches root namespace
  / the publish is isolated: a transient pub/sub failure must not permanently disable this timer job.
  / the counter still advances, so it counts beats ATTEMPTED and a gap in what subscribers received
  / stays visible to them
  $[publishroot;
    safecall[`publishheartbeat;`publish;.z.m.pubsubpublish[tablename;];row];
    .z.m.ownhb:row];
  .z.m.hbcounter:hbcounter+1;
  };

checkheartbeat:{[]
  / flag processes that have not heartbeated within the warning / error grace periods - timer job
  / status: 0 healthy, 1 warning, 2+ error. grace periods are computed as locals first, since module
  / functions do not resolve inside qsql
  requireinit[`checkheartbeat];
  / NB cp[] is deliberately outside any safecall. setcp probes the clock once at swap time, so a
  / clock with external dependencies could still throw here and take this job out under di.timer's
  / disableonfail. accepted as a much narrower risk than the sweep's (see hbsubscriptions), not missed
  now:cp[];
  / evict first: maxage is validated to exceed the error period, so nothing can be evicted before it
  / has already been through its error transition
  evictstale[now];
  t:0!hb;
  if[not count t;:()];
  wp:warningperiod each t`sym;
  ep:errorperiod each t`sym;
  stats:update status:(`short$now>time+wp)+`short$2*now>time+ep from t;
  newwarn:select sym,procname,time from stats where status=1,not warning;
  newerr:select sym,procname,time from stats where status>1,not error;
  if[count newwarn;warn newwarn];
  if[count newerr;err newerr];
  };

storeheartbeat:{[batch]
  / store incoming heartbeats, keeping the latest per process and clearing warning / error state.
  / call this from the consuming process's own upd when a heartbeat arrives - deliberately NOT an
  / automatic upd hook, which legacy composed at load time and which breaks on load order
  requireinit[`storeheartbeat];
  / validated up front so a malformed payload names itself in the log, rather than surfacing as a
  / raw 'sym from the select below and bypassing the logger entirely
  if[98h<>type batch;
    raiseerror[`storeheartbeat;"batch must be an unkeyed table of heartbeat rows; got type ",
      string type batch]];
  if[not count batch;:()];
  / time is required, not just sym and procname: checkheartbeat compares now against time+period, so
  / a row without one can never warn or error
  if[not all `sym`procname`time in cols batch;
    raiseerror[`storeheartbeat;"batch must carry sym, procname and time columns; got: ",
      ", " sv string cols batch]];
  / the type is checked too, not just presence: a date column reaches the keyed upsert and throws a
  / raw 'type that bypasses the logger entirely
  if[12h<>type batch`time;
    raiseerror[`storeheartbeat;"the time column must be a timestamp vector; got type ",
      string type batch`time]];
  / tolerate a publisher on a newer schema by keeping the columns we know and ignoring the rest.
  / rejecting the batch outright would make a version-skewed publisher look DEAD to this monitor,
  / which is a far worse failure than dropping a column we have no use for. warn only when the
  / unexpected set changes, so skew stays visible without a log line per beat
  if[count extra:(cols batch) except cols schema;
    if[not extra~warnedcols;
      .z.m.warnedcols:extra;
      .z.m.logwarn[`storeheartbeat;"ignoring unrecognised heartbeat column(s) - publisher may be ",
        "on a newer schema: ",", " sv string extra]]];
  rows:((cols schema) inter cols batch)#batch;
  / a null time is permanently invisible to checkheartbeat: now>time+period is never true against a
  / null, so such a process could never be flagged however long it stays silent. drop it loudly
  if[count bad:select from rows where null time;
    .z.m.logwarn[`storeheartbeat;"dropping heartbeat row(s) with a null time - they could never be ",
      "flagged as stale: ",", " sv string distinct exec procname from bad]];
  rows:select from rows where not null time;
  if[not count rows;:()];
  .z.m.hb:hb upsert update warning:0b,error:0b from select by sym,procname from rows;
  };

addprocs:{[proctypes;procnames]
  / seed the store with expected processes so one that never heartbeats at all is still flagged.
  / prepended, so a real heartbeat arriving later wins
  requireinit[`addprocs];
  pt:(),proctypes;
  pn:(),procnames;
  if[not all 11h=type each (pt;pn);
    raiseerror[`addprocs;"proctypes and procnames must be symbols or symbol lists"]];
  if[not (count pt)=count pn;
    raiseerror[`addprocs;"proctypes and procnames must be the same length; got ",
      (string count pt)," and ",string count pn]];
  / counter stays null, which is what marks the row as operator intent rather than an observation:
  / evictstale keeps it forever, and only removeprocs will clear it
  seed:2!([]sym:pt;procname:pn;time:cp[];counter:0N;pid:0Ni;host:`;port:0Ni;warning:0b;error:0b);
  .z.m.hb:seed,hb;
  };

removeprocs:{[proctypes;procnames]
  / forget the named processes entirely - the counterpart to addprocs. needed because a seeded row is
  / deliberately never evicted on age, so without this a decommissioned process declared via addprocs
  / could never be removed from the store at all
  requireinit[`removeprocs];
  pt:(),proctypes;
  pn:(),procnames;
  if[not all 11h=type each (pt;pn);
    raiseerror[`removeprocs;"proctypes and procnames must be symbols or symbol lists"]];
  if[not (count pt)=count pn;
    raiseerror[`removeprocs;"proctypes and procnames must be the same length; got ",
      (string count pt)," and ",string count pn]];
  drop:([]sym:pt;procname:pn);
  .z.m.hb:2!delete from 0!hb where ([]sym;procname) in drop;
  };

subscribe:{[handles]
  / subscribe to heartbeats on the given remote handle(s). the send is async, so a failure on the
  / REMOTE side is not reported here - the sweep's never-beaten warning is what surfaces that
  requireinit[`subscribe];
  h:(),handles;
  if[not type[h] within 5 7h;
    raiseerror[`subscribe;"handles must be integers; got type ",string type h]];
  valid:validhandles h;
  if[count skipped:h except valid;
    .z.m.logwarn[`subscribe;"skipping handle(s) that cannot be subscribed - 0i is this process ",
      "itself and a null handle is a dead server row: ",", " sv string skipped]];
  subscribeone each valid;
  };

gethb:{[]
  / the store of heartbeats RECEIVED from other processes
  requireinit[`gethb];
  :hb;
  };

getownhb:{[]
  / the last heartbeat this process produced. under publishroot 0b this is the only record of it,
  / since nothing is published; under publishroot 1b it is empty and the row went out over pub/sub
  requireinit[`getownhb];
  :ownhb;
  };

setcp:{[f]
  / replace the current-time function - used by tests and simulation
  requireinit[`setcp];
  if[not type[f] within 100 112h;raiseerror[`setcp;"f must be a function returning a timestamp"]];
  / call it once and check the result type. a clock returning anything else does NOT throw inside
  / checkheartbeat - the staleness comparison just silently evaluates false against every row, so
  / monitoring would quietly stop flagging anything at all rather than failing loudly
  probe:@[f;::;{[e] '"di.heartbeat: setcp: the clock function threw when called: ",e}];
  if[not -12h=type probe;
    raiseerror[`setcp;"the clock function must return a timestamp; got type ",string type probe]];
  .z.m.cp:f;
  };

teardown:{[]
  / release everything init installed: the timer jobs and the root names
  requireinit[`teardown];
  .z.m.timerdeletejobs jobids;
  / keyed off what is actually installed, NOT off the current config - a re-init that flipped
  / publishroot off would otherwise leave teardown unable to clean up its own residue
  if[rootinstalled;uninstallroot[]];
  .z.m.enabled:0b;
  .z.m.subenabled:0b;
  / a monitor re-inited after teardown is typically watching a DIFFERENT set of process types, and is
  / cold starting in every sense that matters to whoever reads the log - so it must get the cold-start
  / wording, not "every previously-discovered peer has gone"
  resetdiscovery[];
  .z.m.loginfo[`teardown;"di.heartbeat torn down - timer jobs and root names released"];
  };

init:{[deps]
  / wire the injected deps and this process's config from ONE dict, then install the timer jobs and
  / the root names (when publishroot). idempotent - a second call clears its own timer jobs first and
  / re-registers, leaving the heartbeat store intact
  / deps: `log`timer`pubsub (required), `servers` (required when subenabled),
  /       `proctype`procname (required identity), plus any config key alongside them.
  / a `handlers` key is accepted and ignored, so di.torq's uniform wiring needs no special case
  / e.g. hb.init[(`log`timer`pubsub!(logdep;timerdep;psdep)),`proctype`procname!(`rdb;`rdb1)]
  validatedeps[deps];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  cfg:resolveconfig[deps];
  if[cfg`subenabled;validatemonitordeps[deps]];
  validateconfig[cfg];
  / every validation that can fail runs here, before a single byte of module state is written
  validateroot[cfg];
  .z.m.timeraddjob:(deps`timer)`addjob;
  .z.m.timerdeletejobs:(deps`timer)`deletejobs;
  .z.m.pubsubpublish:(deps`pubsub)`publish;
  .z.m.pubsubsubscribe:(deps`pubsub)`subscribe;
  if[cfg`subenabled;
    .z.m.serversgetservers:(deps`servers)`getservers];
  / first init only - a re-init must not discard heartbeats already received
  if[not initialised[];
    .z.m.hb:storeschema;
    .z.m.ownhb:0#schema;
    .z.m.unseen:unseenschema;
    resetdiscovery[];
    .z.m.rootowned:0b;
    .z.m.rootinstalled:0b;
    .z.m.warnedcols:`symbol$();
    .z.m.hbcounter:0];
  .z.m.config:cfg;
  .z.m.proctype:deps`proctype;
  .z.m.procname:deps`procname;
  / written out one key at a time rather than looped over cfg: an explicit .z.m.<name>: write is the
  / documented form, it keeps every config key greppable, and it does not lean on dynamic .z.m indexing
  .z.m.enabled:cfg`enabled;
  .z.m.subenabled:cfg`subenabled;
  .z.m.debug:cfg`debug;
  .z.m.publishroot:cfg`publishroot;
  .z.m.publishinterval:cfg`publishinterval;
  .z.m.checkinterval:cfg`checkinterval;
  .z.m.subscribeinterval:cfg`subscribeinterval;
  .z.m.warningtolerance:cfg`warningtolerance;
  .z.m.errortolerance:cfg`errortolerance;
  .z.m.subscribewarnsweeps:cfg`subscribewarnsweeps;
  .z.m.maxage:cfg`maxage;
  .z.m.pid:cfg`pid;
  .z.m.host:cfg`host;
  .z.m.port:cfg`port;
  .z.m.connections:cfg`connections;
  .z.m.onwarning:cfg`onwarning;
  .z.m.onerror:cfg`onerror;
  / reconcile the root names FIRST. this is the one step that can fail on external state (a foreign
  / table already at that name), so failing here leaves the process untouched rather than
  / half-configured with timers already publishing into a topic di.pubsub cannot serve
  $[publishroot;installroot[];droprootnames[]];
  if[not publishroot;
    .z.m.loginfo[`init;"publishroot is 0b - nothing published at root and no pub/sub publishing; ",
      "own heartbeats are tracked locally and readable via getownhb"]];
  registertimers[];
  / NB the index expressions are parenthesised deliberately. juxtaposition binds to the WHOLE
  / right-hand expression, so ("disabled";"enabled")enabled,", monitoring ",... parses as
  / ("disabled";"enabled")[enabled,", monitoring ",...] - indexing by the rest of the string, which
  / yields a nested list rather than a flat one. di.log rejects that with 'type; a permissive mock
  / logger does not, which is exactly why this survived a green suite
  .z.m.loginfo[`init;"di.heartbeat initialised - proctype ",(string proctype),", procname ",
    (string procname),", publishing ",(("disabled";"enabled")enabled),", monitoring ",
    (("disabled";"enabled")subenabled)];
  };

getapimeta:{[]
  / one row per CALLABLE api function, for di.torq to register with di.api. init and getapimeta are
  / plumbing di.torq calls by convention and are deliberately omitted. names are bare
  :flip `name`public`descrip`params`return!flip(
    (`teardown;         1b; "release the timer jobs and the published root names";
       "[]";                                            "null");
    (`version;          1b; "module version string";
       "[]";                                            "string: version");
    (`publishheartbeat; 1b; "publish one heartbeat row over pub/sub and bump the counter";
       "[]";                                            "null");
    (`checkheartbeat;   1b; "flag processes that have not heartbeated within the grace periods";
       "[]";                                            "null");
    (`storeheartbeat;   1b; "store incoming heartbeats, latest per process, clearing warning/error";
       "[table: heartbeat rows]";                       "null");
    (`addprocs;         1b; "seed the store with expected processes so a silent one is still flagged";
       "[symbol|list: proctypes; symbol|list: procnames]"; "null");
    (`removeprocs;      1b; "forget the named processes entirely - the counterpart to addprocs";
       "[symbol|list: proctypes; symbol|list: procnames]"; "null");
    (`subscribe;        1b; "subscribe to heartbeats on the given remote handle(s)";
       "[int|list: handles]";                           "null");
    (`gethb;            1b; "the store of heartbeats received from other processes";
       "[]";                                            "table: keyed on sym,procname");
    (`getownhb;         1b; "the last heartbeat this process produced (populated when publishroot is 0b)";
       "[]";                                            "table: zero or one row");
    (`setcp;            1b; "replace the module's current-time function, for tests and simulation";
       "[function: niladic returning a timestamp]";     "null"));
  };
