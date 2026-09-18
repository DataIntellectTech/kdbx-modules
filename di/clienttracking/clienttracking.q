/ track the client sessions connected to a KDB-X process in a session table
/ consumes di.torq.handlers (injected) to observe connection open/close and, once a query owner
/ exists, to count per-request usage - it never assigns .z.* directly
/ NB the exported `version` is defined in init.q (read from the VERSION file), not here

/ ============================================================
/ constants (load-time)
/ ============================================================

/ session table schema - one row per client session; an open session has a null endp
/ w is grouped for fast per-handle lookup; hits/sz are longs
clientschema:([]
  w:`g#`int$();          / connection handle (.z.w at open)
  ipa:`symbol$();        / client ip address, dotted-decimal
  u:`symbol$();          / client user (.z.u at open)
  a:`int$();             / client ip address, raw int (.z.a at open)
  startp:`timestamp$();  / session start - connection open time
  endp:`timestamp$();    / session end - connection close time; null while open
  lastp:`timestamp$();   / time of the last request seen from this client
  hits:`long$();         / number of requests served for this client
  sz:`long$());          / total (approximate) bytes of results returned to this client

/ this module's settings, read from the `clienttracking section of the process config; an absent
/ section (or key) takes the default. defaults are TorQ's EFFECTIVE ones from config/settings/default.q
/ (.clients.enabled/opencloseonly/MAXIDLE/RETAIN), not the dotz.q fallbacks that file always overrides
configdefaults:`enabled`maxidle`retain`trackusage!(
  1b;           / register the lifecycle observers at all; 0b wires the log and registers nothing
  0D;           / force-close a live handle idle for longer than this; 0D (the default) disables reaping
  0D02:00:00;   / purge a closed session this long after it ended
  1b);          / count per-request usage (hits/sz/lastp) - the inverse of TorQ's opencloseonly

/ priority used when registering with di.torq.handlers - lower runs first; 0 is a neutral default
handlerpriority:0;

/ the simple connection-lifecycle events observed, and the observer each one gets
lifecycleevents:`.z.po`.z.pc`.z.wo`.z.wc;

/ the phased query events usage counting attaches to (as post-phase watchers). post fires AFTER
/ di.torq.handlers' own transform phase (pre -> exec -> transform -> post), so the result a post
/ handler sees is the same, final, post-transform value the dispatcher returns to the caller -
/ see hitpost below and clienttracking.md's "Design decisions" for why that matters here
usageevents:`.z.pg`.z.ps`.z.ws;

/ ============================================================
/ internal helpers
/ ============================================================

ipa:{[a]
  / format a raw .z.a int ip address as a dotted-decimal symbol
  / .z.a is a signed int32 (high ips are negative); 0x0 vs takes its two's-complement bytes and
  / "i"$ casts each byte UNSIGNED (0-255), so octets >= 128 render correctly (e.g. 192.168.0.1)
  :`$"." sv string "i"$0x0 vs a;
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.clienttracking: ",string[ctx],": ",msg;
  };

track:{[h]
  / record a newly-seen client handle - sweep first, then append an open session row for h
  / a handle being opened cannot still have a genuinely open session, so any open row already carrying h
  / (a close this module never saw - registered late, disabled at the time, or addclient called twice) is
  / closed first; otherwise the OS reusing the handle number would leave two open rows both counting hits
  cleanup[];
  update endp:.z.p from .z.M.clients where w=h,null endp;
  .z.M.clients upsert (h;ipa .z.a;.z.u;.z.a;.z.p;0Np;.z.p;0j;0j);
  };

closeclient:{[h]
  / mark the open session for handle h as closed, then sweep
  update endp:.z.p from .z.M.clients where w=h,null endp;
  cleanup[];
  };

hitpost:{[countsz;result;args]
  / usage post-handler - registered as the projection hitpost[countsz], since di.torq.handlers calls
  / post[result;args]; args is unused. bumps the request count (and lastp) for the calling client (.z.w)
  / countsz: add -22!result to sz. only .z.pg actually sends its handler's return value back to the
  / client; an async (.z.ps) or websocket (.z.ws) handler's return value is discarded by kdb+, so
  / counting it would inflate sz with bytes that were never transferred (TorQ counted all three)
  / runs only on a successful exec (di.torq.handlers post fires after transform, once the owner has
  / returned), so it cannot see errors; on a multithreaded (negative \p) process a global write here
  / hits 'noupdate and is isolated/logged by di.torq.handlers rather than counting
  / amended BY NAME (.z.M.clients is the module-qualified name of .z.m.clients): this is the per-request
  / hot path, and a by-value update would copy three columns of the whole session table every request
  / (measured 24x slower at 50k retained rows)
  bytes:$[countsz;-22!result;0j];
  update lastp:.z.p,hits:hits+1,sz:sz+bytes from .z.M.clients where w=.z.w,null endp;
  };

disableusage:{[]
  / remove any usage post-handlers this module registered (idempotent - di.torq.handlers no-ops an unknown name)
  .z.m.handlers[`remove][;`post;`clienttracking] each usageevents;
  .z.m.usageactive:0b;
  };

reapstatus:{[]
  / say so when idle reaping is configured but cannot run: lastp only advances through the usage
  / watcher, so until it is live on at least one query event every session looks idle and cleanup
  / suspends the reap rather than closing every connection on the process
  if[(0D<.z.m.maxidle) and not .z.m.usageactive;
    .z.m.logwarn[`cleanup;"maxidle is ",string[.z.m.maxidle]," but usage counting is not live on any query event",
      " - idle reaping is suspended until enableusage[] attaches to an exec owner (lastp cannot advance otherwise)"]];
  };

registerlifecycle:{[]
  / register the connection and websocket open/close observers (idempotent - di.torq.handlers replaces in place)
  .z.m.handlers[`register][`.z.po;`;`clienttracking;handlerpriority;track];
  .z.m.handlers[`register][`.z.pc;`;`clienttracking;handlerpriority;closeclient];
  .z.m.handlers[`register][`.z.wo;`;`clienttracking;handlerpriority;track];
  .z.m.handlers[`register][`.z.wc;`;`clienttracking;handlerpriority;closeclient];
  };

removelifecycle:{[]
  / remove the lifecycle observers (idempotent - di.torq.handlers no-ops an unknown name)
  .z.m.handlers[`remove][;`;`clienttracking] each lifecycleevents;
  };

validatedeps:{[deps]
  / strict up-front validation of the injected dependencies - plain signals, the log is not wired yet
  if[99h<>type deps;
    '"di.clienttracking: deps must be a dict with `log and `handlers keys"];
  if[not `log in key deps;
    '"di.clienttracking: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.clienttracking: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.clienttracking: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[not `handlers in key deps;
    '"di.clienttracking: handlers dependency is required; pass di.torq.handlers register/remove/list keyed on `handlers"];
  if[99h<>type deps`handlers;
    '"di.clienttracking: handlers value must be a dict; pass register/remove/list functions"];
  if[not all `register`remove`list in key deps`handlers;
    '"di.clienttracking: handlers dict must have `register`remove`list keys; got: ",(", " sv string key deps`handlers)];
  };

resolveconfig:{[config]
  / take this module's `clienttracking section of the process config and merge it over the defaults
  / an absent section means every default; unknown keys in the section are ignored
  if[99h<>type config;
    raiseerror[`init;"config must be a dict (the process config); clienttracking settings live under its `clienttracking key"]];
  sect:$[`clienttracking in key config;config`clienttracking;()!()];
  if[99h<>type sect;
    raiseerror[`init;"the `clienttracking config section must be a dict"]];
  :configdefaults,(key[configdefaults] inter key sect)#sect;
  };

coercespan:{[k;v]
  / a timespan setting: accept a timespan atom, or - TOML has no timespan type, so a .toml settings file
  / can only carry a string - its string form in q's nDhh:mm:ss literal shape. the D is required because
  / "N"$ reads a bare "900" as 09:00 (hours) and "15:00" as fifteen hours, silently
  if[10h=type v;v:$["D" in v;"N"$v;0Nn]];
  if[not -16h=type v;
    raiseerror[`init;"config key ",string[k]," must be a timespan, or its string form such as \"0D00:15:00\""]];
  if[(null v) or (v<0D) or v=0Wn;
    raiseerror[`init;"config key ",string[k]," must be a finite, non-negative timespan"]];
  :v;
  };

validateconfig:{[cfg]
  / type-check every setting, returning the normalised dict - nested ifs, so a wrong type is reported
  / by name rather than as a raw 'type
  if[not -1h=type cfg`enabled;raiseerror[`init;"config key enabled must be a boolean"]];
  if[not -1h=type cfg`trackusage;raiseerror[`init;"config key trackusage must be a boolean"]];
  cfg[`maxidle]:coercespan[`maxidle;cfg`maxidle];
  cfg[`retain]:coercespan[`retain;cfg`retain];
  :cfg;
  };

/ ============================================================
/ public api
/ ============================================================

init:{[config;deps]
  / wire the required dependencies (log, handlers), resolve this module's config section, then register
  / the lifecycle observers and (when trackusage) the usage watchers - idempotent, a re-init reclaims the
  / same registrations and leaves the session table intact
  / config: the process config dict; settings live under its `clienttracking key (see configdefaults) -
  /         an absent section means every default
  / deps:   `log (required, `info`warn`error binary {[c;m]} funcs) and `handlers (required, di.torq.handlers
  /         register/remove/list); other injectables di.torq passes (`timer, `servers) are accepted and unused
  / example: ct.init[enlist[`clienttracking]!enlist enlist[`maxidle]!enlist 0D01:00:00;`log`handlers!(logdep;hdep)]
  validatedeps deps;
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.handlers:deps`handlers;
  cfg:validateconfig resolveconfig config;
  / one explicit write per key - greppable, and a missing write is visible rather than silently unset
  .z.m.enabled:cfg`enabled;
  .z.m.maxidle:cfg`maxidle;
  .z.m.retain:cfg`retain;
  .z.m.trackusage:cfg`trackusage;
  / whether the usage watcher is live on any query event - set by enableusage/disableusage below; gates idle reaping
  .z.m.usageactive:0b;
  / create the session table on first init only; a re-init must leave the existing table intact
  if[not `clients in key .z.m;.z.m.clients:clientschema];
  / disabled: unhook anything a previous (enabled) init registered, then stop - nothing else is touched
  if[not .z.m.enabled;
    removelifecycle[];
    disableusage[];
    .z.m.loginfo[`init;"di.clienttracking loaded but disabled - no handlers registered"];
    :(::)];
  registerlifecycle[];
  $[.z.m.trackusage;enableusage[];disableusage[]];
  if[not .z.m.trackusage;reapstatus[]];
  .z.m.loginfo[`init;"di.clienttracking initialised - maxidle ",string[.z.m.maxidle],", retain ",string[.z.m.retain]];
  };

getclients:{[]
  / the current client-session tracking table - one row per session (open rows have a null endp)
  :.z.m.clients;
  };

addclient:{[h]
  / manually record a client handle in the tracking table using the current .z context (like TorQ's addw)
  if[not -6h=type h;raiseerror[`addclient;"handle must be an int"]];
  track h;
  };

cleanup:{[]
  / reap sessions whose handle has gone, force-close idle live handles, purge expired closed rows
  / runs automatically on every open/close; also exported so a host can drive it periodically (di.timer)
  / idle reaping needs the usage watcher live (see reapstatus) - lastp cannot advance without it
  / .z.w is never reaped: the handle this call arrived on is mid-request, not idle - its lastp is only
  / bumped by the post watcher AFTER this returns, so without the guard a client calling cleanup[] over
  / IPC while stale would have its own handle closed under it and never see the reply
  now:.z.p;
  update endp:now from .z.M.clients where null endp,not w in key .z.W;
  if[(0D<.z.m.maxidle) and .z.m.usageactive;
    idle:exec w from .z.m.clients where null endp,w in key .z.W,w<>.z.w,lastp<now-.z.m.maxidle;
    if[count idle;
      @[hclose;;::] each idle;
      update endp:now from .z.M.clients where w in idle,null endp];
    ];
  delete from .z.M.clients where not null endp,endp<now-.z.m.retain;
  };

enableusage:{[]
  / (re)wire usage counting onto each phased query event that now has an exec owner; idempotent
  / call again after the query owner (gateway/permissions) is registered, since post cannot attach before exec
  / a deferral is logged at info, not warn - no owner is the normal state of a stock di.torq process; the
  / one thing worth a warn (maxidle configured but unable to run) is reapstatus's job
  / only .z.pg returns its handler's result to the caller, so only its watcher measures bytes (see hitpost)
  active:{[event]
    owned:`exec in exec phase from .z.m.handlers[`list] event;
    if[owned;
      .z.m.handlers[`register][event;`post;`clienttracking;handlerpriority;hitpost[event=`.z.pg]];
      .z.m.loginfo[`enableusage;"usage counting active on ",string event]];
    if[not owned;
      .z.m.loginfo[`enableusage;"usage counting on ",string[event]," deferred: no exec owner yet"]];
    :owned;
    } each usageevents;
  .z.m.usageactive:any active;
  reapstatus[];
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE api function (NOT init/getapimeta/version - those are
  / plumbing/metadata di.torq handles by convention), for di.torq to collect and register with di.api.
  / names are bare; di.torq applies process-wide qualification. one (name;public;descrip;params;return) row per line
  :flip `name`public`descrip`params`return!flip(
    (`getclients; 1b; "current client-session tracking table (open and recently-closed sessions)"; "[]"; "table: one row per session");
    (`addclient;  1b; "manually record a client handle in the tracking table";                     "[int: handle]"; "null");
    (`cleanup;    1b; "run a cleanup sweep - reap gone handles, close idle handles, purge expired"; "[]"; "null");
    (`enableusage;1b; "(re)wire usage counting onto phased query events that now have an exec owner"; "[]"; "null"));
  };
